//
//  GuestServices.swift
//  iSH+
//
//  What iSH offered beyond a terminal, for the Linux VM:
//  - Documents/Shared (in the Files app) is shared with the guest at
//    /mnt/ios (virtio-9p).
//  - The iOS clipboard, through the org.ishplus.clipboard port: the guest's
//    pbcopy sends "C <length>\n<data>", pbpaste sends "P\n" and gets
//    "<length>\n<data>". The guest's init also sends "U <uid> <gid>\n",
//    its user, to own the files added to the share from iOS.
//  - Commands from Shortcuts, through the org.ishplus.exec port (see
//    tools/guest/boot/exec-agent.sh): "<id> <length>\n<command>", answered
//    with "<id> <status> <length>\n<output>".
//

import Foundation
import UIKit

/// A virtio-serial port of the VM, as a Unix socket QEMU listens on.
final class GuestPort {
    let name: String
    let path: String
    private var fd: Int32 = -1
    private var buffer = Data()

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    var qemuArguments: [String] {
        ["-chardev", "socket,id=\(name),path=\(path),server=on,wait=off",
         "-device", "virtserialport,chardev=\(name),name=org.ishplus.\(name)"]
    }

    /// Connects, retrying while QEMU starts. Blocks.
    func connect() -> Bool {
        if fd >= 0 { return true }
        for _ in 0..<1200 {
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                _ = path.withCString { strlcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, raw.count) }
            }
            let ok = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            } == 0
            if ok {
                fd = s
                buffer = Data()
                return true
            }
            close(s)
            usleep(100_000)
        }
        return false
    }

    func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &chunk, chunk.count)
        guard n > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }

    /// Whether data arrives within the timeout.
    func waitForData(timeout: TimeInterval) -> Bool {
        if !buffer.isEmpty { return true }
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&poller, 1, Int32(timeout * 1000)) > 0
    }

    func readLine() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            guard fill() else { return nil }
        }
    }

    func read(count: Int) -> Data? {
        while buffer.count < count {
            guard fill() else { return nil }
        }
        let data = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(data)
    }

    func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }
}

final class GuestServices {
    static let shared = GuestServices()

    /// Shared with the guest at /mnt/ios; in the Files app as iSH+ > Shared.
    static var sharedFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Shared")
    }

    private var clipboard: GuestPort!
    private var exec: GuestPort!
    private var ports: GuestPort!
    private let execQueue = DispatchQueue(label: "app.ishplus.exec")
    private var nextID = 1
    /// The guest's agent answered (it is up).
    private(set) var execReady = false

    func qemuArguments(socketDirectory: URL) -> [String] {
        try? FileManager.default.createDirectory(at: Self.sharedFolder, withIntermediateDirectories: true)
        // The guest's DNS, answered by the system resolver (see DNSProxy)
        if let port = DNSProxy.shared.start() {
            setenv("ISHPLUS_DNS_PORT", "\(port)", 1)
        }
        clipboard = GuestPort(name: "clipboard", path: socketDirectory.appendingPathComponent("clipboard").path)
        exec = GuestPort(name: "exec", path: socketDirectory.appendingPathComponent("exec").path)
        ports = GuestPort(name: "ports", path: socketDirectory.appendingPathComponent("ports").path)
        PortForwarder.shared.configure(monitorPath: socketDirectory.appendingPathComponent("mon").path)
        // Files made in the guest keep their owner and mode in extended
        // attributes; others appear owned by the guest's user, which the
        // guest reports at boot ("U <uid> <gid>" on the clipboard port).
        return ["-fsdev", "local,id=share,path=\(Self.sharedFolder.path),security_model=mapped-xattr",
                "-device", "virtio-9p-pci,fsdev=share,mount_tag=ishplus-share"]
            + clipboard.qemuArguments + exec.qemuArguments + ports.qemuArguments
    }

    /// Called once QEMU is running.
    func start() {
        Thread.detachNewThread { [clipboard] in
            guard let clipboard, clipboard.connect() else { return }
            Self.serveClipboard(clipboard)
        }
        execQueue.async { [exec] in
            _ = exec?.connect()
        }
        // Ports servers listen on in the guest (ishplus-agent)
        Thread.detachNewThread { [ports] in
            guard let ports, ports.connect() else { return }
            while let line = ports.readLine() {
                guard line.hasPrefix("L") else { continue }
                PortForwarder.shared.update(guestPorts: line.split(separator: " ").dropFirst().compactMap { Int($0) })
            }
        }
    }

    private static func serveClipboard(_ port: GuestPort) {
        while let line = port.readLine() {
            if line.hasPrefix("C "), let length = Int(line.dropFirst(2)), length >= 0,
               let data = port.read(count: length) {
                DispatchQueue.main.async {
                    if let text = String(data: data, encoding: .utf8) {
                        UIPasteboard.general.string = text
                    } else {
                        UIPasteboard.general.setData(data, forPasteboardType: "public.data")
                    }
                }
            } else if line.hasPrefix("U ") {
                let ids = line.split(separator: " ").compactMap { Int32($0) }
                if ids.count == 2 { VirtualMachine.shared.setShareOwner(uid: ids[0], gid: ids[1]) }
            } else if line == "P" {
                var text = ""
                DispatchQueue.main.sync { text = UIPasteboard.general.string ?? "" }
                let data = Data(text.utf8)
                _ = port.write(Data("\(data.count)\n".utf8) + data)
            }
        }
    }

    /// Runs a command in the guest, as the user its sessions log in as.
    func run(_ command: String, completion: @escaping (Int32, String) -> Void) {
        execQueue.async { [self] in
            guard let exec, exec.connect() else {
                return completion(-1, "The Linux VM is not running.")
            }
            // Until the guest's agent has answered once it may not be
            // listening yet, and requests sent before are lost: wait for it
            // with a harmless command, so the real one runs only once.
            if !execReady {
                let ping = Data("0 4\ntrue".utf8)
                var attempts = 0
                while true {
                    guard attempts < 60, exec.write(ping) else {
                        exec.disconnect()
                        return completion(-1, "Linux did not answer.")
                    }
                    attempts += 1
                    if exec.waitForData(timeout: 5) { break }
                }
                execReady = true
            }
            let id = nextID
            nextID += 1
            let body = Data(command.utf8)
            guard exec.write(Data("\(id) \(body.count)\n".utf8) + body) else {
                exec.disconnect()
                return completion(-1, "Could not send the command.")
            }
            // Replies to earlier, abandoned requests are skipped
            while let header = exec.readLine() {
                let fields = header.split(separator: " ")
                guard fields.count == 3, let replyID = Int(fields[0]), let status = Int32(fields[1]),
                      let length = Int(fields[2]), let output = exec.read(count: length) else { break }
                if replyID == id {
                    return completion(status, String(decoding: output, as: UTF8.self))
                }
            }
            exec.disconnect()
            completion(-1, "The Linux VM stopped.")
        }
    }
}

// For the Run Command shortcut in the app target (which is a separate Swift
// module): plain C entry points.

@_cdecl("ishplus_vm_is_running")
public func ishplus_vm_is_running() -> Bool {
    VirtualMachine.shared.isRunning
}

@_cdecl("ishplus_vm_run_command")
public func ishplus_vm_run_command(_ command: UnsafePointer<CChar>, _ context: UnsafeMutableRawPointer?,
                                   _ done: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>) -> Void) {
    GuestServices.shared.run(String(cString: command)) { status, output in
        output.withCString { done(context, status, $0) }
    }
}
