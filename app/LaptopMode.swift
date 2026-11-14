//
//  LaptopMode.swift
//  iSH+
//
//  The iPad or iPhone as the bottom half of a laptop: with a monitor
//  connected (HDMI or AirPlay), or an iPhone Duo half folded, the terminal
//  session or the Linux desktop shows on the monitor (or the upper half), at
//  its full size, and this screen (or the lower half) becomes a keyboard,
//  with every key a computer has, and a trackpad.
//
//  The terminal controller (TerminalViewController.m) registers itself as
//  the host: it makes the view that shows the current session elsewhere,
//  takes it back, and sends the session's input.
//

import UIKit
import GameController

// MARK: - Coordinator

@objc(ISHLaptopMode)
public final class LaptopMode: NSObject {
    @objc public static let shared = LaptopMode()

    // Set by the terminal controller
    /// The controller laptop mode is presented from.
    @objc public weak var host: UIViewController?
    /// A view showing the current session (it moves the session's surface there).
    @objc public var makeTerminalView: ((CGRect) -> UIView?)?
    /// Gives the session's surface back to the terminal controller's view.
    @objc public var releaseTerminalView: (() -> Void)?
    /// Input for the current session, as typed.
    @objc public var sendTerminalInput: ((Data) -> Void)?
    /// Whether the desktop is what the user is looking at.
    @objc public var desktopIsShowing: (() -> Bool)?
    /// Whether a session runs and nothing is in the way (the JIT screen).
    @objc public var isReady: (() -> Bool)?
    /// Laptop mode ended: shows on this screen what the monitor showed.
    @objc public var restoreMode: ((Bool) -> Void)?
    /// The terminal controller's sessions menu (sessions, the desktop).
    @objc public var sessionsMenu: (() -> [UIMenuElement])?
    /// iSH+'s settings.
    @objc public var makeSettings: (() -> UIViewController?)?

    @objc public var isActive: Bool { kind != nil }
    @objc public var showsDesktop: Bool { content == .desktop }
    @objc public func showDesktopContent() { show(.desktop) }
    @objc public func showTerminalContent() { show(.terminal) }

    /// The terminal controller shows another session: so does the monitor.
    @objc public func terminalChanged() {
        guard kind != nil, content == .terminal else { return }
        screen?.reloadTerminal()
    }

    enum Content { case terminal, desktop }
    enum Kind { case external, folded }

    private(set) var kind: Kind?
    private(set) var content: Content = .terminal
    private var controls: LaptopControlsViewController?
    private var screen: LaptopScreenViewController?
    private var presented: UIViewController?
    private var externalWindow: UIWindow?
    private var externalScene: UIWindowScene?
    private var folded = false
    private var hingeInstalled = false

    /// The host is ready (its view is in a window): starts what is pending.
    @objc public func hostDidAppear() {
        installHinge()
        registerExternalDisplay()
        // Diagnostics: a file named laptop containing "fold" in the VM folder
        // acts as an iPhone Duo half folded (the fold across the middle)
        let flag = VirtualMachine.guestDirectory.appendingPathComponent("laptop")
        let test = (try? String(contentsOf: flag, encoding: .utf8)) ?? ""
        if test.hasPrefix("fold") {
            folded = true
            testFold = true
            // "fold desktop": with the desktop above the fold
            testDesktop = test.contains("desktop")
        }
        update()
    }

    private var testFold = false
    private var testDesktop = false

    // MARK: External display

    private var externalRegistration: AnyObject?

    /// iOS 27: the external display is a scene accessory of a view
    /// controller (here the terminal controller, which stays in its window
    /// under laptop mode): only then does iOS give iSH+ a scene there,
    /// rather than mirror this screen. As MeloNX does.
    private func registerExternalDisplay() {
        guard externalRegistration == nil, #available(iOS 27.0, *), let host else { return }
        let configuration = UISceneConfiguration(name: "External Display", sessionRole: .windowExternalDisplayNonInteractive)
        configuration.delegateClass = ExternalSceneDelegate.self
        externalRegistration = host.registerSceneAccessory(.externalNonInteractive(sceneConfiguration: configuration))
        vmLog("laptop mode: registered for external displays")
    }

    func externalSceneConnected(_ scene: UIWindowScene) {
        vmLog("laptop mode: external display connected (\(scene.session.role.rawValue), \(Int(scene.screen.bounds.width))x\(Int(scene.screen.bounds.height)) pt at \(scene.screen.scale)x)")
        externalScene = scene
        update()
    }

    func externalSceneDisconnected(_ scene: UIWindowScene) {
        vmLog("laptop mode: external display disconnected")
        guard scene === externalScene else { return }
        externalScene = nil
        update()
    }

    // MARK: iPhone Duo

    /// The fold, on the host's window: half folded with the fold across the
    /// screen (laptop posture) is laptop mode.
    private func installHinge() {
        guard !hingeInstalled, #available(iOS 27.1, *), let window = host?.view.window else { return }
        hingeInstalled = true
        let interaction = UIHingeInteraction { [weak self, weak window] _, update in
            guard let self, let window else { return }
            var folded = false
            if let hinge = update.hinge, hinge.status == .partiallyOpen {
                // The fold must run across the screen as it is held (the
                // upper half stands, the lower half lies flat)
                folded = window.reservedRegions(kind: .division).contains { $0.isActive && $0.frame.width > $0.frame.height }
            }
            if folded != self.folded {
                self.folded = folded
                self.update()
            }
        }
        window.addInteraction(interaction)
    }

    /// The fold's rect in a view, when folded.
    func foldRect(in view: UIView) -> CGRect? {
        if testFold { return CGRect(x: 0, y: view.bounds.midY - 10, width: view.bounds.width, height: 20) }
        guard #available(iOS 27.1, *), folded, let window = view.window,
              let region = window.reservedRegions(kind: .division).first(where: { $0.isActive }) else { return nil }
        return view.convert(region.frame, from: window)
    }

    // MARK: Starting and ending

    /// A monitor first; else the fold; else nothing.
    private func update() {
        let wanted: Kind? = externalScene != nil ? .external : (folded ? .folded : nil)
        guard wanted != kind else {
            (presented as? FoldedLaptopViewController)?.view.setNeedsLayout()
            return
        }
        // Back to this screen: as laptop mode left it (terminal or desktop)
        end(restore: wanted == nil) { [weak self] in
            guard let self, let wanted else { return }
            self.start(wanted)
        }
    }

    private func topViewController() -> UIViewController? {
        var top = host
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    private func start(_ kind: Kind) {
        guard isReady?() ?? true, let top = topViewController(), host?.view.window != nil else {
            vmLog("laptop mode: not started (ready \(isReady?() ?? true), host \(host != nil), in a window \(host?.view.window != nil))")
            return
        }
        vmLog("laptop mode: starting (\(kind == .external ? "monitor" : "folded"), presented from \(type(of: top)))")
        if kind == .external && externalScene == nil { return }
        self.kind = kind
        content = desktopIsShowing?() == true || testDesktop ? .desktop : .terminal
        let controls = LaptopControlsViewController(mode: self)
        let screen = LaptopScreenViewController(fullResolution: kind == .external)
        self.controls = controls
        self.screen = screen
        let shown: UIViewController
        if kind == .folded {
            shown = FoldedLaptopViewController(screen: screen, controls: controls)
        } else {
            shown = controls
        }
        // Over the host, which stays in its window (the display's registration)
        shown.modalPresentationStyle = .overFullScreen
        presented = shown
        top.present(shown, animated: true) { [weak self] in
            guard let self, self.kind == kind else { return }
            if kind == .external, let scene = self.externalScene {
                let window = UIWindow(windowScene: scene)
                window.rootViewController = screen
                window.isHidden = false
                self.externalWindow = window
            }
            screen.show(self.content)
            controls.contentChanged()
        }
    }

    private func end(restore: Bool, completion: @escaping () -> Void) {
        guard kind != nil else { return completion() }
        let desktop = content == .desktop
        kind = nil
        screen?.show(nil)
        externalWindow?.isHidden = true
        externalWindow = nil
        screen = nil
        controls?.stop()
        controls = nil
        let presented = self.presented
        self.presented = nil
        let ended = { [weak self] in
            NotificationCenter.default.post(name: LaptopMode.didEnd, object: nil)
            if restore { self?.restoreMode?(desktop) }
            completion()
        }
        if let presented, presented.presentingViewController != nil {
            presented.dismiss(animated: true, completion: ended)
        } else {
            ended()
        }
    }

    /// From the controls: what the monitor (or upper half) shows.
    func show(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        screen?.show(content)
        controls?.contentChanged()
    }

    /// Laptop mode ended: the desktop view under it takes its frames back.
    static let didEnd = Notification.Name("ISHLaptopModeDidEnd")

    /// The guest's screen size, for the trackpad's speed.
    var desktopSize: CGSize { DesktopDisplay.shared.size }
}

// MARK: - External display scene

/// The external display's scene (HDMI, AirPlay): iSH+ draws there itself
/// rather than iOS mirroring this screen.
@objc(ISHExternalSceneDelegate)
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        LaptopMode.shared.externalSceneConnected(scene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let scene = scene as? UIWindowScene else { return }
        LaptopMode.shared.externalSceneDisconnected(scene)
    }
}

// MARK: - The screen (monitor or upper half)

final class LaptopScreenViewController: UIViewController {
    /// The monitor's own pixels; else the view's points, at least 1024 wide.
    private let fullResolution: Bool
    private let display = DesktopDisplay.shared
    private let screenLayer = CALayer()
    private let cursorLayer = CALayer()
    private let statusLabel = UILabel()
    private var terminalView: UIView?
    private var content: LaptopMode.Content?
    private var guestSize = CGSize.zero
    private var pointer = CGPoint.zero
    private var cursorHotSpot = CGPoint.zero
    private var cursorImageSize = CGSize.zero
    private var lastRequestedSize = CGSize.zero
    private var resizeWork: DispatchWorkItem?

    init(fullResolution: Bool) {
        self.fullResolution = fullResolution
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true
        screenLayer.magnificationFilter = .linear
        screenLayer.minificationFilter = .trilinear
        view.layer.addSublayer(screenLayer)
        cursorLayer.zPosition = 10
        cursorLayer.magnificationFilter = .nearest
        view.layer.addSublayer(cursorLayer)
        statusLabel.textColor = .lightGray
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        terminalView?.frame = view.bounds.inset(by: view.safeAreaInsets)
        layoutScreen()
        if content == .desktop { requestSize() }
    }

    /// Another session: its view instead (the old one's surface is back
    /// with the terminal controller, which shows the new one meanwhile).
    func reloadTerminal() {
        guard content == .terminal else { return }
        terminalView?.removeFromSuperview()
        terminalView = nil
        content = nil
        show(.terminal)
    }

    /// Shows the content (nil: gives everything back).
    func show(_ content: LaptopMode.Content?) {
        loadViewIfNeeded()
        if self.content == .terminal && content != .terminal {
            terminalView?.removeFromSuperview()
            terminalView = nil
            LaptopMode.shared.releaseTerminalView?()
        }
        if self.content == .desktop && content != .desktop {
            if display.viewer === self {
                display.viewer = nil
                display.detach()
                display.onFrame = nil
                display.onCursor = nil
                display.onCursorPosition = nil
            }
            screenLayer.contents = nil
            cursorLayer.contents = nil
            guestSize = .zero
        }
        self.content = content
        statusLabel.text = nil
        switch content {
        case .terminal:
            // Made at its size: the session's view inside sizes itself from it
            let frame = view.bounds.inset(by: view.safeAreaInsets)
            if terminalView == nil, let terminal = LaptopMode.shared.makeTerminalView?(frame) {
                terminalView = terminal
                terminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.addSubview(terminal)
            }
        case .desktop:
            statusLabel.text = "Starting the desktop…"
            display.viewer = self
            display.onFrame = { [weak self] contents, size in self?.showFrame(contents, size: size) }
            display.onCursor = { [weak self] image, hotSpot in self?.setCursor(image, hotSpot: hotSpot) }
            display.onCursorPosition = { [weak self] point, visible in
                guard let self else { return }
                self.pointer = point
                self.cursorLayer.isHidden = !visible
                self.layoutScreen()
            }
            display.attach()
            // The trackpad moves Linux's pointer, as a mouse does
            display.relative = display.hasRelativeMouse
            lastRequestedSize = .zero
            requestSize()
            DesktopSession.start { [weak self] error in
                if let error { self?.statusLabel.text = error }
            }
        case nil:
            break
        }
    }

    private func showFrame(_ contents: AnyObject?, size: CGSize) {
        guard let contents, size.width > 0, size.height > 0 else { return }
        statusLabel.text = nil
        guestSize = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if screenLayer.contents as AnyObject? === contents { screenLayer.contents = nil }
        screenLayer.contents = contents
        layoutScreenLocked()
        CATransaction.commit()
    }

    private func setCursor(_ image: CGImage?, hotSpot: CGPoint) {
        cursorLayer.contents = image
        cursorLayer.isHidden = image == nil
        cursorHotSpot = hotSpot
        cursorImageSize = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        layoutScreen()
    }

    private func layoutScreen() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutScreenLocked()
        CATransaction.commit()
    }

    private func layoutScreenLocked() {
        let area = view.bounds
        guard guestSize.width > 0, guestSize.height > 0, area.width > 0 else { return }
        let fit = min(area.width / guestSize.width, area.height / guestSize.height)
        let size = CGSize(width: guestSize.width * fit, height: guestSize.height * fit)
        let rect = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        screenLayer.frame = rect
        cursorLayer.frame = CGRect(x: rect.minX + (pointer.x - cursorHotSpot.x) * fit,
                                   y: rect.minY + (pointer.y - cursorHotSpot.y) * fit,
                                   width: cursorImageSize.width * fit, height: cursorImageSize.height * fit)
    }

    /// The monitor's resolution (its pixels), or the upper half's points
    /// (at least 1024 wide, so a desktop fits).
    private func requestSize() {
        let bounds = view.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        var factor: CGFloat
        if fullResolution {
            factor = view.window?.screen.scale ?? view.contentScaleFactor
        } else {
            factor = max(1, 1024 / bounds.width)
        }
        factor = max(factor, 1)
        let width = Int((bounds.width * factor / 8).rounded()) * 8
        let height = Int((bounds.height * factor / 8).rounded()) * 8
        let size = CGSize(width: width, height: height)
        guard size != lastRequestedSize else { return }
        lastRequestedSize = size
        display.setSize(width: width, height: height)
        resizeWork?.cancel()
        let work = DispatchWorkItem { DesktopSession.resize() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}

// MARK: - iPhone Duo, half folded

/// The screen above the fold, the keyboard and trackpad below it.
final class FoldedLaptopViewController: UIViewController {
    private let screen: LaptopScreenViewController
    private let controls: LaptopControlsViewController

    init(screen: LaptopScreenViewController, controls: LaptopControlsViewController) {
        self.screen = screen
        self.controls = controls
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var childViewControllerForPointerLock: UIViewController? { controls }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        for child in [screen, controls] as [UIViewController] {
            addChild(child)
            view.addSubview(child.view)
            child.didMove(toParent: self)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        controls.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        // Above and below the fold (half and half until it is known)
        let fold = LaptopMode.shared.foldRect(in: view) ?? CGRect(x: 0, y: bounds.midY, width: bounds.width, height: 0)
        screen.view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, fold.minY))
        controls.view.frame = CGRect(x: 0, y: fold.maxY, width: bounds.width, height: max(0, bounds.maxY - fold.maxY))
    }
}

// MARK: - The keyboard and trackpad

final class LaptopControlsViewController: UIViewController {
    private unowned let mode: LaptopMode
    private let keyboard = LaptopKeyboardView()
    private let trackpad = LaptopTrackpadView()
    private let toolbar = UIStackView()
    private let display = DesktopDisplay.shared
    private var translator = TerminalKeyTranslator()
    private let mouse = CapturedMouse()
    /// With the trackpad (desktop), the keyboard takes about half the
    /// height; without it (terminal), all of it
    private var keyboardWithTrackpad: [NSLayoutConstraint] = []
    private var keyboardAlone: [NSLayoutConstraint] = []

    init(mode: LaptopMode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    /// A real mouse moves Linux's pointer on the monitor, uncaught by this screen
    override var prefersPointerLocked: Bool { mode.content == .desktop }
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LaptopColors.background
        setUpToolbar()
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        trackpad.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        view.addSubview(keyboard)
        view.addSubview(trackpad)
        let guide = view.safeAreaLayoutGuide
        // A MacBook's lower half: the keyboard, then a trackpad centered below it
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            toolbar.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),
            // Keys about the size of iPadOS's own: no bigger on big screens
            keyboard.topAnchor.constraint(greaterThanOrEqualTo: toolbar.bottomAnchor, constant: 6),
            keyboard.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            keyboard.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -12).withPriority(.defaultHigh),
            keyboard.widthAnchor.constraint(lessThanOrEqualToConstant: 1100),
            keyboard.heightAnchor.constraint(lessThanOrEqualToConstant: 360),
            trackpad.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            trackpad.widthAnchor.constraint(equalTo: keyboard.widthAnchor, multiplier: 0.5).withPriority(.defaultHigh),
            trackpad.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).withPriority(.defaultHigh),
            trackpad.widthAnchor.constraint(lessThanOrEqualTo: keyboard.widthAnchor),
        ])
        // Desktop: the keyboard below the switch, the trackpad under it
        keyboardWithTrackpad = [
            keyboard.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            keyboard.heightAnchor.constraint(equalTo: guide.heightAnchor, multiplier: 0.52).withPriority(.defaultHigh),
            trackpad.topAnchor.constraint(equalTo: keyboard.bottomAnchor, constant: 10),
            trackpad.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -10),
        ]
        // Terminal: the keyboard alone, at the bottom, where the hands are
        keyboardAlone = [
            keyboard.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -10),
            keyboard.heightAnchor.constraint(equalTo: guide.heightAnchor).withPriority(.defaultHigh),
        ]
        NSLayoutConstraint.activate(keyboardWithTrackpad)
        keyboard.onKey = { [weak self] usage, down in self?.key(usage, down: down) }
        trackpad.onMove = { [weak self] dx, dy in self?.move(dx: dx, dy: dy) }
        trackpad.onButton = { [weak self] button, down in self?.button(button, down: down) }
        trackpad.onScroll = { [weak self] dx, dy in self?.scroll(dx: dx, dy: dy) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    func contentChanged() {
        loadViewIfNeeded()
        keyboard.repeats = mode.content == .terminal
        // The trackpad is for the desktop's pointer
        let desktop = mode.content == .desktop
        trackpad.isHidden = !desktop
        NSLayoutConstraint.deactivate(keyboardWithTrackpad + keyboardAlone)
        NSLayoutConstraint.activate(desktop ? keyboardWithTrackpad : keyboardAlone)
        translator = TerminalKeyTranslator()
        keyboard.releaseAll()
        setNeedsUpdateOfPrefersPointerLocked()
        if mode.content == .desktop { mouse.start(display) } else { mouse.stop() }
        becomeFirstResponder()
    }

    func stop() {
        keyboard.releaseAll()
        mouse.stop()
    }

    /// As the terminal's keyboard bar: sessions (and the desktop), settings, paste.
    private func setUpToolbar() {
        func button(_ symbol: String, _ label: String) -> UIButton {
            var configuration: UIButton.Configuration
            if #available(iOS 26.0, *) {
                configuration = .glass() // Liquid Glass
            } else {
                configuration = .plain()
                configuration.background.backgroundColor = LaptopColors.key
                configuration.background.cornerRadius = 6
            }
            configuration.image = UIImage(systemName: symbol)
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            configuration.baseForegroundColor = .label
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
            let button = UIButton(configuration: configuration)
            button.accessibilityLabel = label
            // Capsules, as the glass style draws them, with room for the symbol
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 60),
                button.heightAnchor.constraint(equalToConstant: 44),
            ])
            return button
        }
        let sessions = button("square.on.square", "Sessions")
        sessions.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                // Whether there is a desktop to offer (asked of Linux, briefly), as the terminal's bar does
                DesktopSession.checkAvailability(timeout: 1.5) { _ in completion(self?.mode.sessionsMenu?() ?? []) }
            },
        ])
        sessions.showsMenuAsPrimaryAction = true
        let settings = button("gear", "Settings")
        settings.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
        let paste = button("doc.on.clipboard", "Paste")
        paste.addTarget(self, action: #selector(pasteText), for: .touchUpInside)
        for item in [sessions, settings, paste] { toolbar.addArrangedSubview(item) }
        toolbar.axis = .horizontal
        toolbar.spacing = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func showSettings() {
        guard let settings = mode.makeSettings?() else { return }
        present(settings, animated: true)
    }

    /// The clipboard as typed: to the session, or as keys on the desktop.
    @objc private func pasteText() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        switch mode.content {
        case .terminal:
            if let data = text.data(using: .utf8) { mode.sendTerminalInput?(data) }
        case .desktop:
            for character in text {
                let usage: Int, shift: Bool
                if character == "\n" || character == "\r\n" { (usage, shift) = (Keys.enter, false) }
                else if let key = Keys.usage(for: character) { (usage, shift) = key }
                else { continue }
                if shift { display.key(Keys.leftShift, down: true) }
                display.key(usage, down: true)
                display.key(usage, down: false)
                if shift { display.key(Keys.leftShift, down: false) }
            }
        }
    }

    // MARK: Output

    private func key(_ usage: Int, down: Bool, hardware: Bool = false) {
        // A hardware keyboard's caps lock shows on this one too
        if hardware && usage == 57 && down { keyboard.toggleCapsLock() }
        switch mode.content {
        case .desktop:
            display.key(usage, down: down)
        case .terminal:
            if let data = translator.handle(usage: usage, down: down) { mode.sendTerminalInput?(data) }
        }
    }

    private func move(dx: CGFloat, dy: CGFloat) {
        guard mode.content == .desktop else { return }
        // Faster on bigger screens: crossing the trackpad crosses most of it
        let size = mode.desktopSize
        let factor = max(1.2, size.width / max(trackpad.bounds.width, 1) * 0.9)
        display.move(dx: dx * factor, dy: dy * factor)
    }

    private func button(_ button: DesktopDisplay.MouseButton, down: Bool) {
        guard mode.content == .desktop else { return }
        display.button(button, down: down)
    }

    private func scroll(dx: Int, dy: Int) {
        guard mode.content == .desktop else { return }
        display.scroll(dx: dx, dy: dy)
    }

    // MARK: A hardware keyboard: every key, to the same place

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key { self.key(key.keyCode.rawValue, down: true, hardware: true); handled = true }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key { self.key(key.keyCode.rawValue, down: false); handled = true }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key { self.key(key.keyCode.rawValue, down: false) }
        }
        super.pressesCancelled(presses, with: event)
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

// MARK: - A captured mouse

/// A mouse's own movement, buttons and wheel, to Linux's relative mouse
/// (with the pointer locked, iPadOS hides its own and keeps it in place).
final class CapturedMouse {
    private var observer: NSObjectProtocol?
    private weak var display: DesktopDisplay?
    private var wheelRemainder = CGPoint.zero

    var isActive: Bool { observer != nil }

    func start(_ display: DesktopDisplay) {
        guard observer == nil else { return }
        self.display = display
        GCMouse.mice().forEach(listen)
        observer = NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            if let mouse = note.object as? GCMouse { self?.listen(to: mouse) }
        }
    }

    func stop() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
        for mouse in GCMouse.mice() {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = nil
            input.leftButton.pressedChangedHandler = nil
            input.rightButton?.pressedChangedHandler = nil
            input.middleButton?.pressedChangedHandler = nil
            input.scroll.valueChangedHandler = nil
        }
        for button in [DesktopDisplay.MouseButton.left, .middle, .right] { display?.button(button, down: false) }
    }

    private func listen(to mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = { [weak self] _, dx, dy in
            // Up is positive for GameController, down for Linux
            self?.display?.move(dx: CGFloat(dx), dy: CGFloat(-dy))
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in self?.display?.button(.left, down: pressed) }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.display?.button(.right, down: pressed) }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.display?.button(.middle, down: pressed) }
        input.scroll.valueChangedHandler = { [weak self] _, x, y in
            guard let self else { return }
            // Wheel clicks; trackpads give fractions. Up is positive here too.
            self.wheelRemainder.x += CGFloat(x)
            self.wheelRemainder.y -= CGFloat(y)
            let dx = Int(self.wheelRemainder.x), dy = Int(self.wheelRemainder.y)
            self.wheelRemainder.x -= CGFloat(dx)
            self.wheelRemainder.y -= CGFloat(dy)
            self.display?.scroll(dx: dx, dy: dy)
        }
    }
}

// MARK: - Keys to terminal input

/// Keys (USB HID usages, down and up) to what a terminal reads: text,
/// control characters, escape sequences (xterm's). Tracks the modifiers.
struct TerminalKeyTranslator {
    private var shift = false, control = false, alt = false, capsLock = false

    private static let base: [Int: (String, String)] = {
        var table: [Int: (String, String)] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { table[4 + i] = (String(c), String(c).uppercased()) }
        let digits = Array("1234567890"), shifted = Array("!@#$%^&*()")
        for i in 0..<10 { table[30 + i] = (String(digits[i]), String(shifted[i])) }
        let pairs: [(Int, String, String)] = [
            (44, " ", " "), (45, "-", "_"), (46, "=", "+"), (47, "[", "{"), (48, "]", "}"), (49, "\\", "|"),
            (51, ";", ":"), (52, "'", "\""), (53, "`", "~"), (54, ",", "<"), (55, ".", ">"), (56, "/", "?"),
        ]
        for (usage, plain, shifted) in pairs { table[usage] = (plain, shifted) }
        return table
    }()

    private static let special: [Int: String] = [
        40: "\r", 41: "\u{1b}", 42: "\u{7f}", 43: "\t",
        79: "\u{1b}[C", 80: "\u{1b}[D", 81: "\u{1b}[B", 82: "\u{1b}[A",
        58: "\u{1b}OP", 59: "\u{1b}OQ", 60: "\u{1b}OR", 61: "\u{1b}OS",
        62: "\u{1b}[15~", 63: "\u{1b}[17~", 64: "\u{1b}[18~", 65: "\u{1b}[19~",
        66: "\u{1b}[20~", 67: "\u{1b}[21~", 68: "\u{1b}[23~", 69: "\u{1b}[24~",
        73: "\u{1b}[2~", 74: "\u{1b}[H", 75: "\u{1b}[5~", 76: "\u{1b}[3~", 77: "\u{1b}[F", 78: "\u{1b}[6~",
    ]

    mutating func handle(usage: Int, down: Bool) -> Data? {
        switch usage {
        case 225, 229: shift = down; return nil
        case 224, 228: control = down; return nil
        case 226, 230: alt = down; return nil
        case 227, 231: return nil
        case 57: if down { capsLock.toggle() }; return nil
        default: break
        }
        guard down else { return nil }
        var text: String
        if let special = Self.special[usage] {
            text = special
            if usage == 43 && shift { text = "\u{1b}[Z" }
        } else if let (plain, shifted) = Self.base[usage] {
            let isLetter = (4...29).contains(usage)
            text = (shift != (isLetter && capsLock)) ? shifted : plain
            if control, let scalar = plain.unicodeScalars.first {
                switch plain {
                case "a"..."z": text = String(UnicodeScalar(UInt8(scalar.value) & 0x1f))
                case " ", "2": text = "\u{0}"
                case "[": text = "\u{1b}"
                case "\\": text = "\u{1c}"
                case "]": text = "\u{1d}"
                case "6": text = "\u{1e}"
                case "/", "-": text = "\u{1f}"
                default: break
                }
            }
        } else {
            return nil
        }
        // Alt (Meta) sends Escape first, as xterm's metaSendsEscape
        if alt && !text.hasPrefix("\u{1b}[") { text = "\u{1b}" + text }
        return text.data(using: .utf8)
    }
}

// MARK: - Colors

/// The keyboard's and trackpad's colors, light or dark with the appearance,
/// as iOS's own keyboard.
enum LaptopColors {
    private static func dynamic(dark: CGFloat, light: CGFloat) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: dark, alpha: 1) : UIColor(white: light, alpha: 1) }
    }
    static let background = dynamic(dark: 0.08, light: 0.80)
    static let key = dynamic(dark: 0.22, light: 1.0)
    /// A key held down
    static let pressed = dynamic(dark: 0.45, light: 0.62)
    /// A key that is on (caps lock, a latched modifier): lighter on dark,
    /// darker on light
    static let on = dynamic(dark: 0.36, light: 0.72)
    static let trackpad = dynamic(dark: 0.16, light: 0.90)
    static let trackpadBorder = dynamic(dark: 0.30, light: 0.70)
}

// MARK: - Keyboard view

/// A full keyboard, as on a laptop: Esc and the function keys, every
/// symbol, Control, Alt (Option) and Super. Each touch is a key held down
/// until the finger lifts, so keys combine as on a real keyboard. A
/// modifier tapped alone stays down for the next key (tap it again to
/// release it).
final class LaptopKeyboardView: UIView {
    var onKey: ((Int, Bool) -> Void)?
    /// Keys held down repeat (for the terminal; Linux's desktop repeats them itself).
    var repeats = true

    private struct Key {
        let label: String
        let shifted: String?
        let usage: Int
        let width: CGFloat
    }

    private static let modifierUsages: Set<Int> = [224, 225, 226, 227, 228, 229, 230, 231]

    private static let rows: [[Key]] = {
        func k(_ label: String, _ usage: Int, _ width: CGFloat = 1, _ shifted: String? = nil) -> Key {
            Key(label: label, shifted: shifted, usage: usage, width: width)
        }
        func letters(_ s: String) -> [Key] {
            s.map { c in k(String(c), 4 + Int(c.asciiValue! - 97), 1, String(c).uppercased()) }
        }
        let digits = Array("1234567890"), symbols = Array("!@#$%^&*()")
        var numberRow = [k("`", 53, 1, "~")]
        for i in 0..<10 { numberRow.append(k(String(digits[i]), 30 + i, 1, String(symbols[i]))) }
        numberRow += [k("-", 45, 1, "_"), k("=", 46, 1, "+"), k("⌫", 42, 1.5)]
        var functionRow = [k("esc", 41, 1.25)]
        for i in 1...12 { functionRow.append(k("F\(i)", 57 + i, 0.9)) }
        functionRow.append(k("del", 76, 1.25))
        return [
            functionRow,
            numberRow,
            [k("tab", 43, 1.5)] + letters("qwertyuiop") + [k("[", 47, 1, "{"), k("]", 48, 1, "}"), k("\\", 49, 1, "|")],
            [k("caps", 57, 1.75)] + letters("asdfghjkl") + [k(";", 51, 1, ":"), k("'", 52, 1, "\""), k("return", 40, 1.75)],
            [k("shift", 225, 2.25)] + letters("zxcvbnm") + [k(",", 54, 1, "<"), k(".", 55, 1, ">"), k("/", 56, 1, "?"), k("shift", 229, 2.25)],
            [k("ctrl", 224, 1.25), k("alt", 226, 1.25), k("super", 227, 1.25), k("", 44, 5), k("alt", 230, 1.25),
             k("←", 80), k("↑", 82), k("↓", 81), k("→", 79)],
        ]
    }()

    private var keyViews: [(key: Key, view: UILabel)] = []
    /// What each finger is pressing
    private var touched: [UITouch: Int] = [:]
    /// Modifiers held by a finger, and whether a key was pressed meanwhile
    private var heldModifiers: [Int: Bool] = [:]
    /// Modifiers tapped alone: down until the next key
    private var latched: Set<Int> = []
    private var repeatTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        for row in Self.rows {
            for key in row {
                let label = UILabel()
                label.text = key.label
                label.textAlignment = .center
                label.textColor = .label
                label.adjustsFontSizeToFitWidth = true
                label.minimumScaleFactor = 0.5
                label.backgroundColor = LaptopColors.key
                label.layer.cornerRadius = 6
                label.clipsToBounds = true
                label.isAccessibilityElement = true
                label.accessibilityTraits = .keyboardKey
                label.accessibilityLabel = key.label.isEmpty ? "space" : key.label
                addSubview(label)
                keyViews.append((key, label))
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
#if targetEnvironment(simulator)
        // Trying the look of caps lock on (simctl spawn ... defaults write
        // <app> ISHSimulatorCapsLock -bool YES)
        if window != nil, !capsLock, UserDefaults.standard.bool(forKey: "ISHSimulatorCapsLock") { toggleCapsLock() }
#endif
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap: CGFloat = 5
        // The function row is shorter, as on a laptop
        let weights = Self.rows.indices.map { $0 == 0 ? CGFloat(0.75) : 1 }
        let unitHeight = (bounds.height - gap * CGFloat(Self.rows.count - 1)) / weights.reduce(0, +)
        let fontSize = max(9, min(20, unitHeight * 0.38))
        var index = 0
        var y: CGFloat = 0
        for (r, row) in Self.rows.enumerated() {
            let height = unitHeight * weights[r]
            let units = row.reduce(0) { $0 + $1.width }
            let unit = (bounds.width - gap * CGFloat(row.count - 1)) / units
            var x: CGFloat = 0
            for key in row {
                let width = unit * key.width
                let view = keyViews[index].view
                view.frame = CGRect(x: x, y: y, width: width, height: height)
                view.font = .systemFont(ofSize: key.label.count > 2 ? fontSize * 0.7 : fontSize)
                x += width + gap
                index += 1
            }
            y += height + gap
        }
        updateLabels()
    }

    private func usage(at point: CGPoint) -> Int? {
        keyViews.first { $0.view.frame.insetBy(dx: -2, dy: -2).contains(point) }?.key.usage
    }

    private var shiftActive: Bool {
        heldModifiers[225] != nil || heldModifiers[229] != nil || latched.contains(225) || latched.contains(229)
    }

    /// Caps lock is on: its key shows it, and letters are capitals.
    private(set) var capsLock = false

    /// Caps lock pressed (here, or on a hardware keyboard).
    func toggleCapsLock() {
        capsLock.toggle()
        updateLabels()
    }

    private func updateLabels() {
        let shift = shiftActive
        for (key, view) in keyViews {
            let letter = (4...29).contains(key.usage)
            view.text = (shift != (letter && capsLock)) ? (key.shifted ?? key.label) : key.label
            let pressed = touched.values.contains(key.usage)
            let on = latched.contains(key.usage) || (key.usage == 57 && capsLock)
            view.backgroundColor = pressed ? LaptopColors.pressed : on ? LaptopColors.on : LaptopColors.key
        }
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let usage = usage(at: touch.location(in: self)) else { continue }
            touched[touch] = usage
            press(usage)
        }
        updateLabels()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let usage = touched.removeValue(forKey: touch) else { continue }
            release(usage)
        }
        updateLabels()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func press(_ usage: Int) {
        UIDevice.current.playInputClick()
        if Self.modifierUsages.contains(usage) {
            if latched.remove(usage) != nil {
                // Tapped again: released (on the finger's lift, nothing more)
                onKey?(usage, false)
                heldModifiers[usage] = true
                return
            }
            heldModifiers[usage] = false
            onKey?(usage, true)
            return
        }
        for modifier in heldModifiers.keys { heldModifiers[modifier] = true }
        if usage == 57 { capsLock.toggle() }
        onKey?(usage, true)
        startRepeat(usage)
    }

    private func release(_ usage: Int) {
        if Self.modifierUsages.contains(usage) {
            let usedOrUnlatched = heldModifiers.removeValue(forKey: usage) ?? true
            if usedOrUnlatched {
                if !latched.contains(usage) { onKey?(usage, false) }
            } else {
                latched.insert(usage) // tapped alone: for the next key
            }
            return
        }
        stopRepeat()
        onKey?(usage, false)
        // A latched modifier is used once
        for modifier in latched { onKey?(modifier, false) }
        latched.removeAll()
    }

    /// Lifts every key (switching what the keys go to, leaving).
    func releaseAll() {
        stopRepeat()
        for usage in Set(touched.values).union(latched).union(heldModifiers.keys) { onKey?(usage, false) }
        touched.removeAll()
        heldModifiers.removeAll()
        latched.removeAll()
        updateLabels()
    }

    private func startRepeat(_ usage: Int) {
        stopRepeat()
        guard repeats, ![41, 57].contains(usage) else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, self.touched.values.contains(usage) else { self?.stopRepeat(); return }
                self.onKey?(usage, true)
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

extension LaptopKeyboardView: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

// MARK: - Trackpad view

/// One finger moves the pointer; tap clicks, two fingers tap for the right
/// button and three for the middle one; two fingers scroll; touch, hold,
/// then move to drag.
final class LaptopTrackpadView: UIView, UIGestureRecognizerDelegate {
    var onMove: ((CGFloat, CGFloat) -> Void)?
    var onButton: ((DesktopDisplay.MouseButton, Bool) -> Void)?
    var onScroll: ((Int, Int) -> Void)?
    var isEnabled = true { didSet { alpha = isEnabled ? 1 : 0.5 } }

    private var lastLocation = CGPoint.zero
    private var dragging = false
    private var scrollRemainder = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = LaptopColors.trackpad
        layer.cornerRadius = 14
        layer.borderColor = LaptopColors.trackpadBorder.resolvedColor(with: traitCollection).cgColor
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: LaptopTrackpadView, _) in
                view.layer.borderColor = LaptopColors.trackpadBorder.resolvedColor(with: view.traitCollection).cgColor
            }
        }
        layer.borderWidth = 1
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        func add(_ recognizer: UIGestureRecognizer) {
            recognizer.allowedTouchTypes = direct
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        add(pan)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        add(scroll)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        add(tap)
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped))
        twoFingerTap.numberOfTouchesRequired = 2
        add(twoFingerTap)
        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(threeFingerTapped))
        threeFingerTap.numberOfTouchesRequired = 3
        add(threeFingerTap)
        tap.require(toFail: twoFingerTap)
        twoFingerTap.require(toFail: threeFingerTap)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        add(hold)
    }

    required init?(coder: NSCoder) { fatalError() }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Hold, then move: a drag
        recognizer is UILongPressGestureRecognizer || other is UILongPressGestureRecognizer
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard isEnabled else { return }
        let location = recognizer.location(in: self)
        if recognizer.state == .began { lastLocation = location }
        let delta = CGPoint(x: location.x - lastLocation.x, y: location.y - lastLocation.y)
        lastLocation = location
        // A constant speed: Linux does not accelerate either (desktop.sh)
        onMove?(delta.x, delta.y)
    }

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        guard isEnabled else { return }
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        if recognizer.state == .began { scrollRemainder = .zero }
        // Content follows the fingers, as on iOS
        scrollRemainder.x -= translation.x
        scrollRemainder.y -= translation.y
        let step: CGFloat = 14
        let dx = Int(scrollRemainder.x / step), dy = Int(scrollRemainder.y / step)
        scrollRemainder.x -= CGFloat(dx) * step
        scrollRemainder.y -= CGFloat(dy) * step
        if dx != 0 || dy != 0 { onScroll?(dx, dy) }
    }

    private func click(_ button: DesktopDisplay.MouseButton) {
        guard isEnabled else { return }
        onButton?(button, true)
        onButton?(button, false)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func tapped() { click(.left) }
    @objc private func twoFingerTapped() { click(.right) }
    @objc private func threeFingerTapped() { click(.middle) }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        guard isEnabled else { return }
        switch recognizer.state {
        case .began:
            dragging = true
            onButton?(.left, true)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .ended, .cancelled, .failed:
            if dragging {
                dragging = false
                onButton?(.left, false)
            }
        default:
            break
        }
    }
}
