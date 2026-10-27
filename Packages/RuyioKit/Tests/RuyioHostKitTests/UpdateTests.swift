import Foundation
import Testing
@testable import RuyioHostKit
import RuyioPersistence
import RuyioProtocol
import RuyioCore

@Suite(.serialized)
struct UpdateTests {
    let id = PluginID("org.ruyio.test-plugin")
    func ref(_ a: String) -> ActionRef { ActionRef(pluginID: id, actionID: ActionID(a)) }

    func engine() throws -> HostEngine {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("upd-\(UUID().uuidString)")
        let paths = AppPaths(applicationSupport: base.appendingPathComponent("S"), caches: base.appendingPathComponent("C"))
        try paths.ensureDirectories()
        let engine = try HostEngine(paths: paths, locale: "en")
        engine.setBridge(TestBridge())
        return engine
    }

    @Test func successfulUpdateSwitchesVersionAndCarriesData() async throws {
        let engine = try engine()
        try await engine.start(bundledPackages: [try PackageFixture.build(version: "1.0.0")])
        _ = await engine.invoke(InvocationRequest(ref: ref("storage"), entry: .commandPalette))
        let oldPath = try #require(await engine.registry.record(id)?.installPath)

        let preview = try engine.installer.inspect(package: try PackageFixture.build(version: "1.1.0"), trust: .bundledDefault)
        let outcome = await engine.updater.update(with: preview)
        #expect(outcome == .completed(version: SemanticVersion("1.1.0")!))
        let record = try #require(await engine.registry.record(id))
        #expect(record.version == "1.1.0")
        #expect(record.dataGeneration == 2)
        #expect(await engine.registry.status(id)?.activation == .enabled)
        #expect(await engine.invoke(InvocationRequest(ref: ref("version"), entry: .commandPalette)).output == .notice("1.1.0"))
        #expect(await engine.invoke(InvocationRequest(ref: ref("storage-read"), entry: .commandPalette)).output == .notice("中文内容"))
        #expect(!FileManager.default.fileExists(atPath: oldPath), "old version removed after healthy start")
        await engine.shutdown()
    }

    @Test func failureBeforeCommitRestoresOldVersionDataAndEntries() async throws {
        let engine = try engine()
        try await engine.start(bundledPackages: [try PackageFixture.build(version: "1.0.0")])
        _ = await engine.invoke(InvocationRequest(ref: ref("storage"), entry: .commandPalette))
        let preview = try engine.installer.inspect(package: try PackageFixture.build(version: "1.1.0", failMigration: true), trust: .bundledDefault)
        let outcome = await engine.updater.update(with: preview)
        guard case .rolledBack(let still, _) = outcome else { Issue.record("expected rollback, got \(outcome)"); return }
        #expect(still == SemanticVersion("1.0.0"))
        let record = try #require(await engine.registry.record(id))
        #expect(record.version == "1.0.0")
        #expect(record.dataGeneration == 1)
        #expect(record.updateState == .updateFailed)
        #expect(await engine.registry.status(id)?.activation == .enabled)
        #expect(await engine.registry.snapshot().entries.commands.contains { $0.ref.pluginID == id })
        #expect(await engine.invoke(InvocationRequest(ref: ref("storage-read"), entry: .commandPalette)).output == .notice("中文内容"))
        let versions = try FileManager.default.contentsOfDirectory(atPath: URL(fileURLWithPath: record.installPath).deletingLastPathComponent().deletingLastPathComponent().path)
        #expect(versions == ["1.0.0"])
        await engine.shutdown()
    }

    @Test func signerChangeIsNeverANormalUpdate() async throws {
        let engine = try engine()
        try await engine.start(bundledPackages: [try PackageFixture.build(version: "1.0.0")])
        var preview = try engine.installer.inspect(package: try PackageFixture.build(version: "1.1.0"), trust: .bundledDefault)
        preview.signing.teamID = "OTHERTEAM1"
        guard case .rolledBack = await engine.updater.update(with: preview) else { Issue.record("signer change accepted"); return }
        #expect(await engine.registry.record(id)?.version == "1.0.0")
        await engine.shutdown()
    }

    @Test func crashRecoveryRollsBackUncommittedTransaction() async throws {
        let engine = try engine()
        try await engine.start(bundledPackages: [try PackageFixture.build(version: "1.0.0")])
        let record = try #require(await engine.registry.record(id))
        let journal = UpdateCoordinator.Journal(id: "j1", pluginID: id, phase: .backedUp, oldVersion: "1.0.0", newVersion: "1.1.0",
                                                oldGeneration: 1, newGeneration: 2, oldInstallPath: record.installPath,
                                                oldExecutablePath: record.executablePath, newInstallPath: nil, wasEnabled: true, updatedAt: Date())
        let candidate = engine.services.stores.dataRoot(pluginID: id, development: false).appendingPathComponent("2")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(journal).write(to: engine.paths.transactionsRoot.appendingPathComponent("j1.json"))
        await engine.updater.recover()
        #expect(!FileManager.default.fileExists(atPath: candidate.path))
        #expect(await engine.registry.record(id)?.version == "1.0.0")
        #expect(await engine.registry.record(id)?.updateState == .updateFailed)
        await engine.shutdown()
    }
}
