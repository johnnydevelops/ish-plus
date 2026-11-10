//
//  VMSettingsViewController.swift
//  iSH+
//
//  Settings > Linux VM: memory and CPU cores (automatic by default, from
//  this iPad's RAM and performance cores), and the servers forwarded from
//  Linux (shared with the network or not).
//

import UIKit

@objc(ISHVMSettingsViewController)
public final class VMSettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable { case performance, ports }
    private let networkSwitch = UISwitch()
    /// What the running VM was started with, to tell when a restart is needed.
    private let startedWith = (VMSettings.memoryMB, VMSettings.cpuCount)

    @objc public init() {
        super.init(style: .insetGrouped)
        title = "Linux VM"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        networkSwitch.isOn = UserDefaults.standard.bool(forKey: PortForwarder.shareOnNetworkKey)
        networkSwitch.addTarget(self, action: #selector(networkChanged), for: .valueChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(portsChanged),
                                               name: PortForwarder.didChangeNotification, object: nil)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    @objc private func portsChanged() {
        tableView.reloadSections(IndexSet(integer: Section.ports.rawValue), with: .automatic)
    }

    @objc private func networkChanged() {
        PortForwarder.shared.setSharedOnNetwork(networkSwitch.isOn)
    }

    private var needsRestart: Bool {
        VirtualMachine.shared.isRunning && (VMSettings.memoryMB, VMSettings.cpuCount) != startedWith
    }

    // MARK: Table

    public override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .performance: return needsRestart ? 3 : 2
        case .ports: return 1 + PortForwarder.shared.ports.count
        }
    }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .performance: return "Performance"
        case .ports: return "Open Ports"
        }
    }

    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .performance:
            return "This iPad has \(VMSettings.deviceMemoryGB) GB of memory; iOS ends apps that use much more than half of it. Changes apply the next time Linux starts."
        case .ports:
            let ports = PortForwarder.shared.ports.isEmpty
                ? "Servers started in Linux appear here, and open at localhost on this iPad. "
                : ""
            return ports + "When shared on the network, other devices can connect to them at this iPad's address."
        }
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default
        var content = UIListContentConfiguration.valueCell()
        switch (Section(rawValue: indexPath.section)!, indexPath.row) {
        case (.performance, 0):
            content.text = "Memory"
            content.secondaryText = VMSettings.chosenMemoryMB == 0
                ? "Automatic (\(VMSettings.formatMemory(VMSettings.memoryMB)))"
                : VMSettings.formatMemory(VMSettings.memoryMB)
            cell.accessoryType = .disclosureIndicator
        case (.performance, 1):
            content.text = "CPU Cores"
            content.secondaryText = VMSettings.chosenCPUCount == 0
                ? "Automatic (\(VMSettings.cpuCount))" : "\(VMSettings.cpuCount)"
            cell.accessoryType = .disclosureIndicator
        case (.performance, _):
            content = .cell()
            content.text = "Quit iSH+ to Apply"
            content.textProperties.color = .systemRed
        case (.ports, 0):
            content = .cell()
            content.text = "Share on Network"
            cell.accessoryView = networkSwitch
            cell.selectionStyle = .none
        case (.ports, let row):
            let port = PortForwarder.shared.ports[row - 1]
            content = .subtitleCell()
            content.text = "localhost:\(port.hostPort)"
            content.secondaryText = port.hostPort != port.guestPort ? "Port \(port.guestPort) in Linux" : nil
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "globe")
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch (Section(rawValue: indexPath.section)!, indexPath.row) {
        case (.performance, 0):
            let automatic = Choice(label: "Automatic", detail: VMSettings.formatMemory(VMSettings.automaticMemoryMB), value: 0)
            let choices = [automatic] + VMSettings.memoryChoices.map {
                Choice(label: VMSettings.formatMemory($0), detail: nil, value: $0)
            }
            show(ChoiceViewController(title: "Memory", choices: choices, selected: VMSettings.chosenMemoryMB,
                                      footer: "Automatic gives Linux as much memory as this iPad can safely run it with. More memory lets Linux keep more files cached and run bigger programs; too much and iOS ends iSH+.") {
                VMSettings.chosenMemoryMB = $0
            }, sender: self)
        case (.performance, 1):
            let automatic = Choice(label: "Automatic", detail: "\(VMSettings.automaticCPUCount)", value: 0)
            let choices = [automatic] + (1...VMSettings.maximumCPUCount).map {
                Choice(label: "\($0)", detail: nil, value: $0)
            }
            show(ChoiceViewController(title: "CPU Cores", choices: choices, selected: VMSettings.chosenCPUCount,
                                      footer: "Automatic uses one core per performance core of this iPad. Cores beyond those run on efficiency cores, which can slow the others down.") {
                VMSettings.chosenCPUCount = $0
            }, sender: self)
        case (.performance, _):
            exit(0)
        case (.ports, 0):
            break
        case (.ports, let row):
            UIApplication.shared.open(PortForwarder.shared.ports[row - 1].url)
        }
    }
}

struct Choice {
    let label: String
    let detail: String?
    let value: Int
}

/// A list to pick one value from.
final class ChoiceViewController: UITableViewController {
    private let choices: [Choice]
    private var selected: Int
    private let footer: String?
    private let picked: (Int) -> Void

    init(title: String, choices: [Choice], selected: Int, footer: String?, picked: @escaping (Int) -> Void) {
        self.choices = choices
        self.selected = selected
        self.footer = footer
        self.picked = picked
        super.init(style: .insetGrouped)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { choices.count }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { footer }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let choice = choices[indexPath.row]
        var content = UIListContentConfiguration.valueCell()
        content.text = choice.label
        content.secondaryText = choice.detail
        cell.contentConfiguration = content
        cell.accessoryType = choice.value == selected ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selected = choices[indexPath.row].value
        picked(selected)
        tableView.reloadData()
    }
}
