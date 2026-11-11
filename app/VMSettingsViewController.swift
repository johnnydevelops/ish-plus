//
//  VMSettingsViewController.swift
//  iSH+
//
//  Settings > Linux VM: memory and CPU cores (automatic by default, from
//  this iPad's RAM and performance cores), GPU acceleration, and the servers
//  forwarded from Linux (shared with the network or not).
//

import UIKit

@objc(ISHVMSettingsViewController)
public final class VMSettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable { case performance, graphics, ports }
    private let networkSwitch = UISwitch()
    private let automaticMemorySwitch = UISwitch()
    private let gpuSwitch = UISwitch()
    private let vulkanSwitch = UISwitch()
    private let memorySlider = UISlider()
    /// The memory, in MB; can be typed
    private let memoryField = UITextField()
    private let maximumMemory = VMSettings.maximumMemoryMB
    /// Memory slider steps
    private static let memoryStep = 16
    /// What the running VM was started with, to tell when a restart is needed.
    private let startedWith = (VMSettings.memoryMB, VMSettings.cpuCount)
    private let startedWithGPU = (VirtualMachine.shared.gpuAccelerated, VirtualMachine.shared.vulkan)
    /// The "Quit iSH+ to Apply" row is shown
    private var showingRestart = false

    // The cells with controls are made once and never reloaded: a control
    // moved between two cells while one replaced the other (a reload while
    // the switch was changing) froze UIKit in a layout loop (#6).
    private lazy var automaticCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private lazy var memoryCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private lazy var networkCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private lazy var gpuCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private lazy var vulkanCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private let memoryTitle = UILabel()

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
        gpuSwitch.isOn = VMSettings.gpuAcceleration
        gpuSwitch.addTarget(self, action: #selector(gpuChanged), for: .valueChanged)
        vulkanSwitch.isOn = VMSettings.vulkan
        vulkanSwitch.isEnabled = VMSettings.gpuAcceleration
        vulkanSwitch.addTarget(self, action: #selector(vulkanChanged), for: .valueChanged)
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
        buildControlCells()
        updateMemoryControls()
        showingRestart = needsRestart
        NotificationCenter.default.addObserver(self, selector: #selector(portsChanged),
                                               name: PortForwarder.didChangeNotification, object: nil)
    }

    private func buildControlCells() {
        automaticCell.selectionStyle = .none
        automaticCell.accessoryView = automaticMemorySwitch

        memoryCell.selectionStyle = .none
        memoryTitle.text = "Memory"
        memoryTitle.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [memoryTitle, memorySlider, memoryField])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        memoryCell.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            memoryField.widthAnchor.constraint(equalToConstant: 104),
            row.leadingAnchor.constraint(equalTo: memoryCell.contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: memoryCell.contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: memoryCell.contentView.layoutMarginsGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: memoryCell.contentView.layoutMarginsGuide.bottomAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])

        gpuCell.selectionStyle = .none
        gpuCell.accessoryView = gpuSwitch
        var gpuContent = UIListContentConfiguration.cell()
        gpuContent.text = "GPU Acceleration"
        gpuCell.contentConfiguration = gpuContent

        vulkanCell.selectionStyle = .none
        vulkanCell.accessoryView = vulkanSwitch
        var vulkanContent = UIListContentConfiguration.subtitleCell()
        vulkanContent.text = "Vulkan"
        vulkanContent.secondaryText = "Experimental"
        vulkanContent.secondaryTextProperties.color = .secondaryLabel
        vulkanCell.contentConfiguration = vulkanContent

        networkCell.selectionStyle = .none
        networkCell.accessoryView = networkSwitch
        var content = UIListContentConfiguration.cell()
        content.text = "Share on Network"
        networkCell.contentConfiguration = content
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The CPU row, after choosing in its list
        tableView.reloadRows(at: [IndexPath(row: 2, section: Section.performance.rawValue)], with: .none)
        updateRestartRow()
    }

    @objc private func portsChanged() {
        // Only the port rows (row 0 holds the switch)
        let section = Section.ports.rawValue
        let old = tableView.numberOfRows(inSection: section) - 1
        let new = PortForwarder.shared.ports.count
        tableView.performBatchUpdates {
            let common = min(old, new)
            if common > 0 {
                tableView.reloadRows(at: (1...common).map { IndexPath(row: $0, section: section) }, with: .none)
            }
            if new > old {
                tableView.insertRows(at: ((old + 1)...new).map { IndexPath(row: $0, section: section) }, with: .automatic)
            } else if old > new {
                tableView.deleteRows(at: ((new + 1)...old).map { IndexPath(row: $0, section: section) }, with: .automatic)
            }
        }
        refreshFooter(of: .ports)
    }

    private func updateMemoryControls() {
        let automatic = automaticMemorySwitch.isOn
        memorySlider.value = Float(VMSettings.memoryMB)
        memorySlider.isEnabled = !automatic
        memoryField.text = "\(VMSettings.memoryMB)"
        memoryField.isEnabled = !automatic
        memoryField.textColor = automatic ? .secondaryLabel : .label
        memoryTitle.isEnabled = !automatic
        var content = UIListContentConfiguration.cell()
        content.text = "Automatic Memory"
        content.secondaryText = automatic ? "\(VMSettings.formatMemory(VMSettings.automaticMemoryMB)) for this \(UIDevice.current.model)" : nil
        content.secondaryTextProperties.color = .secondaryLabel
        automaticCell.contentConfiguration = content
    }

    /// A typed amount, within 256 MB and the maximum
    @objc private func memoryTyped() {
        if let typed = Int(memoryField.text ?? "") {
            VMSettings.chosenMemoryMB = min(maximumMemory, max(256, typed))
        }
        updateMemoryControls()
        updateRestartRow()
    }

    @objc private func automaticMemoryChanged() {
        // Off: start from the automatic amount
        VMSettings.chosenMemoryMB = automaticMemorySwitch.isOn ? 0 : VMSettings.memoryMB
        updateMemoryControls()
        updateRestartRow()
    }

    /// The slider moves in steps of 16 MB (up to the maximum, which may not be one)
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
        updateRestartRow()
    }

    /// Shows or hides "Quit iSH+ to Apply" by itself, and resizes the
    /// changed rows, without reloading the cells that hold controls.
    private func updateRestartRow() {
        let show = needsRestart
        tableView.performBatchUpdates {
            if show != showingRestart {
                let row = IndexPath(row: 3, section: Section.performance.rawValue)
                show ? tableView.insertRows(at: [row], with: .automatic) : tableView.deleteRows(at: [row], with: .automatic)
                showingRestart = show
            }
        }
    }

    private func refreshFooter(of section: Section) {
        UIView.performWithoutAnimation {
            tableView.footerView(forSection: section.rawValue)?.textLabel?.text =
                self.tableView(tableView, titleForFooterInSection: section.rawValue)
            tableView.footerView(forSection: section.rawValue)?.setNeedsLayout()
        }
    }

    @objc private func gpuChanged() {
        VMSettings.gpuAcceleration = gpuSwitch.isOn
        vulkanSwitch.isEnabled = gpuSwitch.isOn
        vulkanSwitch.setOn(VMSettings.vulkan, animated: true)
        refreshFooter(of: .graphics)
        updateRestartRow()
    }

    @objc private func vulkanChanged() {
        VMSettings.vulkan = vulkanSwitch.isOn
        refreshFooter(of: .graphics)
        updateRestartRow()
    }

    @objc private func networkChanged() {
        PortForwarder.shared.setSharedOnNetwork(networkSwitch.isOn)
    }

    private var needsRestart: Bool {
        VirtualMachine.shared.isRunning && ((VMSettings.memoryMB, VMSettings.cpuCount) != startedWith ||
            (VMSettings.gpuAcceleration, VMSettings.vulkan) != startedWithGPU)
    }

    // MARK: Table

    public override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .performance: return showingRestart ? 4 : 3
        case .graphics: return VMSettings.gpuAvailable ? (VMSettings.vulkanAvailable ? 2 : 1) : 0
        case .ports: return 1 + PortForwarder.shared.ports.count
        }
    }

    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .performance: return "Performance"
        case .graphics: return VMSettings.gpuAvailable ? "Graphics" : nil
        case .ports: return "Open Ports"
        }
    }

    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .performance:
            if VMSettings.memoryDonorsAvailable {
                return "Linux's memory is held by a helper process, so it does not count toward the \(VMSettings.formatMemory(VMSettings.processMemoryLimitMB)) iOS lets iSH+ itself use; Linux can have up to \(VMSettings.formatMemory(maximumMemory)) of this \(UIDevice.current.model)'s \(VMSettings.deviceMemoryGB) GB. Changes apply the next time Linux starts."
            }
            return "iOS lets iSH+ use \(VMSettings.formatMemory(VMSettings.processMemoryLimitMB)) of this \(UIDevice.current.model)'s \(VMSettings.deviceMemoryGB) GB before ending it; QEMU itself needs some, so Linux can have up to \(VMSettings.formatMemory(maximumMemory)). Changes apply the next time Linux starts."
        case .graphics:
            guard VMSettings.gpuAvailable else { return nil }
            var text = "GPU acceleration draws the Desktop and Linux's OpenGL programs with this \(UIDevice.current.model)'s GPU. While it is on, Linux can't be saved for an instant resume when iOS ends iSH+."
            if VMSettings.vulkanAvailable {
                text += " Vulkan also gives Linux's programs Vulkan; it is experimental, and Linux is paused while iSH+ is in the background."
            }
            return text + " Changes apply the next time Linux starts."
        case .ports:
            let ports = PortForwarder.shared.ports.isEmpty
                ? "Servers started in Linux appear here, and open at localhost on this \(UIDevice.current.model). "
                : ""
            return ports + "When shared on the network, other devices can connect to them at this \(UIDevice.current.model)'s address."
        }
    }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch (Section(rawValue: indexPath.section)!, indexPath.row) {
        case (.performance, 0): return automaticCell
        case (.performance, 1): return memoryCell
        case (.graphics, 0): return gpuCell
        case (.graphics, 1): return vulkanCell
        case (.ports, 0): return networkCell
        default: break
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default
        var content = UIListContentConfiguration.valueCell()
        switch (Section(rawValue: indexPath.section)!, indexPath.row) {
        case (.performance, 2):
            content.text = "CPU Cores"
            content.secondaryText = VMSettings.chosenCPUCount == 0
                ? "Automatic (\(VMSettings.cpuCount))" : "\(VMSettings.cpuCount)"
            cell.accessoryType = .disclosureIndicator
        case (.performance, _):
            content = .cell()
            content.text = "Quit iSH+ to Apply"
            content.textProperties.color = .systemRed
        case (.graphics, _):
            break
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
        case (.performance, 2):
            let automatic = Choice(label: "Automatic", detail: "\(VMSettings.automaticCPUCount)", value: 0)
            let choices = [automatic] + (1...VMSettings.maximumCPUCount).map {
                Choice(label: "\($0)", detail: nil, value: $0)
            }
            show(ChoiceViewController(title: "CPU Cores", choices: choices, selected: VMSettings.chosenCPUCount,
                                      footer: "Automatic uses one core per performance core of this \(UIDevice.current.model). Cores beyond those run on efficiency cores, which can slow the others down.") {
                VMSettings.chosenCPUCount = $0
            }, sender: self)
        case (.performance, 3):
            exit(0)
        case (.ports, let row) where row > 0:
            UIApplication.shared.open(PortForwarder.shared.ports[row - 1].url)
        default:
            break
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
