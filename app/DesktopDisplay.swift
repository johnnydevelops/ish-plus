//
//  DesktopDisplay.swift
//  iSH+
//
//  The VM's display (virtio-gpu) and pointer and keyboard (virtio-tablet,
//  virtio-keyboard), through iSH+'s bridge in QEMU (deps/qemu,
//  ui/ishplus-display.c). QEMU reports frames on its main loop thread.
//  Without GPU acceleration they are copied into a buffer of our own, which
//  the Desktop view shows; with it, QEMU draws the guest's screen into
//  IOSurfaces on the GPU, which the view shows as they are (no copies).
//

import CoreGraphics
import Foundation
import IOSurface

final class DesktopDisplay {
    static let shared = DesktopDisplay()

    private typealias Attach = @convention(c) (UnsafeRawPointer) -> Int32
    private typealias Detach = @convention(c) () -> Void
    private typealias SetSize = @convention(c) (Int32, Int32) -> Void
    private typealias Pointer = @convention(c) (Int32, Int32) -> Void
    private typealias Button = @convention(c) (Int32, Int32) -> Void
    private typealias Scroll = @convention(c) (Int32, Int32) -> Void
    private typealias Key = @convention(c) (Int32, Int32) -> Void
    private typealias GPUFrameCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Int32) -> Void
    private typealias SetGPUFrames = @convention(c) (UnsafeMutableRawPointer?, GPUFrameCallback?) -> Void

    private typealias SurfaceCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Int32, Int32) -> Void
    private typealias UpdateCallback = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32) -> Void
    private typealias CursorCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt32>?, Int32, Int32, Int32, Int32) -> Void
    private typealias CursorPositionCallback = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32) -> Void

    private var attachFunction: Attach?
    private var detachFunction: Detach?
    private var setSizeFunction: SetSize?
    private var pointerFunction: Pointer?
    private var buttonFunction: Button?
    private var scrollFunction: Scroll?
    private var keyFunction: Key?
    private var setGPUFramesFunction: SetGPUFrames?

    /// QEMU's library is loaded (the VM ran) and has the bridge.
    var isAvailable: Bool { attachFunction != nil }

    /// Called by VirtualMachine once QEMU's library is open.
    func load(from handle: UnsafeMutableRawPointer) {
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        attachFunction = symbol("ishplus_display_attach", Attach.self)
        detachFunction = symbol("ishplus_display_detach", Detach.self)
        setSizeFunction = symbol("ishplus_display_set_size", SetSize.self)
        pointerFunction = symbol("ishplus_input_pointer", Pointer.self)
        buttonFunction = symbol("ishplus_input_button", Button.self)
        scrollFunction = symbol("ishplus_input_scroll", Scroll.self)
        keyFunction = symbol("ishplus_input_key", Key.self)
        setGPUFramesFunction = symbol("ishplus_display_set_gpu_frames", SetGPUFrames.self)
    }

    // MARK: Frames

    /// A copy of the guest's screen, in memory CoreGraphics can show.
    final class Frame {
        let width: Int, height: Int, stride: Int
        let data: UnsafeMutableRawPointer
        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            stride = width * 4
            data = UnsafeMutableRawPointer.allocate(byteCount: max(stride * height, 4), alignment: 64)
            memset(data, 0, stride * height)
        }
        deinit { data.deallocate() }

        func image() -> CGImage? {
            let retained = Unmanaged.passRetained(self)
            guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: data, size: stride * height,
                                                releaseData: { info, _, _ in
                Unmanaged<Frame>.fromOpaque(info!).release()
            }) else {
                retained.release()
                return nil
            }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    /// Main thread: a new frame to show, a CGImage or an IOSurface (layer
    /// contents), and its size in pixels (nil: no display yet).
    var onFrame: ((AnyObject?, CGSize) -> Void)?
    /// Main thread: the guest's cursor (image, hot spot), nil to hide it.
    var onCursor: ((CGImage?, CGPoint) -> Void)?
    /// Main thread: where the guest put its cursor.
    var onCursorPosition: ((CGPoint, Bool) -> Void)?

    private let lock = NSLock()
    private var frame: Frame?
    private var source: UnsafeRawPointer?
    private var sourceStride = 0
    private var presentScheduled = false
    private var callbacks: UnsafeMutablePointer<UnsafeRawPointer?>?

    /// GPU frames: the newest IOSurface QEMU drew (held with a use count, so
    /// QEMU draws into others), and the one on screen.
    private var gpuSurface: IOSurfaceRef?
    private var gpuSize = CGSize.zero
    private var shownSurface: IOSurfaceRef?
    private var newGPUFrame = false
    /// The screen is QEMU's GPU frames, not the copy.
    private var gpuMode = false
    /// The software surface's size while in GPU mode (copied when it ends)
    private var sourceSize = (width: 0, height: 0)

    /// The guest's screen size, in pixels.
    var size: CGSize {
        lock.lock(); defer { lock.unlock() }
        if gpuMode { return gpuSize }
        return frame.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
    }

    private func copyAll(_ pixels: UnsafeRawPointer, width: Int, height: Int, stride: Int) {
        let frame = Frame(width: width, height: height)
        for row in 0..<height {
            memcpy(frame.data + row * frame.stride, pixels + row * stride, width * 4)
        }
        self.frame = frame
    }

    private func surface(_ pixels: UnsafeRawPointer?, width: Int, height: Int, stride: Int) {
        lock.lock()
        if let pixels, width > 0, height > 0 {
            source = pixels
            sourceStride = stride
            sourceSize = (width, height)
            if gpuMode {
                frame = nil    // copied if the GPU frames end
            } else {
                copyAll(pixels, width: width, height: height, stride: stride)
            }
        } else {
            frame = nil
            source = nil
        }
        let gpu = gpuMode
        lock.unlock()
        if !gpu { schedulePresent() }
    }

    /// QEMU's thread: a GPU frame, or nil when the screen is back to software.
    private func gpuFrame(_ surface: IOSurfaceRef?, width: Int, height: Int) {
        lock.lock()
        // One use count each for the newest and the shown surface (once if
        // the same); QEMU redraws a held one only when all are held.
        if let surface, surface !== gpuSurface, surface !== shownSurface { IOSurfaceIncrementUseCount(surface) }
        if let old = gpuSurface, old !== shownSurface, old !== surface { IOSurfaceDecrementUseCount(old) }
        gpuSurface = surface
        newGPUFrame = surface != nil
        if surface != nil {
            gpuMode = true
            gpuSize = CGSize(width: width, height: height)
        } else {
            gpuMode = false
            if let source, sourceSize.width > 0 {
                copyAll(source, width: sourceSize.width, height: sourceSize.height, stride: sourceStride)
            }
        }
        lock.unlock()
        schedulePresent()
    }

    private func update(x: Int, y: Int, width: Int, height: Int) {
        lock.lock()
        if !gpuMode, let frame, let source {
            let x0 = max(0, min(x, frame.width)), x1 = max(x0, min(x + width, frame.width))
            let y0 = max(0, min(y, frame.height)), y1 = max(y0, min(y + height, frame.height))
            if x1 > x0 {
                for row in y0..<y1 {
                    memcpy(frame.data + row * frame.stride + x0 * 4, source + row * sourceStride + x0 * 4, (x1 - x0) * 4)
                }
            }
        }
        lock.unlock()
        schedulePresent()
    }

    private func schedulePresent() {
        lock.lock()
        let scheduled = presentScheduled
        presentScheduled = true
        lock.unlock()
        guard !scheduled else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            presentScheduled = false
            if gpuMode, let surface = gpuSurface {
                guard newGPUFrame else { lock.unlock(); return }
                newGPUFrame = false
                let size = gpuSize
                let previous = shownSurface
                shownSurface = surface
                lock.unlock()
                onFrame?(surface, size)
                // Free for QEMU once the layer shows the new one (the render
                // server holds the surface it shows)
                if let previous, previous !== surface { releaseAfterCommit(previous) }
                return
            }
            let frame = self.frame
            let previous = shownSurface
            shownSurface = nil
            lock.unlock()
            onFrame?(frame?.image(), frame.map { CGSize(width: $0.width, height: $0.height) } ?? .zero)
            if let previous { releaseAfterCommit(previous) }
        }
    }

    /// Main thread: lets QEMU draw into a surface again once the layer that
    /// showed it has moved on (the render server holds its own use).
    private func releaseAfterCommit(_ surface: IOSurfaceRef) {
        DispatchQueue.main.async { [self] in
            lock.lock()
            let held = surface === gpuSurface || surface === shownSurface
            lock.unlock()
            if !held { IOSurfaceDecrementUseCount(surface) }
        }
    }

    private func cursor(_ pixels: UnsafePointer<UInt32>?, width: Int, height: Int, hotX: Int, hotY: Int) {
        var image: CGImage?
        if let pixels, width > 0, height > 0 {
            let data = Data(bytes: pixels, count: width * height * 4)
            if let provider = CGDataProvider(data: data as CFData) {
                image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.first.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            }
        }
        let hotSpot = CGPoint(x: hotX, y: hotY)
        DispatchQueue.main.async { [self] in onCursor?(image, hotSpot) }
    }

    // MARK: Attaching

    /// Starts receiving frames (the Desktop view is on screen).
    @discardableResult
    func attach() -> Bool {
        guard let attachFunction else { return false }
        if callbacks == nil {
            let surface: SurfaceCallback = { _, pixels, width, height, stride in
                DesktopDisplay.shared.surface(pixels, width: Int(width), height: Int(height), stride: Int(stride))
            }
            let update: UpdateCallback = { _, x, y, width, height in
                DesktopDisplay.shared.update(x: Int(x), y: Int(y), width: Int(width), height: Int(height))
            }
            let cursor: CursorCallback = { _, pixels, width, height, hotX, hotY in
                DesktopDisplay.shared.cursor(pixels, width: Int(width), height: Int(height), hotX: Int(hotX), hotY: Int(hotY))
            }
            let position: CursorPositionCallback = { _, x, y, visible in
                let point = CGPoint(x: Int(x), y: Int(y))
                DispatchQueue.main.async { DesktopDisplay.shared.onCursorPosition?(point, visible != 0) }
            }
            // struct IshplusDisplayCallbacks: a context, then four functions
            let table = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 5)
            table[0] = nil
            table[1] = unsafeBitCast(surface, to: UnsafeRawPointer.self)
            table[2] = unsafeBitCast(update, to: UnsafeRawPointer.self)
            table[3] = unsafeBitCast(cursor, to: UnsafeRawPointer.self)
            table[4] = unsafeBitCast(position, to: UnsafeRawPointer.self)
            callbacks = table
        }
        guard attachFunction(UnsafeRawPointer(callbacks!)) == 0 else { return false }
        let gpuFrame: GPUFrameCallback = { _, surface, width, height in
            let surface = surface.map { Unmanaged<IOSurfaceRef>.fromOpaque($0).takeUnretainedValue() }
            DesktopDisplay.shared.gpuFrame(surface, width: Int(width), height: Int(height))
        }
        setGPUFramesFunction?(nil, gpuFrame)
        return true
    }

    /// Stops receiving frames (Linux keeps its desktop).
    func detach() {
        detachFunction?()
        lock.lock()
        frame = nil
        source = nil
        // The surface on screen stays until the view is gone
        if let surface = gpuSurface, surface !== shownSurface { IOSurfaceDecrementUseCount(surface) }
        gpuSurface = nil
        gpuMode = false
        lock.unlock()
    }

    /// The size the guest should use, offered as its preferred mode.
    func setSize(width: Int, height: Int) {
        setSizeFunction?(Int32(width), Int32(height))
    }

    // MARK: Input (any thread)

    private let inputQueue = DispatchQueue(label: "app.ishplus.desktop.input")

    func movePointer(to point: CGPoint) {
        let x = Int32(point.x.rounded()), y = Int32(point.y.rounded())
        inputQueue.async { [pointerFunction] in pointerFunction?(x, y) }
    }

    enum MouseButton: Int32 { case left = 0, middle = 1, right = 2 }

    func button(_ button: MouseButton, down: Bool) {
        inputQueue.async { [buttonFunction] in buttonFunction?(button.rawValue, down ? 1 : 0) }
    }

    func click(_ button: MouseButton) {
        self.button(button, down: true)
        self.button(button, down: false)
    }

    /// Wheel clicks; positive dy scrolls down.
    func scroll(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        inputQueue.async { [scrollFunction] in scrollFunction?(Int32(dx), Int32(dy)) }
    }

    /// A USB HID usage (as UIKey.keyCode).
    func key(_ usage: Int, down: Bool) {
        inputQueue.async { [keyFunction] in keyFunction?(Int32(usage), down ? 1 : 0) }
    }
}
