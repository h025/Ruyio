import Foundation
import Testing
@testable import RuyioHostKit
import RuyioPersistence
import RuyioProtocol
import RuyioCore

struct DesktopPlacementTests {
    @Test func placementTravelsWithTheDirectoryGrantOfItsOwnPlugin() {
        let contexts = InvocationContexts()
        let plugin = PluginID("org.ruyio.test-plugin")
        let execution = ExecutionID()
        let dir = FileManager.default.temporaryDirectory
        let placed = contexts.issue(dir, for: plugin, execution: execution, placement: CGPoint(x: 120, y: 340))
        let plain = contexts.issue(dir, for: plugin, execution: execution)
        #expect(contexts.placement(of: placed, for: plugin) == CGPoint(x: 120, y: 340))
        #expect(contexts.placement(of: plain, for: plugin) == nil)
        #expect(contexts.placement(of: placed, for: PluginID("org.example.other")) == nil)
        contexts.revokeAll(for: execution)
        #expect(contexts.placement(of: placed, for: plugin) == nil)
    }

    @Test func onlyFilesCreatedThroughAPlacedDirectoryAreMoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("placement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(applicationSupport: root.appendingPathComponent("Support"), caches: root.appendingPathComponent("Caches"))
        try paths.ensureDirectories()
        let target = root.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let database = try HostDatabase()
        let contexts = InvocationContexts()
        let stores = StoreProvider(paths: paths, identity: { $0.rawValue })
        let broker = FileBroker(database: database, contexts: contexts) { _, _ in Data() }
        let bridge = TestBridge()
        let services = HostServices(stores: stores, fileBroker: broker, contexts: contexts, database: database, bridge: bridge)
        let manifest = PackageFixture.manifest(permissions: [.filesWrite])
        let session = SessionInfo(pluginID: manifest.id, manifest: manifest, runtimeMode: .normal, dataGeneration: 1, isDevelopment: true)
        func write(_ name: String, into ref: FileRef) async throws {
            let request = FileWriteRequest(directory: ref, items: [FileWriteItem(fileName: name, source: .text("x"))],
                                           conflictPolicy: .fail, revealAfterWrite: false)
            _ = try await services.handleRequest(Envelope(kind: .request, method: CapabilityMethod.fileWrite, operationID: OperationID(),
                                                          payload: try JSONCoding.value(request)), session: session)
        }
        let location = CGPoint(x: 400, y: 300)
        let placed = contexts.issue(target, for: manifest.id, execution: ExecutionID(), placement: location)
        try await write("Note.txt", into: placed)
        #expect(bridge.placements.count == 1)
        #expect(bridge.placements.first?.urls.map(\.lastPathComponent) == ["Note.txt"])
        #expect(bridge.placements.first?.location == location)

        // A conflict writes nothing, so nothing is moved.
        try await write("Note.txt", into: placed)
        #expect(bridge.placements.count == 1)

        try await write("Other.txt", into: contexts.issue(target, for: manifest.id, execution: ExecutionID()))
        #expect(bridge.placements.count == 1)
    }

    @Test func clickLocationIsOptionalOnTheWireAndValidated() throws {
        let legacy = Data(#"{"wireSchemaVersion":1,"requestID":"r","createdAt":0,"pluginID":"p","actionID":"a","selection":[],"snapshotGeneration":1}"#.utf8)
        #expect(try FinderWire.decoder().decode(FinderRequest.self, from: legacy).clickLocation == nil)
        #expect(FinderBridge.clickLocation([10, 20]) == CGPoint(x: 10, y: 20))
        #expect(FinderBridge.clickLocation([-1500, 300]) == CGPoint(x: -1500, y: 300))
        for bad: [Double]? in [nil, [1], [1, 2, 3], [.infinity, 1], [1, 1e9]] {
            #expect(FinderBridge.clickLocation(bad) == nil)
        }
    }
}
