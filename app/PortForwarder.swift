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
    private var monitorPath: String?
    private var forwarded: [Int: Int] = [:] // guest port -> host port
    private var wanted: Set<Int> = []
    private var bindAddress = "127.0.0.1"

    /// The ports forwarded now, by guest port.
    @objc public private(set) var ports: [ForwardedPort] = []

    func configure(monitorPath: String) {
        self.monitorPath = monitorPath
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

    /// Runs a command on QEMU's monitor (HMP) and returns its output.
    private func monitor(_ command: String) -> String? {
        guard let path = monitorPath else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            _ = path.withCString { strlcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, raw.count) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
        guard connected else { return nil }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // The banner ends with the first prompt; the command's output with the next
        func readUntilPrompt() -> String? {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buffer, buffer.count)
                guard n > 0 else { return nil }
                data.append(contentsOf: buffer[0..<n])
                if let text = String(data: data, encoding: .utf8), text.hasSuffix("(qemu) ") {
                    return text
                }
            }
        }
        guard readUntilPrompt() != nil else { return nil }
        _ = (command + "\n").withCString { write(fd, $0, strlen($0)) }
        guard let output = readUntilPrompt() else { return nil }
        // Drop the echoed command and the prompt
        return output.replacingOccurrences(of: "(qemu) ", with: "")
            .replacingOccurrences(of: command, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
