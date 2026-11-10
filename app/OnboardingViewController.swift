//
//  OnboardingViewController.swift
//  iSH+
//
//  First-launch setup for JIT: Developer Mode, LocalDevVPN and pairing iSH+
//  with this device, so its built-in JIT enabler can attach to itself (like
//  Madeira), without StikDebug.
//

import UIKit
import UniformTypeIdentifiers

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
}

@objc(ISHOnboardingViewController)
public final class OnboardingViewController: UIViewController, UIDocumentPickerDelegate {
    private struct Step {
        let symbol: String
        let title: String
        let text: String
    }

    private let steps: [Step] = [
        Step(symbol: "cpu",
             title: "Welcome to iSH+",
             text: "iSH+ runs a real Linux kernel in a virtual machine. To run it at full speed it needs JIT, which iSH+ can enable for itself once it is paired with this device. This takes a few minutes, once."),
        Step(symbol: "hammer",
             title: "Turn On Developer Mode",
             text: "Open Settings → Privacy & Security → Developer Mode and turn it on. Your device restarts; come back to iSH+ afterwards."),
        Step(symbol: "network.badge.shield.half.filled",
             title: "Connect LocalDevVPN",
             text: "iSH+ talks to this device's developer services through LocalDevVPN. Install it from the App Store and connect it. It only routes traffic to this device and must be connected whenever iSH+ enables JIT."),
        Step(symbol: "link",
             title: "Pair iSH+",
             text: "Pair iSH+ with this device so it can attach its debugger to itself. Import a pairing file made on a computer, or pair directly on this device."),
        Step(symbol: "checkmark.seal",
             title: "All Set",
             text: "iSH+ will enable JIT by itself whenever it starts the Linux VM. Keep LocalDevVPN connected. You can redo this setup from Settings at any time."),
    ]

    private var index = 0
    private let completion: () -> Void

    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let textLabel = UILabel()
    private let statusLabel = UILabel()
    private let buttons = UIStackView()
    private let pageControl = UIPageControl()

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
        pageControl.isUserInteractionEnabled = false
        pageControl.currentPageIndicatorTintColor = .label
        pageControl.pageIndicatorTintColor = .tertiaryLabel

        let content = UIStackView(arrangedSubviews: [symbolView, titleLabel, textLabel, statusLabel])
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
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 460).withPriority(.defaultHigh),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor),
            textLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        show(0, animated: false)
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
            updateStatus()
            setButtons(buttonsForStep())
        }
        if animated {
            UIView.transition(with: view, duration: 0.25, options: .transitionCrossDissolve, animations: update)
        } else {
            update()
        }
    }

    private func updateStatus() {
        statusLabel.isHidden = true
        if index == 3 && Onboarding.hasPairing {
            statusLabel.isHidden = false
            statusLabel.textColor = .systemGreen
            statusLabel.text = "Paired. A pairing file is installed."
        }
    }

    private func buttonsForStep() -> [UIButton] {
        let next = makeButton("Continue", prominent: true) { [weak self] in self?.advance() }
        switch index {
        case 0:
            return [makeButton("Set Up JIT", prominent: true) { [weak self] in self?.advance() },
                    makeButton("Skip for Now", prominent: false) { [weak self] in self?.finish() }]
        case 1:
            return [next,
                    makeButton("Open Settings", prominent: false) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }]
        case 2:
            return [next,
                    makeButton("Get LocalDevVPN", prominent: false) {
                        if let url = URL(string: "itms-apps://apps.apple.com/search?term=LocalDevVPN") { UIApplication.shared.open(url) }
                    }]
        case 3:
            var list = [makeButton("Import Pairing File…", prominent: !Onboarding.hasPairing) { [weak self] in self?.importPairingFile() },
                        makeButton("Pair With This Device", prominent: false) { [weak self] in self?.pairOnDevice() }]
            if Onboarding.hasPairing {
                list.insert(next, at: 0)
            } else {
                list.append(makeButton("Skip", prominent: false) { [weak self] in self?.advance() })
            }
            return list
        default:
            return [makeButton("Start iSH+", prominent: true) { [weak self] in self?.finish() }]
        }
    }

    private func setButtons(_ list: [UIButton]) {
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        list.forEach { buttons.addArrangedSubview($0) }
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
        Onboarding.completed = true
        dismiss(animated: true) { [completion] in completion() }
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
            // A pairing record is a property list with these keys.
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["HostPrivateKey"] != nil || plist["DeviceCertificate"] != nil else {
                showAlert("Not a Pairing File", "That file does not look like a pairing file for this device.")
                return
            }
            let destination = Onboarding.pairingFileURL
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            show(index, animated: true)
        } catch {
            showAlert("Could Not Import", error.localizedDescription)
        }
    }

    private func pairOnDevice() {
        showAlert("Coming Soon",
                  "Pairing directly on this device (iOS 27) is being built. For now, import a pairing file made on a computer.")
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

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
