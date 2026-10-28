import Foundation
import Testing
@testable import RuyioHostKit
import RuyioCore
import RuyioPersistence
import RuyioProtocol

@Suite(.serialized)
struct RuntimeDataReviewTests {
    let id = PluginID("org.ruyio.test-plugin")

    private func invoke(_ action: String, on engine: HostEngine) async -> ExecutionReport {
        await engine.invoke(InvocationRequest(ref: ActionRef(pluginID: id, actionID: ActionID(action)), entry: .commandPalette))
    }

    @Test func truncatedUniversalImagesAreRejectedWithoutReadingPastTheHeader() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fat-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        for count in 4..<28 {
            var bytes = [UInt8](repeating: 0, count: count)
            bytes.replaceSubrange(0..<4, with: [0xca, 0xfe, 0xba, 0xbe])
            if count >= 8 { bytes[7] = 1 }
            try Data(bytes).write(to: file)
            #expect(MachO.isExecutableImage(file), "malformed image must fail nested-code validation")
        }
        // Complete FAT entry, but the declared slice is outside the file.
        var bytes: [UInt8] = [0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 1]
        bytes += [1, 0, 0, 12, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 16, 0, 0, 0, 0]
        try Data(bytes).write(to: file)
        #expect(MachO.isExecutableImage(file))
        try Data("ordinary resource".utf8).write(to: file)
        #expect(!MachO.isExecutableImage(file))
    }

    @Test func universalInspectionChecksEverySlice() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fat-slices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        var bytes: [UInt8] = [0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2]
        for offset in [UInt8(48), 64] {
            bytes += [1, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, offset, 0, 0, 0, 16, 0, 0, 0, 0]
        }
        bytes += [0xcf, 0xfa, 0xed, 0xfe, 12, 0, 0, 1, 0, 0, 0, 0, 6, 0, 0, 0]
        bytes += [0xcf, 0xfa, 0xed, 0xfe, 12, 0, 0, 1, 0, 0, 0, 0, 2, 0, 0, 0]
        try Data(bytes).write(to: file)
        #expect(MachO.isExecutableImage(file), "an executable in a later slice is still executable code")
        bytes[76] = 6
        try Data(bytes).write(to: file)
        #expect(!MachO.isExecutableImage(file), "valid library-only images are allowed")
    }

    @Test func sameTeamDifferentIdentifierCannotClaimRetainedDataOrSettings() async throws {
        let engine = try UpdateTests().engine()
        try await engine.start(bundledPackages: [try PackageFixture.build()])
        #expect(await invoke("storage", on: engine).state == .succeeded)
        try engine.database.setPluginSetting(id, key: "chosenEditor", value: "private.preference")
        let oldRoot = engine.services.stores.dataRoot(pluginID: id, development: false)
        try await engine.uninstall(id, deleteData: false)

        let package = try PackageFixture.build(infoOverrides: ["CFBundleIdentifier": "org.ruyio.plugin.different-identity"])
        let preview = try engine.installer.inspect(package: package, trust: .bundledDefault)
        _ = try await engine.commitInstall(preview, updateChannel: .bundledWithHost, source: nil)
        #expect(engine.services.stores.dataRoot(pluginID: id, development: false) != oldRoot)
        #expect(await invoke("storage-read", on: engine).output == .notice("missing"))
        #expect(try engine.database.pluginSettings(id).isEmpty)
        #expect(FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent("1/Store.sqlite").path))
        await engine.shutdown()
    }

    @Test func verifiedInstalledLegacyDataMovesToItsCompleteIdentity() async throws {
        let engine = try UpdateTests().engine()
        try await engine.start(bundledPackages: [try PackageFixture.build()])
        #expect(await invoke("storage", on: engine).state == .succeeded)
        let record = try #require(await engine.registry.record(id))
        let fullRoot = engine.services.stores.dataRoot(pluginID: id, development: false)
        let legacyRoot = engine.paths.dataRoot.appendingPathComponent(AppPaths.identityDirectoryName(pluginID: id, teamID: record.teamID))
        await engine.shutdown()
        engine.services.stores.close(pluginID: id)
        try FileManager.default.moveItem(at: fullRoot, to: legacyRoot)

        let restarted = try HostEngine(paths: engine.paths, locale: "en")
        try await restarted.start(bundledPackages: [])
        #expect(await invoke("storage-read", on: restarted).output == .notice("中文内容"))
        #expect(!FileManager.default.fileExists(atPath: legacyRoot.path))
        #expect(FileManager.default.fileExists(atPath: fullRoot.path))
        await restarted.shutdown()
    }

    @Test func legacyDataThatCannotMoveBlocksOnlyThatPluginUntilRetried() async throws {
        let engine = try UpdateTests().engine()
        try await engine.start(bundledPackages: [try PackageFixture.build()])
        #expect(await invoke("storage", on: engine).state == .succeeded)
        let record = try #require(await engine.registry.record(id))
        let fullRoot = engine.services.stores.dataRoot(pluginID: id, development: false)
        let legacyRoot = engine.paths.dataRoot.appendingPathComponent(AppPaths.identityDirectoryName(pluginID: id, teamID: record.teamID))
        await engine.shutdown()
        engine.services.stores.close(pluginID: id)
        try FileManager.default.moveItem(at: fullRoot, to: legacyRoot)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: legacyRoot.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: legacyRoot.path) }

        // The host still starts; the plugin stays off instead of opening an empty partition.
        let restarted = try HostEngine(paths: engine.paths, locale: "en")
        try await restarted.start(bundledPackages: [])
        #expect(await restarted.registry.record(id)?.activationState == .disabled)
        #expect(!FileManager.default.fileExists(atPath: fullRoot.path))

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: legacyRoot.path)
        #expect(await restarted.enable(id) == nil)
        #expect(await invoke("storage-read", on: restarted).output == .notice("中文内容"))
        #expect(!FileManager.default.fileExists(atPath: legacyRoot.path))
        await restarted.shutdown()
    }

    @Test func restoreOfOlderDefaultRequiresFreshPartitionWhenRetainedSchemaIsNewer() async throws {
        let engine = try UpdateTests().engine()
        try await engine.start(bundledPackages: [try PackageFixture.build()])
        #expect(await invoke("storage", on: engine).state == .succeeded)
        let upgrade = try engine.installer.inspect(package: try PackageFixture.build(version: "1.1.0", schema: 2), trust: .bundledDefault)
        #expect(await engine.updater.update(with: upgrade) == .completed(version: SemanticVersion("1.1.0")!))
        let root = engine.services.stores.dataRoot(pluginID: id, development: false)
        let candidate = try engine.services.stores.store(pluginID: id, generation: 2, development: false).get(collection: "notes", id: "n1")
        #expect(candidate?.body["migrated"] == .bool(true), "the migration callback must actually transform stored data")
        #expect(UpdateCoordinator.readGenerationInfo(root.appendingPathComponent("2"))?.storageSchemaVersion == 2)
        try await engine.uninstall(id, deleteData: false)
        do {
            try await engine.restoreDefault(id)
            Issue.record("incompatible retained schema was attached to the old default")
        } catch let error as RuyioError {
            #expect(error.code == .retainedDataIncompatible)
        }
        #expect(await engine.registry.record(id) == nil)
        try await engine.restoreDefault(id, dataChoice: .fresh)
        #expect(await engine.registry.record(id)?.dataGeneration == 3)
        #expect(await invoke("storage-read", on: engine).output == .notice("missing"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("2/Store.sqlite").path))
        #expect(UpdateCoordinator.readGenerationInfo(root.appendingPathComponent("2"))?.storageSchemaVersion == 2)
        await engine.shutdown()
    }

    @Test func unlabelledRetainedGenerationIsNeverAttachedAutomatically() async throws {
        let engine = try UpdateTests().engine()
        let package = try PackageFixture.build()
        try await engine.start(bundledPackages: [package])
        #expect(await invoke("storage", on: engine).state == .succeeded)
        let record = try #require(await engine.registry.record(id))
        try await engine.uninstall(id, deleteData: false)
        try engine.database.setSetting(HostEngine.keptGenerationKey(record), HostEngine.RetainedData?.none)
        let preview = try engine.installer.inspect(package: package, trust: .bundledDefault)
        #expect(try engine.requiresFreshData(for: preview))
        #expect(try engine.requiresFreshData(for: preview), "cancelling the data decision can safely retry the same preview")
        #expect(FileManager.default.fileExists(atPath: preview.stagingRoot.path), "preflight must keep the verified staging copy")
        #expect(await engine.registry.record(id) == nil, "preflight must not install or attach retained data")
        do {
            _ = try await engine.commitInstall(preview, updateChannel: .bundledWithHost, source: nil)
            Issue.record("unlabelled retained generation was attached")
        } catch let error as RuyioError {
            #expect(error.code == .retainedDataIncompatible)
        }
        #expect(await engine.registry.record(id) == nil)
        let fresh = try engine.installer.inspect(package: package, trust: .bundledDefault)
        #expect(try engine.requiresFreshData(for: fresh))
        _ = try await engine.commitInstall(fresh, updateChannel: .bundledWithHost, source: nil, dataChoice: .fresh)
        #expect(await engine.registry.record(id)?.dataGeneration == 2)
        #expect(await invoke("storage-read", on: engine).output == .notice("missing"))
        await engine.shutdown()
    }

    @Test func healthFailureAndUnsupportedMigrationKeepOldData() async throws {
        let engine = try UpdateTests().engine()
        try await engine.start(bundledPackages: [try PackageFixture.build()])
        #expect(await invoke("storage", on: engine).state == .succeeded)
        for (schema, failHealth) in [(2, true), (3, false)] {
            let package = try PackageFixture.build(version: "1.1.0", failHealth: failHealth, schema: schema)
            let preview = try engine.installer.inspect(package: package, trust: .bundledDefault)
            guard case .rolledBack = await engine.updater.update(with: preview) else {
                Issue.record("failed preparation unexpectedly committed"); continue
            }
            let record = try #require(await engine.registry.record(id))
            #expect(record.version == "1.0.0")
            #expect(record.dataGeneration == 1)
            #expect(await invoke("storage-read", on: engine).output == .notice("中文内容"))
            let old = try engine.services.stores.store(pluginID: id, generation: 1, development: false).get(collection: "notes", id: "n1")
            #expect(old?.body["migrated"] == nil)
            let candidate = engine.services.stores.dataRoot(pluginID: id, development: false).appendingPathComponent("2")
            #expect(!FileManager.default.fileExists(atPath: candidate.path))
        }
        await engine.shutdown()
    }

    @Test func failedDataDeletionKeepsDisabledRecordForRetry() async throws {
        let engine = try UpdateTests().engine()
        try await engine.start(bundledPackages: [try PackageFixture.build()])
        #expect(await invoke("storage", on: engine).state == .succeeded)
        let root = engine.services.stores.dataRoot(pluginID: id, development: false)
        let blocked = root.appendingPathComponent("locked-data")
        try Data("must be deleted".utf8).write(to: blocked)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blocked.path) }
        do {
            try await engine.uninstall(id, deleteData: true)
            Issue.record("uninstall incorrectly reported success while data could not be removed")
        } catch let error as RuyioError {
            #expect(error.code == .storageFailure)
            #expect(error.retryable)
        }
        #expect(await engine.registry.record(id)?.activationState == .disabled)
        #expect(await engine.registry.record(id)?.installationState == .installed)
        #expect(FileManager.default.fileExists(atPath: blocked.path))
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blocked.path)
        try await engine.uninstall(id, deleteData: true)
        #expect(await engine.registry.record(id) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        await engine.shutdown()
    }

    @Test func orphanedLegacyDataIsNotClaimedByANewInstall() async throws {
        let engine = try UpdateTests().engine()
        let legacyIdentity = AppPaths.identityDirectoryName(pluginID: id, teamID: nil)
        let legacyDirectory = engine.paths.dataDirectory(identity: legacyIdentity, generation: 4, development: false)
        let oldStore = try PluginStore(directory: legacyDirectory)
        try oldStore.put(StoredDocument(collection: "notes", id: "n1", body: ["v": "private legacy data"]))
        try engine.database.setSetting("data.keptGeneration." + legacyIdentity, 4)
        try await engine.start(bundledPackages: [try PackageFixture.build()])
        #expect(await engine.registry.record(id)?.dataGeneration == 1)
        #expect(await invoke("storage-read", on: engine).output == .notice("missing"))
        #expect(try oldStore.get(collection: "notes", id: "n1")?.body["v"] == "private legacy data")
        await engine.shutdown()
    }

    @Test func backupChoiceUpdatesAllRootsIncludingUninstalledData() throws {
        let engine = try UpdateTests().engine()
        let retained = engine.paths.dataRoot.appendingPathComponent("retained-identity")
        let development = engine.paths.developmentDataRoot.appendingPathComponent("development-identity")
        for root in [retained, development] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try BackupPolicy.setExcludedFromBackup(true, at: root)
        }
        try BackupPolicy.setIncludedInBackup(true, paths: engine.paths)
        for root in [engine.paths.dataRoot, engine.paths.developmentDataRoot, retained, development] {
            #expect(!BackupPolicy.isExcludedFromBackup(root))
        }
        try BackupPolicy.setIncludedInBackup(false, paths: engine.paths)
        for root in [engine.paths.dataRoot, engine.paths.developmentDataRoot, retained, development] {
            #expect(BackupPolicy.isExcludedFromBackup(root))
        }
    }

    @Test func relatedHostSettingsAreNotPartiallySavedWhenEncodingFails() throws {
        let database = try HostDatabase()
        try database.setSettings(["host.settings": ["includeInBackup": false], "data.includeInBackup": false])
        #expect(throws: (any Error).self) {
            try database.setSettings(["host.settings": ["invalid": .number(.nan)], "data.includeInBackup": true])
        }
        #expect(try database.setting("data.includeInBackup", as: Bool.self) == false)
        #expect(try database.setting("host.settings", as: JSONValue.self) == ["includeInBackup": false])
    }

    @Test func explicitNewOperationRunsWhileAnEarlierOutcomeAwaitsReview() async throws {
        let engine = try UpdateTests().engine()
        try await engine.start(bundledPackages: [try PackageFixture.build()])
        var manifest = try #require(await engine.registry.manifest(id))
        let index = try #require(manifest.actions.firstIndex { $0.id == ActionID("echo") })
        manifest.actions[index].hasSideEffects = true
        let encoded = String(decoding: try JSONCoding.encoder().encode(manifest), as: UTF8.self)
        try await engine.registry.update(id) { $0.manifest = encoded }
        let earlier = OperationID()
        try engine.database.saveOperation(OperationRecord(operationID: earlier.rawValue, pluginID: id.rawValue,
                                                           actionID: "echo", executionID: nil, phase: .unknown, intent: "{}"))
        let explicit = await invoke("echo", on: engine)
        #expect(explicit.state == .succeeded)
        #expect(explicit.operationID != nil && explicit.operationID != earlier)
        // The earlier outcome still waits for the user; running something new never resolves it.
        #expect(try engine.database.unresolvedOperations(pluginID: id).map(\.operationID) == [earlier.rawValue])
        await engine.shutdown()
    }
}
