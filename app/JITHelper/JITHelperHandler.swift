//
//  JITHelperHandler.swift
//  iSH+ JIT helper extension
//
//  Enables JIT for iSH+ from a separate process (a process cannot debug
//  itself): connects to this device's developer services through
//  LocalDevVPN with the user's pairing file, attaches debugserver to iSH+
//  and runs StikJIT's universal JIT script, which serves iSH+'s requests for
//  executable memory (brk #0xf00d) until iSH+ asks it to detach.
//
//  Request (NSExtensionItem.userInfo["ishplus-jit-request"], JSON):
//      { "pid": Int, "pairing": base64 pairing file }
//  Response (userInfo["ishplus-jit-response"], JSON):
//      { "ok": Bool, "error": String?, "log": [String] }
//

import Foundation
import StikJIT

@objc(ISHJITHelperHandler)
final class JITHelperHandler: NSObject, NSExtensionRequestHandling {
    static let requestKey = "ishplus-jit-request"
    static let responseKey = "ishplus-jit-response"
    private static let queue = DispatchQueue(label: "app.ishplus.jit-helper")

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let data = item.userInfo?[Self.requestKey] as? Data,
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = request["pid"] as? Int,
              let pairingBase64 = request["pairing"] as? String,
              let pairing = Data(base64Encoded: pairingBase64) else {
            Self.respond(context, ok: false, error: "Invalid request from iSH+.", log: [])
            return
        }
        Self.queue.async {
            var log: [String] = []
            func note(_ line: String) {
                NSLog("[iSH+ JIT] %@", line)
                log.append(line)
                if log.count > 60 { log.removeFirst() }
            }
            do {
                let manager = FileManager.default
                let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("StikJIT")
                try manager.createDirectory(at: root, withIntermediateDirectories: true)
                let pairingURL = root.appendingPathComponent("pairing-\(UUID().uuidString).plist")
                try pairing.write(to: pairingURL, options: .atomic)
                defer { try? manager.removeItem(at: pairingURL) }

                note("Enabling JIT for pid \(pid)")
                // Blocks until iSH+ asks the script to detach. The script is
                // needed on iOS 26+ even without TXM: iSH+ cannot make its own
                // pages executable, the debugger has to allocate them.
                try StikJIT.enableJIT(targetPID: Int32(pid),
                                      pairingFile: pairingURL,
                                      ddiPaths: .default(in: root),
                                      script: .universal,
                                      forceScript: true,
                                      preparationProgress: { stage in note("\(stage)") },
                                      progress: { note($0) })
                note("Detached")
                Self.respond(context, ok: true, error: nil, log: log)
            } catch {
                note("Failed: \(error.localizedDescription)")
                Self.respond(context, ok: false, error: error.localizedDescription, log: log)
            }
        }
    }

    private static func respond(_ context: NSExtensionContext, ok: Bool, error: String?, log: [String]) {
        var response: [String: Any] = ["ok": ok, "log": log]
        if let error { response["error"] = error }
        let item = NSExtensionItem()
        item.userInfo = [responseKey: (try? JSONSerialization.data(withJSONObject: response)) ?? Data()]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
