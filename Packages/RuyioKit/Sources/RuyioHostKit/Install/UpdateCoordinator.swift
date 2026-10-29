import Foundation
import RuyioCore
import RuyioPersistence
import RuyioProtocol

/// Transactional plugin update (plan §15.2, R01/R02).
///
/// prepared → quiescing → backedUp → migrated → ready → committed. Entry points stay closed until the
/// single persisted commit (one Host.sqlite write switching version, paths and data generation). Before
/// commit any failure restores old code, data and activation; after commit a runtime failure keeps the
/// new data and reports "update committed, runtime error". Every phase is journaled for crash recovery.
public actor UpdateCoordinator {
    public enum Phase: String, Codable, Sendable { case prepared, quiescing, backedUp, migrated, ready, committed, rolledBack, failed }

    public struct Journal: Codable, Sendable {
        public var id: String
        public var pluginID: PluginID
        public var phase: Phase
        public var oldVersion: String
        public var newVersion: String
        public var oldGeneration: Int
        public var newGeneration: Int
        public var oldInstallPath: String
        public var oldExecutablePath: String
        public var newInstallPath: String?
        public var wasEnabled: Bool
        public var updatedAt: Date
        /// The committed record before the update; rollback restores exactly this.
        public var oldRecord: InstalledPluginRecord?
    }

    public enum Outcome: Sendable, Equatable {
        case completed(version: SemanticVersion)
        /// Failed before commit: old version, data and entries are back (PRD §19.11).
        case rolledBack(stillUsing: SemanticVersion, error: RuyioError)
        /// Committed but the new version failed to run: new data kept, no automatic rollback.
        case committedWithRuntimeError(version: SemanticVersion, error: RuyioError)
    }

    private let engine: HostEngine
    private var journalsDirectory: URL { engine.paths.transactionsRoot }

    public init(engine: HostEngine) {
        self.engine = engine
    }

    /// Permission and identity differences shown before the user confirms (PRD §19.11).
    public struct Diff: Sendable {
        public var fromVersion: SemanticVersion
        public var toVersion: SemanticVersion
        public var addedPermissions: [Permission]
        public var signerChanged: Bool
        public var isDowngrade: Bool
    }

    public func diff(for preview: InstallPreview) async -> Diff? {
        guard let record = await engine.registry.record(preview.manifest.id), let current = try? record.decodedManifest() else { return nil }
        let added = Set(preview.manifest.permissions).subtracting(current.permissions).sorted()
        let signerChanged = record.publisherID != preview.signing.publisherID || record.signingIdentifier != preview.signing.identifier
        return Diff(fromVersion: current.version, toVersion: preview.manifest.version, addedPermissions: added,
                    signerChanged: signerChanged, isDowngrade: preview.manifest.version < current.version)
    }

    // MARK: Downgrade (R16 / DIST-06)

    /// How data is handled when installing an older version. The current data is never modified.
    public enum DataChoice: Sendable, Hashable {
        /// Only when the target declares the same storage schema as the current data.
        case keepCurrent
        /// A retained generation whose recorded schema matches the target; the UI shows its date.
        case snapshot(generation: Int, createdAt: Date)
        /// A new empty partition; current data stays on disk for recovery.
        case fresh
    }

    public struct GenerationInfo: Codable, Sendable, Hashable {
        public var storageSchemaVersion: Int
        public var pluginVersion: String
        public var createdAt: Date
    }

    public func downgradeChoices(for preview: InstallPreview) async -> [DataChoice] {
        guard let record = await engine.registry.record(preview.manifest.id), let current = try? record.decodedManifest() else { return [] }
        var choices: [DataChoice] = []
        if preview.manifest.storageSchemaVersion == current.storageSchemaVersion { choices.append(.keepCurrent) }
        let root = engine.services.stores.dataRoot(pluginID: preview.manifest.id, development: record.isDevelopment)
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted(by: >) {
            guard let generation = Int(name), generation != record.dataGeneration,
                  let info = Self.readGenerationInfo(root.appendingPathComponent(name)),
                  info.storageSchemaVersion == preview.manifest.storageSchemaVersion else { continue }
            choices.append(.snapshot(generation: generation, createdAt: info.createdAt))
        }
        choices.append(.fresh)
        return choices
    }

    /// User-initiated install of an older version from the plugin detail (PRD §19.11).
    public func downgrade(with preview: InstallPreview, data choice: DataChoice) async -> Outcome {
        guard await downgradeChoices(for: preview).contains(choice) else {
            engine.installer.discard(preview)
            let still = SemanticVersion((await engine.registry.record(preview.manifest.id))?.version ?? "0.0.0") ?? preview.manifest.version
            return .rolledBack(stillUsing: still, error: RuyioError(.sourceInvalid, diagnostic: "data choice not compatible with this version"))
        }
        return await apply(preview, allowOlder: true, data: choice)
    }

    static func readGenerationInfo(_ directory: URL) -> GenerationInfo? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("generation.json")) else { return nil }
        return try? JSONCoding.decoder().decode(GenerationInfo.self, from: data)
    }

    static func writeGenerationInfo(_ info: GenerationInfo, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(info).write(to: directory.appendingPathComponent("generation.json"), options: .atomic)
    }

    public func update(with preview: InstallPreview) async -> Outcome {
        await apply(preview, allowOlder: false, data: .keepCurrent)
    }

    private func apply(_ preview: InstallPreview, allowOlder: Bool, data choice: DataChoice) async -> Outcome {
        let id = preview.manifest.id
        guard let record = await engine.registry.record(id), let oldVersion = SemanticVersion(record.version) else {
            return .rolledBack(stillUsing: preview.manifest.version, error: RuyioError(.pluginNotFound, objectID: id.rawValue))
        }
        // Publisher changes are never a normal update (PRD §19.11, R08).
        if record.publisherID != preview.signing.publisherID || record.signingIdentifier != preview.signing.identifier {
            engine.installer.discard(preview)
            return .rolledBack(stillUsing: oldVersion, error: RuyioError(.sourceInvalid, objectID: id.rawValue, diagnostic: "signer changed; reinstall required"))
        }
        guard allowOlder ? preview.manifest.version < oldVersion : preview.manifest.version > oldVersion else {
            engine.installer.discard(preview)
            return .rolledBack(stillUsing: oldVersion, error: RuyioError(.sourceInvalid, objectID: id.rawValue,
                                                                       diagnostic: allowOlder ? "not an older version" : "not a newer version"))
        }
        // A source that is no longer allowed is refused before anything stops or a journal exists.
        do { try await engine.validateUpdateSource(id) } catch {
            engine.installer.discard(preview)
            return .rolledBack(stillUsing: oldVersion, error: (error as? RuyioError) ?? RuyioError(.sourceInvalid, objectID: id.rawValue))
        }
        var committed = false
        let root = engine.services.stores.dataRoot(pluginID: id, development: record.isDevelopment)
        var journal = Journal(id: UUID().uuidString.lowercased(), pluginID: id, phase: .prepared, oldVersion: record.version,
                              newVersion: preview.manifest.version.description, oldGeneration: record.dataGeneration,
                              newGeneration: max(record.dataGeneration, Self.highestGeneration(in: root)) + 1, oldInstallPath: record.installPath,
                              oldExecutablePath: record.executablePath, newInstallPath: nil,
                              wasEnabled: record.enabledPreference, updatedAt: Date(), oldRecord: record)
        do {
            try write(journal)
            // quiescing: stop new invocations, finish or cancel work, stop the process.
            journal.phase = .quiescing
            try write(journal)
            try await engine.registry.setActivation(id, .disabling)
            await engine.supervisor.unregister(id)

            // backedUp: the candidate generation starts from current data, a matching snapshot, or nothing.
            try write(journal)
            let sourceSchema: Int
            switch choice {
            case .keepCurrent:
                sourceSchema = try record.decodedManifest().storageSchemaVersion
                try copyGeneration(pluginID: id, development: record.isDevelopment, from: journal.oldGeneration, to: journal.newGeneration)
            case .snapshot(let generation, _):
                guard let info = Self.readGenerationInfo(root.appendingPathComponent(String(generation))),
                      info.storageSchemaVersion == preview.manifest.storageSchemaVersion else {
                    throw RuyioError(.retainedDataIncompatible, objectID: id.rawValue)
                }
                sourceSchema = info.storageSchemaVersion
                try copyGeneration(pluginID: id, development: record.isDevelopment, from: generation, to: journal.newGeneration)
            case .fresh:
                sourceSchema = 0
                try FileManager.default.createDirectory(at: root.appendingPathComponent(String(journal.newGeneration)), withIntermediateDirectories: true)
            }
            // The old generation is kept and labelled so it can serve as a compatible snapshot later.
            if let current = try? record.decodedManifest(), Self.readGenerationInfo(root.appendingPathComponent(String(journal.oldGeneration))) == nil {
                try Self.writeGenerationInfo(GenerationInfo(storageSchemaVersion: current.storageSchemaVersion, pluginVersion: record.version, createdAt: Date()),
                                         to: root.appendingPathComponent(String(journal.oldGeneration)))
            }
            // Even plugins without persisted records get a valid empty database for the read-only health check.
            try engine.services.stores.store(pluginID: id, generation: journal.newGeneration, development: record.isDevelopment).quickCheck()
            journal.phase = .backedUp
            try write(journal)

            // Code goes into its own version directory; the old one is untouched until cleanup.
            var newRecord = try engine.installer.commit(preview, isDefault: record.isDefault, updateChannel: record.updateChannel, source: record.source)
            journal.newInstallPath = newRecord.installPath
            try write(journal)

            // migrated + ready: migration and health sessions on the candidate partition only (R02).
            let preparation = DataPreparationRequest(sourceSchemaVersion: sourceSchema, targetSchemaVersion: preview.manifest.storageSchemaVersion)
            for mode in [RuntimeMode.migration, .health] {
                let info = SessionInfo(pluginID: id, manifest: preview.manifest, runtimeMode: mode, dataGeneration: journal.newGeneration,
                                       isDevelopment: record.isDevelopment)
                let session = PluginSession(info: info, executable: URL(fileURLWithPath: newRecord.executablePath), services: engine.services)
                do {
                    try await session.start(locale: engine.locale, firstLaunch: true)
                    try await session.prepareData(preparation)
                } catch {
                    // Never leave a hung migration process writing into the candidate being discarded.
                    await session.kill()
                    throw error
                }
                await session.stop()
                journal.phase = mode == .migration ? .migrated : .ready
                try write(journal)
            }

            try Self.writeGenerationInfo(GenerationInfo(storageSchemaVersion: preview.manifest.storageSchemaVersion,
                                                        pluginVersion: preview.manifest.version.description, createdAt: Date()),
                                         to: root.appendingPathComponent(String(journal.newGeneration)))

            // committed: the single persisted switch (gate still closed until it succeeds).
            try await engine.validateUpdateSource(id)
            newRecord.dataGeneration = journal.newGeneration
            newRecord.installedAt = record.installedAt
            newRecord.enabledPreference = record.enabledPreference
            newRecord.activationState = .disabled
            newRecord.isDefault = record.isDefault
            try await engine.registry.insert(newRecord)
            committed = true
            journal.phase = .committed
            try write(journal)
        } catch {
            let failure = (error as? RuyioError) ?? RuyioError(.internalError, objectID: id.rawValue, diagnostic: String(describing: error))
            if committed {
                // The database switch is final even if writing the final journal fails.
                if journal.wasEnabled { _ = await engine.enable(id, userInitiated: false) }
                await cleanup(journal)
                return .committedWithRuntimeError(version: preview.manifest.version, error: failure)
            }
            engine.installer.discard(preview)
            await rollback(journal, record: record)
            return .rolledBack(stillUsing: oldVersion, error: failure)
        }

        // After commit: reopen entries per the user's previous preference.
        if journal.wasEnabled, let error = await engine.enable(id, userInitiated: false) {
            try? await engine.registry.setRuntimeError(id, error)
            // Committed is final: finish now, so a stale journal can never delete code installed later.
            await cleanup(journal)
            return .committedWithRuntimeError(version: preview.manifest.version, error: error)
        }
        await cleanup(journal)
        return .completed(version: preview.manifest.version)
    }

    /// Crash recovery on launch: uncommitted transactions roll back; committed ones finish cleanup.
    public func recover() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: journalsDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let journal = try? JSONCoding.decoder().decode(Journal.self, from: data) else { continue }
            switch journal.phase {
            case .committed:
                await cleanup(journal)
            case .rolledBack, .failed:
                try? FileManager.default.removeItem(at: file)
            default:
                guard let record = await engine.registry.record(journal.pluginID) else { continue }
                // The Host.sqlite switch is the commit point: if it already happened, finish, never roll back.
                if record.version == journal.newVersion && record.dataGeneration == journal.newGeneration {
                    if journal.wasEnabled { _ = await engine.enable(journal.pluginID, userInitiated: false) }
                    await cleanup(journal)
                } else {
                    await rollback(journal, record: record)
                }
            }
        }
    }

    // MARK: Internals

    private func rollback(_ journal: Journal, record current: InstalledPluginRecord) async {
        var journal = journal
        let record = journal.oldRecord ?? current
        // Old code and old data generation are still the committed state; discard the candidates.
        let candidate = engine.services.stores.dataRoot(pluginID: journal.pluginID, development: record.isDevelopment)
            .appendingPathComponent(String(journal.newGeneration))
        engine.services.stores.close(pluginID: journal.pluginID)
        try? FileManager.default.removeItem(at: candidate)
        if let newPath = journal.newInstallPath, newPath != journal.oldInstallPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: newPath).deletingLastPathComponent())
        }
        if let current = await engine.registry.record(journal.pluginID), current.version != journal.oldVersion {
            try? await engine.registry.insert(record)
        }
        if journal.wasEnabled { _ = await engine.enable(journal.pluginID, userInitiated: false) }
        else { try? await engine.registry.setActivation(journal.pluginID, .disabled) }
        try? await engine.registry.update(journal.pluginID) { $0.updateState = .updateFailed }
        journal.phase = .rolledBack
        try? write(journal)
    }

    static func highestGeneration(in root: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).compactMap(Int.init).max() ?? 0
    }

    private func cleanup(_ journal: Journal) async {
        // Old backup is removed only after the new version is healthy (plan §15.2 step 8), and never while
        // it is the installed code again (e.g. the user downgraded back to it).
        if journal.oldInstallPath != journal.newInstallPath {
            let oldDirectory = URL(fileURLWithPath: journal.oldInstallPath).deletingLastPathComponent()
            let current = await engine.registry.record(journal.pluginID)?.installPath
            if current.map({ !$0.hasPrefix(oldDirectory.path + "/") }) ?? true {
                try? FileManager.default.removeItem(at: oldDirectory)
            }
        }
        try? FileManager.default.removeItem(at: journalsDirectory.appendingPathComponent("\(journal.id).json"))
    }

    private func copyGeneration(pluginID: PluginID, development: Bool, from old: Int, to new: Int) throws {
        let root = engine.services.stores.dataRoot(pluginID: pluginID, development: development)
        let source = root.appendingPathComponent(String(old), isDirectory: true)
        let destination = root.appendingPathComponent(String(new), isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: source.appendingPathComponent("Store.sqlite").path) else { return }
        defer { try? fm.removeItem(at: destination.appendingPathComponent("generation.json")) }
        // SQLite online backup, never a raw copy of a live db/WAL pair.
        let store = try engine.services.stores.store(pluginID: pluginID, generation: old, development: development)
        try store.backup(to: destination.appendingPathComponent("Store.sqlite"))
        for folder in ["Blobs.noindex"] {
            let from = source.appendingPathComponent(folder)
            if fm.fileExists(atPath: from.path) {
                // APFS clone when available; copies otherwise.
                try fm.copyItem(at: from, to: destination.appendingPathComponent(folder))
            }
        }
    }

    private func write(_ journal: Journal) throws {
        var copy = journal
        copy.updatedAt = Date()
        try FileManager.default.createDirectory(at: journalsDirectory, withIntermediateDirectories: true)
        let data = try JSONCoding.encoder().encode(copy)
        try data.write(to: journalsDirectory.appendingPathComponent("\(journal.id).json"), options: .atomic)
    }
}
