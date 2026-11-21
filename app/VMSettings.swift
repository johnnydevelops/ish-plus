//
//  VMSettings.swift
//  iSH+
//
//  The Linux VM's memory and CPU count, chosen by the user (Settings > Linux
//  VM) within what this device can run. Applied when the VM starts.
//

import Foundation
import os

@objc(ISHVMSettings)
public final class VMSettings: NSObject {
    private static let memoryKey = "VM Memory"
    private static let cpuKey = "VM CPUs"
    private static let gpuKey = "VM GPU Acceleration"
    private static let vulkanKey = "VM Vulkan"
    private static let pages4KKey = "VM 4K Pages"

    /// RAM in this device, in GB (rounded, so 2.8 GB of usable memory is 3).
    @objc public static var deviceMemoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }

    /// The memory iOS lets iSH+ use before ending it (with the increased
    /// memory limit entitlement): what it uses now plus what is still
    /// available to it. About 1.85 GB on a 3 GB iPad.
    @objc public static var processMemoryLimitMB: Int {
        let available = os_proc_available_memory()
        guard available > 0 else {
            // Not limited (or unknown): estimate, as a bit over half the RAM
            return Int(Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576 * 0.6)
        }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let used = result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
        return (used + available) >> 20
    }

    /// QEMU's own memory besides the VM's: its translated code cache
    /// (256 MB), its code and devices, the app.
    private static let qemuOverheadMB = 450
    /// Kept free, so iOS does not end iSH+ at the edge: 10% of the limit, at
    /// least 150 MB (iOS lowers the limit under memory pressure).
    private static var marginMB: Int { max(150, processMemoryLimitMB / 10) }

    /// The most memory the VM can have within iSH+'s own memory limit: the
    /// limit, less QEMU's own and a margin (about 1.2 GB on a 3 GB iPad, 5 GB
    /// on a 12 GB iPhone), at least 512 MB.
    @objc public static var processMaximumMemoryMB: Int {
        max(512, (processMemoryLimitMB - qemuOverheadMB - marginMB) / 16 * 16)
    }

    /// Whether Linux's RAM comes from memory donors (RamDonor.m), outside
    /// iSH+'s memory limit: when the helper extension is in this build, unless
    /// Documents/VM/donate contains "0".
    @objc public static var memoryDonorsAvailable: Bool {
        guard let plugIns = Bundle.main.builtInPlugInsURL,
              FileManager.default.fileExists(atPath: plugIns.appendingPathComponent("iSHJITHelper.appex").path) else {
            return false
        }
        let flag = try? String(contentsOf: VirtualMachine.guestDirectory.appendingPathComponent("donate"), encoding: .utf8)
        return flag?.hasPrefix("0") != true
    }

    /// Whether the LineageOS 17.1 / Android 10 container is enabled in this
    /// session (Documents/VM/android contains "1"). When on, the VM's RAM is
    /// capped lower (1.4–1.7 GB on a 3–4 GB A13 device) so Android + lmkd +
    /// zram coexist with iOS jetsam headroom. See docs/lineageos.md.
    @objc public static var androidContainerEnabled: Bool {
        get {
            let flag = try? String(contentsOf: VirtualMachine.guestDirectory.appendingPathComponent("android"), encoding: .utf8)
            return flag?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
        set {
            // Write (or remove) the flag file the getter reads. The directory
            // exists once the VM has been set up; createDirectory(withIntermediateDirectories:)
            // is a no-op if it is already there.
            let url = VirtualMachine.guestDirectory.appendingPathComponent("android")
            do {
                try FileManager.default.createDirectory(at: VirtualMachine.guestDirectory, withIntermediateDirectories: true)
                if newValue {
                    try "1".write(to: url, atomically: true, encoding: .utf8)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                NSLog("androidContainerEnabled: could not write flag: \(error.localizedDescription)")
            }
        }
    }

    /// The most memory the VM can have here. With memory donors, Linux's RAM
    /// is outside iSH+'s limit, so the device's RAM decides: 60% of it (about
    /// 1.7 GB on a 3 GB iPad, 7 GB on a 12 GB iPhone). Otherwise iSH+'s limit.
    /// When the Android container is on, the cap is tightened to 1.4–1.7 GB
    /// on 3–4 GB A13-class devices (LineageOS 17.1 + lmkd + zram + iOS
    /// jetsam headroom all have to fit). See docs/lineageos.md.
    @objc public static var maximumMemoryMB: Int {
        guard memoryDonorsAvailable else { return processMaximumMemoryMB }
        let deviceMB = Int(ProcessInfo.processInfo.physicalMemory >> 20)
        let donorCap = max(processMaximumMemoryMB, deviceMB * 6 / 10 / 16 * 16)
        guard androidContainerEnabled else { return donorCap }
        // Android needs the donor RAM for itself + zram + host Linux. On a
        // 3 GB device that is 1436 MB; on 4 GB it is 1740 MB; on ≥6 GB the
        // cap is loose enough that the donor cap wins.
        let androidCap: Int
        if deviceMB <= 3072 {
            androidCap = 1436   // 1.4 GB: ~1.6 GB left for iOS + the app
        } else if deviceMB <= 4096 {
            androidCap = 1740   // 1.7 GB: ~2.3 GB left for iOS + the app
        } else {
            androidCap = 2560   // 2.5 GB: comfortable on 6 GB+ devices
        }
        return min(donorCap, androidCap)
    }

    /// Automatic memory (the default): from the RAM, 57% less 650 MB, but at
    /// most 60% of iSH+'s memory limit, in 256 MB steps: 1 GB on a 3 GB iPad
    /// (limit ~1.85 GB), 3.5 GB on a 12 GB iPhone (limit ~6.1 GB; the VM
    /// filling 5.5 GB there got iSH+ ended). With the Android container on,
    /// capped to the Android-friendly maximum above.
    @objc public static var automaticMemoryMB: Int {
        let estimate = Int(Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576 * 0.57) - 650
        let safe = processMemoryLimitMB * 6 / 10
        let auto = min(processMaximumMemoryMB, max(512, min(estimate, safe) / 256 * 256))
        return min(auto, maximumMemoryMB)
    }

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

    /// Whether this build has the GPU libraries: ANGLE (OpenGL ES over Metal),
    /// which QEMU's virglrenderer draws the guest's OpenGL with.
    @objc public static var gpuAvailable: Bool {
        FileManager.default.fileExists(atPath:
            Bundle.main.privateFrameworksURL!.appendingPathComponent("libGLESv2.dylib").path)
    }

    /// Whether this build has MoltenVK (Vulkan over Metal), for Venus.
    @objc public static var vulkanAvailable: Bool {
        FileManager.default.fileExists(atPath:
            Bundle.main.privateFrameworksURL!.appendingPathComponent("MoltenVK.framework/MoltenVK").path)
    }

    /// GPU acceleration for the Desktop (VirGL: the guest's OpenGL drawn
    /// with Metal), chosen by the user; off by default. Linux cannot be saved
    /// for an instant resume while it is on (QEMU cannot save virgl's state).
    @objc public static var gpuAcceleration: Bool {
        get { gpuAvailable && UserDefaults.standard.bool(forKey: gpuKey) }
        set { UserDefaults.standard.set(newValue, forKey: gpuKey) }
    }

    /// Vulkan for Linux (Venus, on MoltenVK), with GPU acceleration;
    /// experimental and off by default. Linux is paused while iSH+ is in the
    /// background, as iOS allows no GPU work then.
    /// Linux with 4 KB memory pages (Alpine's kernel) instead of the default
    /// 16 KB (Debian's 16k kernel, with QEMU's own pages at 16 KB too, so
    /// that each emulated memory access and TLB fill covers 4 times more).
    /// x86 programs (FEX) see 4 KB pages either way. Applied when the VM
    /// starts; a saved state is only resumed with the setting it was made with.
    /// Documents/VM/pages ("4" or "16") overrides it, for comparing the two.
    @objc public static var pages4K: Bool {
        get {
            let file = VirtualMachine.guestDirectory.appendingPathComponent("pages")
            if let pages = try? String(contentsOf: file, encoding: .utf8) {
                return pages.trimmingCharacters(in: .whitespacesAndNewlines) == "4"
            }
            return UserDefaults.standard.bool(forKey: pages4KKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: pages4KKey) }
    }

    @objc public static var vulkan: Bool {
        get { gpuAcceleration && vulkanAvailable && UserDefaults.standard.bool(forKey: vulkanKey) }
        set { UserDefaults.standard.set(newValue, forKey: vulkanKey) }
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
