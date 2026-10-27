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
    private var noticeHandler: (@Sendable (String) -> Void)?
    private var _locale: String
    private var _developerMode = false
    private var _availableUpdates: [PluginID: AvailableUpdate] = [:]

    public init(paths: AppPaths, locale: String, fetcher: any RemoteFetching = SourceFetcher()) throws {
        self.paths = paths
        self._locale = locale
        log = DiagnosticLog(directory: paths.logs)
        database = try HostDatabase(url: paths.hostDatabase, backupDirectory: paths.transactionsRoot)
        registry = PluginRegistry(database: database, locale: locale)
        contexts = InvocationContexts()
        let db = database
        let identity: @Sendable (PluginID) -> String = { id in
            let team = (try? db.installedPlugin(id))?.teamID
            return AppPaths.identityDirectoryName(pluginID: id, teamID: team)
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
            !(((try? database?.setting("data.includeInBackup", as: Bool.self)) ?? false) ?? false)
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
        await updater.recover()
        for (id, ops) in Dictionary(grouping: recovered, by: \.pluginID) {
            if let pid = PluginID(rawValue: id) { await registry.setPendingOutcomes(pid, count: ops.count) }
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
                if let preview = try? installer.inspect(package: package.url, trust: .bundledDefault, expectedSHA256: package.expectedSHA256),
                   preview.isInstallable {
                    _ = await updater.update(with: preview)
                }
            }
        }

        for id in await registry.installedIDs() {
            guard let record = await registry.record(id) else { continue }
            if record.enabledPreference && record.installationState == .installed {
                await enable(id, userInitiated: false)
            } else if record.activationState != .disabled {
                try? await registry.setActivation(id, .disabled)
            }
        }
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
    public func install(bundled package: BundledPackage, enable: Bool) async throws -> PluginID {
        let preview = try installer.inspect(package: package.url, trust: .bundledDefault, expectedSHA256: package.expectedSHA256)
        guard preview.isInstallable else {
            installer.discard(preview)
            throw RuyioError(.sourceInvalid, objectID: package.manifest.id.rawValue, diagnostic: preview.failureSummary)
        }
        let id = preview.manifest.id
        let wasRunning = await supervisor.isRunning(id)
        if wasRunning { await supervisor.stop(id) }
        var record = try installer.commit(preview, isDefault: true, updateChannel: .bundledWithHost)
        if let previous = await registry.record(id) {
            record.dataGeneration = previous.dataGeneration
            record.enabledPreference = previous.enabledPreference
            record.installedAt = previous.installedAt
        }
        record.enabledPreference = enable
        try await registry.insert(record)
        if enable { await self.enable(id, userInitiated: false) }
        return id
    }

    /// Offline restore of an uninstalled default (PRD §19.3). Re-associates kept data.
    public func restoreDefault(_ id: PluginID) async throws {
        guard let package = lock.withLock({ bundled[id] }) else { throw RuyioError(.pluginNotFound, objectID: id.rawValue) }
        try await install(bundled: package, enable: true)
    }

    /// Installs a local development package (developer mode only, PRD §13).
    public func installDevelopmentPackage(at url: URL) async throws -> InstallPreview {
        guard developerMode else { throw RuyioError(.permissionDenied, diagnostic: "developer mode is off") }
        let installed = Set(await registry.installedIDs())
        return try installer.inspect(package: url, trust: .development, installedIDs: installed)
    }

    public func commitInstall(_ preview: InstallPreview, updateChannel: UpdateChannel, source: String?) async throws -> PluginID {
        let record = try installer.commit(preview, isDefault: false, updateChannel: updateChannel, source: source)
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
        try? await registry.update(id) { $0.installationState = .uninstalling }
        do {
            try installer.removeCode(pluginID: id, teamID: record.teamID)
        } catch {
            try? await registry.update(id) { $0.installationState = .installed }
            throw RuyioError(.fileWriteFailed, objectID: id.rawValue, retryable: true, recovery: .revealInFinder, diagnostic: String(describing: error))
        }
        if deleteData {
            services.stores.close(pluginID: id)
            try? FileManager.default.removeItem(at: services.stores.dataRoot(pluginID: id, development: record.isDevelopment))
        }
        try await registry.remove(id, asUninstalledDefault: record.isDefault, keptData: !deleteData)
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
    }

    private var availableUpdates: [PluginID: AvailableUpdate] {
        get { lock.withLock { _availableUpdates } }
        set { lock.withLock { _availableUpdates = newValue } }
    }

    public func availableUpdate(_ id: PluginID) -> AvailableUpdate? { availableUpdates[id] }

    @discardableResult
    public func checkForUpdate(_ id: PluginID) async -> AvailableUpdate? {
        guard let record = await registry.record(id), let installed = SemanticVersion(record.version) else { return nil }
        try? await registry.update(id) { $0.updateState = .checking }
        var found: AvailableUpdate?
        switch record.updateChannel {
        case .bundledWithHost:
            if let package = lock.withLock({ bundled[id] }), package.manifest.version > installed {
                found = AvailableUpdate(pluginID: id, version: package.manifest.version, bundled: package)
            }
        case .descriptor:
            if let source = record.source, let url = URL(string: source), let (descriptor, descriptorURL) = try? await markets.descriptor(at: url),
               descriptor.id == id, let best = descriptor.bestRelease(), best.version > installed {
                found = AvailableUpdate(pluginID: id, version: best.version, descriptor: descriptor, descriptorURL: descriptorURL, release: best)
            }
        case .market:
            if let source = record.source, source.hasPrefix("market:"),
               let (descriptor, descriptorURL) = await markets.descriptor(marketID: String(source.dropFirst(7)), pluginID: id),
               let best = descriptor.bestRelease(), best.version > installed {
                found = AvailableUpdate(pluginID: id, version: best.version, descriptor: descriptor, descriptorURL: descriptorURL, release: best)
            }
        case .none, .development:
            break
        }
        availableUpdates[id] = found
        try? await registry.update(id) { $0.updateState = found == nil ? .none : .available }
        return found
    }

    /// Downloads (or reads the bundled package) and fully verifies the update candidate.
    public func prepareUpdate(_ update: AvailableUpdate, progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> InstallPreview {
        if let bundled = update.bundled {
            return try installer.inspect(package: bundled.url, trust: .bundledDefault, expectedSHA256: bundled.expectedSHA256)
        }
        guard let descriptor = update.descriptor, let url = update.descriptorURL, let release = update.release else {
            throw RuyioError(.sourceInvalid, diagnostic: "no update source")
        }
        return try await markets.prepareInstall(descriptor: descriptor, descriptorURL: url, release: release, progress: progress)
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
            return try await session.openView(ViewOpenRequest(viewID: viewID, parameters: parameters, locale: locale))
        } catch {
            await supervisor.release(pluginID)
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
        if let session = await supervisor.session(for: pluginID) { session.closeView(viewID) }
        await supervisor.release(pluginID)
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
            Task { await registry.setReport(session.pluginID, report) }
        case Method.snapshotPublish:
            guard let report = try? JSONCoding.decode(DynamicItemsReport.self, from: envelope.payload) else { return }
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
