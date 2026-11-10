//
//  FidoBridge.swift
//  iSH+
//
//  Security keys for Linux: the guest's ishplus-fido is a virtual FIDO key
//  (for ssh's sk-* keys and other libfido2 programs) that forwards each
//  request here over the org.ishplus.fido port ("X <command> <length>\n"
//  and the payload; "C\n" cancels). They are sent to a YubiKey or another
//  FIDO key over NFC (CTAP over ISO 7816: SELECT the FIDO applet, then
//  NFCCTAP_MSG for CTAP2, or the U2F APDU as is), and the answer goes back
//  as "<status> <length>\n" and the payload.
//
//  iOS gives apps no access to security keys over USB, only over NFC, which
//  iPads do not have. The NFC session stays open a few seconds after an
//  answer, so the requests of one login (GetInfo, GetAssertion...) take one
//  tap.
//

import CoreNFC
import Foundation

final class FidoBridge: NSObject, NFCTagReaderSessionDelegate {
    static let shared = FidoBridge()

    private static let fidoAID = Data([0xA0, 0x00, 0x00, 0x06, 0x47, 0x2F, 0x00, 0x01])
    private static let commandCBOR = 0x90
    // CTAP errors sent back when there is no answer from a key
    private static let errorTimeout: UInt8 = 0x2F // CTAP2_ERR_ACTION_TIMEOUT
    private static let errorCancel: UInt8 = 0x2D  // CTAP2_ERR_KEEPALIVE_CANCEL
    private static let errorOther: UInt8 = 0x7F

    private var port: GuestPort?
    private let queue = DispatchQueue(label: "app.ishplus.fido")
    private var session: NFCTagReaderSession?
    private var tag: NFCISO7816Tag?
    private var closeTimer: DispatchWorkItem?
    /// The request waiting for a key
    private var pending: (command: Int, payload: Data)?

    func serve(_ port: GuestPort) {
        self.port = port
        Thread.detachNewThread { [self] in
            guard port.connect() else { return }
            while let line = port.readLine() {
                if line == "C" {
                    queue.async { [self] in cancel() }
                    continue
                }
                let fields = line.split(separator: " ")
                guard fields.count == 3, fields[0] == "X", let command = Int(fields[1]), let length = Int(fields[2]),
                      let payload = port.read(count: length) else { continue }
                queue.async { [self] in handle(command: command, payload: payload) }
            }
        }
    }

    // MARK: Requests

    private func handle(command: Int, payload: Data) {
        guard NFCTagReaderSession.readingAvailable else {
            vmLog("security key request, but this device cannot read NFC")
            return answer(status: Self.errorOther, payload: Data())
        }
        pending = (command, payload)
        if let tag, session != nil {
            send(to: tag)
        } else if session == nil {
            DispatchQueue.main.async { [self] in
                let session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: queue)
                session?.alertMessage = "Hold your security key near the iPhone."
                self.session = session
                session?.begin()
            }
        }
    }

    private func cancel() {
        pending = nil
        endSession(error: nil)
    }

    private func answer(status: UInt8, payload: Data) {
        guard let port else { return }
        _ = port.write(Data("\(status) \(payload.count)\n".utf8) + payload)
    }

    // MARK: NFC

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        queue.async { [self] in
            self.session = nil
            tag = nil
            if pending != nil {
                pending = nil
                let code = (error as? NFCReaderError)?.code
                answer(status: code == .readerSessionInvalidationErrorUserCanceled ? Self.errorCancel : Self.errorTimeout,
                       payload: Data())
            }
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard case .iso7816(let found) = tags.first else {
            session.alertMessage = "That is not a FIDO security key. Try another."
            session.restartPolling()
            return
        }
        session.connect(to: tags.first!) { [self] error in
            queue.async { [self] in
                if let error {
                    vmLog("security key: \(error.localizedDescription)")
                    session.restartPolling()
                    return
                }
                // Select the FIDO applet
                let select = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4, p1Parameter: 0x04,
                                            p2Parameter: 0x00, data: Self.fidoAID, expectedResponseLength: 256)
                found.sendCommand(apdu: select) { [self] _, sw1, sw2, error in
                    queue.async { [self] in
                        guard error == nil, sw1 == 0x90, sw2 == 0x00 else {
                            session.alertMessage = "That key has no FIDO applet. Try another."
                            session.restartPolling()
                            return
                        }
                        tag = found
                        session.alertMessage = "Keep the key near the iPhone."
                        send(to: found)
                    }
                }
            }
        }
    }

    /// Sends the pending request to the key and answers it.
    private func send(to tag: NFCISO7816Tag) {
        guard let (command, payload) = pending else { return }
        closeTimer?.cancel()
        let apdu: NFCISO7816APDU?
        if command == Self.commandCBOR {
            // NFCCTAP_MSG: 80 10 00 00, the CBOR request, extended length
            apdu = NFCISO7816APDU(instructionClass: 0x80, instructionCode: 0x10, p1Parameter: 0x00,
                                  p2Parameter: 0x00, data: payload, expectedResponseLength: 65536)
        } else {
            // U2F (CTAP1): the APDU as is
            apdu = NFCISO7816APDU(data: payload)
        }
        guard let apdu else {
            pending = nil
            return answer(status: Self.errorOther, payload: Data())
        }
        exchange(tag, apdu, collected: Data()) { [self] result in
            pending = nil
            switch result {
            case .success(let (data, sw)):
                if command == Self.commandCBOR {
                    sw == 0x9000 ? answer(status: 0, payload: data) : answer(status: Self.errorOther, payload: Data())
                } else {
                    answer(status: 0, payload: data + Data([UInt8(sw >> 8), UInt8(sw & 0xff)]))
                }
                // One tap for the requests of a login: keep the session a bit
                let close = DispatchWorkItem { [weak self] in self?.endSession(error: nil) }
                closeTimer = close
                queue.asyncAfter(deadline: .now() + 5, execute: close)
            case .failure(let error):
                vmLog("security key: \(error.localizedDescription)")
                answer(status: Self.errorOther, payload: Data())
                endSession(error: "Could not talk to the key. Try again.")
            }
        }
    }

    /// Sends an APDU, following 61xx (GET RESPONSE: more data) and 9100
    /// (NFCCTAP_GETRESPONSE: still processing) to the whole answer.
    private func exchange(_ tag: NFCISO7816Tag, _ apdu: NFCISO7816APDU, collected: Data,
                          completion: @escaping (Result<(Data, Int), Error>) -> Void) {
        tag.sendCommand(apdu: apdu) { [self] data, sw1, sw2, error in
            queue.async { [self] in
                if let error { return completion(.failure(error)) }
                let all = collected + data
                switch (sw1, sw2) {
                case (0x61, let more):
                    let next = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xC0, p1Parameter: 0x00,
                                              p2Parameter: 0x00, data: Data(), expectedResponseLength: more == 0 ? 256 : Int(more))
                    exchange(tag, next, collected: all, completion: completion)
                case (0x91, 0x00):
                    // The key is still working (e.g. waiting for its button)
                    let next = NFCISO7816APDU(instructionClass: 0x80, instructionCode: 0x11, p1Parameter: 0x00,
                                              p2Parameter: 0x00, data: Data(), expectedResponseLength: 65536)
                    queue.asyncAfter(deadline: .now() + 0.1) { [self] in
                        exchange(tag, next, collected: Data(), completion: completion)
                    }
                default:
                    completion(.success((all, Int(sw1) << 8 | Int(sw2))))
                }
            }
        }
    }

    private func endSession(error: String?) {
        closeTimer?.cancel()
        closeTimer = nil
        tag = nil
        guard let session else { return }
        self.session = nil
        DispatchQueue.main.async {
            if let error { session.invalidate(errorMessage: error) } else { session.invalidate() }
        }
    }
}
