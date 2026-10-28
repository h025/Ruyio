import Foundation
import Testing
@testable import RuyioHostKit
import RuyioPersistence
import RuyioProtocol
import RuyioCore

struct ScreenCaptureCapabilityTests {
    struct Fixture {
        let root: URL
        let services: HostServices
        let stores: StoreProvider
        let contexts: InvocationContexts
        let bridge: TestBridge
        let session: SessionInfo
    }

    func fixture(permissions: [Permission] = [.screenCapture, .windowsPin]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString)")
        let paths = AppPaths(applicationSupport: root.appendingPathComponent("Support"), caches: root.appendingPathComponent("Caches"))
        try paths.ensureDirectories()
        let database = try HostDatabase()
        let contexts = InvocationContexts()
        let stores = StoreProvider(paths: paths, identity: { $0.rawValue })
        let broker = FileBroker(database: database, contexts: contexts) { _, _ in Data() }
        let bridge = TestBridge()
        let services = HostServices(stores: stores, fileBroker: broker, contexts: contexts, database: database, bridge: bridge)
        let manifest = PackageFixture.manifest(permissions: permissions)
        let session = SessionInfo(pluginID: manifest.id, manifest: manifest, runtimeMode: .normal, dataGeneration: 1, isDevelopment: true)
        return Fixture(root: root, services: services, stores: stores, contexts: contexts, bridge: bridge, session: session)
    }

    func capture(_ f: Fixture, execution: ExecutionID?) async throws -> ScreenCaptureReply {
        let value = try await f.services.handleRequest(Envelope(kind: .request, method: CapabilityMethod.screenCapture, executionID: execution),
                                                       session: f.session)
        return try JSONCoding.decode(ScreenCaptureReply.self, from: value)
    }

    @Test func captureRunsOnlyInsideTheCallingPluginsOwnAction() async throws {
        let f = try fixture()
        defer { f.stores.close(pluginID: f.session.pluginID); try? FileManager.default.removeItem(at: f.root) }
        // Larger than one blob chunk, so the host-side upload path is exercised end to end.
        let png = Data((0..<200_000).map { UInt8($0 % 251) })
        f.bridge.capture = .success(CapturedScreen(png: png, pixelWidth: 640, pixelHeight: 400, scale: 2))

        for execution in [nil, ExecutionID()] {
            await #expect(throws: RuyioError.self) { _ = try await capture(f, execution: execution) }
        }
        let foreign = ExecutionID()
        f.contexts.begin(foreign, for: PluginID("org.example.other"))
        do {
            _ = try await capture(f, execution: foreign)
            Issue.record("Another plugin's action must not unlock a capture")
        } catch let error as RuyioError { #expect(error.code == .permissionDenied) }

        let execution = ExecutionID()
        f.contexts.begin(execution, for: f.session.pluginID)
        let reply = try await capture(f, execution: execution)
        #expect(reply.pixelWidth == 640 && reply.pixelHeight == 400 && reply.scale == 2)
        #expect(try f.stores.store(for: f.session).blobData(reply.blobID) == png)

        f.contexts.revokeAll(for: execution)
        do {
            _ = try await capture(f, execution: execution)
            Issue.record("A finished action must not unlock a capture")
        } catch let error as RuyioError { #expect(error.code == .permissionDenied) }
    }

    @Test func cancelledSelectionReachesThePluginAsCancelled() async throws {
        let f = try fixture()
        defer { f.stores.close(pluginID: f.session.pluginID); try? FileManager.default.removeItem(at: f.root) }
        let execution = ExecutionID()
        f.contexts.begin(execution, for: f.session.pluginID)
        do {
            _ = try await capture(f, execution: execution)
            Issue.record("Escape must cancel")
        } catch let error as RuyioError { #expect(error.code == .cancelled) }
    }

    @Test func pinPassesTheStoredImageAndRejectsBadScaleAndUndeclaredUse() async throws {
        let f = try fixture()
        defer { f.stores.close(pluginID: f.session.pluginID); try? FileManager.default.removeItem(at: f.root) }
        let image = Data("png bytes".utf8)
        let blobID = try f.stores.store(for: f.session).putBlob(image)
        func pin(_ scale: Double, session: SessionInfo) async throws {
            _ = try await f.services.handleRequest(Envelope(kind: .request, method: CapabilityMethod.windowPin,
                                                            payload: try JSONCoding.value(PinImageRequest(blobID: blobID, scale: scale))),
                                                   session: session)
        }
        try await pin(2, session: f.session)
        #expect(f.bridge.pins.count == 1)
        #expect(f.bridge.pins.first?.data == image && f.bridge.pins.first?.scale == 2 && f.bridge.pins.first?.pluginID == f.session.pluginID)

        for scale in [0, 0.5, 5] {
            do {
                try await pin(scale, session: f.session)
                Issue.record("scale \(scale) must be rejected")
            } catch let error as RuyioError { #expect(error.code == .invalidRequest) }
        }
        var undeclared = f.session
        undeclared.manifest = PackageFixture.manifest(permissions: [.clipboardWrite])
        do {
            try await pin(2, session: undeclared)
            Issue.record("windows.pin must be declared")
        } catch let error as RuyioError { #expect(error.code == .permissionNotDeclared) }
        #expect(f.bridge.pins.count == 1)
    }
}
