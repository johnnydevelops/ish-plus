//
//  RunCommandIntent.swift
//  iSH+
//
//  The Run Command action for Shortcuts: runs a command in the Linux VM as
//  the user its sessions log in as, and returns the output. Runs in the
//  background when Linux is running; otherwise iSH+ opens to start it.
//

import AppIntents
import Foundation

// In libiSHApp (GuestServices.swift)
@_silgen_name("ishplus_vm_is_running")
private func vmIsRunning() -> Bool
@_silgen_name("ishplus_vm_run_command")
private func vmRunCommand(_ command: UnsafePointer<CChar>, _ context: UnsafeMutableRawPointer?,
                          _ done: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>) -> Void)

private final class CommandResult {
    let continuation: CheckedContinuation<(Int32, String), Never>
    init(_ continuation: CheckedContinuation<(Int32, String), Never>) { self.continuation = continuation }
}

private func runInLinux(_ command: String) async -> (Int32, String) {
    await withCheckedContinuation { continuation in
        let box = Unmanaged.passRetained(CommandResult(continuation)).toOpaque()
        command.withCString { cCommand in
            vmRunCommand(cCommand, box) { context, status, output in
                let result = Unmanaged<CommandResult>.fromOpaque(context!).takeRetainedValue()
                result.continuation.resume(returning: (status, String(cString: output)))
            }
        }
    }
}

@available(iOS 26.0, *)
struct RunCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Command"
    static let description = IntentDescription("Runs a command in iSH+'s Linux and returns its output.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Command", inputOptions: String.IntentInputOptions(capitalizationType: .none, autocorrect: false))
    var command: String

    @Parameter(title: "Stop if It Fails", default: false)
    var failIfNonzero: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) in iSH+") {
            \.$failIfNonzero
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        if !vmIsRunning() {
            try await continueInForeground("iSH+ needs to start Linux to run the command.", alwaysConfirm: false)
            // The app enables JIT and boots; wait for it
            for _ in 0..<300 where !vmIsRunning() {
                try await Task.sleep(for: .seconds(1))
            }
        }
        let (status, output) = await runInLinux(command)
        if status != 0 && failIfNonzero {
            throw RunCommandError.failed(status: Int(status), output: output)
        }
        return .result(value: output)
    }
}

@available(iOS 26.0, *)
enum RunCommandError: Error, CustomLocalizedStringResourceConvertible {
    case failed(status: Int, output: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .failed(let status, let output):
            return "The command failed (exit status \(status)). \(output)"
        }
    }
}

@available(iOS 26.0, *)
struct ISHShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RunCommandIntent(),
                    phrases: ["Run a command in \(.applicationName)"],
                    shortTitle: "Run Command",
                    systemImageName: "terminal")
    }
}
