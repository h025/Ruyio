import Darwin
import Foundation
import RuyioPluginSDK

/// Fixture plugin for real-process integration tests. Not shipped.
final class TestPlugin: RuyioPlugin, @unchecked Sendable {
    let context: PluginContext
    init(context: PluginContext) {
        self.context = context
    }

    func migrateData(_ request: DataPreparationRequest) async throws {
        if Bundle.main.url(forResource: "fail-migration", withExtension: nil) != nil {
            throw RuyioError(.storageFailure, diagnostic: "fixture migration rejected")
        }
        if request.sourceSchemaVersion == 0 || request.sourceSchemaVersion == request.targetSchemaVersion { return }
        guard request.sourceSchemaVersion == 1, request.targetSchemaVersion == 2 else {
            throw RuyioError(.incompatibleProtocol, diagnostic: "fixture has no migration for this schema")
        }
        if var document = try await context.storage.get(collection: "notes", id: "n1") {
            document.body = ["v": document.body["v"] ?? .null, "schemaVersion": 2, "migrated": true]
            try await context.storage.put(document)
        }
    }

    func checkHealth(_ request: DataPreparationRequest) async throws {
        if Bundle.main.url(forResource: "fail-health", withExtension: nil) != nil {
            throw RuyioError(.storageFailure, diagnostic: "fixture health rejected")
        }
        if let document = try await context.storage.get(collection: "notes", id: "n1") {
            guard document.body["v"]?.stringValue != nil,
                  document.body["schemaVersion"] == .number(Double(request.targetSchemaVersion)) else {
                throw RuyioError(.storageFailure, diagnostic: "fixture document does not match target schema")
            }
        }
    }

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
            let doc = StoredDocument(collection: "notes", id: "n1", body: ["v": "中文内容", "schemaVersion": .number(Double(context.manifest.storageSchemaVersion))], fields: ["kind": "text"],
                                     searchText: "剪贴板历史记录", sortKey: 1)
            try await context.storage.put(doc)
            let loaded = try await context.storage.get(collection: "notes", id: "n1")
            return .succeeded(.notice(loaded?.body["v"]?.stringValue ?? "missing"))
        case "storage-read":
            let loaded = try await context.storage.get(collection: "notes", id: "n1")
            return .succeeded(.notice(loaded?.body["v"]?.stringValue ?? "missing"))
        case "version":
            return .succeeded(.notice(context.manifest.version.description))
        case "undeclared-capability":
            try await context.capabilities.openWebLink("https://example.com")
            return .succeeded()
        case "sandbox-probe":
            // Reports what this process can see; used by the P0-02 experiment.
            let home = ProcessInfo.processInfo.environment["HOME"] ?? "?"
            let desktop = FileManager.default.homeDirectoryForCurrentUser.path
            return .succeeded(.notice("home=\(home) cwd=\(FileManager.default.currentDirectoryPath) desktop=\(desktop)"))
        case "read-path":
            // P0-02: a sandboxed plugin must not read files outside its container.
            let path = invocation.parameters["path"]?.stringValue ?? ""
            let readable = FileManager.default.contents(atPath: path) != nil
            return .succeeded(.notice(readable ? "readable" : "denied"))
        case "network-probe":
            // P0-02: without network.client the sandbox must refuse outbound connections.
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(443).bigEndian
            address.sin_addr.s_addr = inet_addr("1.1.1.1")
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            return .succeeded(.notice(result == 0 ? "connected" : "blocked errno=\(errno)"))
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
    actions: ["echo", "slow", "crash", "block-main", "storage", "undeclared-capability", "sandbox-probe", "read-path", "network-probe", "storage-read", "version"].map {
        ActionDeclaration(id: ActionID($0), title: $0, presentations: presentations)
    }
)
PluginRuntime.run(TestPlugin.self, manifest: PluginRuntime.loadBundledManifest() ?? manifest)
