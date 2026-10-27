import Foundation
@_exported import RuyioCore
@_exported import RuyioProtocol

/// Implement this in a plugin executable and call `PluginRuntime.run(YourPlugin.self)` from `main`.
/// All methods are invoked off the main thread unless documented otherwise.
public protocol RuyioPlugin: AnyObject, Sendable {
    init(context: PluginContext)

    /// Called once after the handshake. Start background work only if declared and enabled.
    func start() async

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
