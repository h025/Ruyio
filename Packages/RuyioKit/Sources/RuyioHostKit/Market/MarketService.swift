import Foundation
import RuyioCore
import RuyioPersistence
import RuyioProtocol
import RuyioSourceTransport

/// Per-entry loading state inside a market (plan §14.4).
public enum MarketEntryLoad: String, Sendable, Hashable {
    case pending, loading, cached, stale, failed
}

public struct MarketEntryState: Sendable, Hashable, Identifiable {
    public var id: PluginID
    public var marketID: String
    public var hintName: String?
    public var hintSummary: String?
    public var load: MarketEntryLoad
    public var descriptor: PluginDescriptor?
    public var descriptorURL: URL?
    public var best: PluginDescriptor.Release?
    public var installedVersion: SemanticVersion?
    public var rollbackWarning: Bool
    public var errorCode: String?

    public var isInstalled: Bool { installedVersion != nil }
    public var hasUpdate: Bool {
        guard let installedVersion, let best else { return false }
        return installedVersion < best.version
    }
}

/// Multi-market management (PRD §7.6.7, plan §14). Refreshing never installs or updates anything;
/// install and update are separate user operations with full verification.
public actor MarketService {
    private let database: HostDatabase
    private let fetcher: any RemoteFetching
    private let installer: PluginInstaller
    private let paths: AppPaths
    private let registry: PluginRegistry
    private var entryCache: [String: MarketEntryState] = [:]
    private var refreshing: Set<String> = []
    private var refreshWaiters: [String: [CheckedContinuation<MarketRecord?, Never>]] = [:]
    /// Trust epoch per market: bumped only when what the market may do changes (added, replaced, enabled,
    /// disabled, removed, conflicted). An ordinary refresh never cancels downloads or listings in flight.
    private var revisions: [String: UInt64] = [:]
    private var sourceCache: [String: (fetchedAt: Date, descriptor: PluginDescriptor, url: URL)] = [:]
    /// Update checks within this window reuse the last index instead of spending GitHub API requests again.
    static let refreshFreshness: TimeInterval = 600

    private func invalidate(_ marketID: String) {
        revisions[marketID, default: 0] &+= 1
        dropCachedEntries(marketID)
    }

    private func dropCachedEntries(_ marketID: String) {
        entryCache = entryCache.filter { !$0.key.hasPrefix(marketID + "#") }
    }

    /// Cached metadata may be browsed, but a disabled, removed or conflicted source cannot act.
    public func requireAvailable(_ marketID: String) throws {
        guard let record = markets().first(where: { $0.marketID == marketID }), record.enabled,
              record.state == "active" || record.state == "stale" else {
            throw RuyioError(.sourceInvalid, objectID: marketID, diagnostic: "market is disabled, removed, unavailable or conflicted")
        }
    }

    private func requireCurrent(_ marketID: String, revision: UInt64) throws {
        try requireAvailable(marketID)
        guard revisions[marketID, default: 0] == revision else {
            throw RuyioError(.cancelled, objectID: marketID, diagnostic: "market changed during the request")
        }
    }

    private var developerMode = false

    public func setDeveloperMode(_ enabled: Bool) { developerMode = enabled }

    public init(database: HostDatabase, fetcher: any RemoteFetching, installer: PluginInstaller, paths: AppPaths, registry: PluginRegistry) {
        self.database = database
        self.fetcher = fetcher
        self.installer = installer
        self.paths = paths
        self.registry = registry
    }

    /// Read-only: never adds, installs or persists anything (PRD §7.6.8).
    public func resolve(_ input: String) async throws -> ResolvedSource {
        try await SourceResolver(fetcher: fetcher).resolve(input)
    }

    public func markets() -> [MarketRecord] { (try? database.markets()) ?? [] }

    public enum AddResult: Sendable {
        case added(MarketRecord)
        case alreadyAdded(MarketRecord)
        /// Same market ID from a different canonical address: the user decides (PRD §7.6.7).
        case conflict(existing: MarketRecord, incomingURL: String)
    }

    public func addMarket(_ resolved: ResolvedSource, replaceExisting: Bool = false) throws -> AddResult {
        guard case .market(let market, _) = resolved.kind else { throw RuyioError(.sourceInvalid, diagnostic: "not a market") }
        let existing = markets().first { $0.marketID == market.id }
        if let existing, !replaceExisting {
            return existing.canonicalURL == resolved.canonicalURL && existing.state != "conflicted"
                ? .alreadyAdded(existing) : .conflict(existing: existing, incomingURL: resolved.canonicalURL)
        }
        var record = MarketRecord(marketID: market.id, name: market.name, inputURL: resolved.inputURL, canonicalURL: resolved.canonicalURL,
                                  githubRepoID: resolved.github?.repoID, ref: resolved.github?.ref, commitSHA: resolved.github?.commitSHA,
                                  enabled: true, state: "active", index: try Self.encodeIndex(resolved))
        record.lastRefreshAt = Date()
        if let existing { record.addedAt = existing.addedAt }
        try database.saveMarket(record)
        invalidate(market.id)
        return .added(record)
    }

    /// Re-reads the index only. Market identity or repository changes freeze the source (R12, R38).
    @discardableResult
    public func refresh(_ marketID: String) async -> MarketRecord? {
        guard var record = markets().first(where: { $0.marketID == marketID }) else { return nil }
        guard record.enabled, record.state != "conflicted" else { return record }
        if refreshing.contains(marketID) {
            return await withCheckedContinuation { refreshWaiters[marketID, default: []].append($0) }
        }
        let revision = revisions[marketID, default: 0]
        refreshing.insert(marketID)
        var completed: MarketRecord?
        defer {
            refreshing.remove(marketID)
            for waiter in refreshWaiters.removeValue(forKey: marketID) ?? [] { waiter.resume(returning: completed) }
        }
        do {
            let resolved = try await resolve(record.inputURL)
            try Task.checkCancellation()
            guard case .market(let market, _) = resolved.kind else { throw RuyioError(.sourceInvalid, diagnostic: "address no longer points to a market") }
            if market.id != record.marketID || (record.githubRepoID != nil && resolved.github?.repoID != record.githubRepoID) {
                record.state = "conflicted"
                record.lastError = market.id != record.marketID ? "market ID changed to \(market.id)" : "repository identity changed"
            } else {
                record.index = try Self.encodeIndex(resolved)
                record.commitSHA = resolved.github?.commitSHA ?? record.commitSHA
                record.name = market.name
                record.state = "active"
                record.lastError = nil
                record.lastRefreshAt = Date()
            }
        } catch is CancellationError {
            return nil
        } catch let error as RuyioError {
            // Failure keeps the last good index browsable and marks it stale (PRD §19.9).
            record.state = record.index == nil ? "unavailable" : "stale"
            record.lastError = error.code.rawValue + (error.diagnostic.map { ": \($0)" } ?? "")
        } catch {
            record.state = record.index == nil ? "unavailable" : "stale"
            record.lastError = String(describing: error)
        }
        // Actor reentrancy allows disable/remove/replace while the network is suspended.
        guard !Task.isCancelled, revisions[marketID, default: 0] == revision,
              markets().contains(where: { $0.marketID == marketID }) else { return nil }
        do { try database.saveMarket(record) }
        catch { return nil }
        // A successful refresh reloads descriptors lazily; a failed one keeps the cache it says it is showing.
        if record.state == "conflicted" { invalidate(marketID) } else if record.lastError == nil { dropCachedEntries(marketID) }
        completed = record
        return record
    }

    public func setEnabled(_ marketID: String, _ enabled: Bool) throws {
        guard var record = markets().first(where: { $0.marketID == marketID }) else { return }
        record.enabled = enabled
        // Enabled is independent of trust. Toggling a conflicted market never restores trust.
        if record.state == "disabled" { record.state = record.index == nil ? "unavailable" : "active" }
        try database.saveMarket(record)
        invalidate(marketID)
    }

    /// Removing a market never uninstalls plugins installed from it (PRD §7.6.7).
    public func remove(_ marketID: String) async throws {
        try database.deleteMarket(marketID)
        invalidate(marketID)
        for id in await registry.installedIDs() {
            guard let record = await registry.record(id), record.source == "market:\(marketID)" else { continue }
            try? await registry.update(id) { $0.sourceState = .orphaned }
        }
    }

    public func index(_ marketID: String) -> (MarketDescriptor, URL)? {
        guard let record = markets().first(where: { $0.marketID == marketID }), let raw = record.index,
              let stored = try? JSONCoding.decoder().decode(StoredIndex.self, from: Data(raw.utf8)) else { return nil }
        return (stored.market, stored.indexURL)
    }

    /// Entries with lazily loaded descriptors (plan §14.4): `limit` bounds network work per call.
    public func entries(_ marketID: String, load limit: Int = 0) async -> [MarketEntryState] {
        guard let (market, indexURL) = index(marketID) else { return [] }
        let revision = revisions[marketID, default: 0]
        var states: [MarketEntryState] = []
        var budget = limit
        for entry in market.plugins {
            let key = "\(marketID)#\(entry.id.rawValue)"
            var state = entryCache[key] ?? MarketEntryState(id: entry.id, marketID: marketID, hintName: entry.name, hintSummary: entry.summary,
                                                            load: .pending, rollbackWarning: false)
            state.installedVersion = await registry.manifest(entry.id)?.version
            guard revisions[marketID, default: 0] == revision else { return [] }
            if budget > 0, (state.load == .pending || state.load == .failed), (try? requireAvailable(marketID)) != nil {
                budget -= 1
                do {
                    state = try await loadDescriptor(entry: entry, marketID: marketID, indexURL: indexURL, base: state, revision: revision)
                } catch {
                    state.load = .failed
                    state.errorCode = (error as? RuyioError)?.code.rawValue ?? ErrorCode.networkFailure.rawValue
                }
            }
            guard revisions[marketID, default: 0] == revision else { return [] }
            entryCache[key] = state
            states.append(state)
        }
        return states
    }

    private func loadDescriptor(entry: MarketDescriptor.Entry, marketID: String, indexURL: URL, base: MarketEntryState, revision: UInt64) async throws -> MarketEntryState {
        var state = base
        try requireCurrent(marketID, revision: revision)
        guard let url = URL(string: entry.manifest, relativeTo: indexURL)?.absoluteURL, url.scheme == "https" else {
            throw RuyioError(.networkPolicy, diagnostic: "descriptor must be https")
        }
        let result = try await fetcher.fetch(url, maxBytes: PluginDescriptor.maxBytes, accept: "application/json")
        try requireCurrent(marketID, revision: revision)
        guard result.statusCode == 200 else { throw RuyioError(.sourceInvalid, diagnostic: "HTTP \(result.statusCode)") }
        let descriptor = try PluginDescriptor.decode(result.data)
        // Entry ID must equal descriptor ID; mismatches isolate only this entry (plan §14.3).
        guard descriptor.id == entry.id else { throw RuyioError(.sourceInvalid, diagnostic: "entry and descriptor IDs differ") }
        state.descriptor = descriptor
        state.descriptorURL = result.finalURL
        state.best = descriptor.bestRelease()
        state.load = .cached
        state.errorCode = nil
        let sourceKey = "market:\(marketID)"
        if let highest = descriptor.releases.map(\.version).max() {
            let seenRaw = (try? database.seenVersion(pluginID: entry.id.rawValue, sourceKey: sourceKey)) ?? nil
            if let seenRaw, let seen = SemanticVersion(seenRaw), highest < seen {
                state.rollbackWarning = true
            } else {
                state.rollbackWarning = false
                try? database.recordSeenVersion(pluginID: entry.id.rawValue, sourceKey: sourceKey, version: highest.description)
            }
        }
        return state
    }

    /// Reads a plugin descriptor directly (independent URL installs check updates here, PRD §19.11).
    public func descriptor(at url: URL) async throws -> (PluginDescriptor, URL) {
        let result = try await fetcher.fetch(url, maxBytes: PluginDescriptor.maxBytes, accept: "application/json")
        guard result.statusCode == 200 else { throw RuyioError(.sourceInvalid, diagnostic: "HTTP \(result.statusCode)") }
        return (try PluginDescriptor.decode(result.data), result.finalURL)
    }

    /// `maxAge` lets browsing reuse a recent answer; resolving a GitHub source costs rate-limited API requests.
    public func descriptor(source: String, maxAge: TimeInterval = 0) async throws -> (PluginDescriptor, URL) {
        if maxAge > 0, let cached = sourceCache[source], -cached.fetchedAt.timeIntervalSinceNow < maxAge {
            return (cached.descriptor, cached.url)
        }
        let resolved = try await SourceResolver(fetcher: fetcher).resolve(PluginSourceBinding.decode(source))
        guard case .plugin(let descriptor, let url) = resolved.kind else { throw RuyioError(.sourceInvalid, diagnostic: "source no longer provides a plugin") }
        sourceCache[source] = (Date(), descriptor, url)
        return (descriptor, url)
    }

    /// Descriptor of one entry in a recorded market, loading it if needed.
    public func descriptor(marketID: String, pluginID: PluginID) async -> (PluginDescriptor, URL)? {
        try? await descriptor(marketID: marketID, pluginID: pluginID, refresh: false)
    }

    /// Loads the requested entry, independent of its position in the index. Explicit update checks
    /// refresh both the index and the descriptor, so an old cache can never claim "up to date".
    public func descriptor(marketID: String, pluginID: PluginID, refresh: Bool) async throws -> (PluginDescriptor, URL) {
        try requireAvailable(marketID)
        let fresh = markets().first { $0.marketID == marketID }.flatMap(\.lastRefreshAt).map { -$0.timeIntervalSinceNow < Self.refreshFreshness } ?? false
        if refresh && !fresh {
            guard let record = await self.refresh(marketID), record.lastError == nil else {
                throw RuyioError(.networkFailure, objectID: marketID, retryable: true, diagnostic: "market refresh did not succeed")
            }
            try requireAvailable(marketID)
        }
        guard let (market, indexURL) = index(marketID), let entry = market.plugins.first(where: { $0.id == pluginID }) else {
            throw RuyioError(.sourceInvalid, objectID: pluginID.rawValue, diagnostic: "plugin is no longer listed in this market")
        }
        let revision = revisions[marketID, default: 0]
        let key = "\(marketID)#\(pluginID.rawValue)"
        var state = entryCache[key] ?? MarketEntryState(id: entry.id, marketID: marketID, hintName: entry.name,
                                                       hintSummary: entry.summary, load: .pending, rollbackWarning: false)
        if refresh || state.descriptor == nil || state.load == .failed {
            state = try await loadDescriptor(entry: entry, marketID: marketID, indexURL: indexURL, base: state, revision: revision)
            entryCache[key] = state
        }
        guard let descriptor = state.descriptor, let url = state.descriptorURL else { throw RuyioError(.sourceInvalid) }
        return (descriptor, url)
    }

    // MARK: Install preparation (PRD §19.10)

    /// Downloads to an isolated staging file, checks size and SHA-256, then runs full verification.
    public func prepareInstall(descriptor: PluginDescriptor, descriptorURL: URL, release: PluginDescriptor.Release,
                               marketID: String? = nil, progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> InstallPreview {
        let revision = marketID.map { revisions[$0, default: 0] }
        if let marketID { try requireAvailable(marketID) }
        let artifact = try SourceResolver.artifactURL(release.artifact, relativeTo: descriptorURL)
        let file = paths.downloads.appendingPathComponent("\(UUID().uuidString).ruyioplugin.zip")
        defer { try? FileManager.default.removeItem(at: file) }
        try await fetcher.download(artifact, to: file, maxBytes: 200 << 20, progress: progress)
        if let marketID, let revision { try requireCurrent(marketID, revision: revision) }
        try Task.checkCancellation()
        var preview = try await inspectRemote(file, expectedSHA256: release.sha256)
        // External description and signed manifest must agree (PRD §7.6.5).
        let matches = preview.manifest.id == descriptor.id && preview.manifest.version == release.version
        preview.checks.append(VerificationCheck(name: "descriptor", outcome: matches ? .passed : .failed,
                                                detail: matches ? nil : "package does not match its descriptor"))
        return preview
    }

    /// Direct package URL: one-time install with a self-computed digest and no update source (R21).
    public func prepareInstall(packageURL: URL, progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> InstallPreview {
        let file = paths.downloads.appendingPathComponent("\(UUID().uuidString).ruyioplugin.zip")
        defer { try? FileManager.default.removeItem(at: file) }
        try await fetcher.download(packageURL, to: file, maxBytes: 200 << 20, progress: progress)
        return try await inspectRemote(file, expectedSHA256: nil)
    }

    /// Checks marking a formal remote package, which developer mode may waive.
    static let notarizationChecks: Set<String> = ["developerID", "hardenedRuntime", "notarization"]

    /// Formal verification first. In developer mode a package that fails only for lacking Developer ID or
    /// notarization is verified again as a development plugin, with a visible marker (A34).
    private func inspectRemote(_ file: URL, expectedSHA256: String?) async throws -> InstallPreview {
        let formal = try await installer.inspect(package: file, trust: .remote, expectedSHA256: expectedSHA256)
        let failed = Set(formal.checks.filter { $0.outcome == .failed }.map(\.name))
        guard developerMode, !failed.isEmpty, failed.isSubset(of: Self.notarizationChecks) else { return formal }
        installer.discard(formal)
        var preview = try await installer.inspect(package: file, trust: .remoteDevelopment, expectedSHA256: expectedSHA256)
        preview.checks.append(VerificationCheck(name: "developerMode", outcome: .notChecked,
                                                detail: "not notarized by Apple; installs as a developer plugin"))
        return preview
    }

    // MARK: Index storage

    struct StoredIndex: Codable {
        var market: MarketDescriptor
        var indexURL: URL
    }

    static func encodeIndex(_ resolved: ResolvedSource) throws -> String {
        guard case .market(let market, let url) = resolved.kind else { throw RuyioError(.sourceInvalid) }
        return String(decoding: try JSONCoding.encoder().encode(StoredIndex(market: market, indexURL: url)), as: UTF8.self)
    }
}
