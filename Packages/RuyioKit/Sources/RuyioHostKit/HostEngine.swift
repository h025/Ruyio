import CryptoKit
import Foundation
import RuyioCore
import RuyioPersistence
import RuyioProtocol
import RuyioSourceTransport

/// A bundled default plugin package (plan §15.3: shipped as data inside the signed host).
public struct BundledPackage: Sendable, Hashable {
    public var url: URL
    public var manifest: PluginManifest
    public var expectedSHA256: String?
}

/// Composition root for the host domain. The app talks to this façade; it owns registry, supervisor,
/// brokers and router and enforces the enable / disable / uninstall / restore flows of PRD §19.3.
public final class HostEngine: @unchecked Sendable {
    public let paths: AppPaths
    public let database: HostDatabase
    public let registry: PluginRegistry
    public let supervisor: PluginSupervisor
    public let router: ActionRouter
    public let services: HostServices
    public let installer: PluginInstaller
    public let contexts: InvocationContexts
    public let fileBroker: FileBroker
    public let markets: MarketService
    public private(set) var updater: UpdateCoordinator!
    public let log: DiagnosticLog

    private let lock = NSLock()
    private var bundled: [PluginID: BundledPackage] = [:]
    private var viewUpdateHandler: (@Sendable (PluginID, ViewDocument) -> Void)?
    private var dynamicItemsHandler: (@Sendable (PluginID, DynamicItemsReport) -> Void)?
    private var statusThrottle: [PluginID: StatusThrottle] = [:]
    private var noticeHandler: (@Sendable (String) -> Void)?
    private var _locale: String
    private var _developerMode = false
    private var _availableUpdates: [PluginID: AvailableUpdate] = [:]
    private var viewSessions: [String: PluginSession] = [:]

    public init(paths: AppPaths, locale: String, fetcher: any RemoteFetching = SourceFetcher()) throws {
        self.paths = paths
        self._locale = locale
        log = DiagnosticLog(directory: paths.logs)
        database = try HostDatabase(url: paths.hostDatabase, backupDirectory: paths.transactionsRoot)
        registry = PluginRegistry(database: database, locale: locale)
        contexts = InvocationContexts()
        let db = database
        let identity: @Sendable (PluginID) -> String = { id in
            let record = try? db.installedPlugin(id)
            return AppPaths.dataIdentityDirectoryName(pluginID: id, publisherID: record?.publisherID, signingIdentifier: record?.signingIdentifier)
        }
        let stores = StoreProvider(paths: paths, identity: identity)
        let storeLookup: @Sendable (PluginID, String) throws -> Data = { id, blobID in
            let record = try db.installedPlugin(id)
            let store = try stores.store(pluginID: id, generation: record?.dataGeneration ?? 1, development: record?.isDevelopment ?? false)
            return try store.blobData(blobID)
        }
        fileBroker = FileBroker(database: database, contexts: contexts, blobReader: storeLookup)
        services = HostServices(stores: stores, fileBroker: fileBroker, contexts: contexts, database: database, bridge: nil)
        supervisor = PluginSupervisor(services: services, locale: locale)
        router = ActionRouter(registry: registry, supervisor: supervisor, database: database, contexts: contexts, locale: locale)
        installer = PluginInstaller(paths: paths)
        markets = MarketService(database: database, fetcher: fetcher, installer: installer, paths: paths, registry: registry)
        stores.excludeFromBackup = { [weak database] _ in
            // PRD §23 #10 (decided A11): sensitive plugin data is excluded unless the user opts in.
            !((try? database?.setting("data.includeInBackup", as: Bool.self)) ?? false)
        }

        services.addEventSink { [weak self] envelope, session in self?.handlePluginEvent(envelope, session: session) }
        updater = UpdateCoordinator(engine: self)
    }

    public var locale: String { lock.withLock { _locale } }

    public func setBridge(_ bridge: SystemBridge) { services.setBridge(bridge) }
    public func setFileConflictDelegate(_ delegate: FileBrokerDelegate) { fileBroker.delegate = delegate }

    public func onViewUpdate(_ handler: @escaping @Sendable (PluginID, ViewDocument) -> Void) { lock.withLock { viewUpdateHandler = handler } }
    public func onDynamicItems(_ handler: @escaping @Sendable (PluginID, DynamicItemsReport) -> Void) { lock.withLock { dynamicItemsHandler = handler } }
    public func onNotice(_ handler: @escaping @Sendable (String) -> Void) { lock.withLock { noticeHandler = handler } }

    // MARK: Startup

    /// Loads state, recovers interrupted operations, installs first-run defaults and starts enabled plugins.
    public func start(bundledPackages: [URL]) async throws {
        await supervisor.setHandlers(
            crash: { [weak self] id, error in Task { await self?.pluginCrashed(id, error: error) } },
            state: { [weak self] id, state in Task { await self?.registry.setProcessState(id, state) } })
        log.record(.hostStarted, ["version": HostInfo.version.description, "os": OSVersion.current.description])
        let recovered = try fileBroker.recoverInterruptedOperations()
        try await registry.load()
        let unmigrated = await migrateInstalledDataIdentities()
        await updater.recover()
        for (id, ops) in Dictionary(grouping: recovered, by: \.pluginID) {
            if let pid = PluginID(rawValue: id) { await registry.setPendingOutcomes(pid, count: ops.count) }
        }

        // Staging copies left by previews that were closed or failed are never resumed (plan §15.3).
        for leftover in (try? FileManager.default.contentsOfDirectory(at: paths.downloads, includingPropertiesForKeys: nil)) ?? []
        where leftover.lastPathComponent.hasPrefix("staging-") {
            try? FileManager.default.removeItem(at: leftover)
        }
        let packages = bundledPackages.compactMap(Self.readBundledPackage)
        lock.withLock { bundled = Dictionary(uniqueKeysWithValues: packages.map { ($0.manifest.id, $0) }) }
        await registry.setBundledDefaults(packages.map(\.manifest))

        for package in packages {
            let id = package.manifest.id
            let installed = await registry.record(id)
            if installed == nil, !(await registry.isDefaultUninstalled(id)) {
                // First run: defaults are installed and enabled (PRD §6). A user uninstall is never undone.
                _ = try? await install(bundled: package, enable: true)
            } else if let installed, installed.isDefault, let current = SemanticVersion(installed.version),
                      current < package.manifest.version, installed.updateChannel == .bundledWithHost {
                // PRD §23 #12 (decided A12): defaults update with the host through the normal transaction.
                if let preview = try? await installer.inspect(package: package.url, trust: .bundledDefault, expectedSHA256: package.expectedSHA256) {
                    if preview.isInstallable { _ = await updater.update(with: preview) } else { installer.discard(preview) }
                }
            } else if let installed, installed.isDefault, installed.updateChannel == .bundledWithHost, HostInfo.officialPublisherID.isEmpty,
                      installed.version == package.manifest.version.description, let digest = Self.sha256(of: package.url),
                      installed.artifactSHA256 != digest {
                // Development builds only (decided A22): a rebuilt default plugin keeps its version, so the stale
                // installed copy is replaced in place. Same version means same data schema; data is untouched.
                // Only for the same signing identity: a publisher change would move code and data to another identity.
                if let preview = try? await installer.inspect(package: package.url, trust: .bundledDefault, expectedSHA256: package.expectedSHA256) {
                    let sameIdentity = preview.recordPublisherID(installed: installed) == installed.publisherID && preview.signing.identifier == installed.signingIdentifier
                    installer.discard(preview)
                    if sameIdentity { _ = try? await install(bundled: package, enable: installed.enabledPreference) }
                }
            }
        }

        for id in await registry.installedIDs() {
            guard let record = await registry.record(id) else { continue }
            if unmigrated.contains(id) {
                // enable() retries the move; until then the plugin must not open an empty partition.
                try? await registry.setActivation(id, .disabled, error: RuyioError(.storageFailure, objectID: id.rawValue, retryable: true, recovery: .retry))
            } else if record.enabledPreference && record.installationState == .installed {
                await enable(id, userInitiated: false)
            } else if record.activationState != .disabled {
                try? await registry.setActivation(id, .disabled)
            }
        }
    }

    static func keptGenerationKey(_ record: InstalledPluginRecord) -> String {
        "data.keptData." + (record.isDevelopment ? "dev." : "") + dataIdentity(record)
    }

    static func dataIdentity(_ record: InstalledPluginRecord) -> String {
        AppPaths.dataIdentityDirectoryName(pluginID: PluginID(record.pluginID), publisherID: record.publisherID, signingIdentifier: record.signingIdentifier)
    }

    struct RetainedData: Codable, Sendable {
        var generation: Int
        var storageSchemaVersion: Int
        var pluginVersion: String
        var identity: String
    }

    public enum RestoreDataChoice: Sendable, Equatable { case keepCompatible, fresh }

    /// Read-only install preflight. Call before asking the user to choose a fresh partition so the
    /// verified preview stays usable; commitInstall still repeats the check at the actual commit.
    public func requiresFreshData(for preview: InstallPreview) throws -> Bool {
        let proposed = try InstalledPluginRecord(manifest: preview.manifest, installPath: preview.stagingBundle,
                                                 executablePath: preview.stagingBundle, publisherID: preview.signing.publisherID,
                                                 signingIdentifier: preview.signing.identifier, isDevelopment: preview.trust.isDevelopment,
                                                 isDefault: false, updateChannel: .none)
        do {
            _ = try retainedGeneration(for: proposed, choice: .keepCompatible)
            return false
        } catch let error as RuyioError where error.code == .retainedDataIncompatible {
            return true
        }
    }

    private func retainedGeneration(for record: InstalledPluginRecord, choice: RestoreDataChoice) throws -> Int? {
        let root = (record.isDevelopment ? paths.developmentDataRoot : paths.dataRoot).appendingPathComponent(Self.dataIdentity(record))
        let highest = UpdateCoordinator.highestGeneration(in: root)
        guard let kept = try database.setting(Self.keptGenerationKey(record), as: RetainedData?.self) ?? nil else {
            guard highest > 0 else { return nil }
            if choice == .fresh { return highest + 1 }
            // A directory alone cannot prove its schema. Never silently attach unlabelled retained data.
            throw RuyioError(.retainedDataIncompatible, objectID: record.pluginID, recovery: .openPluginDetail)
        }
        guard kept.identity == Self.dataIdentity(record), kept.generation > 0 else {
            throw RuyioError(.retainedDataIncompatible, objectID: record.pluginID, recovery: .openPluginDetail)
        }
        if choice == .fresh {
            return max(highest, kept.generation) + 1
        }
        guard kept.storageSchemaVersion == (try record.decodedManifest()).storageSchemaVersion else {
            throw RuyioError(.retainedDataIncompatible, objectID: record.pluginID, recovery: .openPluginDetail,
                             diagnostic: "retained data requires a compatible plugin version or a new data partition")
        }
        return kept.generation
    }

    /// Moves each installed plugin's ID/publisher data directory to its full-identity name. One plugin that
    /// cannot be moved stays disabled with an error; it never blocks the host or the other plugins.
    private func migrateInstalledDataIdentities() async -> Set<PluginID> {
        var failed: Set<PluginID> = []
        for id in await registry.installedIDs() {
            guard let record = await registry.record(id) else { continue }
            do { try claimLegacyData(record) } catch {
                failed.insert(id)
                log.record(.pluginEnabled, ["plugin": id.rawValue, "result": ErrorCode.storageFailure.rawValue, "step": "dataIdentity"])
            }
        }
        return failed
    }

    /// The installed record is the only identity that ever used its ID/publisher directory, so it alone claims
    /// it. Orphaned legacy data (no installed record) is kept for manual recovery, never reassigned. Runs
    /// before any store opens so a plugin never starts on an empty partition beside its old data.
    private func claimLegacyData(_ record: InstalledPluginRecord) throws {
        guard let identifier = record.signingIdentifier, !identifier.isEmpty else { return }
        let root = record.isDevelopment ? paths.developmentDataRoot : paths.dataRoot
        let old = root.appendingPathComponent(AppPaths.identityDirectoryName(pluginID: PluginID(record.pluginID), publisherID: record.publisherID))
        let target = root.appendingPathComponent(Self.dataIdentity(record))
        guard FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: target.path) else { return }
        do { try FileManager.default.moveItem(at: old, to: target) } catch {
            throw RuyioError(.storageFailure, objectID: record.pluginID, retryable: true, recovery: .retry,
                             diagnostic: "could not move data to its identity directory")
        }
    }

    /// Same digest format as `PluginInstaller.inspect`; unpacked directory packages have none.
    static func sha256(of url: URL) -> String? {
        guard !url.hasDirectoryPath, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func readBundledPackage(_ url: URL) -> BundledPackage? {
        if url.hasDirectoryPath {
            guard let root = try? PluginInstaller.locatePackageRoot(url),
                  let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
                  let manifest = try? ManifestValidator.decode(data) else { return nil }
            return BundledPackage(url: url, manifest: manifest, expectedSHA256: nil)
        }
        guard let archive = try? ZipArchive(url: url),
              let entry = archive.entries.first(where: { $0.path == "manifest.json" || ($0.path.hasSuffix("/manifest.json") && $0.path.split(separator: "/").count == 2) }),
              let data = try? archive.contents(of: entry), let manifest = try? ManifestValidator.decode(data) else { return nil }
        return BundledPackage(url: url, manifest: manifest, expectedSHA256: nil)
    }

    // MARK: Install / restore

    @discardableResult
    public func install(bundled package: BundledPackage, enable: Bool, dataChoice: RestoreDataChoice = .keepCompatible) async throws -> PluginID {
        let preview = try await installer.inspect(package: package.url, trust: .bundledDefault, expectedSHA256: package.expectedSHA256)
        guard preview.isInstallable else {
            installer.discard(preview)
            throw RuyioError(.sourceInvalid, objectID: package.manifest.id.rawValue, diagnostic: preview.failureSummary)
        }
        let id = preview.manifest.id
        let previous = await registry.record(id)
        let publisherID = preview.recordPublisherID(installed: previous)
        let proposed = try InstalledPluginRecord(manifest: preview.manifest, installPath: preview.stagingBundle,
                                                 executablePath: preview.stagingBundle, publisherID: publisherID,
                                                 signingIdentifier: preview.signing.identifier, isDevelopment: false,
                                                 isDefault: true, updateChannel: .bundledWithHost)
        if let previous, Self.dataIdentity(previous) != Self.dataIdentity(proposed) {
            installer.discard(preview)
            throw RuyioError(.sourceInvalid, objectID: id.rawValue, diagnostic: "signer changed; reinstall required")
        }
        let kept: Int?
        do {
            if previous == nil { kept = try retainedGeneration(for: proposed, choice: dataChoice) }
            else { kept = nil }
        }
        catch { installer.discard(preview); throw error }
        let wasRunning = await supervisor.isRunning(id)
        if wasRunning { await supervisor.stop(id) }
        var record = try installer.commit(preview, publisherID: publisherID, isDefault: true, updateChannel: .bundledWithHost)
        if let previous {
            record.dataGeneration = previous.dataGeneration
            record.enabledPreference = previous.enabledPreference
            record.installedAt = previous.installedAt
        } else if let kept {
            record.dataGeneration = kept
        }
        record.enabledPreference = enable
        try await registry.insert(record)
        if enable { await self.enable(id, userInitiated: false) }
        return id
    }

    /// Offline restore of an uninstalled default (PRD §19.3). Re-associates kept data.
    public func restoreDefault(_ id: PluginID, dataChoice: RestoreDataChoice = .keepCompatible) async throws {
        guard let package = lock.withLock({ bundled[id] }) else { throw RuyioError(.pluginNotFound, objectID: id.rawValue) }
        try await install(bundled: package, enable: true, dataChoice: dataChoice)
    }

    /// Installs a local development package (developer mode only, PRD §13).
    public func installDevelopmentPackage(at url: URL) async throws -> InstallPreview {
        guard developerMode else { throw RuyioError(.permissionDenied, diagnostic: "developer mode is off") }
        let installed = Set(await registry.installedIDs())
        return try await installer.inspect(package: url, trust: .development, installedIDs: installed)
    }

    /// New installs only. An installed ID changes only through the update transaction or the two-step
    /// cross-identity reinstall, never by overwriting its record (R08, plan §15).
    public func commitInstall(_ preview: InstallPreview, updateChannel: UpdateChannel, source: String?, dataChoice: RestoreDataChoice = .keepCompatible) async throws -> PluginID {
        do { try await validateInstallSource(updateChannel: updateChannel, source: source) }
        catch { installer.discard(preview); throw error }
        if await registry.record(preview.manifest.id) != nil {
            installer.discard(preview)
            throw RuyioError(.pluginAlreadyInstalled, objectID: preview.manifest.id.rawValue)
        }
        let proposed = try InstalledPluginRecord(manifest: preview.manifest, installPath: preview.stagingBundle,
                                                 executablePath: preview.stagingBundle, publisherID: preview.signing.publisherID,
                                                 signingIdentifier: preview.signing.identifier, isDevelopment: preview.trust.isDevelopment,
                                                 isDefault: false, updateChannel: updateChannel)
        let kept: Int?
        do { kept = try retainedGeneration(for: proposed, choice: dataChoice) }
        catch { installer.discard(preview); throw error }
        var record = try installer.commit(preview, publisherID: proposed.publisherID, isDefault: false, updateChannel: updateChannel, source: source)
        if let kept { record.dataGeneration = kept }
        try await registry.insert(record)
        log.record(.pluginInstalled, ["plugin": preview.manifest.id.rawValue, "version": preview.manifest.version.description, "trust": preview.trust.rawValue])
        await enable(preview.manifest.id, userInitiated: true)
        return preview.manifest.id
    }

    public var developerMode: Bool {
        get { lock.withLock { _developerMode } }
        set {
            lock.withLock { _developerMode = newValue }
            if !newValue {
                // Turning developer mode off disables every development plugin (PRD §13).
                Task {
                    for id in await registry.installedIDs() where await registry.record(id)?.isDevelopment == true {
                        await disable(id)
                    }
                }
            }
        }
    }

    // MARK: Enable / disable / uninstall (PRD §19.3)

    /// Validates, registers entries and starts background services. Any failure rolls back to disabled.
    @discardableResult
    public func enable(_ id: PluginID, userInitiated: Bool = true) async -> RuyioError? {
        guard let record = await registry.record(id), let manifest = await registry.manifest(id) else {
            return RuyioError(.pluginNotFound, objectID: id.rawValue)
        }
        if record.isDevelopment && !developerMode {
            let error = RuyioError(.permissionDenied, objectID: id.rawValue, recovery: .openPluginDetail, diagnostic: "developer mode is off")
            try? await registry.setActivation(id, .disabled, error: error, preference: userInitiated ? false : nil)
            return error
        }
        try? await registry.setActivation(id, .enabling, preference: true)
        do {
            try ManifestValidator.validate(manifest)
            guard manifest.minimumMacOSVersion <= OSVersion.current else {
                throw RuyioError(.incompatibleProtocol, objectID: id.rawValue, diagnostic: "requires macOS \(manifest.minimumMacOSVersion)")
            }
            let executable = URL(fileURLWithPath: record.executablePath)
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw RuyioError(.pluginLaunchFailed, objectID: id.rawValue, diagnostic: "executable missing")
            }
            try claimLegacyData(record)
            let isBackground = manifest.permissions.contains(.background)
            await supervisor.register(PluginLaunchSpec(manifest: manifest, executable: executable, isDevelopment: record.isDevelopment,
                                                       dataGeneration: record.dataGeneration, isBackground: isBackground))
            if isBackground {
                _ = try await supervisor.ensureRunning(id)
                await pushSettings(id)
            }
            try await registry.setActivation(id, .enabled)
            log.record(.pluginEnabled, ["plugin": id.rawValue, "version": manifest.version.description])
            return nil
        } catch {
            let failure = (error as? RuyioError) ?? RuyioError(.internalError, objectID: id.rawValue, diagnostic: String(describing: error))
            await supervisor.stop(id)
            try? await registry.setActivation(id, .disabled, error: failure)
            log.record(.pluginEnabled, ["plugin": id.rawValue, "result": failure.code.rawValue])
            return failure
        }
    }

    /// Blocks new invocations first, then stops the process; plugin and data are kept.
    public func disable(_ id: PluginID) async {
        guard await registry.record(id) != nil else { return }
        try? await registry.setActivation(id, .disabling, preference: false)
        await supervisor.unregister(id)
        contexts.revokeAll(pluginID: id)
        try? await registry.setActivation(id, .disabled, preference: false)
        log.record(.pluginDisabled, ["plugin": id.rawValue])
    }

    public struct UninstallPlan: Sendable {
        public var displayName: String
        public var isRunning: Bool
        public var entryCount: Int
        public var dataBytes: Int64
        public var documentCount: Int
        public var isDefault: Bool
    }

    public func uninstallPlan(_ id: PluginID) async -> UninstallPlan? {
        guard let record = await registry.record(id), let manifest = await registry.manifest(id) else { return nil }
        let entries = manifest.actions.reduce(0) { $0 + $1.presentations.count }
        let usage = try? services.stores.store(pluginID: id, generation: record.dataGeneration, development: record.isDevelopment).usage()
        return UninstallPlan(displayName: manifest.displayName(locale: locale).text, isRunning: await supervisor.isRunning(id),
                             entryCount: entries, dataBytes: usage?.bytes ?? 0, documentCount: usage?.documentCount ?? 0, isDefault: record.isDefault)
    }

    /// Disable → remove code → refresh entries. On file errors the plugin stays installed and disabled.
    public func uninstall(_ id: PluginID, deleteData: Bool) async throws {
        guard let record = await registry.record(id) else { throw RuyioError(.pluginNotFound, objectID: id.rawValue) }
        await disable(id)
        services.stores.close(pluginID: id)
        try? await registry.update(id) { $0.installationState = .uninstalling }
        do {
            if deleteData {
                let root = services.stores.dataRoot(pluginID: id, development: record.isDevelopment)
                if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
                try database.clearPluginSettings(id)
                try database.setSetting(Self.keptGenerationKey(record), RetainedData?.none)
            } else {
                // An unreadable stored manifest still allows keeping the data. It is labelled with an unknown
                // schema (-1), so a later install never attaches it silently and offers a fresh partition instead.
                let schema = (try? record.decodedManifest())?.storageSchemaVersion ?? -1
                let retained = RetainedData(generation: record.dataGeneration, storageSchemaVersion: schema,
                                            pluginVersion: record.version, identity: Self.dataIdentity(record))
                try database.setSetting(Self.keptGenerationKey(record), Optional(retained))
                if schema >= 0 {
                    let root = services.stores.dataRoot(pluginID: id, development: record.isDevelopment).appendingPathComponent(String(record.dataGeneration))
                    try UpdateCoordinator.writeGenerationInfo(.init(storageSchemaVersion: schema, pluginVersion: record.version, createdAt: Date()), to: root)
                }
            }
            try installer.removeCode(pluginID: id, publisherID: record.publisherID)
            try await registry.remove(id, asUninstalledDefault: record.isDefault, keptData: !deleteData)
        } catch {
            // Keep a disabled, retryable record until both code and requested data cleanup have succeeded.
            try? await registry.update(id) { $0.installationState = .installed; $0.lastErrorCode = ErrorCode.storageFailure.rawValue }
            throw RuyioError(.storageFailure, objectID: id.rawValue, retryable: true, dataEffect: .partial,
                             recovery: .retry, diagnostic: "plugin removal incomplete; retained installation record for retry")
        }
        log.record(.pluginUninstalled, ["plugin": id.rawValue, "deletedData": String(deleteData)])
    }

    // MARK: Update checks (PRD §19.11): check only, never download or install

    public struct AvailableUpdate: Sendable {
        public var pluginID: PluginID
        public var version: SemanticVersion
        public var descriptor: PluginDescriptor?
        public var descriptorURL: URL?
        public var release: PluginDescriptor.Release?
        public var bundled: BundledPackage?
        public var source: String?
    }

    public enum UpdateCheckResult: Sendable {
        case available(AvailableUpdate)
        case upToDate
        case unavailable(RuyioError)
    }

    private var availableUpdates: [PluginID: AvailableUpdate] {
        get { lock.withLock { _availableUpdates } }
        set { lock.withLock { _availableUpdates = newValue } }
    }

    public func availableUpdate(_ id: PluginID) -> AvailableUpdate? { availableUpdates[id] }

    @discardableResult
    public func checkForUpdate(_ id: PluginID) async -> AvailableUpdate? {
        if case .available(let update) = await checkForUpdateResult(id) { return update }
        return nil
    }

    public func checkForUpdateResult(_ id: PluginID) async -> UpdateCheckResult {
        guard let record = await registry.record(id), let installed = SemanticVersion(record.version) else {
            return .unavailable(RuyioError(.pluginNotFound, objectID: id.rawValue))
        }
        try? await registry.update(id) { $0.updateState = .checking }
        var found: AvailableUpdate?
        do {
            switch record.updateChannel {
            case .bundledWithHost:
                guard let package = lock.withLock({ bundled[id] }) else { throw RuyioError(.sourceInvalid, diagnostic: "bundled update package is unavailable") }
                if package.manifest.version > installed {
                    found = AvailableUpdate(pluginID: id, version: package.manifest.version, bundled: package)
                }
            case .descriptor:
                guard let source = record.source else { throw RuyioError(.sourceInvalid, diagnostic: "no update source") }
                let (descriptor, descriptorURL) = try await markets.descriptor(source: source)
                guard descriptor.id == id else { throw RuyioError(.sourceInvalid, diagnostic: "descriptor plugin ID changed") }
                if let best = descriptor.bestRelease(), best.version > installed {
                    found = AvailableUpdate(pluginID: id, version: best.version, descriptor: descriptor, descriptorURL: descriptorURL, release: best, source: record.source)
                }
            case .market:
                guard let source = record.source, source.hasPrefix("market:") else { throw RuyioError(.sourceInvalid, diagnostic: "no update source") }
                let (descriptor, descriptorURL) = try await markets.descriptor(marketID: String(source.dropFirst(7)), pluginID: id, refresh: true)
                if let best = descriptor.bestRelease(), best.version > installed {
                    found = AvailableUpdate(pluginID: id, version: best.version, descriptor: descriptor, descriptorURL: descriptorURL, release: best, source: record.source)
                }
            case .none, .development:
                throw RuyioError(.sourceInvalid, diagnostic: "this plugin has no update source")
            }
        } catch {
            let failure = (error as? RuyioError) ?? RuyioError(.networkFailure, retryable: true, diagnostic: String(describing: error))
            if Task.isCancelled {
                try? await registry.update(id) { $0.updateState = record.updateState }
                return .unavailable(RuyioError(.cancelled))
            }
            // A failed check reports the failure to the caller but never hides an update already found.
            let known = availableUpdates[id] != nil
            try? await registry.update(id) { $0.updateState = known ? .available : .updateFailed }
            return .unavailable(failure)
        }
        guard !Task.isCancelled else {
            try? await registry.update(id) { $0.updateState = record.updateState }
            return .unavailable(RuyioError(.cancelled))
        }
        guard let current = await registry.record(id), current.source == record.source,
              current.updateChannel == record.updateChannel, current.version == record.version else {
            try? await registry.update(id) { if $0.updateState == .checking { $0.updateState = .none } }
            return .unavailable(RuyioError(.cancelled, diagnostic: "plugin or source changed while checking updates"))
        }
        lock.withLock { _availableUpdates[id] = found }
        try? await registry.update(id) { $0.updateState = found == nil ? .none : .available }
        return found.map(UpdateCheckResult.available) ?? .upToDate
    }

    /// Descriptor for a plugin's recorded source, for listing historical versions (PRD §19.11).
    public func sourceDescriptor(_ id: PluginID) async -> (PluginDescriptor, URL)? {
        guard let record = await registry.record(id), let source = record.source else { return nil }
        switch record.updateChannel {
        case .descriptor:
            return try? await markets.descriptor(source: source, maxAge: MarketService.refreshFreshness)
        case .market where source.hasPrefix("market:"):
            return await markets.descriptor(marketID: String(source.dropFirst(7)), pluginID: id)
        default:
            return nil
        }
    }

    /// Downloads (or reads the bundled package) and fully verifies the update candidate.
    public func prepareUpdate(_ update: AvailableUpdate, progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> InstallPreview {
        try await validateUpdateSource(update.pluginID)
        if let bundled = update.bundled {
            return try await installer.inspect(package: bundled.url, trust: .bundledDefault, expectedSHA256: bundled.expectedSHA256)
        }
        guard let descriptor = update.descriptor, let url = update.descriptorURL, let release = update.release else {
            throw RuyioError(.sourceInvalid, diagnostic: "no update source")
        }
        let source = await registry.record(update.pluginID)?.source
        guard source == update.source else { throw RuyioError(.sourceInvalid, diagnostic: "update source changed; check again") }
        let marketID = source?.hasPrefix("market:") == true ? source.map { String($0.dropFirst(7)) } : nil
        return try await markets.prepareInstall(descriptor: descriptor, descriptorURL: url, release: release, marketID: marketID, progress: progress)
    }

    /// Shared by install, update and downgrade commits, including already downloaded previews.
    public func validateInstallSource(updateChannel: UpdateChannel, source: String?) async throws {
        guard updateChannel == .market else { return }
        guard let source, source.hasPrefix("market:") else { throw RuyioError(.sourceInvalid, diagnostic: "missing market source") }
        try await markets.requireAvailable(String(source.dropFirst(7)))
    }

    public func validateUpdateSource(_ id: PluginID) async throws {
        guard let record = await registry.record(id) else { throw RuyioError(.pluginNotFound, objectID: id.rawValue) }
        try await validateInstallSource(updateChannel: record.updateChannel, source: record.source)
    }

    // MARK: Outcomes that need checking (PRD §20.3, R15)

    /// Target folders of operations whose result is unknown, for "Show in Finder".
    public func pendingOutcomeLocations(_ id: PluginID) -> [URL] {
        let records = (try? database.unresolvedOperations(pluginID: id)) ?? []
        return records.compactMap { record in
            guard let request = try? JSONCoding.decoder().decode(FileWriteRequest.self, from: Data(record.intent.utf8)) else { return nil }
            return URL(fileURLWithPath: request.directory.path)
        }
    }

    /// The user checked the targets; nothing is retried automatically.
    public func markOutcomesResolved(_ id: PluginID) async {
        for var record in (try? database.unresolvedOperations(pluginID: id)) ?? [] {
            record.phase = .resolved
            try? database.saveOperation(record)
        }
        await registry.setPendingOutcomes(id, count: 0)
    }

    // MARK: Same-identity source switch (R08 / SOURCE-04)

    /// Verifies that the new source serves the same plugin ID signed by the same identity, then changes
    /// only the source binding. Code, data, permissions and entry preferences stay as they are.
    public func switchSource(_ id: PluginID, to resolved: ResolvedSource) async throws {
        guard let record = await registry.record(id) else { throw RuyioError(.pluginNotFound, objectID: id.rawValue) }
        let preview: InstallPreview
        let newSource: String
        let channel: UpdateChannel
        switch resolved.kind {
        case .plugin(let descriptor, let url):
            guard descriptor.id == id, let release = descriptor.bestRelease() else { throw RuyioError(.sourceInvalid, diagnostic: "source does not provide this plugin") }
            preview = try await markets.prepareInstall(descriptor: descriptor, descriptorURL: url, release: release)
            newSource = try PluginSourceBinding(resolved).encoded()
            channel = .descriptor
        default:
            throw RuyioError(.sourceInvalid, diagnostic: "choose a plugin descriptor address")
        }
        defer { installer.discard(preview) }
        guard preview.isInstallable, preview.manifest.id == id,
              !UpdateCoordinator.changesIdentity(record, preview) else {
            throw RuyioError(.sourceInvalid, objectID: id.rawValue, diagnostic: "new source is not the same publisher identity")
        }
        try await registry.update(id) {
            $0.source = newSource
            $0.updateChannel = channel
            $0.sourceState = .linked
            $0.updateState = .none
        }
        lock.withLock { _availableUpdates[id] = nil }
    }

    // MARK: Actions and views

    public func invoke(_ request: InvocationRequest) async -> ExecutionReport {
        let report = await router.invoke(request)
        // Result codes only; never parameters, paths or outputs (PRD §21).
        log.record(.actionCompleted, ["action": request.ref.description, "entry": request.entry?.rawValue ?? "-",
                                      "state": report.state.rawValue, "error": report.error?.code.rawValue ?? "-"])
        return report
    }

    /// Opens a plugin view and holds a lease until `closeView`.
    public func openView(pluginID: PluginID, viewID: String, parameters: [String: JSONValue] = [:]) async throws -> ViewDocument {
        guard let status = await registry.status(pluginID), status.isInvocable else {
            throw RuyioError(.pluginNotInvocable, objectID: pluginID.rawValue, recovery: .openPluginDetail)
        }
        let session = try await supervisor.acquireLease(pluginID)
        do {
            let document = try await session.openView(ViewOpenRequest(viewID: viewID, parameters: parameters, locale: locale))
            let previous = lock.withLock { () -> PluginSession? in
                defer { viewSessions["\(pluginID)/\(viewID)"] = session }
                return viewSessions["\(pluginID)/\(viewID)"]
            }
            if let previous { await supervisor.release(previous) }
            return document
        } catch {
            await supervisor.release(session)
            throw error
        }
    }

    public func viewEvent(pluginID: PluginID, viewID: String, revision: Int, event: ViewEvent) async throws -> ViewEventReply {
        guard let session = await supervisor.session(for: pluginID), session.isAlive else {
            throw RuyioError(.pluginCrashed, objectID: pluginID.rawValue, retryable: true)
        }
        return try await session.viewEvent(ViewEventRequest(viewID: viewID, revision: revision, event: event))
    }

    public func closeView(pluginID: PluginID, viewID: String) async {
        guard let session = lock.withLock({ viewSessions.removeValue(forKey: "\(pluginID)/\(viewID)") }) else { return }
        session.closeView(viewID)
        await supervisor.release(session)
    }

    public func refreshDynamicItems(pluginID: PluginID, provider: String) async {
        guard let session = try? await supervisor.ensureRunning(pluginID),
              let report = try? await session.dynamicItems(provider: provider) else { return }
        let handler = lock.withLock { dynamicItemsHandler }
        handler?(pluginID, report)
    }

    // MARK: Settings and locale

    public func pluginSettings(_ id: PluginID) -> [String: JSONValue] { (try? database.pluginSettings(id)) ?? [:] }

    public func setPluginSetting(_ id: PluginID, key: String, value: JSONValue) async throws {
        try database.setPluginSetting(id, key: key, value: value)
        await pushSettings(id)
    }

    private func pushSettings(_ id: PluginID) async {
        guard let session = await supervisor.session(for: id), session.isAlive else { return }
        session.sendSettings(pluginSettings(id))
    }

    public func setLocale(_ locale: String) async {
        lock.withLock { _locale = locale }
        await registry.setLocale(locale)
        await router.setLocale(locale)
        await supervisor.updateLocale(locale)
    }

    public func shutdown() async {
        await supervisor.stopAll()
    }

    // MARK: Events

    private func handlePluginEvent(_ envelope: Envelope, session: SessionInfo) {
        switch envelope.method {
        case Method.statusPublish:
            guard let report = try? JSONCoding.decode(PluginStatusReport.self, from: envelope.payload) else { return }
            applyStatusThrottled(report, pluginID: session.pluginID)
        case Method.snapshotPublish:
            guard var report = try? JSONCoding.decode(DynamicItemsReport.self, from: envelope.payload) else { return }
            // Only providers the manifest declares, so a plugin cannot grow the Finder state without bound;
            // only a clipboard-reading plugin may describe what is on the clipboard.
            let declared = Set(session.manifest.actions.compactMap { $0.presentation(.finderContextMenu)?.childrenProvider })
            guard declared.contains(report.provider) else { return }
            if !session.manifest.permissions.contains(.clipboardRead) { report.clipboardKinds = [] }
            let handler = lock.withLock { dynamicItemsHandler }
            handler?(session.pluginID, report)
        case Method.viewUpdate:
            guard let document = try? JSONCoding.decode(ViewDocument.self, from: envelope.payload),
                  (try? UISchemaLimits.validate(document)) != nil else { return }
            let handler = lock.withLock { viewUpdateHandler }
            handler?(session.pluginID, document)
        case Method.actionProgress:
            guard let execution = envelope.executionID, let progress = try? JSONCoding.decode(ActionProgress.self, from: envelope.payload) else { return }
            Task { await router.reportProgress(execution, progress) }
        default:
            break
        }
    }

    /// Status changes rebuild the menu bar and Finder snapshot, so each plugin gets at most a few per
    /// second (plan §9: UI updates are coalesced and throttled); the latest report always wins.
    private func applyStatusThrottled(_ report: PluginStatusReport, pluginID: PluginID) {
        let now = Date()
        let action: (apply: Bool, schedule: Bool) = lock.withLock {
            var entry = statusThrottle[pluginID] ?? StatusThrottle()
            defer { statusThrottle[pluginID] = entry }
            if now.timeIntervalSince(entry.lastApplied) >= Self.statusInterval && entry.pending == nil {
                entry.lastApplied = now
                return (true, false)
            }
            let schedule = entry.pending == nil
            entry.pending = report
            return (false, schedule)
        }
        if action.apply { Task { await registry.setReport(pluginID, report) } }
        guard action.schedule else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.statusInterval))
            guard let self else { return }
            let latest: PluginStatusReport? = self.lock.withLock {
                let pending = self.statusThrottle[pluginID]?.pending
                self.statusThrottle[pluginID]?.pending = nil
                self.statusThrottle[pluginID]?.lastApplied = Date()
                return pending
            }
            if let latest { await self.registry.setReport(pluginID, latest) }
        }
    }

    struct StatusThrottle {
        var lastApplied = Date.distantPast
        var pending: PluginStatusReport?
    }

    static let statusInterval: TimeInterval = 0.25

    /// Crash: mark runtimeFailed, keep files and diagnostics, never auto-restart in a loop (PRD §17).
    private func pluginCrashed(_ id: PluginID, error: RuyioError) async {
        log.record(.pluginCrashed, ["plugin": id.rawValue, "code": error.code.rawValue])
        guard let record = await registry.record(id), record.activationState == .enabled || record.activationState == .needsPermission else { return }
        guard let manifest = await registry.manifest(id) else { return }
        if manifest.permissions.contains(.background) {
            try? await registry.setRuntimeError(id, error)
        }
    }
}
