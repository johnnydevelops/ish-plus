//
//  VirtualMachine.swift
//  iSH+
//
//  The Linux VM engine: runs our QEMU fork (libqemu-system-aarch64, built by
//  tools/build-qemu-ios.sh) inside the app process, booting a real Linux
//  kernel. Each guest console (hvc0...) is a Unix socket that one iSH+ session
//  connects to.
//

import Darwin
import Foundation

@objc(ISHVirtualMachineError)
public enum VirtualMachineError: Int, LocalizedError, CustomStringConvertible {
    case noJIT, missingGuest, missingLibrary, alreadyStopped, allConsolesBusy

    public var description: String {
        switch self {
        case .noJIT:
            return "JIT is not enabled. Start iSH+ from a JIT enabler (StikDebug, SideStore, or a debugger) and try again."
        case .missingGuest:
            return "No Linux guest installed. Copy vmlinuz, initramfs, modloop and rootfs.img to iSH+/VM in the Files app."
        case .missingLibrary:
            return "This build of iSH+ does not include the QEMU engine."
        case .alreadyStopped:
            return "The Linux VM has shut down. Restart iSH+ to start it again."
        case .allConsolesBusy:
            return "All Linux VM consoles are in use. Close a session first."
        }
    }

    public var errorDescription: String? { description }
}

/// One iSH+ session's connection to a guest console.
@objc(ISHVirtualMachineConsole)
public final class VirtualMachineConsole: NSObject {
    @objc public let index: Int
    private let fd: Int32
    private let source: DispatchSourceRead
    private let queue: DispatchQueue
    private var closed = false
    private var started = false

    fileprivate init(index: Int, fd: Int32, output: @escaping (Data) -> Void, closed: @escaping () -> Void) {
        self.index = index
        self.fd = fd
        queue = DispatchQueue(label: "app.ishplus.vm.console\(index)")
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        super.init()
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(self.fd, &buffer, buffer.count)
            if n > 0 {
                output(Data(buffer[0..<n]))
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                self.closed = true
                self.source.cancel()
                closed()
            }
        }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
    }

    /// Starts reading once the socket is connected.
    fileprivate func start() {
        queue.async { [self] in
            guard !closed, !started else { return }
            started = true
            source.resume()
        }
    }

    /// Sends what the user typed to the guest.
    @objc public func send(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 {
                        if errno == EINTR || errno == EAGAIN { usleep(1000); continue }
                        return
                    }
                    offset += n
                }
            }
        }
    }

    @objc public func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            if !started {
                // A dispatch source must be resumed before it is cancelled.
                started = true
                source.resume()
            }
            source.cancel()
        }
    }
}

@objc(ISHVirtualMachine)
public final class VirtualMachine: NSObject {
    @objc public static let shared = VirtualMachine()

    /// Guest consoles, and therefore the most sessions the VM can have at once.
    @objc public static let consoleCount = 4

    @objc public private(set) var isRunning = false
    /// Run QEMU's TCG interpreter instead of its JIT, for when JIT cannot be
    /// enabled. Much slower, but needs no executable memory.
    @objc public var interpreted = false
    @objc public private(set) var hasStopped = false
    private var busyConsoles = Set<Int>()
    private let lock = NSLock()

    /// Where the guest files live: Documents/VM, visible in the Files app.
    @objc public static var guestDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("VM")
    }

    private static let guestFiles = ["vmlinuz", "initramfs", "modloop", "rootfs.img"]

    private static func library(interpreted: Bool) -> URL {
        Bundle.main.privateFrameworksURL!.appendingPathComponent(
            interpreted ? "libqemu-system-aarch64-tci.dylib" : "libqemu-system-aarch64.dylib")
    }

    /// Whether this build includes the interpreter fallback.
    @objc public static var interpreterAvailable: Bool {
        FileManager.default.fileExists(atPath: library(interpreted: true).path)
    }

    @objc public static var guestInstalled: Bool {
        guestFiles.allSatisfy { FileManager.default.fileExists(atPath: guestDirectory.appendingPathComponent($0).path) }
    }

    /// True when the process may create executable memory, i.e. a debugger
    /// attached at some point (CS_DEBUGGED). QEMU's JIT needs this on iOS.
    @objc public static var jitAvailable: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        var flags: UInt32 = 0
        let CS_OPS_STATUS: UInt32 = 0
        let CS_DEBUGGED: UInt32 = 0x10000000
        guard ish_csops(getpid(), CS_OPS_STATUS, &flags, MemoryLayout<UInt32>.size) == 0 else { return false }
        return flags & CS_DEBUGGED != 0
        #endif
    }

    private var socketDirectory: URL {
        // Unix socket paths are limited to 104 bytes, so keep this short.
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vm")
    }

    private func socketPath(_ index: Int) -> String {
        socketDirectory.appendingPathComponent("c\(index)").path
    }

    // MARK: Starting

    /// Starts the VM if it is not running yet. Returns once QEMU is launched;
    /// the guest keeps booting in the background.
    @objc public func startIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        if isRunning { return }
        if hasStopped { throw VirtualMachineError.alreadyStopped }
        guard interpreted || VirtualMachine.jitAvailable else { throw VirtualMachineError.noJIT }
        guard VirtualMachine.guestInstalled else { throw VirtualMachineError.missingGuest }

        let library = VirtualMachine.library(interpreted: interpreted)
        guard let handle = dlopen(library.path, RTLD_NOW | RTLD_LOCAL),
              let symbol = dlsym(handle, "qemu_embedded_main") else {
            NSLog("iSH+ VM: dlopen failed: %s", String(cString: dlerror()))
            throw VirtualMachineError.missingLibrary
        }
        typealias EmbeddedMain = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        let qemuMain = unsafeBitCast(symbol, to: EmbeddedMain.self)

        try? FileManager.default.removeItem(at: socketDirectory)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)

        let arguments = makeArguments()
        NSLog("iSH+ VM: qemu %@", arguments.joined(separator: " "))

        // QEMU's main loop runs on its own thread with a large stack; QEMU keeps
        // global state, so a VM can only be started once per app launch.
        let thread = Thread { [weak self] in
            var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            let status = qemuMain(Int32(arguments.count), &argv)
            NSLog("iSH+ VM: QEMU exited with status %d", status)
            self?.lock.lock()
            self?.isRunning = false
            self?.hasStopped = true
            self?.lock.unlock()
        }
        thread.name = "qemu-main"
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInteractive
        thread.start()
        isRunning = true
    }

    private func makeArguments() -> [String] {
        let guest = VirtualMachine.guestDirectory
        func file(_ name: String) -> String { guest.appendingPathComponent(name).path }
        let cpus = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 4))
        var args = [
            "qemu-system-aarch64",
            "-nodefaults", "-no-user-config",
            "-M", "virt",
            // max: ARMv8.x features (FEX needs v8.2+ and LSE). pauth-impdef:
            // a cheap pointer authentication algorithm instead of QARMA.
            "-cpu", "max,pauth-impdef=on",
            "-accel", "tcg,thread=multi,tb-size=256",
            "-smp", "\(cpus)",
            "-m", "1024",
            "-kernel", file("vmlinuz"),
            "-initrd", file("initramfs"),
            "-append", "root=/dev/vda rootfstype=ext4 modules=virtio_blk,ext4,squashfs console=hvc0 quiet",
            "-drive", "if=none,file=\(file("rootfs.img")),format=raw,id=root,cache=writeback,discard=unmap",
            "-device", "virtio-blk-pci,drive=root",
            "-drive", "if=none,file=\(file("modloop")),format=raw,id=modloop,readonly=on",
            "-device", "virtio-blk-pci,drive=modloop",
            "-netdev", "user,id=net",
            "-device", "virtio-net-pci,netdev=net,romfile=",
            "-device", "virtio-rng-pci",
            "-device", "virtio-serial-pci",
            "-display", "none", "-serial", "none", "-monitor", "none",
        ]
        for i in 0..<VirtualMachine.consoleCount {
            args += ["-chardev", "socket,id=con\(i),path=\(socketPath(i)),server=on,wait=off",
                     "-device", "virtconsole,chardev=con\(i)"]
        }
        return args
    }

    // MARK: Consoles

    /// Connects a session to the next free guest console. output and closed
    /// are called on a background queue.
    @objc(openConsoleWithOutput:closed:error:)
    public func openConsole(output: @escaping (Data) -> Void,
                                  closed: @escaping () -> Void) throws -> VirtualMachineConsole {
        try startIfNeeded()
        lock.lock()
        guard let index = (0..<VirtualMachine.consoleCount).first(where: { !busyConsoles.contains($0) }) else {
            lock.unlock()
            throw VirtualMachineError.allConsolesBusy
        }
        busyConsoles.insert(index)
        lock.unlock()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let console = VirtualMachineConsole(index: index, fd: fd, output: output, closed: { [weak self] in
            self?.lock.lock()
            self?.busyConsoles.remove(index)
            self?.lock.unlock()
            closed()
        })
        connect(fd: fd, path: socketPath(index), console: console)
        return console
    }

    /// QEMU creates the sockets once it has started, so keep trying for a while.
    private func connect(fd: Int32, path: String, console: VirtualMachineConsole) {
        DispatchQueue.global(qos: .userInitiated).async {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                _ = path.withCString { strlcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, raw.count) }
            }
            for _ in 0..<600 {
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                if result == 0 {
                    console.start()
                    // Nudge the console so getty prints its prompt.
                    console.send(Data([0x0d]))
                    return
                }
                usleep(100_000)
            }
            NSLog("iSH+ VM: could not connect to %@", path)
            console.close()
        }
    }
}

@_silgen_name("csops")
private func ish_csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32
