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
//  tap, and closes as soon as the login's last request (the GetAssertion
//  that needs the user, or MakeCredential) is answered. Every delegate
//  callback checks it comes from the current session: a closed session's
//  invalidation can arrive after the next session has started.
//

import CoreNFC
import Foundation
import UIKit

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
    /// The pending request was already sent again after the key left
    private var retried = false
    /// Times the pending request's session was refused by iOS and restarted
    private var busyRetries = 0
    /// A session is being created on the main thread
    private var starting = false
    /// When the last session was closed or ended. iOS ends a new session
    /// at once ("Session invalidated unexpectedly") when it begins too soon
    /// after the previous one closed, e.g. ssh to a second host right after
    /// the first login's "Done".
    private var lastSessionEnd: DispatchTime?
    private static let sessionCooldown: TimeInterval = 2.5

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
        // GetInfo: from the key's last answer when no key is at hand (one
        // tap less per login), or a generic one without NFC, so libfido2
        // keeps treating the device as a FIDO2 key (it falls back to U2F,
        // and ssh to "device is not fido2", when GetInfo fails)
        if command == Self.commandCBOR && payload == Self.getInfo && !(tag != nil && session != nil) {
            if let cached = UserDefaults.standard.data(forKey: Self.infoKey) {
                return answer(status: 0, payload: cached)
            }
            if !NFCTagReaderSession.readingAvailable {
                return answer(status: 0, payload: Self.genericInfo)
            }
        }
        guard NFCTagReaderSession.readingAvailable else {
            vmLog("security key request, but this device cannot read NFC")
            reportNoNFC()
            return answer(status: Self.errorOther, payload: Data())
        }
        pending = (command, payload)
        retried = false
        busyRetries = 0
        if let tag, session != nil {
            send(to: tag)
        } else if session == nil {
            startSession()
        }
        // Otherwise a session is up and waiting for a key: it takes this request.
    }

    // MARK: Without NFC

    private static let getInfo = Data([0x04])
    private static let infoKey = "Security Key Info"
    /// authenticatorGetInfo's answer for a FIDO2 key in general: versions
    /// FIDO_2_0 and U2F_V2, a zero AAGUID, and options rk and up.
    private static let genericInfo: Data = {
        var cbor: [UInt8] = [0x00, 0xA3, 0x01, 0x82, 0x68]
        cbor += Array("FIDO_2_0".utf8) + [0x66] + Array("U2F_V2".utf8)
        cbor += [0x03, 0x50] + [UInt8](repeating: 0, count: 16)
        cbor += [0x04, 0xA2, 0x62] + Array("rk".utf8) + [0xF5, 0x62] + Array("up".utf8) + [0xF5]
        return Data(cbor)
    }()
    private var reportedNoNFC = false

    /// Says on screen, once, why security keys do not work.
    private func reportNoNFC() {
        guard !reportedNoNFC else { return }
        reportedNoNFC = true
        DispatchQueue.main.async {
            let (title, message): (String, String)
            if UIDevice.current.userInterfaceIdiom == .pad {
                title = "No NFC on This iPad"
                message = "A program in Linux asked for a security key. iSH+ talks to security keys over NFC, which iPads do not have: they work on an iPhone."
            } else {
                title = "iSH+ Cannot Use NFC"
                message = "A program in Linux asked for a security key, but this copy of iSH+ was signed without the NFC Tag Reading capability, so iOS does not let it use NFC. Install iSH+ with a signing profile that includes it. Free Apple IDs, and some sideloaders such as iloader, cannot add it."
            }
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            guard var top = scene?.keyWindow?.rootViewController else { return }
            while let presented = top.presentedViewController { top = presented }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            top.present(alert, animated: true)
        }
    }

    /// Starts an NFC session for the pending request. On the queue.
    private func startSession() {
        guard !starting else { return }
        starting = true
        // Leave iOS time to finish closing the previous session
        var wait: TimeInterval = 0
        if let lastSessionEnd {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - lastSessionEnd.uptimeNanoseconds) / 1e9
            wait = max(0, Self.sessionCooldown - elapsed)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            let session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: queue)
            session?.alertMessage = "Hold your security key near the iPhone."
            queue.async { [self] in
                starting = false
                guard let session else {
                    vmLog("security key: could not create an NFC session")
                    if pending != nil {
                        pending = nil
                        answer(status: Self.errorOther, payload: Data())
                    }
                    return
                }
                guard pending != nil else { return } // cancelled meanwhile
                self.session = session
                DispatchQueue.main.async { session.begin() }
            }
        }
    }

    private func cancel() {
        pending = nil
        endSession(error: nil)
    }

    /// Whether a request ends a login or registration, so the session can
    /// close at once instead of waiting for more requests: MakeCredential,
    /// or a GetAssertion that needs the user (ssh first checks which key
    /// holds the credential with "up": false, then signs).
    private static func isFinal(command: Int, payload: Data) -> Bool {
        guard command == commandCBOR, let ctap = payload.first else { return false }
        if ctap == 0x01 { return true }
        // "up": false in the options map is a text "up" (62 75 70) then false (f4)
        return ctap == 0x02 && payload.range(of: Data([0x62, 0x75, 0x70, 0xF4])) == nil
    }

    private func answer(status: UInt8, payload: Data) {
        guard let port else { return }
        _ = port.write(Data("\(status) \(payload.count)\n".utf8) + payload)
    }

    // MARK: NFC

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        queue.async { [self] in
            // A session this bridge already let go of (closed after an
            // answer or a failure) ends after the next one may have started:
            // it must not touch the current session or its request.
            guard session === self.session else { return }
            self.session = nil
            tag = nil
            closeTimer?.cancel()
            closeTimer = nil
            lastSessionEnd = .now()
            let code = (error as? NFCReaderError)?.code
            vmLog("security key: NFC session ended: \(error.localizedDescription)")
            guard pending != nil else { return }
            // iOS refused the session because the previous one was still
            // closing ("busy", or ended "unexpectedly" right after begin()):
            // try again, waiting longer each time (~2.5 s cooldown plus 1, 2,
            // 3, 4 s). The guest keeps libfido2 waiting with KEEPALIVEs.
            if code == .readerSessionInvalidationErrorSystemIsBusy
                || code == .readerSessionInvalidationErrorSessionTerminatedUnexpectedly,
               busyRetries < 4 {
                busyRetries += 1
                queue.asyncAfter(deadline: .now() + Double(busyRetries)) { [self] in
                    if pending != nil, self.session == nil { startSession() }
                }
                return
            }
            pending = nil
            answer(status: code == .readerSessionInvalidationErrorUserCanceled ? Self.errorCancel : Self.errorTimeout,
                   payload: Data())
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard session === self.session else { return }
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
            switch result {
            case .success(let (data, sw)):
                pending = nil
                // The key's GetInfo, for when no key is at hand
                if command == Self.commandCBOR && payload == Self.getInfo && sw == 0x9000 && data.first == 0 {
                    UserDefaults.standard.set(data, forKey: Self.infoKey)
                }
                if command == Self.commandCBOR {
                    sw == 0x9000 ? answer(status: 0, payload: data) : answer(status: Self.errorOther, payload: Data())
                } else {
                    answer(status: 0, payload: data + Data([UInt8(sw >> 8), UInt8(sw & 0xff)]))
                }
                if Self.isFinal(command: command, payload: payload) {
                    // The login is done: no reason to keep the sheet up
                    endSession(error: nil, message: "Done. You can remove the key.")
                } else {
                    // One tap for the requests of a login: keep the session a bit
                    let close = DispatchWorkItem { [weak self] in self?.endSession(error: nil) }
                    closeTimer = close
                    queue.asyncAfter(deadline: .now() + 5, execute: close)
                }
            case .failure(let error):
                vmLog("security key: \(error.localizedDescription)")
                // Usually the key left the field (the session was kept open
                // from an earlier request): ask for it again, once.
                if !retried, let session {
                    retried = true
                    self.tag = nil
                    DispatchQueue.main.async {
                        session.alertMessage = "Hold your security key near the iPhone again."
                        session.restartPolling()
                    }
                    return
                }
                pending = nil
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

    private func endSession(error: String?, message: String? = nil) {
        closeTimer?.cancel()
        closeTimer = nil
        tag = nil
        guard let session else { return }
        self.session = nil
        lastSessionEnd = .now()
        DispatchQueue.main.async {
            if let error {
                session.invalidate(errorMessage: error)
            } else {
                if let message { session.alertMessage = message }
                session.invalidate()
            }
        }
    }
}
