import Foundation
import Testing
import RuyioCore
import RuyioProtocol
import RuyioHostKit

private final class ReceivedDocuments: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ViewDocument] = []
    func append(_ document: ViewDocument) { lock.withLock { values.append(document) } }
    var documents: [ViewDocument] { lock.withLock { values } }
}

struct ViewUpdateRouterTests {
    @Test func subscriptionsFilterBothIdentityAndViewWithoutReplacingOtherSurfaces() {
        let router = ViewUpdateRouter()
        let plugin = PluginID("org.ruyio.first")
        let otherPlugin = PluginID("org.ruyio.second")
        let overlay = ReceivedDocuments()
        let settings = ReceivedDocuments()
        let unrelated = ReceivedDocuments()
        let secondOverlay = ReceivedDocuments()
        let token = router.observe(pluginID: plugin, viewID: "history") { overlay.append($0) }
        _ = router.observe(pluginID: plugin, viewID: "settings") { settings.append($0) }
        _ = router.observe(pluginID: otherPlugin, viewID: "history") { unrelated.append($0) }
        _ = router.observe(pluginID: plugin, viewID: "history") { secondOverlay.append($0) }

        let history = ViewDocument(viewID: "history", revision: 2, root: .loading)
        router.publish(pluginID: plugin, document: history)
        #expect(overlay.documents == [history])
        #expect(secondOverlay.documents == [history])
        #expect(settings.documents.isEmpty)
        #expect(unrelated.documents.isEmpty)

        router.remove(token)
        router.remove(token)
        let latest = ViewDocument(viewID: "history", revision: 3, root: .loading)
        router.publish(pluginID: plugin, document: latest)
        #expect(overlay.documents == [history])
        #expect(secondOverlay.documents == [history, latest])
        let preferences = ViewDocument(viewID: "settings", revision: 1, root: .loading)
        router.publish(pluginID: plugin, document: preferences)
        #expect(settings.documents == [preferences])
        router.publish(pluginID: otherPlugin, document: history)
        #expect(unrelated.documents == [history])
    }
}
