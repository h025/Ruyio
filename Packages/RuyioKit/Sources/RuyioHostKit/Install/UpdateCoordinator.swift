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
        let signerChanged = record.teamID != preview.signing.teamID || record.signingIdentifier != preview.signing.identifier
        return Diff(fromVersion: current.version, toVersion: preview.manifest.version, addedPermissions: added,
                    signerChanged: signerChanged, isDowngrade: preview.manifest.version < current.version)
    }

    public func update(with preview: InstallPreview) async -> Outcome {
        let id = preview.manifest.id
        guard let record = await engine.registry.record(id), let oldVersion = SemanticVersion(record.version) else {
            return .rolledBack(stillUsing: preview.manifest.version, error: RuyioError(.pluginNotFound, objectID: id.rawValue))
        }
        // Publisher changes are never a normal update (PRD §19.11, R08).
        if record.teamID != preview.signing.teamID || record.signingIdentifier != preview.signing.identifier {
            engine.installer.discard(preview)
            return .rolledBack(stillUsing: oldVersion, error: RuyioError(.sourceInvalid, objectID: id.rawValue, diagnostic: "signer changed; reinstall required"))
        }
        guard preview.manifest.version > oldVersion else {
            engine.installer.discard(preview)
            return .rolledBack(stillUsing: oldVersion, error: RuyioError(.sourceInvalid, objectID: id.rawValue, diagnostic: "not a newer version"))
        }
        var journal = Journal(id: UUID().uuidString.lowercased(), pluginID: id, phase: .prepared, oldVersion: record.version,
                              newVersion: preview.manifest.version.description, oldGeneration: record.dataGeneration,
                              newGeneration: record.dataGeneration + 1, oldInstallPath: record.installPath,
                              oldExecutablePath: record.executablePath, newInstallPath: nil,
                              wasEnabled: record.enabledPreference, updatedAt: Date())
        do {
            try write(journal)
            // quiescing: stop new invocations, finish or cancel work, stop the process.
            journal.phase = .quiescing
            try write(journal)
            try await engine.registry.setActivation(id, .disabling)
            await engine.supervisor.unregister(id)

            // backedUp: consistent copy of the stopped store into the candidate generation.
            try copyGeneration(pluginID: id, development: record.isDevelopment, from: journal.oldGeneration, to: journal.newGeneration)
            journal.phase = .backedUp
            try write(journal)

            // Code goes into its own version directory; the old one is untouched until cleanup.
            var newRecord = try engine.installer.commit(preview, isDefault: record.isDefault, updateChannel: record.updateChannel, source: record.source)
            journal.newInstallPath = newRecord.installPath
            try write(journal)

            // migrated + ready: migration and health sessions on the candidate partition only (R02).
            for mode in [RuntimeMode.migration, .health] {
                let info = SessionInfo(pluginID: id, manifest: preview.manifest, runtimeMode: mode, dataGeneration: journal.newGeneration,
                                       isDevelopment: record.isDevelopment)
                let session = PluginSession(info: info, executable: URL(fileURLWithPath: newRecord.executablePath), services: engine.services)
                try await session.start(locale: engine.locale, firstLaunch: true)
                guard await session.ping() else { throw RuyioError(.handshakeFailed, objectID: id.rawValue, diagnostic: "\(mode.rawValue) check failed") }
                await session.stop()
                journal.phase = mode == .migration ? .migrated : .ready
                try write(journal)
            }

            // committed: the single persisted switch (gate still closed until it succeeds).
            newRecord.dataGeneration = journal.newGeneration
            newRecord.installedAt = record.installedAt
            newRecord.enabledPreference = record.enabledPreference
            newRecord.activationState = .disabled
            newRecord.isDefault = record.isDefault
            try await engine.registry.insert(newRecord)
            journal.phase = .committed
            try write(journal)
        } catch {
            let failure = (error as? RuyioError) ?? RuyioError(.internalError, objectID: id.rawValue, diagnostic: String(describing: error))
            await rollback(journal, record: record)
            return .rolledBack(stillUsing: oldVersion, error: failure)
        }

        // After commit: reopen entries per the user's previous preference.
        if journal.wasEnabled, let error = await engine.enable(id, userInitiated: false) {
            try? await engine.registry.setRuntimeError(id, error)
            return .committedWithRuntimeError(version: preview.manifest.version, error: error)
        }
        cleanup(journal)
        return .completed(version: preview.manifest.version)
    }

    /// Crash recovery on launch: uncommitted transactions roll back; committed ones finish cleanup.
    public func recover() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: journalsDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let journal = try? JSONCoding.decoder().decode(Journal.self, from: data) else { continue }
            switch journal.phase {
            case .committed:
                cleanup(journal)
            case .rolledBack, .failed:
                try? FileManager.default.removeItem(at: file)
            default:
                if let record = await engine.registry.record(journal.pluginID) {
                    await rollback(journal, record: record)
                }
            }
        }
    }

    // MARK: Internals

    private func rollback(_ journal: Journal, record: InstalledPluginRecord) async {
        var journal = journal
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

    private func cleanup(_ journal: Journal) {
        // Old backup is removed only after the new version is healthy (plan §15.2 step 8).
        if journal.oldInstallPath != journal.newInstallPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: journal.oldInstallPath).deletingLastPathComponent())
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
