//
//  VMSettings.swift
//  iSH+
//
//  The Linux VM's memory and CPU count, chosen by the user (Settings > Linux
//  VM) within what this iPad can run. Applied when the VM starts.
//

import Foundation
import os

@objc(ISHVMSettings)
public final class VMSettings: NSObject {
    private static let memoryKey = "VM Memory"
    private static let cpuKey = "VM CPUs"

    /// RAM in this iPad, in GB (rounded, so 2.8 GB of usable memory is 3).
    @objc public static var deviceMemoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }

    /// The most memory the VM can have here. iOS ends apps (even with the
    /// increased memory limit entitlement) at a bit over half the RAM — about
    /// 1.7 GB on a 3 GB iPad — and QEMU itself needs some (its translated code
    /// cache alone is 256 MB), so: 57% of the RAM, less 650 MB, in 256 MB
    /// steps, at least 1 GB and at most 16 GB.
    @objc public static var maximumMemoryMB: Int {
        let limit = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576 * 0.57
        let usable = Int(limit) - 650
        return min(16384, max(1024, usable / 256 * 256))
    }

    /// Automatic memory (the default): the maximum. 1 GB on 3 GB iPads,
    /// about 1.5 GB on 4 GB, 2.5 GB on 6 GB, 3.5 GB on 8 GB.
    @objc public static var automaticMemoryMB: Int { maximumMemoryMB }

    @objc public static let memoryChoices: [Int] = {
        var choices: [Int] = []
        var value = 512
        while value <= maximumMemoryMB {
            choices.append(value)
            value += value < 2048 ? 256 : 512
        }
        if choices.last != maximumMemoryMB { choices.append(maximumMemoryMB) }
        return choices
    }()

    /// The memory the user chose, or 0 for automatic.
    @objc public static var chosenMemoryMB: Int {
        get { UserDefaults.standard.integer(forKey: memoryKey) }
        set { UserDefaults.standard.set(newValue, forKey: memoryKey) }
    }

    /// The memory the VM gets.
    @objc public static var memoryMB: Int {
        chosenMemoryMB > 0 ? min(chosenMemoryMB, maximumMemoryMB) : automaticMemoryMB
    }

    /// One vCPU per performance core: vCPUs on efficiency cores slow the
    /// others down (cross-CPU TLB flushes wait for them), which made starting
    /// processes ~35% slower on an A13 (2 performance cores) with 4 vCPUs
    /// than with 2, for little gain in parallel work.
    @objc public static var automaticCPUCount: Int { max(1, min(VirtualMachine.performanceCores, 8)) }

    @objc public static var maximumCPUCount: Int { max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8)) }

    /// The CPU count the user chose, or 0 for automatic.
    @objc public static var chosenCPUCount: Int {
        get { UserDefaults.standard.integer(forKey: cpuKey) }
        set { UserDefaults.standard.set(newValue, forKey: cpuKey) }
    }

    /// The vCPUs the VM gets.
    @objc public static var cpuCount: Int {
        chosenCPUCount > 0 ? min(chosenCPUCount, maximumCPUCount) : automaticCPUCount
    }

    /// "1 GB", "1.25 GB", "512 MB"
    @objc public static func formatMemory(_ mb: Int) -> String {
        if mb < 1024 { return "\(mb) MB" }
        if mb % 1024 == 0 { return "\(mb / 1024) GB" }
        var text = String(format: "%.2f", Double(mb) / 1024)
        while text.hasSuffix("0") { text.removeLast() }
        return text + " GB"
    }
}
