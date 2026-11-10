//
//  VMState.swift
//  iSH+
//
//  Instant resume: when iSH+ goes to the background without "Keep Running
//  in Background", Linux is paused and its state saved to a file (QEMU
//  migration, mapped-ram: only the memory in use is written). If iOS ends
//  iSH+ meanwhile, the next launch restores that state instead of booting,
//  so shells and programs are where they were; if not, Linux continues.
//
//  QEMU cannot save a VM while a 9p share is mounted, so the guest unmounts
//  the iOS share first (boot/suspend.sh) and mounts it again, with the
//  current time, after (boot/resume.sh).
//

import Foundation
import UIKit

@objc(ISHVMState)
public final class VMState: NSObject {
    @objc public static let shared = VMState()

    private struct Saved: Codable {
        let distro: String
        let fingerprint: String
        let date: Date
    }

    private let queue = DispatchQueue(label: "app.ishplus.vmstate")
    private var directory: URL { VirtualMachine.guestDirectory.appendingPathComponent("state") }
    private var stateURL: URL { directory.appendingPathComponent("vm.state") }
    private var infoURL: URL { directory.appendingPathComponent("state.json") }
    /// Linux is paused and saved, and the app is still running.
    private var paused = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Restoring a saved state at launch.
    private(set) var restoring = false

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.enteredBackground()
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.enteringForeground()
        }
    }

    /// What a saved state must match: the same VM (distribution, memory,
    /// CPUs) and the same app build (kernel, QEMU, devices).
    private func fingerprint(distro: Distro) -> String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let executable = Bundle.main.executableURL.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
        }?.timeIntervalSince1970 ?? 0
        return "\(build)|\(executable)|\(distro.id)|\(VMSettings.memoryMB)|\(VMSettings.cpuCount)"
    }

    // MARK: Launch

    /// When the saved state was made, if there is one this VM can resume
    /// (states for another configuration are discarded).
    @objc public var savedDate: Date? {
        guard let distro = DistroManager.shared.active,
              let data = try? Data(contentsOf: infoURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        guard saved.distro == distro.id, saved.fingerprint == fingerprint(distro: distro) else {
            vmLog("discarding a saved state made for another configuration")
            discard()
            return nil
        }
        return saved.date
    }

    /// Start Linux afresh instead of resuming.
    @objc public func discardSavedState() {
        discard()
    }

    /// Whether to start QEMU waiting for a saved state (adds -incoming).
    func prepareRestore(distro: Distro) -> Bool {
        guard savedDate != nil else { return false }
        restoring = true
        return true
    }

    /// After qemu_init, when restoring: loads the state and continues.
    func restoreAfterInit() {
        guard restoring else { return }
        queue.async { [self] in
            let start = Date()
            var ok = false
            if waitForMonitor() {
                _ = QEMUMonitor.run("migrate_set_capability mapped-ram on")
                _ = QEMUMonitor.run("migrate_incoming file:\(stateURL.path)")
                ok = waitForMigration(timeout: 120)
            }
            restoring = false
            discard() // the disk changes from now on: the state must not be used again
            guard ok else {
                vmLog("could not restore the saved state")
                return
            }
            _ = QEMUMonitor.run("cont")
            vmLog(String(format: "restored the saved state in %.1f s", Date().timeIntervalSince(start)))
            resumeGuest()
        }
    }

    // MARK: Background

    private var keepsRunningInBackground: Bool {
        UserDefaults.standard.object(forKey: "Keep Alive In Background") as? Bool ?? true
    }

    private func enteredBackground() {
        guard VirtualMachine.shared.isRunning, !keepsRunningInBackground, !restoring, !paused else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save Linux") { [weak self] in
            self?.endBackgroundTask()
        }
        queue.async { [self] in
            paused = save()
            DispatchQueue.main.async { self.endBackgroundTask() }
        }
    }

    private func enteringForeground() {
        queue.async { [self] in
            guard paused else { return }
            paused = false
            // Still running: no need for the saved state
            discard()
            _ = QEMUMonitor.run("cont")
            resumeGuest()
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    /// Pauses Linux and saves it. On failure Linux keeps running.
    private func save() -> Bool {
        guard let distro = DistroManager.shared.active else { return false }
        let start = Date()
        let (status, output) = runInGuest("sh /opt/ishplus/boot/suspend.sh", timeout: 15)
        guard status == 0, output.contains("ready") else {
            vmLog("not saving Linux: the guest is not ready (\(output))")
            resumeGuest()
            return false
        }
        _ = QEMUMonitor.run("stop")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        discard()
        _ = QEMUMonitor.run("migrate_set_capability mapped-ram on")
        _ = QEMUMonitor.run("migrate -d file:\(stateURL.path)")
        guard waitForMigration(timeout: 25) else {
            vmLog("could not save Linux")
            discard()
            _ = QEMUMonitor.run("cont")
            resumeGuest()
            return false
        }
        let saved = Saved(distro: distro.id, fingerprint: fingerprint(distro: distro), date: Date())
        try? JSONEncoder().encode(saved).write(to: infoURL, options: .atomic)
        vmLog(String(format: "saved Linux in %.1f s", Date().timeIntervalSince(start)))
        return true
    }

    // MARK: Helpers

    private func discard() {
        try? FileManager.default.removeItem(at: infoURL)
        try? FileManager.default.removeItem(at: stateURL)
    }

    private func resumeGuest() {
        GuestServices.shared.run("sh /opt/ishplus/boot/resume.sh \(Int(Date().timeIntervalSince1970))", asRoot: true) { _, _ in }
    }

    private func runInGuest(_ command: String, timeout: TimeInterval) -> (Int32, String) {
        let done = DispatchSemaphore(value: 0)
        var result: (Int32, String) = (-1, "no answer")
        GuestServices.shared.run(command, asRoot: true) { status, output in
            result = (status, output)
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        return result
    }

    private func waitForMonitor() -> Bool {
        for _ in 0..<100 {
            if QEMUMonitor.run("info status", timeout: 1) != nil { return true }
            usleep(100_000)
        }
        return false
    }

    /// Waits for a migration (saving or loading) to finish; true if it completed.
    private func waitForMigration(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let info = QEMUMonitor.run("info migrate") ?? ""
            if info.contains("completed") { return true }
            if info.contains("failed") || info.contains("cancelled") {
                vmLog("migration: \(info)")
                return false
            }
            usleep(200_000)
        }
        return false
    }
}
