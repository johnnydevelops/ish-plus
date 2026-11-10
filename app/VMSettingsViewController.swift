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
    private let automaticMemorySwitch = UISwitch()
    private let memorySlider = UISlider()
    /// The memory, in MB; can be typed
    private let memoryField = UITextField()
    private let maximumMemory = VMSettings.maximumMemoryMB
    /// Memory slider steps
    private static let memoryStep = 256
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
        automaticMemorySwitch.isOn = VMSettings.chosenMemoryMB == 0
        automaticMemorySwitch.addTarget(self, action: #selector(automaticMemoryChanged), for: .valueChanged)
        memorySlider.minimumValue = 512
        memorySlider.maximumValue = Float(maximumMemory)
        memorySlider.addTarget(self, action: #selector(memorySliderChanged), for: .valueChanged)
        memorySlider.addTarget(self, action: #selector(memorySliderEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        memoryField.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        memoryField.textAlignment = .right
        memoryField.keyboardType = .numberPad
        memoryField.borderStyle = .roundedRect
        let unit = UILabel()
        unit.text = " MB "
        unit.textColor = .secondaryLabel
        unit.font = .preferredFont(forTextStyle: .body)
        memoryField.rightView = unit
        memoryField.rightViewMode = .always
        memoryField.addTarget(self, action: #selector(memoryTyped), for: .editingDidEnd)
        let toolbar = UIToolbar()
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace),
                         UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.view.endEditing(true) })]
        toolbar.sizeToFit()
        memoryField.inputAccessoryView = toolbar
        updateMemoryControls()
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

    private func updateMemoryControls() {
        memorySlider.value = Float(VMSettings.memoryMB)
        memorySlider.isEnabled = !automaticMemorySwitch.isOn
        memoryField.text = "\(VMSettings.memoryMB)"
        memoryField.isEnabled = !automaticMemorySwitch.isOn
        memoryField.textColor = automaticMemorySwitch.isOn ? .secondaryLabel : .label
    }

    /// A typed amount, within 256 MB and the maximum
    @objc private func memoryTyped() {
        if let typed = Int(memoryField.text ?? "") {
            VMSettings.chosenMemoryMB = min(maximumMemory, max(256, typed))
        }
        updateMemoryControls()
        reloadRestartRow()
    }

    @objc private func automaticMemoryChanged() {
        // Off: start from the automatic amount
        VMSettings.chosenMemoryMB = automaticMemorySwitch.isOn ? 0 : VMSettings.memoryMB
        updateMemoryControls()
        reloadRestartRow()
    }

    /// The slider moves in steps of 256 MB (up to the maximum, which may not be one)
    private var sliderMemory: Int {
        let value = Int(memorySlider.value.rounded())
        let stepped = (value + Self.memoryStep / 2) / Self.memoryStep * Self.memoryStep
        // The maximum itself is reachable at the end of the slider
        return memorySlider.value >= Float(maximumMemory) - 1 ? maximumMemory : min(maximumMemory, max(512, stepped))
    }

    @objc private func memorySliderChanged() {
        memoryField.text = "\(sliderMemory)"
    }

    @objc private func memorySliderEnded() {
        VMSettings.chosenMemoryMB = sliderMemory
        updateMemoryControls()
        reloadRestartRow()
    }

    private func reloadRestartRow() {
        tableView.reloadSections(IndexSet(integer: Section.performance.rawValue), with: .none)
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
        case .performance: return needsRestart ? 4 : 3
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
            return "iOS lets iSH+ use \(VMSettings.formatMemory(VMSettings.processMemoryLimitMB)) of this iPad's \(VMSettings.deviceMemoryGB) GB before ending it; QEMU itself needs some, so Linux can have up to \(VMSettings.formatMemory(maximumMemory)). Changes apply the next time Linux starts."
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
            content = .cell()
            content.text = "Automatic Memory"
            content.secondaryText = automaticMemorySwitch.isOn
                ? "\(VMSettings.formatMemory(VMSettings.automaticMemoryMB)) for this iPad" : nil
            content.secondaryTextProperties.color = .secondaryLabel
            cell.accessoryView = automaticMemorySwitch
            cell.selectionStyle = .none
        case (.performance, 1):
            cell.selectionStyle = .none
            cell.contentConfiguration = nil
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            let title = UILabel()
            title.text = "Memory"
            title.isEnabled = !automaticMemorySwitch.isOn
            let row = UIStackView(arrangedSubviews: [title, memorySlider, memoryField])
            row.spacing = 12
            row.alignment = .center
            row.translatesAutoresizingMaskIntoConstraints = false
            title.setContentHuggingPriority(.required, for: .horizontal)
            memoryField.widthAnchor.constraint(equalToConstant: 104).isActive = true
            cell.contentView.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                row.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
                row.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            ])
            return cell
        case (.performance, 2):
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
        case (.performance, 0), (.performance, 1):
            break
        case (.performance, 2):
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
