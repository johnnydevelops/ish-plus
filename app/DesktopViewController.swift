//
//  DesktopViewController.swift
//  iSH+
//
//  The Desktop session: Linux's X11 desktop on the VM's display, shown when
//  Xorg and a desktop environment or window manager are installed (the
//  guest's boot/desktop.sh decides, and starts them). Touch controls like
//  UTM's:
//  - Trackpad mode: drag moves the pointer, tap clicks, long press then drag
//    holds the button (to move windows, select text).
//  - Touch mode: the pointer goes where you touch; tap clicks there, drag
//    drags, long press right-clicks.
//  - Both: two-finger tap right-clicks, three-finger tap middle-clicks,
//    two-finger drag scrolls, pinch zooms (move while pinching to pan).
//  - A mouse or trackpad on iPad points and clicks directly; hardware
//    keyboards type, and the on-screen keyboard has Esc, Tab, Ctrl, Alt,
//    Super and arrows.
//

import UIKit
import GameController

// MARK: - Availability and control (in the guest, as root)

/// Whether the display has rounded corners (and so maybe a notch, Dynamic
/// Island or home indicator to keep clear of). Square screens report safe
/// area insets too (iPadOS: 20 points at the bottom), which there would only
/// waste space.
@objc(ISHScreenShape)
public final class ScreenShape: NSObject {
    @objc public static var isRounded: Bool {
        let key = "_displayCornerRadius"
        guard UIScreen.main.responds(to: NSSelectorFromString(key)) else { return true }
        return ((UIScreen.main.value(forKey: key) as? CGFloat) ?? 1) > 0
    }

    /// The display's corner radius, in points (0 on a square one).
    @objc public static var cornerRadius: CGFloat {
        let key = "_displayCornerRadius"
        guard UIScreen.main.responds(to: NSSelectorFromString(key)) else { return 0 }
        return (UIScreen.main.value(forKey: key) as? CGFloat) ?? 0
    }

    /// @insets on a rounded screen, none on a square one.
    @objc public static func insets(_ insets: UIEdgeInsets) -> UIEdgeInsets {
        isRounded ? insets : .zero
    }
}

@objc(ISHDesktopSession)
public final class DesktopSession: NSObject {
    private static let script = "sh /opt/ishplus/boot/desktop.sh"

    /// A desktop Linux can start: an X11 or Wayland session, or a window manager.
    @objc(ISHDesktopSessionChoice)
    public final class Choice: NSObject {
        /// What desktop.sh starts it by (nil from an older support disk: the default)
        @objc public let id: String?
        @objc public let name: String
        @objc public let wayland: Bool

        init(id: String?, name: String, wayland: Bool) {
            self.id = id
            self.name = name
            self.wayland = wayland
        }
    }

    /// The desktops installed, as last checked; empty when there is none
    /// (or Linux is not running).
    @objc public private(set) static var available: [Choice] = []

    /// The first one's name ("Xfce Session", "openbox"...), or nil.
    @objc public static var availableName: String? { available.first?.name }

    /// The one the user picked (nil: desktop.sh's default, or the last one).
    @objc public static var chosen: String?

    /// Checks again; completion(name) on the main thread, within the timeout
    /// (with the last known answer if Linux is busy).
    @objc public static func checkAvailability(timeout: TimeInterval, completion: @escaping (String?) -> Void) {
        guard VirtualMachine.shared.isRunning, DesktopDisplay.shared.isAvailable else {
            available = []
            return completion(nil)
        }
        var answered = false
        let answer: (String?) -> Void = { name in
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                completion(name)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { answer(availableName) }
        // Every session ("id<TAB>x11|wayland<TAB>name" lines); an older
        // support disk only knows check (the default's name)
        GuestServices.shared.run("\(script) list", asRoot: true) { status, output in
            let choices: [Choice] = output.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 3, !fields[0].isEmpty, !fields[2].isEmpty else { return nil }
                return Choice(id: fields[0], name: fields[2], wayland: fields[1] == "wayland")
            }
            if status == 0 && !choices.isEmpty {
                DispatchQueue.main.async {
                    available = choices
                    answer(availableName)
                }
                return
            }
            GuestServices.shared.run("\(script) check", asRoot: true) { status, output in
                let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    available = status == 0 && !name.isEmpty ? [Choice(id: nil, name: name, wayland: false)] : []
                    answer(availableName)
                }
            }
        }
    }

    /// Starts the chosen desktop (switching from another one), unless it runs.
    static func start(completion: @escaping (String?) -> Void) {
        let id = chosen.map { " '" + $0.replacingOccurrences(of: "'", with: "") + "'" } ?? ""
        GuestServices.shared.run("\(script) start\(id)", asRoot: true) { status, output in
            let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { completion(status == 0 ? nil : (message.isEmpty ? "The desktop did not start." : message)) }
        }
    }

    /// Another desktop picked while one shows: switches to it.
    @objc public static func choose(_ id: String?, switchNow: Bool) {
        chosen = id
        if switchNow { start { _ in } }
    }

    static func resize() {
        GuestServices.shared.run("\(script) resize", asRoot: true) { _, _ in }
    }

    static func stop(completion: @escaping () -> Void) {
        GuestServices.shared.run("\(script) stop", asRoot: true) { _, _ in
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// The Desktop session's screen; menuProvider gives its sessions menu.
    @objc public static func makeViewController(menuProvider: @escaping () -> [UIMenuElement]) -> UIViewController {
        let controller = DesktopViewController()
        controller.menuProvider = menuProvider
        controller.modalPresentationStyle = .fullScreen
        return controller
    }
}

// MARK: - The view

final class DesktopViewController: UIViewController, UIGestureRecognizerDelegate, UIKeyInput, UIPointerInteractionDelegate {
    var menuProvider: (() -> [UIMenuElement])?

    private let display = DesktopDisplay.shared
    private let screenLayer = CALayer()
    private let cursorLayer = CALayer()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var toolbar: UIView!
    private var toolbarHidden = false
    private var showToolbarButton: UIButton!
    private var modeButton: UIButton!

    /// The guest's screen, in its pixels
    private var guestSize: CGSize = .zero
    /// Zoom (1: the whole screen fits) and the point of the screen at the view's center
    private var zoom: CGFloat = 1
    private var center = CGPoint(x: 0.5, y: 0.5)
    /// Where the pointer is, in guest pixels
    private var pointer = CGPoint.zero
    private var cursorHotSpot = CGPoint.zero
    private var cursorImageSize = CGSize.zero

    private enum InputMode: String { case trackpad, touch }
    private var mode: InputMode {
        get { InputMode(rawValue: UserDefaults.standard.string(forKey: "Desktop Input Mode") ?? "") ?? .trackpad }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "Desktop Input Mode"); updateModeButton() }
    }

    private var started = false
    private var lastRequestedSize: CGSize = .zero
    private var resizeWork: DispatchWorkItem?

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

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

        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        setUpToolbar()
        setUpGestures()
        view.addInteraction(UIPointerInteraction(delegate: self))

        hideKeyboard()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        takeFrames()
    }

    private var laptopObserver: NSObjectProtocol?

    /// The guest's frames, cursor and input to this view.
    private func takeFrames() {
        if laptopObserver == nil {
            // Laptop mode was over this view: the frames come back here
            laptopObserver = NotificationCenter.default.addObserver(forName: LaptopMode.didEnd, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.viewIfLoaded?.window != nil, self.presentedViewController == nil else { return }
                self.takeFrames()
                self.requestSize(force: true)
            }
        }
        display.onFrame = { [weak self] contents, size in self?.show(contents, size: size) }
        display.onCursor = { [weak self] image, hotSpot in self?.setCursor(image, hotSpot: hotSpot) }
        display.onCursorPosition = { [weak self] point, visible in
            guard let self, self.mode == .touch || self.display.relative || !self.pointerMovedLocally else { return }
            self.pointer = point
            self.cursorLayer.isHidden = !visible
            self.layoutScreen()
            if self.display.relative && self.zoom > 1 { self.followPointer() }
        }
        // Reports the current screen again
        display.viewer = self
        display.attach()
        updateRelative()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        started = true
        if guestSize == .zero { setStatus("Starting the desktop…", busy: true) }
        requestSize(force: true)
        // Starts Xorg and the desktop, unless they are running
        DesktopSession.start { [weak self] error in
            guard let self else { return }
            if let error {
                self.setStatus(error, busy: false)
            } else if self.guestSize == .zero {
                self.setStatus("Waiting for the desktop…", busy: true)
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setCaptured(false)
        // Unless laptop mode's screen took the frames over meanwhile
        guard display.viewer === self else { return }
        display.viewer = nil
        display.detach()
        display.onFrame = nil
        display.onCursor = nil
        display.onCursorPosition = nil
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutScreen()
        if started { requestSize(force: false) }
    }

    private func setStatus(_ text: String?, busy: Bool) {
        statusLabel.text = text
        statusLabel.isHidden = text == nil
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    // MARK: Screen

    /// A CGImage, or an IOSurface QEMU drew on the GPU (shown as it is).
    private func show(_ contents: AnyObject?, size: CGSize) {
        guard let contents, size.width > 0, size.height > 0 else { return }
        if size != guestSize || !statusLabel.isHidden {
            guestSize = size
            pointer = CGPoint(x: min(pointer.x, size.width - 1), y: min(pointer.y, size.height - 1))
            setStatus(nil, busy: false)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The same IOSurface again (redrawn): the layer only notices a change
        if screenLayer.contents as AnyObject? === contents { screenLayer.contents = nil }
        screenLayer.contents = contents
        layoutScreenLocked()
        CATransaction.commit()
    }

    /// The part of the view the guest's screen goes in: clear of the
    /// rounded corners, notch or Dynamic Island and home indicator, where the
    /// display has them (the safe area; all of the view on square screens).
    private var screenArea: CGRect {
        let area = view.bounds.inset(by: ScreenShape.insets(view.safeAreaInsets))
        return area.width > 0 && area.height > 0 ? area : view.bounds
    }

    /// Where the guest's screen is in the view (aspect fit, zoomed).
    private var screenRect: CGRect {
        let area = screenArea
        guard guestSize.width > 0, guestSize.height > 0 else { return area }
        let fit = min(area.width / guestSize.width, area.height / guestSize.height) * zoom
        let size = CGSize(width: guestSize.width * fit, height: guestSize.height * fit)
        var origin = CGPoint(x: area.midX - center.x * size.width, y: area.midY - center.y * size.height)
        // Keep the screen on the area (centered when smaller than it)
        origin.x = size.width <= area.width ? area.minX + (area.width - size.width) / 2
            : min(area.minX, max(area.maxX - size.width, origin.x))
        origin.y = size.height <= area.height ? area.minY + (area.height - size.height) / 2
            : min(area.minY, max(area.maxY - size.height, origin.y))
        return CGRect(origin: origin, size: size)
    }

    /// View points per guest pixel.
    private var scale: CGFloat {
        guestSize.width > 0 ? screenRect.width / guestSize.width : 1
    }

    private func layoutScreen() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutScreenLocked()
        CATransaction.commit()
    }

    private func layoutScreenLocked() {
        let rect = screenRect
        screenLayer.frame = rect
        let scale = self.scale
        cursorLayer.frame = CGRect(x: rect.minX + (pointer.x - cursorHotSpot.x) * scale,
                                   y: rect.minY + (pointer.y - cursorHotSpot.y) * scale,
                                   width: cursorImageSize.width * scale, height: cursorImageSize.height * scale)
    }

    private func setCursor(_ image: CGImage?, hotSpot: CGPoint) {
        cursorLayer.contents = image
        cursorLayer.isHidden = image == nil
        cursorHotSpot = hotSpot
        cursorImageSize = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        layoutScreen()
    }

    /// The guest's screen follows the view's safe area: its points, at least
    /// 1024 wide, so small screens still fit a desktop.
    private func requestSize(force: Bool) {
        let bounds = screenArea.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let factor = max(1, 1024 / bounds.width)
        let width = Int((bounds.width * factor / 8).rounded()) * 8
        let height = Int((bounds.height * factor / 8).rounded()) * 8
        let size = CGSize(width: width, height: height)
        guard force || size != lastRequestedSize else { return }
        lastRequestedSize = size
        display.setSize(width: width, height: height)
        guard !force else { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { DesktopSession.resize() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: Toolbar

    private func toolbarButton(_ symbol: String, _ label: String, action: Selector? = nil, menu: UIMenu? = nil) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        if let action { button.addTarget(self, action: action, for: .touchUpInside) }
        if let menu {
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
        }
        return button
    }

    private func setUpToolbar() {
        let sessions = toolbarButton("square.on.square", "Sessions", menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.menuProvider?() ?? []) },
        ]))
        let keyboard = toolbarButton("keyboard", "Keyboard", action: #selector(toggleKeyboard))
        modeButton = toolbarButton("cursorarrow.rays", "Input Mode", action: #selector(toggleMode))
        let fit = toolbarButton("arrow.down.right.and.arrow.up.left", "Zoom to Fit", action: #selector(zoomToFit))
        captureButton = toolbarButton("computermouse", "Capture Mouse", action: #selector(toggleCapture))
        captureButton.isHidden = traitCollection.userInterfaceIdiom != .pad
        let more = toolbarButton("ellipsis.circle", "More", menu: UIMenu(children: [
            UIAction(title: "Hide Toolbar", image: UIImage(systemName: "chevron.up")) { [weak self] _ in self?.setToolbarHidden(true) },
            UIAction(title: "Log Out of the Desktop", image: UIImage(systemName: "power"), attributes: .destructive) { [weak self] _ in
                self?.stopDesktop()
            },
        ]))
        let stack = UIStackView(arrangedSubviews: [sessions, keyboard, modeButton, captureButton, fit, more])
        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let bar: UIView
        if #available(iOS 26.0, *) {
            let glass = UIVisualEffectView(effect: UIGlassEffect())
            glass.cornerConfiguration = .capsule()
            glass.contentView.addSubview(stack)
            bar = glass
        } else {
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
            blur.layer.cornerRadius = 22
            blur.clipsToBounds = true
            blur.contentView.addSubview(stack)
            bar = blur
        }
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            bar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        toolbar = bar

        // A small handle brings the toolbar back
        showToolbarButton = toolbarButton("chevron.down", "Show Toolbar", action: #selector(showToolbar))
        showToolbarButton.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.6)
        showToolbarButton.layer.cornerRadius = 14
        showToolbarButton.translatesAutoresizingMaskIntoConstraints = false
        showToolbarButton.isHidden = true
        view.addSubview(showToolbarButton)
        NSLayoutConstraint.activate([
            showToolbarButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            showToolbarButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
        updateModeButton()
    }

    private func updateModeButton() {
        guard let modeButton else { return }
        let touch = mode == .touch
        modeButton.configuration?.image = UIImage(systemName: touch ? "hand.point.up.left" : "cursorarrow.rays")
        modeButton.accessibilityValue = touch ? "Touch" : "Trackpad"
    }

    @objc private func toggleMode() {
        mode = mode == .trackpad ? .touch : .trackpad
        updateRelative()
        showHint(mode == .touch ? "Touch mode: the pointer goes where you touch" : "Trackpad mode: drag to move the pointer")
    }

    @objc private func zoomToFit() {
        UIView.animate(withDuration: 0.2) { [self] in
            zoom = 1
            center = CGPoint(x: 0.5, y: 0.5)
            layoutScreen()
        }
    }

    @objc private func showToolbar() { setToolbarHidden(false) }

    private func setToolbarHidden(_ hidden: Bool) {
        toolbarHidden = hidden
        UIView.animate(withDuration: 0.2) { [self] in
            toolbar.alpha = hidden ? 0 : 1
            showToolbarButton.isHidden = !hidden
        }
    }

    private func stopDesktop() {
        setStatus("Logging out…", busy: true)
        DesktopSession.stop { [weak self] in
            guard let self else { return }
            self.guestSize = .zero
            self.screenLayer.contents = nil
            self.cursorLayer.contents = nil
            self.setStatus(nil, busy: false)
            self.dismiss(animated: true)
        }
    }

    private var hintLabel: UILabel?
    private func showHint(_ text: String) {
        hintLabel?.removeFromSuperview()
        let label = PaddedLabel()
        label.text = text
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        hintLabel = label
        UIView.animate(withDuration: 0.3, delay: 2, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }

    // MARK: Touch

    private var pinch: UIPinchGestureRecognizer!
    private var scrollPan: UIPanGestureRecognizer!
    private var pointerMovedLocally = false
    private var dragging = false
    private var scrollRemainder = CGPoint.zero
    private var pinchStart: (zoom: CGFloat, center: CGPoint, location: CGPoint)?

    private func setUpGestures() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        func add(_ recognizer: UIGestureRecognizer) {
            recognizer.allowedTouchTypes = direct
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        add(tap)
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        add(twoFingerTap)
        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(threeFingerTapped(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        add(threeFingerTap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        add(pan)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.4
        add(longPress)
        scrollPan = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        add(scrollPan)
        pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        add(pinch)
        tap.require(toFail: twoFingerTap)
        twoFingerTap.require(toFail: threeFingerTap)

        // Mouse wheels and trackpad scrolling on iPad
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        view.addGestureRecognizer(wheel)
        // A mouse or trackpad pointer moves the guest's pointer directly
        view.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and two-finger scroll together; pan and long press together (drag after holding)
        let pair: Set<ObjectIdentifier> = [ObjectIdentifier(recognizer), ObjectIdentifier(other)]
        if pair == [ObjectIdentifier(pinch), ObjectIdentifier(scrollPan)] { return true }
        return recognizer is UILongPressGestureRecognizer || other is UILongPressGestureRecognizer
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Not the toolbar's buttons
        !(touch.view is UIControl) && touch.view?.isDescendant(of: toolbar) != true
    }

    /// A view point as a guest pixel.
    private func guestPoint(_ point: CGPoint) -> CGPoint {
        let rect = screenRect, scale = self.scale
        return CGPoint(x: max(0, min(guestSize.width - 1, (point.x - rect.minX) / scale)),
                       y: max(0, min(guestSize.height - 1, (point.y - rect.minY) / scale)))
    }

    private func setPointer(_ point: CGPoint) {
        pointer = point
        pointerMovedLocally = true
        display.movePointer(to: point)
        layoutScreen()
        if zoom > 1 { followPointer() }
    }

    /// Zoomed in: keep the pointer on screen.
    private func followPointer() {
        let rect = screenRect, scale = self.scale
        let p = CGPoint(x: rect.minX + pointer.x * scale, y: rect.minY + pointer.y * scale)
        let margin: CGFloat = 40, area = screenArea
        var dx: CGFloat = 0, dy: CGFloat = 0
        if p.x < area.minX + margin { dx = p.x - (area.minX + margin) } else if p.x > area.maxX - margin { dx = p.x - (area.maxX - margin) }
        if p.y < area.minY + margin { dy = p.y - (area.minY + margin) } else if p.y > area.maxY - margin { dy = p.y - (area.maxY - margin) }
        guard dx != 0 || dy != 0 else { return }
        center.x += dx / rect.width
        center.y += dy / rect.height
        layoutScreen()
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        if mode == .touch { setPointer(guestPoint(recognizer.location(in: view))) }
        display.click(.left)
    }

    @objc private func twoFingerTapped(_ recognizer: UITapGestureRecognizer) {
        if mode == .touch { setPointer(guestPoint(recognizer.location(in: view))) }
        display.click(.right)
    }

    @objc private func threeFingerTapped(_ recognizer: UITapGestureRecognizer) {
        if mode == .touch { setPointer(guestPoint(recognizer.location(in: view))) }
        display.click(.middle)
    }

    private var lastPan = CGPoint.zero

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: view)
        switch mode {
        case .trackpad:
            if recognizer.state == .began { lastPan = location }
            let delta = CGPoint(x: location.x - lastPan.x, y: location.y - lastPan.y)
            lastPan = location
            // A constant speed: Linux does not accelerate either (desktop.sh)
            let factor = 1.3 / max(scale, 0.01) * (zoom > 1 ? 1 / zoom : 1)
            if display.relative {
                display.move(dx: delta.x * factor, dy: delta.y * factor)
            } else {
                setPointer(CGPoint(x: max(0, min(guestSize.width - 1, pointer.x + delta.x * factor)),
                                   y: max(0, min(guestSize.height - 1, pointer.y + delta.y * factor))))
            }
        case .touch:
            setPointer(guestPoint(location))
            if recognizer.state == .began, !dragging {
                dragging = true
                display.button(.left, down: true)
            }
        }
        if recognizer.state == .ended || recognizer.state == .cancelled, dragging, mode == .touch {
            dragging = false
            display.button(.left, down: false)
        }
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        switch mode {
        case .trackpad:
            // Hold, then drag with the button down
            switch recognizer.state {
            case .began:
                dragging = true
                display.button(.left, down: true)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .ended, .cancelled, .failed:
                if dragging {
                    dragging = false
                    display.button(.left, down: false)
                }
            default: break
            }
        case .touch:
            if recognizer.state == .began {
                setPointer(guestPoint(recognizer.location(in: view)))
                display.click(.right)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        if recognizer === scrollPan, let pinch, abs(pinch.scale - 1) > 0.08, pinch.state == .changed { return }
        let translation = recognizer.translation(in: view)
        recognizer.setTranslation(.zero, in: view)
        if recognizer.state == .began { scrollRemainder = .zero }
        // Content follows the fingers, as on iOS: moving up scrolls down
        scrollRemainder.x -= translation.x
        scrollRemainder.y -= translation.y
        let step: CGFloat = 18
        let dx = Int(scrollRemainder.x / step), dy = Int(scrollRemainder.y / step)
        scrollRemainder.x -= CGFloat(dx) * step
        scrollRemainder.y -= CGFloat(dy) * step
        display.scroll(dx: dx, dy: dy)
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        let location = recognizer.location(in: view)
        switch recognizer.state {
        case .began:
            pinchStart = (zoom, center, location)
        case .changed:
            guard let start = pinchStart else { return }
            zoom = max(1, min(6, start.zoom * recognizer.scale))
            // Pan with the fingers' movement
            let rect = screenRect
            center = CGPoint(x: start.center.x - (location.x - start.location.x) / rect.width,
                             y: start.center.y - (location.y - start.location.y) / rect.height)
            center.x = max(0, min(1, center.x))
            center.y = max(0, min(1, center.y))
            layoutScreen()
        default:
            pinchStart = nil
        }
    }

    // MARK: Mouse and trackpad (iPad)

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        pointerMoved(to: recognizer.location(in: view), began: recognizer.state == .began)
    }

    /// The last place the iPad's pointer was, for relative moves.
    private var lastPointerLocation: CGPoint?

    /// The iPad's pointer moved: where it is (touch mode), or by as much
    /// (trackpad mode: Linux moves its pointer, with its own acceleration).
    /// Nothing while captured: the captured mouse's own motion moves it.
    private func pointerMoved(to location: CGPoint, began: Bool) {
        guard !captured else { return }
        if display.relative {
            if let last = lastPointerLocation, !began {
                let factor = 1 / max(scale, 0.01)
                display.move(dx: (location.x - last.x) * factor, dy: (location.y - last.y) * factor)
            }
            lastPointerLocation = location
        } else {
            setPointer(guestPoint(location))
        }
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden() // the guest draws its own
    }

    private var pointerButtons: [UITouch: DesktopDisplay.MouseButton] = [:]

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .indirectPointer && !captured {
            pointerMoved(to: touch.location(in: view), began: false)
            let mask = event?.buttonMask ?? .primary
            let button: DesktopDisplay.MouseButton = mask.contains(.secondary) ? .right : (mask.rawValue & 4 != 0 ? .middle : .left)
            pointerButtons[touch] = button
            display.button(button, down: true)
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .indirectPointer && !captured {
            pointerMoved(to: touch.location(in: view), began: false)
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        releasePointerButtons(touches)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        releasePointerButtons(touches)
        super.touchesCancelled(touches, with: event)
    }

    private func releasePointerButtons(_ touches: Set<UITouch>) {
        for touch in touches {
            if let button = pointerButtons.removeValue(forKey: touch) { display.button(button, down: false) }
        }
    }

    // MARK: Captured mouse (iPad)

    private var captureButton: UIButton!
    private var captured = false
    private let mouse = CapturedMouse()
    private var resignObserver: NSObjectProtocol?

    override var prefersPointerLocked: Bool { captured }

    /// The relative mouse while captured or in trackpad mode.
    private func updateRelative() {
        display.relative = display.hasRelativeMouse && (captured || mode == .trackpad)
        lastPointerLocation = nil
    }

    @objc private func toggleCapture() { setCaptured(!captured) }

    /// Captured, iPadOS hides its pointer and keeps it in place (pointer
    /// lock), and the mouse's own movement moves Linux's pointer, without
    /// stopping at the screen's edges: as on a computer, and as games
    /// expect. As UTM does it.
    private func setCaptured(_ on: Bool) {
        guard on != captured else { return }
        if on && !display.hasRelativeMouse {
            showHint("Restart Linux to capture the mouse")
            return
        }
        if on && GCMouse.mice().isEmpty {
            showHint("Connect a mouse or trackpad to capture it")
            return
        }
        captured = on
        setNeedsUpdateOfPrefersPointerLocked()
        updateRelative()
        captureButton?.configuration?.image = UIImage(systemName: on ? "computermouse.fill" : "computermouse")
        captureButton?.accessibilityValue = on ? "Captured" : nil
        if on {
            mouse.start(display)
            // iPadOS gives the lock up when iSH+ leaves the foreground
            resignObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setCaptured(false)
            }
            showHint("Mouse captured. Control-Option releases it")
        } else {
            mouse.stop()
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            resignObserver = nil
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    private let emptyInputView = UIView(frame: .zero)
    private var keyboardShown = false
    private lazy var extraKeys = DesktopExtraKeys { [weak self] usage in self?.typeKey(usage) }

    override var inputView: UIView? { keyboardShown ? nil : emptyInputView }
    override var inputAccessoryView: UIView? { keyboardShown ? extraKeys : nil }

    @objc private func toggleKeyboard() {
        keyboardShown ? hideKeyboard() : showKeyboard()
    }

    private func showKeyboard() {
        keyboardShown = true
        reloadInputViews()
        becomeFirstResponder()
    }

    private func hideKeyboard() {
        keyboardShown = false
        reloadInputViews()
    }

    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }

    func insertText(_ text: String) {
        for character in text {
            if character == "\n" { typeKey(Keys.enter); continue }
            guard let (usage, shift) = Keys.usage(for: character) else { continue }
            typeKey(usage, shift: shift)
        }
    }

    func deleteBackward() {
        typeKey(Keys.backspace)
    }

    /// Types a key, with the modifiers held in the extra keys (once).
    private func typeKey(_ usage: Int, shift: Bool = false) {
        let modifiers = extraKeys.takeModifiers() + (shift ? [Keys.leftShift] : [])
        for modifier in modifiers { display.key(modifier, down: true) }
        display.key(usage, down: true)
        display.key(usage, down: false)
        for modifier in modifiers.reversed() { display.key(modifier, down: false) }
    }

    // Hardware keyboards: every key, as pressed and released
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Control-Option releases a captured mouse
        if captured, let flags = event?.modifierFlags, flags.contains(.control), flags.contains(.alternate) {
            setCaptured(false)
        }
        var handled = false
        for press in presses {
            if let key = press.key {
                display.key(key.keyCode.rawValue, down: true)
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key {
                display.key(key.keyCode.rawValue, down: false)
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key { display.key(key.keyCode.rawValue, down: false) }
        }
        super.pressesCancelled(presses, with: event)
    }
}

// MARK: - Keys

/// USB HID keyboard usages, for a US layout (Linux's default).
enum Keys {
    static let enter = 40, escape = 41, backspace = 42, tab = 43
    static let right = 79, left = 80, down = 81, up = 82
    static let leftControl = 224, leftShift = 225, leftAlt = 226, leftGUI = 227

    static func usage(for character: Character) -> (Int, Bool)? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1, scalar.isASCII else { return nil }
        let c = Character(scalar)
        if let v = c.asciiValue {
            if (97...122).contains(v) { return (Int(v) - 97 + 4, false) }
            if (65...90).contains(v) { return (Int(v) - 65 + 4, true) }
            if (49...57).contains(v) { return (Int(v) - 49 + 30, false) }
            if c == "0" { return (39, false) }
        }
        let table: [Character: (Int, Bool)] = [
            " ": (44, false), "\t": (43, false),
            "-": (45, false), "_": (45, true), "=": (46, false), "+": (46, true),
            "[": (47, false), "{": (47, true), "]": (48, false), "}": (48, true),
            "\\": (49, false), "|": (49, true), ";": (51, false), ":": (51, true),
            "'": (52, false), "\"": (52, true), "`": (53, false), "~": (53, true),
            ",": (54, false), "<": (54, true), ".": (55, false), ">": (55, true),
            "/": (56, false), "?": (56, true),
            "!": (30, true), "@": (31, true), "#": (32, true), "$": (33, true), "%": (34, true),
            "^": (35, true), "&": (36, true), "*": (37, true), "(": (38, true), ")": (39, true),
        ]
        return table[c]
    }
}

/// Keys the on-screen keyboard lacks: Esc, Tab, Ctrl, Alt, Super (held for
/// the next key) and arrows.
final class DesktopExtraKeys: UIInputView {
    private let type: (Int) -> Void
    private var held: [Int: UIButton] = [:]

    init(type: @escaping (Int) -> Void) {
        self.type = type
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let keys: [(String, Int, Bool)] = [
            ("esc", Keys.escape, false), ("tab", Keys.tab, false), ("ctrl", Keys.leftControl, true),
            ("alt", Keys.leftAlt, true), ("super", Keys.leftGUI, true),
            ("←", Keys.left, false), ("↓", Keys.down, false), ("↑", Keys.up, false), ("→", Keys.right, false),
        ]
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (title, usage, modifier) in keys {
            var configuration = UIButton.Configuration.gray()
            configuration.title = title
            configuration.cornerStyle = .medium
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] action in
                guard let self, let button = action.sender as? UIButton else { return }
                if modifier {
                    if self.held.removeValue(forKey: usage) != nil {
                        button.configuration?.baseBackgroundColor = nil
                    } else {
                        self.held[usage] = button
                        button.configuration?.baseBackgroundColor = .tintColor.withAlphaComponent(0.4)
                    }
                } else {
                    self.type(usage)
                }
            })
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The held modifiers, released after this key.
    func takeModifiers() -> [Int] {
        let modifiers = Array(held.keys)
        for button in held.values { button.configuration?.baseBackgroundColor = nil }
        held.removeAll()
        return modifiers
    }
}

private final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 12, dy: 8)) }
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 24, height: size.height + 16)
    }
}
