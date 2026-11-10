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

/// Appends to Documents/VM/qemu.log, which also receives QEMU's stderr.
func vmLog(_ message: String) {
    NSLog("iSH+ VM: %@", message)
    let line = "[\(Date())] iSH+: \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
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
            interpreted ? "libqemu-aarch64-softmmu-tci.dylib" : "libqemu-aarch64-softmmu.dylib")
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
        // Diagnostics: a file named force-tci containing "1" in the VM folder
        // runs the interpreter.
        if let flag = try? String(contentsOf: VirtualMachine.guestDirectory.appendingPathComponent("force-tci"), encoding: .utf8),
           flag.hasPrefix("1") {
            interpreted = true
        }
        guard interpreted || VirtualMachine.jitAvailable else { throw VirtualMachineError.noJIT }
        guard VirtualMachine.guestInstalled else { throw VirtualMachineError.missingGuest }

        let library = VirtualMachine.library(interpreted: interpreted)
        guard let handle = dlopen(library.path, RTLD_NOW | RTLD_LOCAL),
              let initSymbol = dlsym(handle, "qemu_init"),
              let loopSymbol = dlsym(handle, "qemu_main_loop"),
              let cleanupSymbol = dlsym(handle, "qemu_cleanup") else {
            vmLog("dlopen failed: \(String(cString: dlerror()))")
            throw VirtualMachineError.missingLibrary
        }
        typealias QemuInit = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        typealias QemuMainLoop = @convention(c) () -> Void
        typealias QemuCleanup = @convention(c) () -> Void
        let qemuInit = unsafeBitCast(initSymbol, to: QemuInit.self)
        let qemuMainLoop = unsafeBitCast(loopSymbol, to: QemuMainLoop.self)
        let qemuCleanup = unsafeBitCast(cleanupSymbol, to: QemuCleanup.self)

        try? FileManager.default.removeItem(at: socketDirectory)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)

        // QEMU reports errors on stderr; keep them in a log the user (and we) can read.
        let logURL = VirtualMachine.guestDirectory.appendingPathComponent("qemu.log")
        if freopen(logURL.path, "a", stderr) != nil {
            setvbuf(stderr, nil, _IONBF, 0)
        }
        let arguments = makeArguments()
        vmLog("starting \(interpreted ? "interpreted" : "with JIT"): \(arguments.joined(separator: " "))")

        // QEMU's main loop runs on its own thread with a large stack; QEMU keeps
        // global state, so a VM can only be started once per app launch.
        let thread = Thread { [weak self] in
            // QEMU calls exit() on errors and shutdown; on its own thread that
            // must only end this thread, not the app (UTM's technique).
            let qemuThread = pthread_self()
            atexit_b {
                if pthread_equal(pthread_self(), qemuThread) != 0 {
                    vmLog("QEMU called exit()")
                    self?.markStopped()
                    pthread_exit(nil)
                }
            }
            var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            var envp: [UnsafeMutablePointer<CChar>?] = [nil]
            let status = qemuInit(Int32(arguments.count), &argv, &envp)
            vmLog("qemu_init returned \(status)")
            qemuMainLoop()
            qemuCleanup()
            vmLog("QEMU stopped")
            self?.markStopped()
        }
        thread.name = "qemu-main"
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInteractive
        thread.start()
        isRunning = true
        scheduleDiagnostics()
    }

    /// Asks QEMU's monitor for the VM state and every vCPU's registers a few
    /// seconds into the boot, twice, and logs the answers: if the PCs move the
    /// guest is running (if slowly); if not, the vCPUs are stuck.
    private func scheduleDiagnostics() {
        let path = socketDirectory.appendingPathComponent("mon").path
        DispatchQueue.global(qos: .utility).async {
            for delay: UInt32 in [6, 8] {
                sleep(delay)
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutableBytes(of: &address.sun_path) { raw in
                    _ = path.withCString { strlcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, raw.count) }
                }
                let ok = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                } == 0
                guard ok else { vmLog("monitor: cannot connect"); Darwin.close(fd); continue }
                let commands = "info status\ninfo registers -a\n"
                _ = commands.withCString { write(fd, $0, strlen($0)) }
                usleep(1_500_000)
                var output = Data()
                var buffer = [UInt8](repeating: 0, count: 65536)
                var flags = fcntl(fd, F_GETFL); flags |= O_NONBLOCK; _ = fcntl(fd, F_SETFL, flags)
                while true {
                    let n = read(fd, &buffer, buffer.count)
                    if n <= 0 { break }
                    output.append(contentsOf: buffer[0..<n])
                }
                Darwin.close(fd)
                let text = String(decoding: output, as: UTF8.self)
                    .split(separator: "\n")
                    .filter { $0.contains("status") || $0.contains("PC=") || $0.contains("CPU#") }
                    .joined(separator: "\n")
                vmLog("monitor after \(delay)s:\n\(text)")
            }
        }
    }

    private func markStopped() {
        lock.lock()
        isRunning = false
        hasStopped = true
        lock.unlock()
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
            // split-wx: JIT code through a second, executable mapping (iOS)
            "-accel", interpreted ? "tcg,thread=multi,tb-size=64" : "tcg,thread=multi,tb-size=64,split-wx=on",
            "-smp", "\(cpus)",
            "-m", "1024",
            "-kernel", file("vmlinuz"),
            "-initrd", file("initramfs"),
            "-append", "root=/dev/vda rootfstype=ext4 modules=virtio_blk,ext4,squashfs earlycon=pl011,0x9000000 console=ttyAMA0 console=hvc0 loglevel=4",
            "-drive", "if=none,file=\(file("rootfs.img")),format=raw,id=root,cache=writeback,discard=unmap",
            "-device", "virtio-blk-pci,drive=root",
            "-drive", "if=none,file=\(file("modloop")),format=raw,id=modloop,readonly=on",
            "-device", "virtio-blk-pci,drive=modloop",
            "-netdev", "user,id=net",
            "-device", "virtio-net-pci,netdev=net,romfile=",
            "-device", "virtio-rng-pci",
            "-device", "virtio-serial-pci",
            "-display", "none",
            "-monitor", "unix:\(socketDirectory.appendingPathComponent("mon").path),server=on,wait=off",
            // Early boot messages (before the virtio console exists) go to the
            // emulated serial port, saved for diagnosing boot problems.
            "-serial", "file:\(file("serial.log"))",
            "-d", "guest_errors,unimp", "-D", file("qemu-debug.log"),
        ]
        for i in 0..<VirtualMachine.consoleCount {
            args += ["-chardev", "socket,id=con\(i),path=\(socketPath(i)),server=on,wait=off",
                     // Named, because Alpine's initramfs reads each port's name
                     "-device", "virtconsole,chardev=con\(i),name=org.ishplus.console.\(i)"]
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
                    vmLog("connected to \(path)")
                    console.start()
                    // Nudge the console so getty prints its prompt.
                    console.send(Data([0x0d]))
                    return
                }
                usleep(100_000)
            }
            vmLog("could not connect to \(path)")
            console.close()
        }
    }
}

@_silgen_name("csops")
private func ish_csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

@_silgen_name("jit_probe_run")
private func jit_probe_run()
