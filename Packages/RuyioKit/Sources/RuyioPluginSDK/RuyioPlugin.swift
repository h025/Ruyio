import Foundation
@_exported import RuyioCore
@_exported import RuyioProtocol

/// Implement this in a plugin executable and call `PluginRuntime.run(YourPlugin.self)` from `main`.
/// All methods are invoked off the main thread unless documented otherwise.
public protocol RuyioPlugin: AnyObject, Sendable {
    init(context: PluginContext)

    /// Called once after the handshake. Start background work only if declared and enabled.
    func start() async

    /// Complete all candidate-data changes before returning. Never starts background work.
    func migrateData(_ request: DataPreparationRequest) async throws

    /// Validate the candidate data using read-only storage. Throw to prevent update commit.
    func checkHealth(_ request: DataPreparationRequest) async throws

    func perform(_ invocation: ActionInvocation, execution: ExecutionID, operation: OperationID?) async throws -> ActionResult

    func openView(_ request: ViewOpenRequest) async throws -> ViewDocument

    func handleViewEvent(_ request: ViewEventRequest) async throws -> ViewEventReply

    func closeView(_ viewID: String) async

    /// Dynamic Finder children for `childrenProvider` (published ahead of time, not queried by Finder).
    func dynamicItems(provider: String) async throws -> DynamicItemsReport

    func localeChanged(_ locale: String) async

    func settingsChanged(_ settings: [String: JSONValue]) async

    /// Graceful stop. Must finish within the host's stop timeout (2 s).
    func shutdown() async
}

public extension RuyioPlugin {
    func start() async {}

    func migrateData(_ request: DataPreparationRequest) async throws {
        guard request.sourceSchemaVersion == 0 || request.sourceSchemaVersion == request.targetSchemaVersion else {
            throw RuyioError(.incompatibleProtocol, diagnostic: "plugin does not provide this data migration")
        }
    }

    /// The host has already opened and integrity-checked the candidate store. A plugin whose data was
    /// migrated must confirm it can read the result; otherwise there is nothing more to verify.
    func checkHealth(_ request: DataPreparationRequest) async throws {
        guard request.sourceSchemaVersion == 0 || request.sourceSchemaVersion == request.targetSchemaVersion else {
            throw RuyioError(.incompatibleProtocol, diagnostic: "a plugin that migrates data must implement checkHealth")
        }
    }

    func openView(_ request: ViewOpenRequest) async throws -> ViewDocument {
        throw RuyioError(.invalidRequest, diagnostic: "view \(request.viewID) not provided")
    }

    func handleViewEvent(_ request: ViewEventRequest) async throws -> ViewEventReply {
        ViewEventReply(document: nil)
    }

    func closeView(_ viewID: String) async {}

    func dynamicItems(provider: String) async throws -> DynamicItemsReport {
        DynamicItemsReport(provider: provider, items: [])
    }

    func localeChanged(_ locale: String) async {}

    func settingsChanged(_ settings: [String: JSONValue]) async {}

    func shutdown() async {}
}
