import Darwin
import Foundation
import RuyioPluginSDK

/// Fixture plugin for real-process integration tests. Not shipped.
final class TestPlugin: RuyioPlugin, @unchecked Sendable {
    let context: PluginContext
    init(context: PluginContext) { self.context = context }

    func perform(_ invocation: ActionInvocation, execution: ExecutionID, operation: OperationID?) async throws -> ActionResult {
        switch invocation.actionID.rawValue {
        case "echo":
            let text = invocation.parameters["text"]?.stringValue ?? ""
            return .succeeded(.notice("echo:\(text):\(context.locale)"))
        case "slow":
            try await Task.sleep(for: .seconds(30))
            return .succeeded()
        case "crash":
            abort()
        case "block-main":
            // Simulates a plugin stuck on the main thread (e.g. promised pasteboard read).
            DispatchQueue.main.async { while true { usleep(100_000) } }
            return .succeeded()
        case "storage":
            let doc = StoredDocument(collection: "notes", id: "n1", body: ["v": "中文内容"], fields: ["kind": "text"],
                                     searchText: "剪贴板历史记录", sortKey: 1)
            try await context.storage.put(doc)
            let loaded = try await context.storage.get(collection: "notes", id: "n1")
            return .succeeded(.notice(loaded?.body["v"]?.stringValue ?? "missing"))
        case "undeclared-capability":
            try await context.capabilities.openWebLink("https://example.com")
            return .succeeded()
        case "sandbox-probe":
            // Reports what this process can see; used by the P0-02 experiment.
            let home = ProcessInfo.processInfo.environment["HOME"] ?? "?"
            let desktop = FileManager.default.homeDirectoryForCurrentUser.path
            return .succeeded(.notice("home=\(home) cwd=\(FileManager.default.currentDirectoryPath) desktop=\(desktop)"))
        default:
            throw RuyioError(.actionNotFound, objectID: invocation.actionID.rawValue)
        }
    }
}

let presentations = [Presentation(type: .commandPalette, title: "Test")]
let manifest = PluginManifest(
    id: PluginID("org.ruyio.test-plugin"), name: "Test Plugin", version: SemanticVersion("1.0.0")!,
    bundlePath: "Test.app", executable: "Test.app/Contents/MacOS/RuyioTestPlugin",
    permissions: [.clipboardWrite],
    actions: ["echo", "slow", "crash", "block-main", "storage", "undeclared-capability", "sandbox-probe"].map {
        ActionDeclaration(id: ActionID($0), title: $0, presentations: presentations)
    }
)
PluginRuntime.run(TestPlugin.self, manifest: manifest)
