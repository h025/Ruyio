import Foundation
import RuyioCore
import RuyioProtocol

/// Each surface owns a subscription; opening settings must not replace an overlay's event handler.
public final class ViewUpdateRouter: @unchecked Sendable {
    private struct Observer {
        var pluginID: PluginID
        var viewID: String
        var receive: @Sendable (ViewDocument) -> Void
    }
    private let lock = NSLock()
    private var observers: [UUID: Observer] = [:]

    public init() {}

    public func observe(pluginID: PluginID, viewID: String,
                        receive: @escaping @Sendable (ViewDocument) -> Void) -> UUID {
        let token = UUID()
        lock.withLock { observers[token] = Observer(pluginID: pluginID, viewID: viewID, receive: receive) }
        return token
    }

    public func remove(_ token: UUID) { _ = lock.withLock { observers.removeValue(forKey: token) } }

    public func publish(pluginID: PluginID, document: ViewDocument) {
        let matching = lock.withLock { observers.values.filter { $0.pluginID == pluginID && $0.viewID == document.viewID } }
        for observer in matching { observer.receive(document) }
    }
}
