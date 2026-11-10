//
//  QEMUMonitor.swift
//  iSH+
//
//  Commands for QEMU's human monitor (HMP), on its Unix socket. QEMU serves
//  one monitor connection at a time, so commands are serialized.
//

import Foundation

enum QEMUMonitor {
    static var socketPath: String?
    private static let lock = NSLock()

    /// Runs a command and returns its output (nil if QEMU did not answer).
    static func run(_ command: String, timeout: TimeInterval = 5) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let path = socketPath else { return nil }
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
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
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
        // Without the echoed command and the prompt (HMP also echoes with
        // terminal escapes, so drop the first line)
        var lines = output.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        if !lines.isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n").replacingOccurrences(of: "(qemu) ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
