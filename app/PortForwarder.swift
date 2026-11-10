//
//  PortForwarder.swift
//  iSH+
//
//  Makes servers in the Linux VM reachable from iOS, like Docker or WSL:
//  the guest's ishplus-agent reports the TCP ports programs listen on
//  ("L <port>..." on the org.ishplus.ports port), and each is forwarded from
//  the iPad's localhost (or every address, if the user shares them on the
//  network) with QEMU's hostfwd, through QEMU's monitor.
//

import Foundation

@objc(ISHForwardedPort)
public final class ForwardedPort: NSObject {
    /// In the guest
    @objc public let guestPort: Int
    /// On the iPad (the same, unless that port was not available)
    @objc public let hostPort: Int

    init(guestPort: Int, hostPort: Int) {
        self.guestPort = guestPort
        self.hostPort = hostPort
    }

    @objc public var url: URL { URL(string: "http://localhost:\(hostPort)")! }
}

@objc(ISHPortForwarder)
public final class PortForwarder: NSObject {
    @objc public static let shared = PortForwarder()
    @objc public static let didChangeNotification = Notification.Name("ISHForwardedPortsDidChange")
    /// Forward on every address (other devices on the network can connect),
    /// instead of only the iPad's localhost.
    @objc public static let shareOnNetworkKey = "Share Ports on Network"

    private let queue = DispatchQueue(label: "app.ishplus.ports")
    private var forwarded: [Int: Int] = [:] // guest port -> host port
    private var wanted: Set<Int> = []
    private var bindAddress = "127.0.0.1"

    /// The ports forwarded now, by guest port.
    @objc public private(set) var ports: [ForwardedPort] = []

    func configure(monitorPath: String) {
        QEMUMonitor.socketPath = monitorPath
    }

    /// From the guest: the ports listened on now.
    func update(guestPorts: [Int]) {
        queue.async { [self] in
            wanted = Set(guestPorts.filter { $0 > 0 && $0 < 65536 })
            sync()
        }
    }

    /// Shares the ports on the network, or only on this iPad.
    @objc public func setSharedOnNetwork(_ shared: Bool) {
        UserDefaults.standard.set(shared, forKey: Self.shareOnNetworkKey)
        queue.async { [self] in
            // Forward everything again on the new address
            for (guest, host) in forwarded { _ = monitor("hostfwd_remove net tcp:\(bindAddress):\(host)") ; _ = guest }
            forwarded = [:]
            sync()
        }
    }

    private func sync() {
        bindAddress = UserDefaults.standard.bool(forKey: Self.shareOnNetworkKey) ? "0.0.0.0" : "127.0.0.1"
        var changed = false
        for (guest, host) in forwarded where !wanted.contains(guest) {
            _ = monitor("hostfwd_remove net tcp:\(bindAddress):\(host)")
            forwarded[guest] = nil
            changed = true
        }
        for guest in wanted.sorted() where forwarded[guest] == nil {
            // The same port if iOS allows it, else 10000 + the port
            for host in [guest, 10000 + guest] where host < 65536 {
                if let output = monitor("hostfwd_add net tcp:\(bindAddress):\(host)-:\(guest)"),
                   !output.localizedCaseInsensitiveContains("could not") &&
                   !output.localizedCaseInsensitiveContains("error") {
                    forwarded[guest] = host
                    vmLog("forwarding port \(guest) on \(bindAddress):\(host)")
                    changed = true
                    break
                }
            }
        }
        guard changed else { return }
        let list = forwarded.sorted { $0.key < $1.key }.map { ForwardedPort(guestPort: $0.key, hostPort: $0.value) }
        DispatchQueue.main.async {
            self.ports = list
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    private func monitor(_ command: String) -> String? {
        QEMUMonitor.run(command)
    }
}
