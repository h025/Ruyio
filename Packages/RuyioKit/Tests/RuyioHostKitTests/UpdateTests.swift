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

        let preview = try await engine.installer.inspect(package: try PackageFixture.build(version: "1.1.0"), trust: .bundledDefault)
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
        let preview = try await engine.installer.inspect(package: try PackageFixture.build(version: "1.1.0", failMigration: true), trust: .bundledDefault)
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
        var preview = try await engine.installer.inspect(package: try PackageFixture.build(version: "1.1.0"), trust: .bundledDefault)
        preview.signing.teamID = "OTHERTEAM1"
        guard case .rolledBack = await engine.updater.update(with: preview) else { Issue.record("signer change accepted"); return }
        #expect(await engine.registry.record(id)?.version == "1.0.0")
        await engine.shutdown()
    }

    @Test func updatesKeepTheSelfSignedPublisherCertificate() async throws {
        let engine = try engine()
        let publisher = try SigningFixture.first.get()
        let installed = try await engine.installer.inspect(package: try PackageFixture.build(version: "1.0.0", signer: publisher), trust: .remote)
        _ = try await engine.commitInstall(installed, updateChannel: .none, source: nil)
        #expect(await engine.registry.record(id)?.publisherID == publisher.publisherID)

        // Same identifier, another certificate: someone else's build, never a normal update (A39).
        let impostor = try await engine.installer.inspect(package: try PackageFixture.build(version: "1.1.0", signer: try SigningFixture.second.get()), trust: .remote)
        #expect(impostor.isInstallable)
        #expect(await engine.updater.diff(for: impostor)?.signerChanged == true)
        guard case .rolledBack = await engine.updater.update(with: impostor) else { Issue.record("certificate change accepted"); return }
        // Nor may an ad-hoc build replace it.
        let adHoc = try await engine.installer.inspect(package: try PackageFixture.build(version: "1.1.0"), trust: .development)
        guard case .rolledBack = await engine.updater.update(with: adHoc) else { Issue.record("ad-hoc build accepted"); return }

        let genuine = try await engine.installer.inspect(package: try PackageFixture.build(version: "1.1.0", signer: publisher), trust: .remote)
        #expect(await engine.updater.update(with: genuine) == .completed(version: SemanticVersion("1.1.0")!))
        #expect(await engine.registry.record(id)?.publisherID == publisher.publisherID)
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

@Suite(.serialized)
struct ReviewRegressionTests {
    @Test func terminalNeverReceivesFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("term-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("run.command")
        try "echo hi".write(to: file, atomically: true, encoding: .utf8)
        #expect(try HostServices.terminalDirectory(for: file).standardizedFileURL == dir.standardizedFileURL)
        #expect(try HostServices.terminalDirectory(for: dir).standardizedFileURL == dir.standardizedFileURL)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: RuyioError.self) { try HostServices.terminalDirectory(for: link) }
        let app = dir.appendingPathComponent("Fake.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        #expect(throws: RuyioError.self) { try HostServices.terminalDirectory(for: app) }
    }

    @Test func executableMustBeTheBundleMainExecutable() {
        var manifest = PackageFixture.manifest()
        manifest.executable = "Test.app/Contents/MacOS/Other/RuyioTestPlugin"
        let problems = PluginInstaller.infoPlistViolations(["CFBundleExecutable": "RuyioTestPlugin", "LSUIElement": true], manifest: manifest)
        #expect(problems.contains("executable is not the bundle's main executable"))
        #expect(PluginInstaller.infoPlistViolations(["CFBundleExecutable": "RuyioTestPlugin", "LSUIElement": true], manifest: PackageFixture.manifest()).isEmpty)
    }

    @Test func recoveryAfterCommitBeforeJournalKeepsNewVersion() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        let paths = AppPaths(applicationSupport: base.appendingPathComponent("S"), caches: base.appendingPathComponent("C"))
        try paths.ensureDirectories()
        let engine = try HostEngine(paths: paths, locale: "en")
        engine.setBridge(TestBridge())
        let id = PluginID("org.ruyio.test-plugin")
        try await engine.start(bundledPackages: [try PackageFixture.build(version: "1.0.0")])
        let old = try #require(await engine.registry.record(id))
        let preview = try await engine.installer.inspect(package: try PackageFixture.build(version: "1.1.0"), trust: .bundledDefault)
        _ = await engine.updater.update(with: preview)
        let committed = try #require(await engine.registry.record(id))
        #expect(committed.version == "1.1.0")
        // Simulate a crash between the Host.sqlite commit and the journal write.
        let journal = UpdateCoordinator.Journal(id: "late", pluginID: id, phase: .ready, oldVersion: "1.0.0", newVersion: "1.1.0",
                                                oldGeneration: 1, newGeneration: committed.dataGeneration, oldInstallPath: old.installPath,
                                                oldExecutablePath: old.executablePath, newInstallPath: committed.installPath,
                                                wasEnabled: true, updatedAt: Date(), oldRecord: old)
        try JSONCoding.encoder().encode(journal).write(to: paths.transactionsRoot.appendingPathComponent("late.json"))
        await engine.updater.recover()
        let after = try #require(await engine.registry.record(id))
        #expect(after.version == "1.1.0")
        #expect(FileManager.default.fileExists(atPath: after.executablePath))
        #expect(FileManager.default.fileExists(atPath: engine.services.stores.dataRoot(pluginID: id, development: false).appendingPathComponent(String(after.dataGeneration)).path))
        await engine.shutdown()
    }

    @Test func uploadStagingIsBounded() throws {
        let store = try PluginStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString)"))
        let chunk = Data(count: 1024)
        _ = try store.appendUpload(BlobPutRequest(uploadID: nil, chunk: chunk, isFinal: false))
        _ = try store.appendUpload(BlobPutRequest(uploadID: nil, chunk: chunk, isFinal: false))
        #expect(throws: RuyioError.self) { _ = try store.appendUpload(BlobPutRequest(uploadID: nil, chunk: chunk, isFinal: false)) }
    }
}

@Suite(.serialized)
struct DowngradeTests {
    let id = PluginID("org.ruyio.test-plugin")
    func ref(_ a: String) -> ActionRef { ActionRef(pluginID: id, actionID: ActionID(a)) }

    func engine(starting version: String, schema: Int = 1) async throws -> HostEngine {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dg-\(UUID().uuidString)")
        let paths = AppPaths(applicationSupport: base.appendingPathComponent("S"), caches: base.appendingPathComponent("C"))
        try paths.ensureDirectories()
        let engine = try HostEngine(paths: paths, locale: "en")
        engine.setBridge(TestBridge())
        try await engine.start(bundledPackages: [try PackageFixture.build(version: version, schema: schema)])
        _ = await engine.invoke(InvocationRequest(ref: ref("storage"), entry: .commandPalette))
        return engine
    }

    @Test func sameSchemaCanKeepCurrentData() async throws {
        let engine = try await engine(starting: "1.1.0")
        let preview = try await engine.installer.inspect(package: try PackageFixture.build(version: "1.0.0"), trust: .bundledDefault)
        let choices = await engine.updater.downgradeChoices(for: preview)
        #expect(choices.contains(.keepCurrent))
        #expect(await engine.updater.downgrade(with: preview, data: .keepCurrent) == .completed(version: SemanticVersion("1.0.0")!))
        #expect(await engine.invoke(InvocationRequest(ref: ref("version"), entry: .commandPalette)).output == .notice("1.0.0"))
        #expect(await engine.invoke(InvocationRequest(ref: ref("storage-read"), entry: .commandPalette)).output == .notice("中文内容"))
        await engine.shutdown()
    }

    @Test func incompatibleSchemaOnlyOffersFreshDataAndKeepsCurrentOnDisk() async throws {
        let engine = try await engine(starting: "1.1.0", schema: 2)
        let preview = try await engine.installer.inspect(package: try PackageFixture.build(version: "1.0.0", schema: 1), trust: .bundledDefault)
        let choices = await engine.updater.downgradeChoices(for: preview)
        #expect(choices == [.fresh])
        // Confirming a risk is not enough: keeping incompatible data is refused (R16).
        guard case .rolledBack = await engine.updater.downgrade(with: try await engine.installer.inspect(package: try PackageFixture.build(version: "1.0.0", schema: 1), trust: .bundledDefault), data: .keepCurrent) else {
            Issue.record("incompatible keepCurrent accepted"); return
        }
        #expect(await engine.updater.downgrade(with: preview, data: .fresh) == .completed(version: SemanticVersion("1.0.0")!))
        #expect(await engine.invoke(InvocationRequest(ref: ref("storage-read"), entry: .commandPalette)).output == .notice("missing"))
        let root = engine.services.stores.dataRoot(pluginID: id, development: false)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("1/Store.sqlite").path), "previous data kept for recovery")
        await engine.shutdown()
    }

    @Test func retainedGenerationIsOfferedAsSnapshot() async throws {
        let engine = try await engine(starting: "1.0.0")
        let upgrade = try await engine.installer.inspect(package: try PackageFixture.build(version: "1.1.0", schema: 2), trust: .bundledDefault)
        #expect(await engine.updater.update(with: upgrade) == .completed(version: SemanticVersion("1.1.0")!))
        let back = try await engine.installer.inspect(package: try PackageFixture.build(version: "1.0.0", schema: 1), trust: .bundledDefault)
        let choices = await engine.updater.downgradeChoices(for: back)
        guard let snapshot = choices.first(where: { if case .snapshot = $0 { return true }; return false }) else {
            Issue.record("snapshot not offered: \(choices)"); return
        }
        #expect(!choices.contains(.keepCurrent))
        #expect(await engine.updater.downgrade(with: back, data: snapshot) == .completed(version: SemanticVersion("1.0.0")!))
        #expect(await engine.invoke(InvocationRequest(ref: ref("storage-read"), entry: .commandPalette)).output == .notice("中文内容"))
        await engine.shutdown()
    }
}
