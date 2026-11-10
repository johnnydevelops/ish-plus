//
//  DistroSetupViewController.swift
//  iSH+
//
//  The account to create in a distribution being added: a user name and
//  password (iSH+'s sessions log in as this user, who can become root with
//  su, or sudo/doas once installed), and the root password.
//

import UIKit

final class DistroSetupViewController: UITableViewController, UITextFieldDelegate {
    private let image: DistroImage
    private let started: () -> Void
    private var size: Int64?

    private let userField = UITextField()
    private let passwordField = UITextField()
    private let confirmField = UITextField()
    private let sameSwitch = UISwitch()
    private let rootField = UITextField()
    private let rootConfirmField = UITextField()

    private enum Section: Int, CaseIterable { case user, root, download }

    init(image: DistroImage, started: @escaping () -> Void) {
        self.image = image
        self.started = started
        super.init(style: .insetGrouped)
        title = image.title
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.keyboardDismissMode = .interactive
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Download", style: .done,
                                                            target: self, action: #selector(download))
        configure(userField, placeholder: "Username", secure: false, content: .username)
        userField.autocapitalizationType = .none
        userField.autocorrectionType = .no
        userField.spellCheckingType = .no
        configure(passwordField, placeholder: "Password", secure: true, content: .newPassword)
        configure(confirmField, placeholder: "Confirm Password", secure: true, content: .newPassword)
        configure(rootField, placeholder: "Root Password", secure: true, content: .newPassword)
        configure(rootConfirmField, placeholder: "Confirm Root Password", secure: true, content: .newPassword)
        sameSwitch.isOn = true
        sameSwitch.addTarget(self, action: #selector(sameChanged), for: .valueChanged)
        updateButton()
        Task { @MainActor in
            size = await DistroManager.shared.size(of: image)
            tableView.reloadSections(IndexSet(integer: Section.download.rawValue), with: .none)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        userField.becomeFirstResponder()
    }

    private func configure(_ field: UITextField, placeholder: String, secure: Bool, content: UITextContentType) {
        field.placeholder = placeholder
        field.isSecureTextEntry = secure
        field.textContentType = content
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .next
        field.delegate = self
        field.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
    }

    // MARK: Validation

    private var userName: String { userField.text ?? "" }

    private var problem: String? {
        if userName.isEmpty || passwordField.text?.isEmpty != false { return "" }
        if !DistroSetup.isValid(user: userName) {
            return "Use lowercase letters, digits, - and _, starting with a letter (and not root)."
        }
        if passwordField.text != confirmField.text { return "The passwords do not match." }
        if !sameSwitch.isOn {
            if rootField.text?.isEmpty != false { return "" }
            if rootField.text != rootConfirmField.text { return "The root passwords do not match." }
        }
        return nil
    }

    @objc private func fieldChanged() {
        updateButton()
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.footerView(forSection: Section.user.rawValue)?.textLabel?.text =
                self.tableView(tableView, titleForFooterInSection: Section.user.rawValue)
            tableView.footerView(forSection: Section.user.rawValue)?.sizeToFit()
            tableView.endUpdates()
        }
    }

    private func updateButton() {
        navigationItem.rightBarButtonItem?.isEnabled = problem == nil
    }

    @objc private func sameChanged() {
        tableView.reloadSections(IndexSet(integer: Section.root.rawValue), with: .automatic)
        updateButton()
    }

    @objc private func download() {
        guard problem == nil else { return }
        let password = passwordField.text ?? ""
        let setup = DistroSetup(user: userName, password: password,
                                rootPassword: sameSwitch.isOn ? password : (rootField.text ?? ""))
        view.endEditing(true)
        DistroManager.shared.install(image, setup: setup)
        started()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let order = [userField, passwordField, confirmField] + (sameSwitch.isOn ? [] : [rootField, rootConfirmField])
        if let index = order.firstIndex(of: textField), index + 1 < order.count {
            order[index + 1].becomeFirstResponder()
        } else if problem == nil {
            download()
        }
        return false
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .user: return 3
        case .root: return sameSwitch.isOn ? 1 : 3
        case .download: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .user: return "Your Account"
        case .root: return "Root"
        case .download: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .user:
            if let problem, !problem.isEmpty { return problem }
            return "iSH+ logs in as this user. Its password is asked by sudo and similar tools."
        case .root:
            return "Become root with su. The user can also use sudo or doas once installed."
        case .download:
            let size = size.map { "A \(DistrosViewController.bytes($0)) download. " } ?? ""
            return size + "\(image.name) is installed the next time iSH+ starts it."
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.selectionStyle = .none
        cell.contentView.subviews.forEach { $0.removeFromSuperview() }
        cell.accessoryView = nil
        cell.contentConfiguration = nil
        var field: UITextField?
        switch Section(rawValue: indexPath.section)! {
        case .user:
            field = [userField, passwordField, confirmField][indexPath.row]
        case .root:
            if indexPath.row == 0 {
                var content = UIListContentConfiguration.cell()
                content.text = "Same Password as the User"
                cell.contentConfiguration = content
                cell.accessoryView = sameSwitch
            } else {
                field = [rootField, rootConfirmField][indexPath.row - 1]
            }
        case .download:
            var content = UIListContentConfiguration.cell()
            content.text = "Distribution"
            content.secondaryText = image.title
            content.prefersSideBySideTextAndSecondaryText = true
            cell.contentConfiguration = content
        }
        if let field {
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                field.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
                field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ])
        }
        return cell
    }
}
