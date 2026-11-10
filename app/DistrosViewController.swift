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

/// The distributions available to download.
final class DistroCatalogViewController: UITableViewController {
    private var families: [DistroFamily] = []
    private let spinner = UIActivityIndicatorView(style: .large)
    private var failure: String?

    init() {
        super.init(style: .insetGrouped)
        title = "Add a Distribution"
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

    override func numberOfSections(in tableView: UITableView) -> Int { failure != nil ? 1 : families.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        failure != nil ? 1 : families[section].images.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        failure != nil ? nil : families[section].name
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if let failure { return failure }
        if families[section].name == "Alpine Linux" {
            return "Small and quick to install: a good start."
        }
        if families[section].name == "Artix Linux" {
            return "Artix's ARM port. A large download (over 1 GB) that takes a while to install."
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = UIListContentConfiguration.cell()
        if failure != nil {
            content.text = "Try Again"
            content.textProperties.color = .tintColor
        } else {
            let image = families[indexPath.section].images[indexPath.row]
            content.text = image.release
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if failure != nil {
            spinner.startAnimating()
            load()
            return
        }
        let image = families[indexPath.section].images[indexPath.row]
        Task { @MainActor in
            let size = await DistroManager.shared.size(of: image)
            let alert = UIAlertController(
                title: "Download \(image.title)?",
                message: size.map { "\(DistrosViewController.bytes($0)) download." },
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Download", style: .default) { [weak self] _ in
                DistroManager.shared.install(image)
                self?.navigationController?.popViewController(animated: true)
            })
            present(alert, animated: true)
        }
    }
}
