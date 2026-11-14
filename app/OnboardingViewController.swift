//
//  OnboardingViewController.swift
//  iSH+
//
//  First-launch setup for JIT: LocalDevVPN and pairing iSH+
//  with this device, so its built-in JIT enabler can attach to itself (like
//  Madeira), without StikDebug.
//

import AVFoundation
import Network
import UIKit
import UniformTypeIdentifiers
import UserNotifications

@objc(ISHOnboarding)
public final class Onboarding: NSObject {
    private static let completedKey = "Onboarding Completed"

    @objc public static var completed: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }

    /// Where an imported pairing file is kept (not visible in the Files app).
    @objc public static var pairingFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("JIT/pairing.plist")
    }

    @objc public static var hasPairing: Bool {
        FileManager.default.fileExists(atPath: pairingFileURL.path)
    }

    /// The permissions step was seen (it came with 1.2.1: people who set up
    /// iSH+ before see it once, to decide about the microphone).
    private static let permissionsKey = "Permissions Reviewed 1"
    @objc public static var permissionsReviewed: Bool {
        get { UserDefaults.standard.bool(forKey: permissionsKey) }
        set { UserDefaults.standard.set(newValue, forKey: permissionsKey) }
    }
}

// MARK: - Permissions

/// What iSH+ may use, as asked in setup: the local network (pairing with
/// this device for JIT), the microphone (shared with Linux) and
/// notifications (the pairing code, while pairing in Settings).
enum Permissions {
    enum State { case unknown, allowed, denied }

    static var microphone: State {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .allowed
            case .denied: return .denied
            default: return .unknown
            }
        }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .allowed
        case .denied: return .denied
        default: return .unknown
        }
    }

    static func requestMicrophone(_ done: @escaping () -> Void) {
        let finish: (Bool) -> Void = { granted in
            DispatchQueue.main.async {
                // Linux's sound card records only with a play-and-record session
                if granted { VirtualMachine.activateAudioSession() }
                done()
            }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: finish)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(finish)
        }
    }

    static func notifications(_ answer: @escaping (State) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: State
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: state = .allowed
            case .denied: state = .denied
            default: state = .unknown
            }
            DispatchQueue.main.async { answer(state) }
        }
    }

    static func requestNotifications(_ done: @escaping () -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async(execute: done)
        }
    }

    /// iOS has no way to ask whether the local network is allowed: browsing
    /// for the pairing service asks for it (once), and the browser then
    /// runs (allowed) or waits with a policy error (not allowed).
    private(set) static var localNetwork: State = .unknown
    private static var browser: NWBrowser?

    static func requestLocalNetwork(_ done: @escaping () -> Void) {
        browser?.cancel()
        let browser = NWBrowser(for: .bonjour(type: "_remotepairing-pairable-host._tcp", domain: nil), using: .tcp)
        self.browser = browser
        var answered = false
        let answer: (State) -> Void = { state in
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                localNetwork = state
                browser.cancel()
                if Self.browser === browser { Self.browser = nil }
                done()
            }
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready: answer(.allowed)
            case .waiting(let error), .failed(let error):
                if case .dns(let code) = error, code == -65570 { answer(.denied) } // kDNSServiceErr_PolicyDenied
            default: break
            }
        }
        browser.start(queue: .main)
        // No answer while the prompt is up, and none when allowed with no
        // service around: what is known after a while
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { answer(localNetwork) }
    }
}

@objc(ISHOnboardingViewController)
public final class OnboardingViewController: UIViewController, UIDocumentPickerDelegate {
    private enum StepKind { case welcome, permissions, vpn, pairing, distro, done }

    private struct Step {
        let kind: StepKind
        let symbol: String
        let title: String
        let text: String
    }

    private static let allSteps: [Step] = [
        Step(kind: .welcome, symbol: "cpu",
             title: "Welcome to iSH+",
             text: "iSH+ runs a real Linux distribution in a virtual machine. Setting it up takes a few minutes: pairing iSH+ with this device so it can enable JIT and run at full speed, and choosing your distribution."),
        Step(kind: .permissions, symbol: "hand.raised",
             title: "Permissions",
             text: "iSH+ can use these. Allow the ones you want: you can change them later in the Settings app."),
        Step(kind: .vpn, symbol: "network.badge.shield.half.filled",
             title: "Connect LocalDevVPN",
             text: "iSH+ talks to this device's developer services through LocalDevVPN. Install it from the App Store and connect it. It only routes traffic to this device, and is only needed while iSH+ enables JIT. Using another VPN, like Tailscale? Add the iSH+ JIT shortcut: it switches to LocalDevVPN for JIT, then back."),
        Step(kind: .pairing, symbol: "link",
             title: "Pair iSH+",
             text: "Pair iSH+ with this device so it can attach its debugger to itself. Import a pairing file made on a computer, or pair directly on this device."),
        Step(kind: .distro, symbol: "shippingbox",
             title: "Choose a Distribution",
             text: "Pick the Linux distribution iSH+ runs, and create your account. It downloads while you finish setting up, and installs the first time it starts. You can add more in Settings > Distributions."),
        Step(kind: .done, symbol: "checkmark.seal",
             title: "All Set",
             text: "iSH+ will enable JIT by itself whenever it starts the Linux VM. Keep LocalDevVPN connected. You can redo this setup from Settings at any time."),
    ]

    /// From Settings (JIT Setup) the distribution step is left out; for
    /// people who set up iSH+ before the permissions step, only that.
    private var steps: [Step] {
        if onlyPermissions { return Self.allSteps.filter { $0.kind == .permissions } }
        return fromSettings ? Self.allSteps.filter { $0.kind != .distro } : Self.allSteps
    }

    /// Only the permissions step (shown once to people who set up iSH+ before it).
    @objc public var onlyPermissions = false
    private var notificationsState: Permissions.State = .unknown

    private var index = 0
    private let completion: () -> Void
    /// Opened from Settings rather than on first launch: start at pairing,
    /// offer Cancel, and finish with Done.
    @objc public var fromSettings = false

    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let textLabel = UILabel()
    private let statusLabel = UILabel()
    private let buttons = UIStackView()
    private let pageControl = UIPageControl()
    /// The permissions step's rows: icon, name, what for, and Allow
    private let permissionsList = UIStackView()

    @objc public init(completion: @escaping () -> Void) {
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 56, weight: .regular)
        symbolView.tintColor = .tintColor
        symbolView.contentMode = .scaleAspectFit
        titleLabel.font = UIFont.preferredFont(forTextStyle: .largeTitle).bold()
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        textLabel.font = .preferredFont(forTextStyle: .body)
        textLabel.textColor = .secondaryLabel
        textLabel.textAlignment = .center
        textLabel.numberOfLines = 0
        textLabel.adjustsFontForContentSizeCategory = true
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        buttons.axis = .vertical
        buttons.spacing = 12
        pageControl.numberOfPages = steps.count
        pageControl.isHidden = steps.count < 2
        NotificationCenter.default.addObserver(self, selector: #selector(distrosChanged),
                                               name: DistroManager.didChangeNotification, object: nil)
        // Back from the Settings app (a permission changed there)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        pageControl.isUserInteractionEnabled = false
        pageControl.currentPageIndicatorTintColor = .label
        pageControl.pageIndicatorTintColor = .tertiaryLabel

        permissionsList.axis = .vertical
        permissionsList.spacing = 18
        permissionsList.isHidden = true
        let content = UIStackView(arrangedSubviews: [symbolView, titleLabel, textLabel, permissionsList, statusLabel])
        content.axis = .vertical
        // Fill, so multi-line labels wrap at the full width instead of being
        // truncated; the symbol stays centered via its content mode.
        content.alignment = .fill
        symbolView.contentMode = .center
        for label in [titleLabel, textLabel, statusLabel] {
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        content.spacing = 16
        content.setCustomSpacing(24, after: symbolView)

        let stack = UIStackView(arrangedSubviews: [content, buttons, pageControl])
        stack.axis = .vertical
        stack.spacing = 32
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addCenteredScrolling(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 460).withPriority(UILayoutPriority(999)),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor),
            textLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        show(fromSettings ? 1 : 0, animated: false)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Multi-line labels in stack views need their real width to size
        // their height; otherwise the text gets truncated.
        var changed = false
        for label in [titleLabel, textLabel, statusLabel] where label.bounds.width > 0 && label.preferredMaxLayoutWidth != label.bounds.width {
            label.preferredMaxLayoutWidth = label.bounds.width
            changed = true
        }
        if changed {
            view.setNeedsLayout()
        }
    }

    // MARK: Steps

    private func show(_ newIndex: Int, animated: Bool) {
        index = newIndex
        let step = steps[index]
        let update = { [self] in
            symbolView.image = UIImage(systemName: step.symbol)
            titleLabel.text = step.title
            textLabel.text = step.text
            pageControl.currentPage = index
            permissionsList.isHidden = step.kind != .permissions
            if step.kind == .permissions {
                updatePermissionRows()
                refreshPermissions()
            }
            updateStatus()
            setButtons(buttonsForStep())
        }
        if animated {
            UIView.transition(with: view, duration: 0.25, options: .transitionCrossDissolve, animations: update)
        } else {
            update()
        }
    }

    private var distroChosen = false
    /// Progress of pairing on this device, shown on the pairing step.
    private var pairingStatus: String?

    @objc private func distrosChanged() {
        guard steps[index].kind == .distro else { return }
        updateStatus()
        let chosen = !DistroManager.shared.distros.isEmpty
        if chosen != distroChosen {
            distroChosen = chosen
            setButtons(buttonsForStep())
        }
    }

    private func updateStatus() {
        // Work out the final state, then apply it once: setting isHidden on
        // a stack view's subview more than once while animating can leave
        // it in the wrong state.
        var status: (String, UIColor)?
        switch steps[index].kind {
        case .distro:
            if let distro = DistroManager.shared.distros.last {
                if let download = DistroManager.shared.downloads[distro.id] {
                    let percent = Int(download.fraction * 100)
                    status = (download.verifying ? "\(distro.title): checking the download…"
                              : "\(distro.title): downloading… \(percent)%", .secondaryLabel)
                } else {
                    status = ("\(distro.title) is ready.", .systemGreen)
                }
            }
        case .vpn:
            if JITShortcut.enabled {
                status = (JITShortcut.restoresVPN
                          ? "The \(JITShortcut.name) shortcut switches to LocalDevVPN while JIT turns on, then back to your VPN."
                          : "The \(JITShortcut.name) shortcut turns LocalDevVPN on while JIT turns on, then off again.", .systemGreen)
            }
        case .pairing:
            if let pairingStatus {
                status = (pairingStatus, .secondaryLabel)
            } else if Onboarding.hasPairing {
                status = ("Paired. A pairing file is installed.", .systemGreen)
            }
        default:
            break
        }
        statusLabel.text = status?.0
        statusLabel.textColor = status?.1 ?? .secondaryLabel
        if statusLabel.isHidden != (status == nil) {
            statusLabel.isHidden = status == nil
        }
    }

    private func buttonsForStep() -> [UIButton] {
        let next = makeButton("Continue", prominent: true) { [weak self] in self?.advance() }
        switch steps[index].kind {
        case .welcome:
            return [makeButton("Get Started", prominent: true) { [weak self] in self?.advance() },
                    makeButton("Skip for Now", prominent: false) { [weak self] in self?.finish() }]
        case .permissions:
            // One button: Done (accent) once everything is allowed, else Skip
            let all = Permissions.localNetwork == .allowed && Permissions.microphone == .allowed
                && notificationsState == .allowed
            let go: () -> Void = { [weak self] in
                guard let self else { return }
                self.onlyPermissions ? self.finish() : self.advance()
            }
            return [makeButton(all ? "Done" : "Skip", prominent: all, action: go)]
        case .vpn:
            var list = [next,
                        makeButton("Get LocalDevVPN", prominent: false) {
                            if let url = URL(string: "itms-apps://apps.apple.com/search?term=LocalDevVPN") { UIApplication.shared.open(url) }
                        }]
            if JITShortcut.isSupported, JITShortcut.bundledFile != nil {
                list.append(makeButton(JITShortcut.enabled ? "Add the Shortcut Again" : "Add the \(JITShortcut.name) Shortcut",
                                       prominent: false) { [weak self] in self?.addShortcut() })
            }
            return list
        case .pairing where pairing:
            return [makeButton("Cancel Pairing", prominent: false) { OnDevicePairing.cancel() }]
        case .pairing:
            var list = [makeButton("Import Pairing File…", prominent: !Onboarding.hasPairing) { [weak self] in self?.importPairingFile() },
                        makeButton("Pair With This Device", prominent: false) { [weak self] in self?.pairOnDevice() }]
            if Onboarding.hasPairing {
                list.insert(next, at: 0)
            } else {
                list.append(makeButton("Skip", prominent: false) { [weak self] in self?.advance() })
            }
            return list
        case .distro:
            let chosen = !DistroManager.shared.distros.isEmpty
            distroChosen = chosen
            let choose = makeButton(chosen ? "Choose Another…" : "Choose a Distribution…", prominent: !chosen) { [weak self] in
                self?.chooseDistro()
            }
            return chosen ? [next, choose] : [choose, makeButton("Skip", prominent: false) { [weak self] in self?.advance() }]
        case .done:
            return [makeButton(fromSettings ? "Done" : "Start iSH+", prominent: true) { [weak self] in self?.finish() }]
        }
    }

    // MARK: Permissions step

    /// Notifications' state is asked asynchronously: then rows and button again.
    @objc private func becameActive() {
        if steps[index].kind == .permissions { refreshPermissions() }
    }

    private func refreshPermissions() {
        Permissions.notifications { [weak self] state in
            guard let self, self.steps[self.index].kind == .permissions else { return }
            self.notificationsState = state
            self.updatePermissionRows()
            self.setButtons(self.buttonsForStep())
        }
    }

    private func updatePermissionRows() {
        permissionsList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let refresh: () -> Void = { [weak self] in self?.refreshPermissions() }
        let rows: [(String, String, String, Permissions.State, () -> Void)] = [
            ("network", "Local Network", "To pair with this device and enable JIT by itself.",
             Permissions.localNetwork, { Permissions.requestLocalNetwork(refresh) }),
            ("mic", "Microphone", "Shared with Linux, so programs there can record.",
             Permissions.microphone, { Permissions.requestMicrophone(refresh) }),
            ("bell.badge", "Notifications", "To show the pairing code while you pair in Settings.",
             notificationsState, { Permissions.requestNotifications(refresh) }),
        ]
        for (symbol, name, detail, state, request) in rows {
            permissionsList.addArrangedSubview(permissionRow(symbol: symbol, name: name, detail: detail,
                                                             state: state, request: request))
        }
    }

    private func permissionRow(symbol: String, name: String, detail: String,
                               state: Permissions.State, request: @escaping () -> Void) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = .tintColor
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let title = UILabel()
        title.text = name
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        let subtitle = UILabel()
        subtitle.text = detail
        subtitle.font = .preferredFont(forTextStyle: .footnote)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0
        subtitle.adjustsFontForContentSizeCategory = true
        let labels = UIStackView(arrangedSubviews: [title, subtitle])
        labels.axis = .vertical
        labels.spacing = 2

        // Allow; a checkmark once allowed; Settings once declined (iOS asks once)
        let trailing: UIView
        switch state {
        case .allowed:
            let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            check.tintColor = .systemGreen
            check.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .regular)
            check.accessibilityLabel = "Allowed"
            trailing = check
        case .unknown, .denied:
            var config: UIButton.Configuration
            if #available(iOS 26.0, *) { config = .glass() } else { config = .tinted() }
            config.title = state == .denied ? "Settings" : "Allow"
            config.cornerStyle = .capsule
            config.buttonSize = .medium
            trailing = UIButton(configuration: config, primaryAction: UIAction { _ in
                if state == .denied {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } else {
                    request()
                }
            })
        }
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [icon, labels, trailing])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 14
        return row
    }

    private func setButtons(_ list: [UIButton]) {
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        list.forEach { buttons.addArrangedSubview($0) }
        if fromSettings && index < steps.count - 1 {
            buttons.addArrangedSubview(makeButton("Cancel", prominent: false) { [weak self] in
                self?.dismiss(animated: true) { [weak self] in self?.completion() }
            })
        }
    }

    private func makeButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> UIButton {
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) {
            config = prominent ? .prominentGlass() : .glass()
        } else {
            config = prominent ? .filled() : .tinted()
        }
        config.title = title
        config.cornerStyle = .capsule
        config.buttonSize = .large
        return UIButton(configuration: config, primaryAction: UIAction { _ in action() })
    }

    private func advance() {
        if index + 1 < steps.count {
            show(index + 1, animated: true)
        } else {
            finish()
        }
    }

    private func finish() {
        Onboarding.permissionsReviewed = true
        if onlyPermissions {
            dismiss(animated: true) { [completion] in completion() }
            return
        }
        Onboarding.completed = true
        dismiss(animated: true) { [completion] in completion() }
    }

    // MARK: Shortcut

    /// Offers the bundled iSH+ JIT shortcut to Shortcuts (share sheet).
    private func addShortcut() {
        guard let file = JITShortcut.bundledFile else { return }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        share.completionWithItemsHandler = { [weak self] _, completed, _, _ in
            guard completed else { return }
            JITShortcut.enabled = true
            if let self { show(index, animated: true) }
        }
        if let popover = share.popoverPresentationController {
            popover.sourceView = buttons
            popover.sourceRect = buttons.bounds
        }
        present(share, animated: true)
    }

    // MARK: Distribution

    private func chooseDistro() {
        let catalog = DistroCatalogViewController()
        let navigation = UINavigationController(rootViewController: catalog)
        catalog.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak navigation] _ in
            navigation?.dismiss(animated: true)
        })
        catalog.onStarted = { [weak self, weak navigation] in
            navigation?.dismiss(animated: true)
            self?.show(self?.index ?? 0, animated: true)
        }
        present(navigation, animated: true)
    }

    // MARK: Pairing

    private func importPairingFile() {
        let types: [UTType] = [.propertyList, .xml, .data, UTType(filenameExtension: "mobiledevicepairing") ?? .data]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        do {
            let data = try Data(contentsOf: url)
            // Two formats exist: classic lockdown pairing records (HostPrivateKey,
            // DeviceCertificate...) and RemotePairing files (iOS 17+, e.g. from
            // StikPair's rp_pairing_file.plist). Both are dictionaries with key
            // material; accept either.
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  !plist.isEmpty,
                  plist.keys.contains(where: { $0.lowercased().contains("key") || $0.lowercased().contains("certificate") }) else {
                showAlert("Not a Pairing File", "That file does not look like a pairing file. Use a pairing file made for this device, for example rp_pairing_file.plist from StikPair.")
                return
            }
            let kind = plist["HostPrivateKey"] != nil ? "lockdown" : "remotepairing"
            UserDefaults.standard.set(kind, forKey: "Pairing File Kind")
            let destination = Onboarding.pairingFileURL
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            show(index, animated: true)
        } catch {
            showAlert("Could Not Import", error.localizedDescription)
        }
    }

    /// Pairing with this device is in progress.
    private var pairing = false

    private func pairOnDevice() {
        guard OnDevicePairing.isSupported else {
            showAlert("Needs iOS 27", "Pairing on this device needs iOS 27 or later. Import a pairing file made on a computer instead.")
            return
        }
        pairing = true
        pairingStatus = "Starting…"
        show(index, animated: true)
        OnDevicePairing.start { [weak self] event in
            guard let self else { return }
            switch event {
            case .waiting:
                pairingStatus = "Now open Settings > Privacy & Security > Developer Mode, scroll down and tap Pair with \(OnDevicePairing.hostName). Keep Wi-Fi on."
            case .pin(let pin):
                pairingStatus = "Enter \(OnDevicePairing.spaced(pin)) in Settings."
            case .paired:
                pairing = false
                pairingStatus = nil
            case .failed(let message):
                pairing = false
                pairingStatus = nil
                if message != "Cancelled." {
                    showAlert("Could Not Pair", message)
                }
            }
            if steps[index].kind == .pairing {
                show(index, animated: true)
            }
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}

extension UIView {
    /// Adds @content centered in this view, in a scroll view so it can still
    /// be reached where it does not fit (an iPhone in landscape).
    func addCenteredScrolling(_ content: UIView) {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        addSubview(scroll)
        scroll.addSubview(content)
        let page = scroll.contentLayoutGuide
        let fill = page.heightAnchor.constraint(equalTo: safeAreaLayoutGuide.heightAnchor)
        fill.priority = .defaultLow
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            // At least the visible height (centered), or the content's
            page.heightAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.heightAnchor),
            fill,
            content.topAnchor.constraint(greaterThanOrEqualTo: page.topAnchor, constant: 20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -20),
            content.centerYAnchor.constraint(equalTo: page.centerYAnchor),
            content.centerXAnchor.constraint(equalTo: page.centerXAnchor),
        ])
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
