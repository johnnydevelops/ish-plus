//
//  OnDevicePairing.swift
//  iSH+
//
//  Pairs iSH+ with the device it runs on (iOS 27+), like StikPair, so the
//  built-in JIT enabler works without a computer: iSH+ poses as a computer
//  ("pairable host", ffi/rppairing), advertises itself over Bonjour, and the
//  user picks it in Settings > Privacy & Security > Developer Mode and types
//  the PIN iSH+ shows (also as a notification, since they are in Settings).
//

import Foundation
import UIKit
import UserNotifications

@_silgen_name("ishplus_pairing_run")
private func ishplus_pairing_run(
    _ name: UnsafePointer<CChar>, _ model: UnsafePointer<CChar>,
    _ ready: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt16,
                             UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<UnsafePointer<CChar>?>?, Int) -> Void,
    _ pin: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void,
    _ ctx: UnsafeMutableRawPointer?,
    _ outFile: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    _ outLength: UnsafeMutablePointer<Int>,
    _ outDevice: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
@_silgen_name("ishplus_pairing_cancel")
private func ishplus_pairing_cancel()
@_silgen_name("ishplus_pairing_free")
private func ishplus_pairing_free(_ data: UnsafeMutablePointer<UInt8>?, _ length: Int)
@_silgen_name("ishplus_pairing_free_string")
private func ishplus_pairing_free_string(_ string: UnsafeMutablePointer<CChar>?)

final class OnDevicePairing: NSObject {
    /// The name shown in Settings ("Pair with iSH+").
    static let hostName = "iSH+"

    static var isSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    enum Event {
        /// Advertising: the user can go to Settings now.
        case waiting
        case pin(String)
        case paired(device: String)
        case failed(String)
    }

    private static var current: OnDevicePairing?
    private let handler: (Event) -> Void
    private var service: NetService?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init(handler: @escaping (Event) -> Void) {
        self.handler = handler
    }

    /// Starts waiting for this device to pair. Events arrive on the main queue.
    static func start(_ handler: @escaping (Event) -> Void) {
        current?.cancel()
        let pairing = OnDevicePairing(handler: handler)
        current = pairing
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        pairing.run()
    }

    static func cancel() {
        current?.cancel()
    }

    private func cancel() {
        ishplus_pairing_cancel()
    }

    private func run() {
        // While the user is in Settings. The background audio keep-alive
        // keeps iSH+ running longer than this, when it is on.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Pairing") { [weak self] in
            self?.cancel()
        }
        let context = Unmanaged.passRetained(self).toOpaque()
        Thread.detachNewThread {
            var file: UnsafeMutablePointer<UInt8>?
            var length = 0
            var device: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            let status = ishplus_pairing_run(Self.hostName, "Mac17,7", { ctx, name, port, keys, values, count in
                let pairing = Unmanaged<OnDevicePairing>.fromOpaque(ctx!).takeUnretainedValue()
                var txt: [String: Data] = [:]
                for i in 0..<count {
                    if let key = keys?[i], let value = values?[i] {
                        txt[String(cString: key)] = Data(String(cString: value).utf8)
                    }
                }
                let serviceName = name.map { String(cString: $0) } ?? UUID().uuidString
                DispatchQueue.main.async { pairing.advertise(name: serviceName, port: port, txt: txt) }
            }, { ctx, pin in
                let pairing = Unmanaged<OnDevicePairing>.fromOpaque(ctx!).takeUnretainedValue()
                let code = pin.map { String(cString: $0) } ?? ""
                DispatchQueue.main.async { pairing.showPin(code) }
            }, context, &file, &length, &device, &error)

            let pairing = Unmanaged<OnDevicePairing>.fromOpaque(context).takeRetainedValue()
            var event: Event
            if status == 0, let file {
                let data = Data(bytes: file, count: length)
                let name = device.map { String(cString: $0) } ?? "this device"
                event = pairing.save(data) ?? .paired(device: name)
            } else {
                event = .failed(error.map { String(cString: $0) } ?? "Pairing failed.")
            }
            ishplus_pairing_free(file, length)
            ishplus_pairing_free_string(device)
            ishplus_pairing_free_string(error)
            DispatchQueue.main.async { pairing.finish(event) }
        }
    }

    private func advertise(name: String, port: UInt16, txt: [String: Data]) {
        let service = NetService(domain: "", type: "_remotepairing-pairable-host._tcp.", name: name, port: Int32(port))
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        self.service = service
        handler(.waiting)
    }

    private func showPin(_ pin: String) {
        handler(.pin(pin))
        let content = UNMutableNotificationContent()
        content.title = "Pair iSH+"
        content.body = "Enter \(Self.spaced(pin)) to pair iSH+ with this device."
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pairing-pin", content: content, trigger: nil))
    }

    /// Stores the pairing file where the JIT enabler reads it. Returns a
    /// failure, or nil.
    private func save(_ data: Data) -> Event? {
        let destination = Onboarding.pairingFileURL
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            UserDefaults.standard.set("remotepairing", forKey: "Pairing File Kind")
            return nil
        } catch {
            return .failed("Paired, but the pairing could not be saved: \(error.localizedDescription)")
        }
    }

    private func finish(_ event: Event) {
        service?.stop()
        service = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["pairing-pin"])
        if case .paired = event {
            let content = UNMutableNotificationContent()
            content.title = "iSH+ Is Paired"
            content.body = "Return to iSH+ to continue."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pairing-done", content: content, trigger: nil))
        }
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        if Self.current === self { Self.current = nil }
        handler(event)
    }

    static func spaced(_ pin: String) -> String {
        pin.count == 6 ? "\(pin.prefix(3)) \(pin.suffix(3))" : pin
    }
}
