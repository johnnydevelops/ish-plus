//
//  DistrosViewController.swift
//  iSH+
//
//  Settings > Distributions: the installed Linux distributions (the active
//  one boots), and a catalog to download more. Also shown on first launch,
//  when there is nothing to boot yet.
//

import UIKit

@objc(ISHDistrosViewController)
public final class DistrosViewController: UITableViewController {
    private let manager = DistroManager.shared
    /// First launch: called once a distribution is ready to boot.
    private var onReady: (() -> Void)?

    @objc public init() {
        super.init(style: .insetGrouped)
        title = "Distributions"
    }

    /// For first launch: asks for a distribution and calls ready once one
    /// can boot.
    @objc public convenience init(firstRunWithReady ready: @escaping () -> Void) {
        self.init()
        onReady = ready
        title = "Choose a Distribution"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var distros: [Distro] { manager.distros }

    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        NotificationCenter.default.addObserver(self, selector: #selector(distrosChanged(_:)),
                                               name: DistroManager.didChangeNotification, object: nil)
        if onReady != nil {
            isModalInPresentation = true
        }
    }

    @objc private func distrosChanged(_ notification: Notification) {
        if let error = notification.userInfo?["error"] as? String {
            let alert = UIAlertController(title: "Download Failed", message: error, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
        tableView.reloadData()
        if let onReady, manager.hasBootableDistro {
            self.onReady = nil
            dismiss(animated: true, completion: onReady)
        }
    }

    // MARK: Table

    public override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? distros.count : 1
    }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 && !distros.isEmpty ? "Installed" : nil
    }

    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1 else {
            return distros.count > 1 ? "The checked distribution starts with iSH+. Each has its own files." : nil
        }
        return "Distributions come from images.linuxcontainers.org (Artix Linux from armtix.artixlinux.org) and are installed the first time they start. iSH+ starts them with its own init and logs in as root, rather than running their init system."
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        cell.accessoryType = .none
        cell.accessoryView = nil
        if indexPath.section == 1 {
            content = .cell()
            content.text = onReady != nil && distros.isEmpty ? "Choose a Distribution…" : "Add a Distribution…"
            content.textProperties.color = .tintColor
            content.image = UIImage(systemName: "plus.circle")
            cell.contentConfiguration = content
            return cell
        }
        let distro = distros[indexPath.row]
        content.text = distro.title
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = DistroIcon.image(for: distro.family ?? "", name: distro.name, size: 36)
        content.imageToTextPadding = 12
        if let download = manager.downloads[distro.id] {
            if download.verifying {
                content.secondaryText = "Checking the download…"
            } else if download.expected > 0 {
                content.secondaryText = "Downloading… \(Self.bytes(download.received)) of \(Self.bytes(download.expected))"
            } else {
                content.secondaryText = "Downloading…"
            }
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        } else if !distro.installed {
            content.secondaryText = "Installs the next time it starts"
        } else {
            content.secondaryText = "\(Self.bytes(distro.diskUsage)) used"
        }
        if distro.id == manager.active?.id {
            cell.accessoryType = .checkmark
        }
        cell.contentConfiguration = content
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 {
            navigationController?.pushViewController(DistroCatalogViewController(), animated: true)
            return
        }
        let distro = distros[indexPath.row]
        guard manager.downloads[distro.id] == nil, distro.id != manager.active?.id else { return }
        manager.setActive(distro)
        if VirtualMachine.shared.isRunning {
            let alert = UIAlertController(
                title: "Restart iSH+ to Switch",
                message: "\(distro.title) starts the next time iSH+ starts. The running distribution keeps running until then.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Later", style: .cancel))
            alert.addAction(UIAlertAction(title: "Quit iSH+", style: .destructive) { _ in exit(0) })
            present(alert, animated: true)
        }
    }

    public override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 0 else { return nil }
        let distro = distros[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.confirmDelete(distro)
            done(false)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private func confirmDelete(_ distro: Distro) {
        if VirtualMachine.shared.isRunning && distro.id == manager.active?.id {
            let alert = UIAlertController(title: "\(distro.title) Is Running",
                                          message: "Choose another distribution and restart iSH+ before deleting this one.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let downloading = manager.downloads[distro.id] != nil
        let alert = UIAlertController(
            title: downloading ? "Cancel the Download?" : "Delete \(distro.title)?",
            message: downloading ? nil : "All of its files are deleted. This cannot be undone.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: downloading ? "Keep Downloading" : "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: downloading ? "Cancel Download" : "Delete", style: .destructive) { [weak self] _ in
            self?.manager.remove(distro)
        })
        present(alert, animated: true)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// A distribution's logo on a tile of its colour (a monogram for those
/// without a logo in Assets.xcassets/Distros).
enum DistroIcon {
    private static let colours: [String: String] = {
        guard let data = NSDataAsset(name: "Distros/DistroColors")?.data,
              let colours = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return colours
    }()

    static func image(for family: String, name: String, size: CGFloat = 40) -> UIImage {
        var colour = UIColor.systemGray
        if let hex = colours[family], let value = UInt32(hex.dropFirst(), radix: 16) {
            colour = UIColor(red: CGFloat(value >> 16 & 0xff) / 255, green: CGFloat(value >> 8 & 0xff) / 255,
                             blue: CGFloat(value & 0xff) / 255, alpha: 1)
        }
        let logo = UIImage(named: "Distros/\(family)")
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            colour.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: size * 0.225).fill()
            if let logo {
                let inset = rect.insetBy(dx: size * 0.2, dy: size * 0.2)
                let scale = min(inset.width / logo.size.width, inset.height / logo.size.height)
                let fitted = CGSize(width: logo.size.width * scale, height: logo.size.height * scale)
                logo.withTintColor(.white).draw(in: CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                                                           width: fitted.width, height: fitted.height))
            } else {
                let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
                let font = UIFont.systemFont(ofSize: size * 0.4, weight: .bold)
                let text = NSAttributedString(string: letters, attributes: [.font: font, .foregroundColor: UIColor.white])
                let textSize = text.size()
                text.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            }
        }
    }
}

/// The distributions available to download; picking one shows its versions.
final class DistroCatalogViewController: UITableViewController {
    /// Called once a download has started (onboarding); otherwise the
    /// catalog returns to the list of distributions.
    var onStarted: (() -> Void)?
    private var families: [DistroFamily] = []
    private let spinner = UIActivityIndicatorView(style: .large)
    private var failure: String?

    init() {
        super.init(style: .insetGrouped)
        title = "Distributions"
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.backgroundView = spinner
        spinner.startAnimating()
        load()
    }

    private func load() {
        failure = nil
        Task { @MainActor in
            do {
                families = try await DistroManager.shared.catalog()
            } catch {
                failure = "Could not load the list of distributions. Check your internet connection.\n\n\(error.localizedDescription)"
            }
            spinner.stopAnimating()
            tableView.reloadData()
        }
    }

    /// Alpine on its own (the suggestion), then the rest.
    override func numberOfSections(in tableView: UITableView) -> Int { failure != nil ? 1 : (families.isEmpty ? 0 : 2) }

    private func families(in section: Int) -> [DistroFamily] {
        section == 0 ? Array(families.prefix(1)) : Array(families.dropFirst())
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        failure != nil ? 1 : families(in: section).count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard failure == nil else { return nil }
        return section == 0 ? "Suggested" : "More Distributions"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if let failure { return failure }
        return section == 1 ? "From images.linuxcontainers.org, and Artix Linux from armtix.artixlinux.org. Logos from Simple Icons; they are trademarks of their owners." : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        if failure != nil {
            var content = UIListContentConfiguration.cell()
            content.text = "Try Again"
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.accessoryType = .none
            return cell
        }
        let family = families(in: indexPath.section)[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = family.name
        content.textProperties.font = .preferredFont(forTextStyle: .headline)
        content.secondaryText = family.summary
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = DistroIcon.image(for: family.key, name: family.name)
        content.imageProperties.cornerRadius = 9
        content.imageToTextPadding = 14
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if failure != nil {
            spinner.startAnimating()
            load()
            return
        }
        let family = families(in: indexPath.section)[indexPath.row]
        let versions = DistroVersionsViewController(family: family, onStarted: onStarted)
        navigationController?.pushViewController(versions, animated: true)
    }
}

/// One distribution's versions; picking one asks for the account to create.
final class DistroVersionsViewController: UITableViewController {
    private let family: DistroFamily
    private let onStarted: (() -> Void)?

    init(family: DistroFamily, onStarted: (() -> Void)?) {
        self.family = family
        self.onStarted = onStarted
        super.init(style: .insetGrouped)
        title = family.name
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 150))
        let icon = UIImageView(image: DistroIcon.image(for: family.key, name: family.name, size: 72))
        let name = UILabel()
        name.text = family.summary
        name.font = .preferredFont(forTextStyle: .subheadline)
        name.textColor = .secondaryLabel
        name.textAlignment = .center
        name.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [icon, name])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: header.layoutMarginsGuide.leadingAnchor),
        ])
        tableView.tableHeaderView = header
    }

    private var releases: [DistroImage] { family.images.filter { !$0.isDevelopment } }
    private var development: [DistroImage] { family.images.filter(\.isDevelopment) }
    private func images(in section: Int) -> [DistroImage] {
        section == 0 && !releases.isEmpty ? releases : development
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        (releases.isEmpty ? 0 : 1) + (development.isEmpty ? 0 : 1)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        images(in: section).count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        images(in: section).first?.isDevelopment == true ? "Development" : "Versions"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        images(in: section).first?.isDevelopment == true ? "Snapshots of the next release: newer, but less stable." : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let image = images(in: indexPath.section)[indexPath.row]
        var content = UIListContentConfiguration.valueCell()
        content.text = image.release
        if indexPath.section == 0 && indexPath.row == 0 && !image.isDevelopment {
            content.secondaryText = image.note.map { "Latest · \($0)" } ?? "Latest"
        } else {
            content.secondaryText = image.note
        }
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let image = images(in: indexPath.section)[indexPath.row]
        let setup = DistroSetupViewController(image: image) { [weak self] in
            guard let self else { return }
            if let onStarted { onStarted(); return }
            if let list = navigationController?.viewControllers.first(where: { $0 is DistrosViewController }) {
                navigationController?.popToViewController(list, animated: true)
            } else {
                navigationController?.popToRootViewController(animated: true)
            }
        }
        navigationController?.pushViewController(setup, animated: true)
    }
}
