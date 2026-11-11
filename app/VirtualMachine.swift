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
import os

@objc(ISHVirtualMachineError)
public enum VirtualMachineError: Int, LocalizedError, CustomStringConvertible {
    case noJIT, missingGuest, missingLibrary, alreadyStopped, allConsolesBusy

    public var description: String {
        switch self {
        case .noJIT:
            return "JIT is not enabled. Start iSH+ from a JIT enabler (StikDebug, SideStore, or a debugger) and try again."
        case .missingGuest:
            return "No Linux distribution is installed. Choose one in Settings > Distributions."
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

    /// Run once, when the console closes (either side)
    private let onClosed: () -> Void

    fileprivate init(index: Int, fd: Int32, output: @escaping (Data) -> Void, closed: @escaping () -> Void) {
        self.index = index
        self.fd = fd
        onClosed = closed
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
                self.onClosed()
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

    /// Tells the guest the terminal's size, so its tty (and programs like
    /// htop) use the whole view. Remembered by QEMU until the guest is ready.
    @objc(resizeWithColumns:rows:)
    public func resize(columns: Int, rows: Int) {
        VirtualMachine.shared.setConsoleSize(index: index, columns: columns, rows: rows)
    }

    /// Closes the session's console: frees it for another session (through
    /// the same cleanup as when the other side closes it) and hangs up its
    /// shell in Linux, so the next session on it starts afresh.
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
            GuestServices.shared.run("sh /opt/ishplus/boot/hangup.sh \(index)", asRoot: true) { _, _ in }
            onClosed()
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
    typealias ConsoleResize = @convention(c) (UnsafePointer<CChar>, Int32, Int32) -> Int32
    private var consoleResize: ConsoleResize?
    typealias ShareOwner = @convention(c) (Int32, Int32) -> Void
    private var shareOwner: ShareOwner?

    /// Who owns files added to the share from iOS, in the guest.
    func setShareOwner(uid: Int32, gid: Int32) {
        shareOwner?(uid, gid)
    }
    /// Last size of each console; sent once QEMU is initialized.
    private var consoleSizes: [Int: (Int, Int)] = [:]
    private var resizeReady = false
    /// Resizing takes QEMU's big lock, so keep it off the main thread.
    private let resizeQueue = DispatchQueue(label: "app.ishplus.vm.resize")

    fileprivate func setConsoleSize(index: Int, columns: Int, rows: Int) {
        lock.lock()
        consoleSizes[index] = (columns, rows)
        let ready = resizeReady
        lock.unlock()
        if ready { sendConsoleSize(index: index, columns: columns, rows: rows) }
    }

    private func sendConsoleSize(index: Int, columns: Int, rows: Int) {
        guard let resize = consoleResize else { return }
        resizeQueue.async {
            _ = "vcon\(index)".withCString { resize($0, Int32(columns), Int32(rows)) }
        }
    }

    private func qemuInitialized() {
        lock.lock()
        resizeReady = true
        let sizes = consoleSizes
        lock.unlock()
        for (index, size) in sizes { sendConsoleSize(index: index, columns: size.0, rows: size.1) }
    }

    /// Where the guest files live: Documents/VM, visible in the Files app.
    @objc public static var guestDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("VM")
    }

    /// The kernel side, shared by every distribution: bundled with the app
    /// (tools/make-guest-kernel.sh, make-guest-support.sh). Copies in
    /// Documents/VM/dev replace them, for testing.
    private static func kernelFile(_ name: String) -> URL? {
        let dev = guestDirectory.appendingPathComponent("dev/\(name)")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        return Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Guest")
    }
    private static let kernelFiles = ["vmlinuz", "initramfs", "modloop", "support.img"]

    private static func library(interpreted: Bool) -> URL {
        Bundle.main.privateFrameworksURL!.appendingPathComponent(
            interpreted ? "libqemu-aarch64-softmmu-tci.dylib" : "libqemu-aarch64-softmmu.dylib")
    }

    /// Whether this build includes the interpreter fallback.
    @objc public static var interpreterAvailable: Bool {
        FileManager.default.fileExists(atPath: library(interpreted: true).path)
    }

    @objc public static var guestInstalled: Bool {
        kernelFiles.allSatisfy { kernelFile($0) != nil } && DistroManager.shared.hasBootableDistro
    }

    /// The distribution this VM boots, and whether it gets installed first.
    private var distro: Distro?
    private var installing = false

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
        guard VirtualMachine.guestInstalled, let distro = DistroManager.shared.active else {
            throw VirtualMachineError.missingGuest
        }
        self.distro = distro
        installing = !distro.installed

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
        if let symbol = dlsym(handle, "ishplus_console_resize") {
            consoleResize = unsafeBitCast(symbol, to: ConsoleResize.self)
        }
        if let symbol = dlsym(handle, "ishplus_9p_set_owner") {
            shareOwner = unsafeBitCast(symbol, to: ShareOwner.self)
        }
        DesktopDisplay.shared.load(from: handle)

        try? FileManager.default.removeItem(at: socketDirectory)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)

        // QEMU reports errors on stderr; keep them in a log the user (and we) can read.
        let logURL = VirtualMachine.guestDirectory.appendingPathComponent("qemu.log")
        if freopen(logURL.path, "a", stderr) != nil {
            setvbuf(stderr, nil, _IONBF, 0)
        }
        var arguments = makeArguments()
        // Instant resume: start from the state saved when iOS ended iSH+
        if VMState.shared.prepareRestore(distro: distro) {
            arguments += ["-incoming", "defer"]
        }
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
            self?.qemuInitialized()
            VMState.shared.restoreAfterInit()
            // Whether the JIT enabler detached (a debugger left attached
            // slows signals down)
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                var info = kinfo_proc()
                var size = MemoryLayout<kinfo_proc>.size
                var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
                if sysctl(&mib, 4, &info, &size, nil, 0) == 0 {
                    vmLog("debugger attached: \((info.kp_proc.p_flag & P_TRACED) != 0 ? "yes" : "no")")
                }
            }
            VirtualMachine.logMemoryFootprint()
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
        GuestServices.shared.start()
        if installing { watchInstallation() }
    }


    private func markStopped() {
        lock.lock()
        isRunning = false
        hasStopped = true
        lock.unlock()
    }

    /// Logs iSH+'s memory footprint (what iOS ends apps for) when it changes
    /// by more than 50 MB, to see how the VM's memory use evolves.
    private static var footprintTimer: DispatchSourceTimer?

    static func logMemoryFootprint() {
        var last = 0
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        footprintTimer = timer
        timer.schedule(deadline: .now(), repeating: 10)
        timer.setEventHandler {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return }
            let mb = Int(info.phys_footprint >> 20)
            if abs(mb - last) >= 50 {
                last = mb
                vmLog("memory footprint: \(mb) MB (available: \(os_proc_available_memory() >> 20) MB)")
            }
        }
        timer.resume()
    }

    /// Performance (big) cores; all cores on chips without the distinction.
    static var performanceCores: Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &value, &size, nil, 0) == 0, value > 0 {
            return Int(value)
        }
        return ProcessInfo.processInfo.activeProcessorCount
    }

    /// The guest reports on the serial port when it has unpacked a new
    /// distribution; then the archive is no longer needed.
    private func watchInstallation() {
        let log = VirtualMachine.guestDirectory.appendingPathComponent("serial.log")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for _ in 0..<(2 * 60 * 60 / 2) {
                sleep(2)
                guard let self, let distro = self.distro, self.isRunning else { return }
                guard let text = try? String(contentsOf: log, encoding: .utf8) else { continue }
                if text.contains("ishplus: installed") {
                    vmLog("\(distro.title) installed")
                    DistroManager.shared.markInstalled(distro)
                    return
                }
                if text.contains("ishplus: boot failed") {
                    vmLog("\(distro.title) failed to install or boot")
                    return
                }
            }
        }
    }

    private func makeArguments() -> [String] {
        let guest = VirtualMachine.guestDirectory
        func file(_ name: String) -> String { guest.appendingPathComponent(name).path }
        func kernel(_ name: String) -> String { VirtualMachine.kernelFile(name)!.path }
        // Chosen in Settings > Linux VM (automatic by default)
        var cpus = VMSettings.cpuCount
        // Developer overrides, for comparing settings without rebuilding:
        // Documents/VM/cpu (a -cpu value), Documents/VM/smp (a count) and
        // Documents/VM/append (more kernel arguments).
        func override(_ name: String) -> String? {
            (try? String(contentsOfFile: file(name), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
        }
        if let smp = override("smp").flatMap(Int.init), smp > 0 { cpus = min(smp, 8) }
        // max: ARMv8.x features (FEX needs v8.2+ and LSE). Pointer
        // authentication and SVE are off: emulating them only costs time
        // (pauth runs on every function call in the guest kernel).
        let cpu = override("cpu") ?? "max,pauth=off,sve=off,sme=off"
        var args = [
            "qemu-system-aarch64",
            "-nodefaults", "-no-user-config",
            "-M", "virt",
            "-cpu", cpu,
            // split-wx: JIT code through a second, executable mapping (iOS)
            "-accel", interpreted ? "tcg,thread=multi,tb-size=256" : "tcg,thread=multi,tb-size=256,split-wx=on",
            "-smp", "\(cpus)",
            "-m", "\(VMSettings.memoryMB)",
            "-kernel", kernel("vmlinuz"),
            "-initrd", kernel("initramfs"),
            // iSH+'s initramfs finds its disks by their serial (see
            // tools/guest/boot/init); boot messages go to the first session.
            // Kernel hardening that costs the most under emulation, for no
            // gain inside the app's sandbox: a random kernel stack offset on
            // every system call (about 6% of a system call here) and zeroing
            // every kernel allocation.
            "-append", "earlycon=pl011,0x9000000 console=ttyAMA0 console=hvc0 loglevel=4"
                + " randomize_kstack_offset=off init_on_alloc=0"
                + (override("append").map { " " + $0 } ?? ""),
            "-drive", "if=none,file=\(distro!.diskURL.path),format=raw,id=root,cache=writeback,discard=unmap,detect-zeroes=unmap",
            "-device", "virtio-blk-pci,drive=root,serial=ishplus-root,discard_granularity=4096",
            "-drive", "if=none,file=\(kernel("modloop")),format=raw,id=modloop,readonly=on",
            "-device", "virtio-blk-pci,drive=modloop,serial=ishplus-modloop",
            "-drive", "if=none,file=\(kernel("support.img")),format=raw,id=support,readonly=on",
            "-device", "virtio-blk-pci,drive=support,serial=ishplus-support",
            "-netdev", "user,id=net",
            "-device", "virtio-net-pci,netdev=net,romfile=",
            "-device", "virtio-rng-pci",
            // Linux reports the memory it frees, which QEMU gives back to
            // iOS (patched for Apple systems): iSH+'s footprint shrinks again
            // after Linux used memory, so iOS is less likely to end it
            "-device", "virtio-balloon-pci,free-page-reporting=on",
            "-device", "virtio-serial-pci",
            // The Desktop session's display, pointer and keyboard (the guest
            // loads their drivers only when the desktop starts)
            "-device", "virtio-gpu-pci",
            "-device", "virtio-tablet-pci",
            "-device", "virtio-keyboard-pci",
            "-display", "none",
            "-monitor", "unix:\(socketDirectory.appendingPathComponent("mon").path),server=on,wait=off",
            // Early boot messages (before the virtio console exists) go to the
            // emulated serial port, saved for diagnosing boot problems.
            "-serial", "file:\(file("serial.log"))",
            "-d", "guest_errors,unimp", "-D", file("qemu-debug.log"),
        ]
        // A new distribution's root filesystem archive, unpacked by the guest
        if installing, let distro,
           let size = try? FileManager.default.attributesOfItem(atPath: distro.archiveURL.path)[.size] as? Int {
            args += ["-drive", "if=none,file=\(distro.archiveURL.path),format=raw,id=install,readonly=on",
                     "-device", "virtio-blk-pci,drive=install,serial=inst:\(size)"]
            // The account to create
            if FileManager.default.fileExists(atPath: distro.setupURL.path) {
                args += ["-drive", "if=none,file=\(distro.setupURL.path),format=raw,id=setup,readonly=on",
                         "-device", "virtio-blk-pci,drive=setup,serial=ishplus-setup"]
            }
        }
        // Developer hook: the guest runs Documents/VM/autorun.sh at boot,
        // with its output in serial.log.
        // (An empty file disables it, since devicectl cannot delete files.)
        if let size = try? FileManager.default.attributesOfItem(atPath: file("autorun.sh"))[.size] as? Int, size > 0 {
            args += ["-drive", "if=none,file=\(file("autorun.sh")),format=raw,id=autorun,readonly=on",
                     "-device", "virtio-blk-pci,drive=autorun,serial=ishplus-autorun"]
        }
        // The Files app share, the clipboard and Shortcuts' commands
        args += GuestServices.shared.qemuArguments(socketDirectory: socketDirectory)
        for i in 0..<VirtualMachine.consoleCount {
            args += ["-chardev", "socket,id=con\(i),path=\(socketPath(i)),server=on,wait=off",
                     "-device", "virtconsole,id=vcon\(i),chardev=con\(i),name=org.ishplus.console.\(i)"]
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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
