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
            return existing.canonicalURL == resolved.canonicalURL ? .alreadyAdded(existing) : .conflict(existing: existing, incomingURL: resolved.canonicalURL)
        }
        var record = MarketRecord(marketID: market.id, name: market.name, inputURL: resolved.inputURL, canonicalURL: resolved.canonicalURL,
                                  githubRepoID: resolved.github?.repoID, ref: resolved.github?.ref, commitSHA: resolved.github?.commitSHA,
                                  enabled: true, state: "active", index: try Self.encodeIndex(resolved))
        record.lastRefreshAt = Date()
        if let existing { record.addedAt = existing.addedAt }
        try database.saveMarket(record)
        entryCache = entryCache.filter { !$0.key.hasPrefix(market.id + "#") }
        return .added(record)
    }

    /// Re-reads the index only. Market identity or repository changes freeze the source (R12, R38).
    @discardableResult
    public func refresh(_ marketID: String) async -> MarketRecord? {
        guard var record = markets().first(where: { $0.marketID == marketID }), !refreshing.contains(marketID) else { return nil }
        refreshing.insert(marketID)
        defer { refreshing.remove(marketID) }
        do {
            let resolved = try await resolve(record.inputURL)
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
                entryCache = entryCache.filter { !$0.key.hasPrefix(marketID + "#") }
            }
        } catch let error as RuyioError {
            // Failure keeps the last good index browsable and marks it stale (PRD §19.9).
            record.state = record.index == nil ? "unavailable" : "stale"
            record.lastError = error.code.rawValue + (error.diagnostic.map { ": \($0)" } ?? "")
        } catch {
            record.state = record.index == nil ? "unavailable" : "stale"
            record.lastError = String(describing: error)
        }
        try? database.saveMarket(record)
        return record
    }

    public func setEnabled(_ marketID: String, _ enabled: Bool) throws {
        guard var record = markets().first(where: { $0.marketID == marketID }) else { return }
        record.enabled = enabled
        if !enabled { record.state = "disabled" } else if record.state == "disabled" { record.state = record.index == nil ? "unavailable" : "active" }
        try database.saveMarket(record)
    }

    /// Removing a market never uninstalls plugins installed from it (PRD §7.6.7).
    public func remove(_ marketID: String) async throws {
        try database.deleteMarket(marketID)
        entryCache = entryCache.filter { !$0.key.hasPrefix(marketID + "#") }
        for id in await registry.installedIDs() {
            guard let record = await registry.record(id), record.source?.hasPrefix("market:\(marketID)") == true else { continue }
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
        var states: [MarketEntryState] = []
        var budget = limit
        for entry in market.plugins {
            let key = "\(marketID)#\(entry.id.rawValue)"
            var state = entryCache[key] ?? MarketEntryState(id: entry.id, marketID: marketID, hintName: entry.name, hintSummary: entry.summary,
                                                            load: .pending, rollbackWarning: false)
            state.installedVersion = await registry.manifest(entry.id)?.version
            if budget > 0, state.load == .pending || state.load == .failed {
                budget -= 1
                state = await loadDescriptor(entry: entry, marketID: marketID, indexURL: indexURL, base: state)
            }
            entryCache[key] = state
            states.append(state)
        }
        return states
    }

    func loadDescriptor(entry: MarketDescriptor.Entry, marketID: String, indexURL: URL, base: MarketEntryState) async -> MarketEntryState {
        var state = base
        do {
            guard let url = URL(string: entry.manifest, relativeTo: indexURL)?.absoluteURL, url.scheme == "https" else {
                throw RuyioError(.networkPolicy, diagnostic: "descriptor must be https")
            }
            let result = try await fetcher.fetch(url, maxBytes: PluginDescriptor.maxBytes, accept: "application/json")
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
                    try? database.recordSeenVersion(pluginID: entry.id.rawValue, sourceKey: sourceKey, version: highest.description)
                }
            }
        } catch let error as RuyioError {
            state.load = .failed
            state.errorCode = error.code.rawValue
        } catch {
            state.load = .failed
        }
        return state
    }

    // MARK: Install preparation (PRD §19.10)

    /// Downloads to an isolated staging file, checks size and SHA-256, then runs full verification.
    public func prepareInstall(descriptor: PluginDescriptor, descriptorURL: URL, release: PluginDescriptor.Release,
                               progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> InstallPreview {
        let artifact = try SourceResolver.artifactURL(release.artifact, relativeTo: descriptorURL)
        let file = paths.downloads.appendingPathComponent("\(UUID().uuidString).ruyioplugin.zip")
        defer { try? FileManager.default.removeItem(at: file) }
        try await fetcher.download(artifact, to: file, maxBytes: 200 << 20, progress: progress)
        try Task.checkCancellation()
        var preview = try installer.inspect(package: file, trust: .remote, expectedSHA256: release.sha256)
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
        return try installer.inspect(package: file, trust: .remote, expectedSHA256: nil)
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
