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

@Suite(.serialized)
struct MarketServiceTests {
    let sha = String(repeating: "c", count: 64)

    func engine(_ fetcher: FakeFetcher) throws -> HostEngine {
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
        #expect(stale?.state == "stale")
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
