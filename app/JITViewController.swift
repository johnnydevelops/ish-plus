//
//  JITViewController.swift
//  iSH+
//
//  Shown before the Linux VM starts: "Enabling JIT…" while waiting for a JIT
//  enabler, then either continues or shows "Failed to enable JIT." with the
//  option to run QEMU's interpreter instead.
//

import UIKit

@objc(ISHJITChoice)
public enum JITChoice: Int {
    case jit           // JIT is enabled, run QEMU normally
    case interpreted   // run QEMU's interpreter (no JIT, much slower)
}

@objc(ISHJITViewController)
public final class JITViewController: UIViewController {
    private let completion: (JITChoice) -> Void
    private var timer: Timer?
    private var deadline = Date()
    private var failureReason: String?
    private static let timeout: TimeInterval = 30
    /// The built-in enabler can take a while the first time (it downloads the
    /// developer disk image).
    private static let helperTimeout: TimeInterval = 120

    /// Starts iSH+'s built-in JIT enabler; calls back with an error message if
    /// it fails. Set by the host, which owns the helper extension launcher.
    @objc public var launchEnabler: ((@escaping (String?) -> Void) -> Void)?

    /// The built-in enabler when iSH+ is paired; StikDebug otherwise, or when
    /// the user picks it after the built-in one failed.
    private var useStikDebug = false
    private var usesBuiltInEnabler: Bool { !useStikDebug && launchEnabler != nil && Onboarding.hasPairing }

    private let symbol = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let buttons = UIStackView()

    @objc public init(completion: @escaping (JITChoice) -> Void) {
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        symbol.tintColor = .secondaryLabel
        titleLabel.font = .preferredFont(forTextStyle: .title2).withTraits(.traitBold)
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontForContentSizeCategory = true
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        detailLabel.adjustsFontForContentSizeCategory = true
        buttons.axis = .vertical
        buttons.spacing = 12
        buttons.alignment = .fill

        let stack = UIStackView(arrangedSubviews: [symbol, spinner, titleLabel, detailLabel, buttons])
        stack.axis = .vertical
        stack.alignment = .fill
        symbol.contentMode = .center
        for label in [titleLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        stack.spacing = 16
        stack.setCustomSpacing(28, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addCenteredScrolling(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            {
                // A definite width; without it the column (and its labels) can collapse.
                let width = stack.widthAnchor.constraint(equalToConstant: 440)
                width.priority = .defaultHigh
                return width
            }(),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(check),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if timer == nil { enableJIT() }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: States

    private func showEnabling() {
        symbol.isHidden = true
        spinner.isHidden = false
        spinner.startAnimating()
        titleLabel.text = "Enabling JIT…"
        detailLabel.text = usesBuiltInEnabler
            ? "Connecting to this device through LocalDevVPN. The first time, iSH+ also downloads the developer disk image, which can take a minute."
            : JITViewController.stikDebugInstalled && (useStikDebug || !Onboarding.hasPairing)
            ? "Waiting for StikDebug to enable JIT for iSH+. Come back to iSH+ when it is done."
            : "Waiting for a JIT enabler (StikDebug, SideStore or a debugger) to attach to iSH+."
        setButtons([])
    }

    private func showFailed() {
        spinner.stopAnimating()
        spinner.isHidden = true
        symbol.isHidden = false
        symbol.image = UIImage(systemName: "exclamationmark.triangle")
        titleLabel.text = "Failed to enable JIT."
        let reason = failureReason.map { "\($0)\n\n" } ?? ""
        detailLabel.text = reason + "The Linux VM needs JIT to run at full speed. Make sure LocalDevVPN is connected, then tap Try Again. You can also run QEMU interpreted, which works without JIT but is much slower."
        var choices: [UIButton] = [
            makeButton("Try Again", prominent: true) { [weak self] in
                self?.useStikDebug = false
                self?.enableJIT()
            },
            makeButton("Set Up JIT…", prominent: false) { [weak self] in
                let onboarding = OnboardingViewController { self?.enableJIT() }
                self?.present(onboarding, animated: true)
            },
        ]
        if JITViewController.stikDebugInstalled && Onboarding.hasPairing {
            choices.append(makeButton("Use StikDebug", prominent: false) { [weak self] in
                self?.useStikDebug = true
                self?.enableJIT()
            })
        }
        if VirtualMachine.interpreterAvailable {
            choices.append(makeButton("Run QEMU Interpreted", prominent: false) { [weak self] in self?.finish(.interpreted) })
        }
        setButtons(choices)
    }

    private func setButtons(_ list: [UIButton]) {
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        list.forEach { buttons.addArrangedSubview($0) }
        buttons.isHidden = list.isEmpty
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
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        return button
    }

    // MARK: Enabling

    private static var stikDebugInstalled: Bool {
        guard let url = URL(string: "stikdebug://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private func enableJIT() {
        showEnabling()
        if VirtualMachine.jitAvailable {
            finish(.jit)
            return
        }
        failureReason = nil
        deadline = Date().addingTimeInterval(usesBuiltInEnabler ? JITViewController.helperTimeout : JITViewController.timeout)
        if usesBuiltInEnabler, let launchEnabler {
            let fail = { [weak self] (error: String) in
                guard let self, self.timer != nil, !VirtualMachine.jitAvailable else { return }
                self.timer?.invalidate()
                self.timer = nil
                self.failureReason = error
                self.showFailed()
            }
            let launch = {
                launchEnabler { error in
                    if let error { fail(error) }
                }
            }
            if JITShortcut.enabled {
                // The iSH+ JIT shortcut switches to LocalDevVPN (and back after)
                DispatchQueue.global().async {
                    let connected = JITShortcut.localDevVPNConnected()
                    DispatchQueue.main.async { [weak self] in
                        if connected { return launch() }
                        self?.detailLabel.text = "Switching to LocalDevVPN with the \(JITShortcut.name) shortcut. Your VPN comes back once JIT is on."
                        JITShortcut.start { error in
                            if let error { return fail(error) }
                            self?.showEnabling()
                            launch()
                        }
                    }
                }
            } else {
                launch()
            }
        } else if JITViewController.stikDebugInstalled,
           let bundleID = Bundle.main.bundleIdentifier,
           let url = URL(string: "stikdebug://enable-jit?bundle-id=\(bundleID)") {
            UIApplication.shared.open(url)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
    }

    @objc private func check() {
        guard timer != nil else { return }
        if VirtualMachine.jitAvailable {
            finish(.jit)
        } else if Date() > deadline {
            timer?.invalidate()
            timer = nil
            showFailed()
        }
    }

    private func finish(_ choice: JITChoice) {
        timer?.invalidate()
        timer = nil
        dismiss(animated: true) { [completion] in completion(choice) }
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
