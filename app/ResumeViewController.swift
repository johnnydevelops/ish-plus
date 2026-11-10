//
//  ResumeViewController.swift
//  iSH+
//
//  Shown before Linux starts when it was saved (iOS ended iSH+ while it was
//  in the background): resume where it was, or start Linux again.
//

import UIKit

@objc(ISHResumeViewController)
public final class ResumeViewController: UIViewController {
    private let savedDate: Date
    private let completion: (Bool) -> Void

    /// completion(true) to resume, (false) to start afresh.
    @objc public init(savedDate: Date, completion: @escaping (Bool) -> Void) {
        self.savedDate = savedDate
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let symbol = UIImageView(image: UIImage(systemName: "arrow.clockwise.circle",
                                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 56)))
        symbol.tintColor = .tintColor
        symbol.contentMode = .center
        let title = UILabel()
        title.text = "Resume Linux?"
        title.font = UIFont.preferredFont(forTextStyle: .largeTitle).withTraits(.traitBold)
        title.textAlignment = .center
        title.numberOfLines = 0
        let detail = UILabel()
        let when = RelativeDateTimeFormatter().localizedString(for: savedDate, relativeTo: Date())
        detail.text = "Linux was saved \(when), when iOS closed iSH+. Resume it with your sessions and programs as they were, or start Linux again."
        detail.font = .preferredFont(forTextStyle: .body)
        detail.textColor = .secondaryLabel
        detail.textAlignment = .center
        detail.numberOfLines = 0
        let resume = makeButton("Resume", prominent: true) { [weak self] in self?.finish(true) }
        let fresh = makeButton("Start Fresh", prominent: false) { [weak self] in self?.finish(false) }
        let stack = UIStackView(arrangedSubviews: [symbol, title, detail, resume, fresh])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(32, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            {
                let width = stack.widthAnchor.constraint(equalToConstant: 440)
                width.priority = .defaultHigh
                return width
            }(),
        ])
    }

    private func finish(_ resume: Bool) {
        dismiss(animated: true) { [completion] in completion(resume) }
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
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
