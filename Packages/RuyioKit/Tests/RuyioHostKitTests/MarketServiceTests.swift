import Foundation
import Testing
@testable import RuyioHostKit
import RuyioPersistence
import RuyioSourceTransport
import RuyioProtocol
import RuyioCore

/// Serves in-memory files by URL; records requests. Lets market logic run without the network.
final class FakeFetcher: RemoteFetching, @unchecked Sendable {
    let lock = NSLock()
    var files: [String: Data] = [:]
    var requests: [String] = []
    func fetch(_ url: URL, maxBytes: Int, accept: String?, timeout: TimeInterval) async throws -> FetchResult {
        lock.withLock { requests.append(url.absoluteString) }
        guard let data = lock.withLock({ files[url.absoluteString] }) else { return FetchResult(data: Data(), finalURL: url, statusCode: 404) }
        guard data.count <= maxBytes else { throw RuyioError(.sourceInvalid) }
        return FetchResult(data: data, finalURL: url, statusCode: 200)
    }
    func download(_ url: URL, to destination: URL, maxBytes: Int, progress: (@Sendable (Int64, Int64?) -> Void)?) async throws {
        guard let data = lock.withLock({ files[url.absoluteString] }) else { throw RuyioError(.networkFailure) }
        try data.write(to: destination)
    }
}

/// Deterministic actor-reentrancy fixture; no sleeps or real network requests.
actor PausingMarketFetcher: RemoteFetching {
    let base: FakeFetcher
    private var address: String?
    private var gate: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var paused = false

    init(base: FakeFetcher) { self.base = base }
    func pauseNext(_ address: String) { self.address = address; paused = false }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func resume() { gate?.resume(); gate = nil }
    func fetch(_ url: URL, maxBytes: Int, accept: String?, timeout: TimeInterval) async throws -> FetchResult {
        if address == url.absoluteString {
            address = nil
            paused = true
            await withCheckedContinuation { continuation in
                gate = continuation
                waiter?.resume()
                waiter = nil
            }
        }
        return try await base.fetch(url, maxBytes: maxBytes, accept: accept, timeout: timeout)
    }
    func download(_ url: URL, to destination: URL, maxBytes: Int, progress: (@Sendable (Int64, Int64?) -> Void)?) async throws {
        try await base.download(url, to: destination, maxBytes: maxBytes, progress: progress)
    }
}

@Suite(.serialized)
struct MarketServiceTests {
    let sha = String(repeating: "c", count: 64)

    func engine(_ fetcher: any RemoteFetching) throws -> HostEngine {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mkt-\(UUID().uuidString)")
        let paths = AppPaths(applicationSupport: base.appendingPathComponent("S"), caches: base.appendingPathComponent("C"))
        try paths.ensureDirectories()
        return try HostEngine(paths: paths, locale: "en", fetcher: fetcher)
    }

    func market(id: String) -> Data {
        Data("{\"schemaVersion\":1,\"kind\":\"market\",\"id\":\"\(id)\",\"name\":\"Example Market\",\"plugins\":[{\"id\":\"org.example.tool\",\"manifest\":\"plugins/tool/ruyio-plugin.json\",\"name\":\"Tool\"},{\"id\":\"org.example.bad\",\"manifest\":\"plugins/bad/ruyio-plugin.json\"}]}".utf8)
    }

    func descriptor(id: String, versions: [String]) -> Data {
        let releases = versions.map { "{\"version\":\"\($0)\",\"minimumHostVersion\":\"1.0.0\",\"minimumMacOSVersion\":\"15.0\",\"architectures\":[\"arm64\"],\"artifact\":\"releases/\($0)/T.ruyioplugin.zip\",\"sha256\":\"\(sha)\"}" }
        return Data("{\"schemaVersion\":1,\"kind\":\"plugin\",\"id\":\"\(id)\",\"name\":\"Tool\",\"releases\":[\(releases.joined(separator: ","))]}".utf8)
    }

    @Test func resolveAddBrowseAndRefreshWithoutInstalling() async throws {
        let fetcher = FakeFetcher()
        fetcher.files["https://example.com/ruyio-market.json"] = market(id: "org.example.market")
        fetcher.files["https://example.com/plugins/tool/ruyio-plugin.json"] = descriptor(id: "org.example.tool", versions: ["1.0.0", "1.1.0"])
        fetcher.files["https://example.com/plugins/bad/ruyio-plugin.json"] = descriptor(id: "org.example.other", versions: ["1.0.0"])
        let engine = try engine(fetcher)
        let resolved = try await engine.markets.resolve("https://example.com/ruyio-market.json")
        guard case .market = resolved.kind else { Issue.record("expected market"); return }
        #expect(await engine.markets.markets().isEmpty, "resolving must not persist anything")

        guard case .added = try await engine.markets.addMarket(resolved) else { Issue.record("not added"); return }
        guard case .alreadyAdded = try await engine.markets.addMarket(resolved) else { Issue.record("duplicate added"); return }

        let entries = await engine.markets.entries("org.example.market", load: 10)
        let tool = try #require(entries.first { $0.id.rawValue == "org.example.tool" })
        #expect(tool.load == .cached)
        #expect(tool.best?.version == SemanticVersion("1.1.0"))
        // An entry whose descriptor ID differs is isolated; the rest of the market keeps working.
        #expect(entries.first { $0.id.rawValue == "org.example.bad" }?.load == .failed)
        #expect(await engine.registry.installedIDs().isEmpty, "browsing must not install")

        // Rolled-back releases are flagged.
        fetcher.files["https://example.com/plugins/tool/ruyio-plugin.json"] = descriptor(id: "org.example.tool", versions: ["1.0.0"])
        _ = await engine.markets.refresh("org.example.market")
        let after = await engine.markets.entries("org.example.market", load: 10)
        #expect(after.first { $0.id.rawValue == "org.example.tool" }?.rollbackWarning == true)
    }

    @Test func idConflictsAndIdentityChangesFreezeTheSource() async throws {
        let fetcher = FakeFetcher()
        fetcher.files["https://a.example.com/ruyio-market.json"] = market(id: "org.example.market")
        fetcher.files["https://b.example.com/ruyio-market.json"] = market(id: "org.example.market")
        let engine = try engine(fetcher)
        _ = try await engine.markets.addMarket(try await engine.markets.resolve("https://a.example.com/ruyio-market.json"))
        let other = try await engine.markets.resolve("https://b.example.com/ruyio-market.json")
        guard case .conflict = try await engine.markets.addMarket(other) else { Issue.record("expected conflict"); return }

        fetcher.files["https://a.example.com/ruyio-market.json"] = market(id: "org.attacker.market")
        let refreshed = await engine.markets.refresh("org.example.market")
        #expect(refreshed?.state == "conflicted")
        #expect(await engine.markets.index("org.example.market")?.0.id == "org.example.market", "old index stays")

        fetcher.files["https://a.example.com/ruyio-market.json"] = nil
        let stale = await engine.markets.refresh("org.example.market")
        #expect(stale?.state == "conflicted")
        try await engine.markets.setEnabled("org.example.market", false)
        try await engine.markets.setEnabled("org.example.market", true)
        await #expect(throws: RuyioError.self) { try await engine.markets.requireAvailable("org.example.market") }
    }

    @Test func githubPluginBindingFollowsRefAndChecksRepositoryIdentity() async throws {
        let fetcher = FakeFetcher()
        let firstSHA = String(repeating: "a", count: 40)
        let nextSHA = String(repeating: "b", count: 40)
        let api = "https://api.github.com/repos/example/tool"
        fetcher.files[api] = Data(#"{"id":42,"default_branch":"main"}"#.utf8)
        fetcher.files[api + "/commits/main"] = Data(firstSHA.utf8)
        fetcher.files["https://raw.githubusercontent.com/example/tool/\(firstSHA)/ruyio-plugin.json"] = descriptor(id: "org.example.tool", versions: ["1.0.0"])
        let engine = try engine(fetcher)
        let initial = try await engine.markets.resolve("https://github.com/example/tool")
        let stored = try PluginSourceBinding(initial).encoded()
        #expect(try PluginSourceBinding.decode(stored).github?.repoID == 42)

        // Even if the default branch changes, the originally selected ref remains the update source.
        fetcher.files[api] = Data(#"{"id":42,"default_branch":"other"}"#.utf8)
        fetcher.files[api + "/commits/main"] = Data(nextSHA.utf8)
        fetcher.files["https://raw.githubusercontent.com/example/tool/\(nextSHA)/ruyio-plugin.json"] = descriptor(id: "org.example.tool", versions: ["1.1.0"])
        let (updated, url) = try await engine.markets.descriptor(source: stored)
        #expect(updated.bestRelease()?.version == SemanticVersion("1.1.0"))
        #expect(url.path.contains(nextSHA))

        fetcher.files[api] = Data(#"{"id":99,"default_branch":"main"}"#.utf8)
        await #expect(throws: RuyioError.self) { _ = try await engine.markets.descriptor(source: stored) }
    }

    @Test func fixedGitHubCommitAndLegacyRawURLStayPinned() async throws {
        let fetcher = FakeFetcher()
        let commit = String(repeating: "a", count: 40)
        let api = "https://api.github.com/repos/example/tool"
        let raw = "https://raw.githubusercontent.com/example/tool/\(commit)/ruyio-plugin.json"
        fetcher.files[api] = Data(#"{"id":42,"default_branch":"main"}"#.utf8)
        fetcher.files[api + "/commits/" + commit] = Data(commit.utf8)
        fetcher.files[raw] = descriptor(id: "org.example.tool", versions: ["1.0.0"])
        let engine = try engine(fetcher)
        let resolved = try await engine.markets.resolve("https://github.com/example/tool/tree/" + commit)
        let stored = try PluginSourceBinding(resolved).encoded()
        fetcher.files[api + "/commits/" + commit] = nil
        #expect(try await engine.markets.descriptor(source: stored).1.absoluteString == raw)
        #expect(try await engine.markets.descriptor(source: raw).1.absoluteString == raw)
    }

    @Test func disabledMarketRejectsCachedDescriptorAndDownloads() async throws {
        let fetcher = FakeFetcher()
        fetcher.files["https://example.com/ruyio-market.json"] = market(id: "org.example.market")
        fetcher.files["https://example.com/plugins/tool/ruyio-plugin.json"] = descriptor(id: "org.example.tool", versions: ["1.0.0"])
        let engine = try engine(fetcher)
        _ = try await engine.markets.addMarket(try await engine.markets.resolve("https://example.com/ruyio-market.json"))
        let (descriptor, url) = try await engine.markets.descriptor(marketID: "org.example.market", pluginID: PluginID("org.example.tool"), refresh: false)
        try await engine.markets.setEnabled("org.example.market", false)
        let requests = fetcher.requests.count
        await #expect(throws: RuyioError.self) {
            _ = try await engine.markets.descriptor(marketID: "org.example.market", pluginID: PluginID("org.example.tool"), refresh: false)
        }
        await #expect(throws: RuyioError.self) {
            _ = try await engine.markets.prepareInstall(descriptor: descriptor, descriptorURL: url, release: descriptor.releases[0], marketID: "org.example.market")
        }
        await #expect(throws: RuyioError.self) {
            try await engine.validateInstallSource(updateChannel: .market, source: "market:org.example.market")
        }
        #expect(fetcher.requests.count == requests)
    }

    @Test func detailLoadsEntriesBeyondTheInitialBatchAndRefreshesCachedVersions() async throws {
        let fetcher = FakeFetcher()
        let plugins = (0..<35).map { ["id": "org.example.tool\($0)", "manifest": "p\($0).json"] }
        fetcher.files["https://example.com/market.json"] = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "kind": "market", "id": "org.example.market", "name": "Market", "plugins": plugins])
        for index in 0..<35 {
            fetcher.files["https://example.com/p\(index).json"] = descriptor(id: "org.example.tool\(index)", versions: ["1.0.0"])
        }
        let engine = try engine(fetcher)
        _ = try await engine.markets.addMarket(try await engine.markets.resolve("https://example.com/market.json"))
        let entries = await engine.markets.entries("org.example.market", load: 30)
        #expect(entries[34].descriptor == nil)
        let id = PluginID("org.example.tool34")
        #expect(try await engine.markets.descriptor(marketID: "org.example.market", pluginID: id, refresh: false).0.id == id)
        fetcher.files["https://example.com/p34.json"] = descriptor(id: id.rawValue, versions: ["1.1.0"])
        #expect(try await engine.markets.descriptor(marketID: "org.example.market", pluginID: id, refresh: true).0.bestRelease()?.version == SemanticVersion("1.1.0"))
    }

    @Test func updateFailureIsDistinctFromUpToDateAndRetainsKnownCandidate() async throws {
        let fetcher = FakeFetcher()
        let engine = try engine(fetcher)
        let manifest = PackageFixture.manifest()
        let source = "https://example.com/plugin.json"
        let record = try InstalledPluginRecord(manifest: manifest, installPath: engine.paths.downloads, executablePath: engine.paths.downloads,
                                               teamID: nil, signingIdentifier: nil, isDevelopment: false, isDefault: false, updateChannel: .descriptor, source: source)
        try await engine.registry.insert(record)
        fetcher.files[source] = descriptor(id: manifest.id.rawValue, versions: ["1.1.0"])
        guard case .available = await engine.checkForUpdateResult(manifest.id) else { Issue.record("update missing"); return }
        fetcher.files[source] = nil
        guard case .unavailable = await engine.checkForUpdateResult(manifest.id) else { Issue.record("failed check claimed success"); return }
        #expect(engine.availableUpdate(manifest.id)?.version == SemanticVersion("1.1.0"))
        // The failed check is reported to the caller, but the known update keeps its badge.
        #expect(await engine.registry.record(manifest.id)?.updateState == .available)
    }

    @Test(arguments: [false, true])
    func inFlightRefreshCannotUndoRemovalOrDisable(remove: Bool) async throws {
        let base = FakeFetcher()
        let address = "https://example.com/market.json"
        base.files[address] = market(id: "org.example.market")
        let fetcher = PausingMarketFetcher(base: base)
        let engine = try engine(fetcher)
        _ = try await engine.markets.addMarket(try await engine.markets.resolve(address))
        await fetcher.pauseNext(address)
        let refresh = Task { await engine.markets.refresh("org.example.market") }
        await fetcher.waitUntilPaused()
        if remove { try await engine.markets.remove("org.example.market") }
        else { try await engine.markets.setEnabled("org.example.market", false) }
        await fetcher.resume()
        #expect(await refresh.value == nil)
        let records = await engine.markets.markets()
        if remove { #expect(records.isEmpty) }
        else { #expect(records.first?.enabled == false) }
    }

    @Test func refreshDuringBrowsingKeepsTheListingAndDescriptorWork() async throws {
        let base = FakeFetcher()
        let address = "https://example.com/ruyio-market.json"
        let tool = "https://example.com/plugins/tool/ruyio-plugin.json"
        base.files[address] = market(id: "org.example.market")
        base.files[tool] = descriptor(id: "org.example.tool", versions: ["1.0.0"])
        let fetcher = PausingMarketFetcher(base: base)
        let engine = try engine(fetcher)
        _ = try await engine.markets.addMarket(try await engine.markets.resolve(address))
        await fetcher.pauseNext(tool)
        let listing = Task { await engine.markets.entries("org.example.market", load: 10) }
        await fetcher.waitUntilPaused()
        // An ordinary refresh (timer, wake, another plugin's update check) lands mid-request.
        #expect(await engine.markets.refresh("org.example.market")?.lastError == nil)
        await fetcher.resume()
        let entries = await listing.value
        #expect(entries.first { $0.id.rawValue == "org.example.tool" }?.load == .cached)
    }

    @Test func remoteInstallRejectsAdHocPackagesAndHashMismatch() async throws {
        let fetcher = FakeFetcher()
        let zip = try PackageFixture.build()
        let data = try Data(contentsOf: zip)
        fetcher.files["https://example.com/plugins/test/releases/1.0.0/T.ruyioplugin.zip"] = data
        let engine = try engine(fetcher)
        let descriptor = try PluginDescriptor.decode(Data("{\"schemaVersion\":1,\"kind\":\"plugin\",\"id\":\"org.ruyio.test-plugin\",\"name\":\"T\",\"releases\":[{\"version\":\"1.0.0\",\"minimumHostVersion\":\"1.0.0\",\"minimumMacOSVersion\":\"15.0\",\"architectures\":[\"arm64\"],\"artifact\":\"releases/1.0.0/T.ruyioplugin.zip\",\"sha256\":\"\(sha)\"}]}".utf8))
        let url = URL(string: "https://example.com/plugins/test/ruyio-plugin.json")!
        await #expect(throws: RuyioError.self) {
            _ = try await engine.markets.prepareInstall(descriptor: descriptor, descriptorURL: url, release: descriptor.releases[0])
        }
        // Direct package: digest is self-computed (no expected value) but remote trust still requires Developer ID.
        let preview = try await engine.markets.prepareInstall(packageURL: URL(string: "https://example.com/plugins/test/releases/1.0.0/T.ruyioplugin.zip")!)
        #expect(preview.expectedSHA256 == nil)
        #expect(!preview.isInstallable)
        #expect(preview.checks.contains { $0.name == "developerID" && $0.outcome == .failed })
    }
}
