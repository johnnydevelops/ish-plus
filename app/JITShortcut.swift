//
//  JITShortcut.swift
//  iSH+
//
//  Switches VPNs for JIT, like Madeira: iOS has one VPN at a time, and iSH+
//  needs LocalDevVPN only while it enables JIT. The "iSH+ JIT" shortcut
//  (tools/make-jit-shortcut.py, bundled, added from onboarding) remembers
//  the VPN that is on (e.g. Tailscale) and connects LocalDevVPN ("start");
//  once the JIT helper is done, it connects that VPN again, or disconnects
//  LocalDevVPN if none was on ("done"). JIT stays on without LocalDevVPN.
//
//  iOS 27 and later: the shortcut keeps the previous VPN with Store Content.
//  iOS 26 has no Store Content: its version (JIT-iOS26) connects LocalDevVPN
//  and disconnects it after JIT, without giving another VPN back.
//

import Foundation
import Network
import UIKit

@objc(ISHJITShortcut)
public final class JITShortcut: NSObject {
    static let name = "iSH+ JIT"
    private static let enabledKey = "JIT Shortcut Enabled"
    /// The "done" run owed after a "start", kept in case iSH+ ends between
    private static let pendingKey = "JIT Shortcut Pending Done"

    @objc public static var isSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }

    /// The shortcut gives the VPN that was on back (iOS 27's Store Content).
    @objc public static var restoresVPN: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    /// The user added the shortcut (in onboarding).
    @objc public static var enabled: Bool {
        get { isSupported && UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    @objc public static var bundledFile: URL? {
        restoresVPN ? Bundle.main.url(forResource: name, withExtension: "shortcut")
            : Bundle.main.url(forResource: name, withExtension: "shortcut", subdirectory: "JIT-iOS26")
    }

    // MARK: Network

    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "app.ishplus.jit-shortcut.path"))
        return monitor
    }()

    /// Only cellular data is available: LocalDevVPN's loopback does not work
    /// over cellular, so the shortcut turns it off while JIT is enabled.
    private static var cellularOnly: Bool {
        let interfaces = monitor.currentPath.availableInterfaces.map(\.type)
        return interfaces.contains(.cellular) && !interfaces.contains(.wifi) && !interfaces.contains(.wiredEthernet)
    }

    /// Whether LocalDevVPN routes to this device (its loopback, lockdownd).
    @objc public static func localDevVPNConnected(timeout: TimeInterval = 0.5) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(62078).bigEndian
        inet_pton(AF_INET, "10.7.0.1", &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }

    // MARK: Running

    private static var completion: ((String?, String?) -> Void)?
    private static var timeout: DispatchWorkItem?

    /// Connects LocalDevVPN with the shortcut and waits until it routes.
    /// completion(nil) when it does, or an error message. Main thread.
    @objc public static func start(completion: @escaping (String?) -> Void) {
        let cellular = cellularOnly
        run(cellular ? "start cellular" : "start") { previousVPN, error in
            if let error { return completion(error) }
            // Owed after JIT: reconnect the VPN that was on, or turn LocalDevVPN off
            let previous = previousVPN?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let done = "done" + (cellular ? " cellular" : "") + (previous.isEmpty ? " vpn-off" : " vpn-restore")
            UserDefaults.standard.set(done, forKey: pendingKey)
            // Its Connect can return before the tunnel routes
            DispatchQueue.global().async {
                let deadline = Date().addingTimeInterval(15)
                var connected = false
                while Date() < deadline && !connected {
                    connected = localDevVPNConnected()
                    if !connected { usleep(250_000) }
                }
                DispatchQueue.main.async {
                    completion(connected ? nil : "LocalDevVPN did not connect. Open LocalDevVPN to check it, then try again.")
                }
            }
        }
    }

    /// After the JIT helper is done: gives the user's VPN back, if the
    /// shortcut switched it, then calls completion once iSH+ is in front
    /// again (JIT stays on). Linux starts from the completion: running the
    /// shortcut takes iSH+ to the background, and Linux starting meanwhile
    /// (its GPU paused for the background) could hang before its first
    /// output. Main thread.
    @objc public static func finish(completion: @escaping () -> Void) {
        guard let done = UserDefaults.standard.string(forKey: pendingKey) else { return completion() }
        // Only once iSH+ is in front (it may still be coming back from the
        // "start" run): iOS does not open Shortcuts for an app that is not,
        // and the VPN was then never given back
        whenActive { runDone(done, completion: completion) }
    }

    private static func runDone(_ done: String, completion: @escaping () -> Void) {
        run(done) { _, error in
            if error == nil {
                UserDefaults.standard.removeObject(forKey: pendingKey)
            } else {
                vmLog("JIT shortcut (\(done)): \(error!)")
            }
            whenActive(completion)
        }
    }

    /// Calls block now if iSH+ is active, else when it becomes active.
    private static func whenActive(_ block: @escaping () -> Void) {
        if UIApplication.shared.applicationState == .active { return block() }
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                       object: nil, queue: .main) { _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            block()
        }
    }

    /// Runs the shortcut with a text input; completion(output, error).
    private static func run(_ input: String, completion: @escaping (String?, String?) -> Void) {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: input),
            URLQueryItem(name: "x-success", value: "ishplus://jit-shortcut/success"),
            URLQueryItem(name: "x-error", value: "ishplus://jit-shortcut/error"),
            URLQueryItem(name: "x-cancel", value: "ishplus://jit-shortcut/cancel"),
        ]
        guard let url = components.url else { return completion(nil, "Could not run the shortcut.") }
        self.completion = completion
        let timeout = DispatchWorkItem {
            finishRun(output: nil, error: "The \(name) shortcut did not come back to iSH+.")
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
        UIApplication.shared.open(url) { opened in
            if !opened { finishRun(output: nil, error: "Shortcuts could not be opened.") }
        }
    }

    private static func finishRun(output: String?, error: String?) {
        timeout?.cancel()
        timeout = nil
        let completion = self.completion
        self.completion = nil
        completion?(output, error)
    }

    /// ishplus://jit-shortcut/... from Shortcuts.
    @objc public static func handle(_ url: URL) -> Bool {
        guard url.scheme == "ishplus", url.host == "jit-shortcut" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.path {
        case "/success":
            finishRun(output: item("result"), error: nil)
        case "/error":
            let message = item("errorMessage") ?? "The shortcut failed."
            // Not installed: back to connecting LocalDevVPN by hand
            if message.localizedCaseInsensitiveContains("find") || message.localizedCaseInsensitiveContains("not found") {
                enabled = false
                finishRun(output: nil, error: "The \(name) shortcut is not installed. Add it again in Settings > JIT Setup, or connect LocalDevVPN yourself.")
            } else {
                finishRun(output: nil, error: message)
            }
        default:
            finishRun(output: nil, error: "The \(name) shortcut was cancelled.")
        }
        return true
    }
}
