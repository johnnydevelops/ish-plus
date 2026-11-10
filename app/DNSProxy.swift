//
//  DNSProxy.swift
//  iSH+
//
//  Answers the Linux VM's DNS queries with the system resolver
//  (DNSServiceQueryRecord), which knows split DNS: names only a VPN can
//  resolve, such as Tailscale's MagicDNS, or a network's local names. QEMU's
//  networking (libslirp, patched: tools/qemu-ios-patches) sends the guest's
//  queries to 10.0.2.3 here instead of to the plain DNS servers.
//

import Darwin
import dnssd
import Foundation

final class DNSProxy {
    static let shared = DNSProxy()

    private var fd: Int32 = -1
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "app.ishplus.dns", attributes: .concurrent)

    /// Listens on 127.0.0.1 and returns the port, or nil.
    func start() -> UInt16? {
        if port != 0 { return port }
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { close(fd); fd = -1; return nil }
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in serve() }
        return port
    }

    private func serve() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var from = sockaddr_storage()
            var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength)
                }
            }
            guard n > 0 else { continue }
            let query = Array(buffer[0..<n])
            queue.async { [self] in
                guard let reply = Self.answer(query) else { return }
                var to = from
                _ = withUnsafePointer(to: &to) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, reply, reply.count, 0, $0, fromLength)
                    }
                }
            }
        }
    }

    // MARK: DNS messages

    private struct Record {
        let type: UInt16
        let rclass: UInt16
        let ttl: UInt32
        let data: [UInt8]
    }

    /// The reply to one query (one question, as stub resolvers send).
    private static func answer(_ query: [UInt8]) -> [UInt8]? {
        guard query.count >= 12, query[2] & 0x80 == 0 else { return nil }
        let questions = Int(query[4]) << 8 | Int(query[5])
        // Read the question name
        var offset = 12
        var labels: [String] = []
        while offset < query.count {
            let length = Int(query[offset])
            if length == 0 { offset += 1; break }
            guard length < 64, offset + 1 + length <= query.count else { return nil }
            labels.append(String(decoding: query[(offset + 1)...(offset + length)], as: UTF8.self))
            offset += 1 + length
        }
        guard questions == 1, offset + 4 <= query.count else {
            return reply(to: query, questionEnd: min(offset, query.count), rcode: 4, records: []) // not implemented
        }
        let type = UInt16(query[offset]) << 8 | UInt16(query[offset + 1])
        let rclass = UInt16(query[offset + 2]) << 8 | UInt16(query[offset + 3])
        let questionEnd = offset + 4
        let name = labels.isEmpty ? "." : labels.joined(separator: ".") + "."
        var (rcode, records) = resolve(name: name, type: type, rclass: rclass)
        // Single-label names (e.g. a Tailscale machine's name) only resolve
        // with the search domains, which getaddrinfo applies
        if labels.count == 1 && records.isEmpty && (type == 1 || type == 28),
           let found = searchDomainAddresses(labels[0], ipv6: type == 28) {
            (rcode, records) = (0, found)
        }
        return reply(to: query, questionEnd: questionEnd, rcode: rcode, records: records)
    }

    private static func reply(to query: [UInt8], questionEnd: Int, rcode: UInt8, records: [Record]) -> [UInt8] {
        var out: [UInt8] = []
        out += query[0..<2]                                  // id
        out += [0x80 | (query[2] & 0x01), 0x80 | rcode]      // QR, RD copied, RA, rcode
        out += [0, questionEnd > 12 ? 1 : 0]                 // questions
        out += [UInt8(records.count >> 8), UInt8(records.count & 0xff)]
        out += [0, 0, 0, 0]                                  // authority, additional
        out += query[12..<questionEnd]
        for record in records {
            out += [0xc0, 0x0c]                              // the question's name
            out += [UInt8(record.type >> 8), UInt8(record.type & 0xff)]
            out += [UInt8(record.rclass >> 8), UInt8(record.rclass & 0xff)]
            out += withUnsafeBytes(of: record.ttl.bigEndian, Array.init)
            out += [UInt8(record.data.count >> 8), UInt8(record.data.count & 0xff)]
            out += record.data
        }
        return out
    }

    // MARK: Resolving

    /// A or AAAA records for a single-label name, with the search domains.
    private static func searchDomainAddresses(_ label: String, ipv6: Bool) -> [Record]? {
        var hints = addrinfo()
        hints.ai_family = ipv6 ? AF_INET6 : AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(label, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var records: [Record] = []
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let info = entry?.pointee {
            if let address = info.ai_addr {
                if ipv6 {
                    address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        records.append(Record(type: 28, rclass: 1, ttl: 60,
                                              data: withUnsafeBytes(of: $0.pointee.sin6_addr, Array.init)))
                    }
                } else {
                    address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        records.append(Record(type: 1, rclass: 1, ttl: 60,
                                              data: withUnsafeBytes(of: $0.pointee.sin_addr, Array.init)))
                    }
                }
            }
            entry = info.ai_next
        }
        // getaddrinfo lists each address once per socket type
        var seen = Set<[UInt8]>()
        records = records.filter { seen.insert($0.data).inserted }
        return records.isEmpty ? nil : records
    }

    private final class Lookup {
        var records: [Record] = []
        var error: DNSServiceErrorType = DNSServiceErrorType(kDNSServiceErr_NoError)
        var done = false
    }

    /// (rcode, records) for a question, from the system resolver.
    private static func resolve(name: String, type: UInt16, rclass: UInt16) -> (UInt8, [Record]) {
        let lookup = Lookup()
        var ref: DNSServiceRef?
        let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates | kDNSServiceFlagsTimeout)
        let context = Unmanaged.passUnretained(lookup).toOpaque()
        let status = DNSServiceQueryRecord(&ref, flags, 0, name, type, rclass, { _, flags, _, error, _, rrtype, rrclass, rdlen, rdata, ttl, context in
            let lookup = Unmanaged<Lookup>.fromOpaque(context!).takeUnretainedValue()
            if error != kDNSServiceErr_NoError {
                lookup.error = error
                lookup.done = true
                return
            }
            if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let rdata {
                let bytes = Array(UnsafeRawBufferPointer(start: rdata, count: Int(rdlen)))
                lookup.records.append(Record(type: rrtype, rclass: rrclass, ttl: ttl, data: bytes))
            }
            if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 {
                lookup.done = true
            }
        }, context)
        guard status == kDNSServiceErr_NoError, let ref else { return (2, []) } // server failure
        defer { DNSServiceRefDeallocate(ref) }
        let socketFD = DNSServiceRefSockFD(ref)
        let deadline = Date().addingTimeInterval(5)
        while !lookup.done {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return (2, []) }
            var poller = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, Int32(remaining * 1000)) > 0,
                  DNSServiceProcessResult(ref) == kDNSServiceErr_NoError else { return (2, []) }
        }
        switch Int(lookup.error) {
        case kDNSServiceErr_NoError:
            // Only the records of the type asked for (CNAMEs are followed)
            let records = lookup.records.filter { $0.type == type || type == 255 }
            return (0, records)
        case kDNSServiceErr_NoSuchRecord:
            return (0, [])      // the name exists, without records of this type
        case kDNSServiceErr_NoSuchName:
            return (3, [])      // NXDOMAIN
        default:
            return (2, [])
        }
    }
}
