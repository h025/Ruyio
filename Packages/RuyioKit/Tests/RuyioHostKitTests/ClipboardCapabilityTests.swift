import Foundation
import Testing
@testable import RuyioHostKit
import RuyioPersistence
import RuyioProtocol
import RuyioCore

struct ClipboardCapabilityTests {
    @Test func invalidFileBatchNeverReachesPasteboardBridge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(applicationSupport: root.appendingPathComponent("Support"), caches: root.appendingPathComponent("Caches"))
        try paths.ensureDirectories()
        let existing = root.appendingPathComponent("existing.txt")
        try Data("test".utf8).write(to: existing)
        let missing = root.appendingPathComponent("missing.txt")
        let database = try HostDatabase()
        let contexts = InvocationContexts()
        let stores = StoreProvider(paths: paths, identity: { $0.rawValue })
        let broker = FileBroker(database: database, contexts: contexts) { _, _ in Data() }
        let bridge = TestBridge()
        bridge.pasteboard = [["public.utf8-plain-text": Data("previous".utf8)]]
        let services = HostServices(stores: stores, fileBroker: broker, contexts: contexts, database: database, bridge: bridge)
        let manifest = PackageFixture.manifest()
        let session = SessionInfo(pluginID: manifest.id, manifest: manifest, runtimeMode: .normal, dataGeneration: 1, isDevelopment: true)
        let request = ClipboardWriteRequest(items: [existing, missing].map {
            PasteboardItemPayload(representations: [PasteboardRepresentation(type: "public.file-url", text: $0.absoluteString)])
        }, originToken: "test")
        do {
            _ = try await services.handleRequest(Envelope(kind: .request, method: CapabilityMethod.clipboardWrite,
                payload: try JSONCoding.value(request)), session: session)
            Issue.record("A stale file in the batch must fail before writing")
        } catch let error as RuyioError { #expect(error.code == .fileAccessDenied) }
        #expect(bridge.pasteboard == [["public.utf8-plain-text": Data("previous".utf8)]])
        var valid = request
        valid.items.removeLast()
        _ = try await services.handleRequest(Envelope(kind: .request, method: CapabilityMethod.clipboardWrite,
            payload: try JSONCoding.value(valid)), session: session)
        #expect(bridge.pasteboard.first?["public.file-url"] == Data(existing.absoluteString.utf8))
        stores.close(pluginID: manifest.id)
    }

    @Test func rejectsMalformedRemoteAndNonFileReferences() throws {
        for url in ["https://example.com/file", "file://remote/tmp/file", "file:///tmp/%00file", "not a URL"] {
            #expect(throws: RuyioError.self) {
                try ClipboardWriteValidator.validateFileReferences([["public.file-url": Data(url.utf8)]])
            }
        }
        try ClipboardWriteValidator.validateFileReferences([["public.utf8-plain-text": Data("ordinary text".utf8)]])
    }
}
