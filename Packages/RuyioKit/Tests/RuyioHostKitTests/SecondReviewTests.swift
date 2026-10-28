import Darwin
import Foundation
import Testing
@testable import RuyioHostKit
import RuyioPersistence
import RuyioProtocol
import RuyioCore

/// Regression tests for the second independent review (status doc §3E).
struct SecondReviewTests {
    let plugin = PluginID("app.ruyio.finder-essentials")

    func broker() throws -> (FileBroker, InvocationContexts, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fb2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let contexts = InvocationContexts()
        return (FileBroker(database: try HostDatabase(), contexts: contexts) { _, _ in Data() }, contexts, dir)
    }

    @Test func pluginReplaceAlwaysGoesThroughTheHostDialog() async throws {
        let (broker, contexts, dir) = try broker()
        try "mine".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let delegate = ScriptedConflicts([ConflictResolution(.skip)])
        broker.delegate = delegate
        let ref = contexts.issue(dir, for: plugin, execution: ExecutionID())
        let reply = try await broker.write(FileWriteRequest(directory: ref, items: [FileWriteItem(fileName: "notes.txt", source: .text("theirs"))], conflictPolicy: .replace),
                                           pluginID: plugin, operationID: OperationID(), executionID: nil)
        #expect(delegate.asked == ["notes.txt"])
        #expect(reply.outcomes.first?.status == .skipped)
        #expect(try String(contentsOf: dir.appendingPathComponent("notes.txt"), encoding: .utf8) == "mine")
    }

    @Test func hiddenFileNamesAreRejected() async throws {
        #expect(throws: RuyioError.self) { try FileBroker.validateFileName(".zshenv") }
        #expect(throws: RuyioError.self) { try FileBroker.validateFileName("  .profile") }
        try FileBroker.validateFileName("a.zshenv")
    }

    @Test func largeBatchCostsOneGrantUse() async throws {
        let (broker, contexts, dir) = try broker()
        let ref = contexts.issue(dir, for: plugin, execution: ExecutionID())
        let items = (0..<100).map { FileWriteItem(fileName: "f\($0).txt", source: .text("x")) }
        let reply = try await broker.write(FileWriteRequest(directory: ref, items: items, conflictPolicy: .fail),
                                           pluginID: plugin, operationID: OperationID(), executionID: nil)
        #expect(reply.outcomes.allSatisfy { $0.status == .written })
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 100)
    }

    @Test func endedExecutionsAreRemembered() {
        let contexts = InvocationContexts()
        let execution = ExecutionID()
        #expect(!contexts.hasEnded(execution))
        contexts.revokeAll(for: execution)
        #expect(contexts.hasEnded(execution))
        #expect(!contexts.hasEnded(nil))
    }

    @Test func symlinkChainsAreRejected() {
        // `l1 -> .` makes `l1/l1/…/x` shallower on disk than its literal path suggests.
        #expect(ZipArchive.passesThroughLink(entryPath: "l1/l1/l1/esc", target: "../../../etc", links: ["l1"]))
        #expect(ZipArchive.passesThroughLink(entryPath: "x", target: "l1/../../etc", links: ["l1"]))
        #expect(!ZipArchive.passesThroughLink(entryPath: "A.app/Contents/Current", target: "MacOS", links: ["A.app/Contents/Current"]))
    }

    @Test func bundlePathMustBeTopLevel() {
        var manifest = PackageFixture.manifest()
        manifest.bundlePath = "a/Test.app"
        manifest.executable = "a/Test.app/Contents/MacOS/RuyioTestPlugin"
        #expect(ManifestValidator.issues(in: manifest).contains { $0.field == "bundlePath" })
    }

    @Test func nestedLaunchableCodeIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nested-\(UUID().uuidString)/Test.app")
        let macOS = root.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixture.testPluginExecutable, to: macOS.appendingPathComponent("RuyioTestPlugin"))
        #expect(PluginInstaller.nestedCodeViolations(bundle: root, mainExecutable: macOS.appendingPathComponent("RuyioTestPlugin")).isEmpty)
        // A second program and an XPC service would both run outside the checks applied to the main one.
        try FileManager.default.copyItem(at: Fixture.testPluginExecutable, to: macOS.appendingPathComponent("helper"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/XPCServices/Evil.xpc"), withIntermediateDirectories: true)
        let problems = PluginInstaller.nestedCodeViolations(bundle: root, mainExecutable: macOS.appendingPathComponent("RuyioTestPlugin"))
        #expect(problems.contains("Contents/MacOS/helper"))
        #expect(problems.contains("Contents/XPCServices"))
    }

    @Test func finderClicksWaitUntilTheHostIsReady() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fbr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bridge = FinderBridge(containerURL: dir)
        bridge.holdUntilReady()
        let request = FinderRequest(pluginID: plugin.rawValue, actionID: "copy-path", dynamicItemID: nil,
                                    targetDirectory: "/tmp", selection: ["/tmp/a"], snapshotGeneration: 1)
        try FinderWire.encoder().encode(request).write(to: bridge.requestsURL.appendingPathComponent("\(request.requestID).json"))
        bridge.drainQueue()
        #expect(try FileManager.default.contentsOfDirectory(atPath: bridge.requestsURL.path).count == 1)
        bridge.markReady()
        bridge.drainQueue()
        #expect(try FileManager.default.contentsOfDirectory(atPath: bridge.requestsURL.path).isEmpty)
    }

    @Test func peerThatStopsReadingCannotHangTheHost() async throws {
        var toPlugin: [Int32] = [0, 0]
        var fromPlugin: [Int32] = [0, 0]
        #expect(pipe(&toPlugin) == 0)
        #expect(pipe(&fromPlugin) == 0)
        let peer = RPCPeer(readFD: fromPlugin[0], writeFD: toPlugin[1], label: "stall")
        peer.start(onRequest: { _ in .null }, onEvent: { _ in }, onClose: { _ in })
        // Nobody reads toPlugin[0]: fill the pipe with large requests; each must fail, none may hang.
        let big = JSONValue.string(String(repeating: "x", count: 200_000))
        let started = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { _ = try? await peer.request("storage.get", payload: big, timeout: .seconds(1)) }
            }
        }
        #expect(ContinuousClock.now - started < .seconds(RPCPeer.writeTimeout + 5))
        peer.close()
        close(toPlugin[0])
        close(fromPlugin[1])
    }

    @Test func commitInstallNeverOverwritesAnInstalledPlugin() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("engine2-\(UUID().uuidString)")
        let paths = AppPaths(applicationSupport: base.appendingPathComponent("Support"), caches: base.appendingPathComponent("Caches"))
        try paths.ensureDirectories()
        let engine = try HostEngine(paths: paths, locale: "en")
        engine.setBridge(TestBridge())
        let zip = try PackageFixture.build()
        try await engine.start(bundledPackages: [zip])
        let preview = try engine.installer.inspect(package: try PackageFixture.build(), trust: .bundledDefault)
        await #expect(throws: RuyioError.self) { _ = try await engine.commitInstall(preview, updateChannel: .descriptor, source: nil) }
        await engine.shutdown()
    }

    @Test func restoreReattachesTheKeptDataGeneration() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("engine3-\(UUID().uuidString)")
        let paths = AppPaths(applicationSupport: base.appendingPathComponent("Support"), caches: base.appendingPathComponent("Caches"))
        try paths.ensureDirectories()
        let engine = try HostEngine(paths: paths, locale: "en")
        engine.setBridge(TestBridge())
        let id = PluginID("org.ruyio.test-plugin")
        try await engine.start(bundledPackages: [try PackageFixture.build()])
        // As if an update had moved the data to generation 3.
        try await engine.registry.update(id) { $0.dataGeneration = 3 }
        try await engine.uninstall(id, deleteData: false)
        try await engine.restoreDefault(id)
        #expect(await engine.registry.record(id)?.dataGeneration == 3)
        await engine.shutdown()
    }
}
