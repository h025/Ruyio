import CryptoKit
import Foundation
import Testing
@testable import RuyioHostKit
import RuyioCore
import RuyioPersistence

@Suite(.serialized)
struct AutomaticUpdateCoordinatorTests {
    let fixture = MarketServiceTests()
    let marketAddress = "https://example.com/market.json"
    let pluginAddress = "https://example.com/plugin.json"

    func prepare(_ fetcher: FakeFetcher) async throws -> HostEngine {
        fetcher.files[marketAddress] = fixture.market(id: "org.example.market")
        let manifest = PackageFixture.manifest()
        fetcher.files[pluginAddress] = fixture.descriptor(id: manifest.id.rawValue, versions: ["1.1.0"])
        let engine = try fixture.engine(fetcher)
        _ = try await engine.markets.addMarket(try await engine.markets.resolve(marketAddress))
        let record = try InstalledPluginRecord(manifest: manifest, installPath: engine.paths.downloads, executablePath: engine.paths.downloads,
                                               publisherID: nil, signingIdentifier: nil, isDevelopment: false, isDefault: false,
                                               updateChannel: .descriptor, source: pluginAddress)
        try await engine.registry.insert(record)
        return engine
    }

    @Test func independentSwitchesUsePersistentRateLimitsAndNeverInstall() async throws {
        let fetcher = FakeFetcher()
        let engine = try await prepare(fetcher)
        let scheduler = AutomaticUpdateCoordinator(engine: engine, schedulesAutomatically: false)
        let now = Date()
        let before = fetcher.requests.count
        await scheduler.checkIfDue(now: now)
        #expect(fetcher.requests.count == before)

        await scheduler.configure(refreshMarkets: true, checkPluginUpdates: false)
        await scheduler.checkIfDue(now: now)
        #expect(fetcher.requests.filter { $0 == marketAddress }.count == 2)
        #expect(!fetcher.requests.contains(pluginAddress))

        await scheduler.configure(refreshMarkets: false, checkPluginUpdates: true)
        await scheduler.checkIfDue(now: now)
        #expect(fetcher.requests.filter { $0 == pluginAddress }.count == 1)
        #expect(engine.availableUpdate(PackageFixture.manifest().id)?.version == SemanticVersion("1.1.0"))
        #expect(await engine.registry.record(PackageFixture.manifest().id)?.version == "1.0.0")
        await scheduler.stop()

        let restarted = AutomaticUpdateCoordinator(engine: engine, schedulesAutomatically: false)
        await restarted.configure(refreshMarkets: true, checkPluginUpdates: true)
        let requests = fetcher.requests.count
        await restarted.checkIfDue(now: now.addingTimeInterval(60))
        #expect(fetcher.requests.count == requests, "relaunch must retain both rate limits")
        await restarted.checkIfDue(now: now.addingTimeInterval(6 * 60 * 60 + 1))
        #expect(fetcher.requests.count == requests + 2)
        #expect(await restarted.status().lastPluginAttempt == now.addingTimeInterval(6 * 60 * 60 + 1))
    }

    @Test func appUpdateChecksRunOnlyWhenEnabledAndNeverDownload() async throws {
        let fetcher = FakeFetcher()
        let engine = try await prepare(fetcher)
        let tests = AppUpdateTests()
        fetcher.files[tests.feed.absoluteString] = tests.appcast()
        let app = tests.service(fetcher, key: .init(), requirement: "identifier \"x\"")
        let scheduler = AutomaticUpdateCoordinator(engine: engine, appUpdates: app, schedulesAutomatically: false)
        let now = Date()
        await scheduler.configure(refreshMarkets: false, checkPluginUpdates: false, checkAppUpdates: false)
        await scheduler.checkIfDue(now: now)
        #expect(!fetcher.requests.contains(tests.feed.absoluteString))

        let found = Locked<[SemanticVersion?]>([])
        await app.observe { item in found.withLock { $0.append(item?.version) } }
        await scheduler.configure(refreshMarkets: false, checkPluginUpdates: false, checkAppUpdates: true)
        await scheduler.checkIfDue(now: now)
        #expect(found.withLock { $0 } == [SemanticVersion("1.2.0")])
        #expect(!fetcher.requests.contains(tests.archiveURL))
        await scheduler.stop()
    }

    @Test func failedChecksAreRateLimitedAndReportedAsFailure() async throws {
        let fetcher = FakeFetcher()
        let engine = try await prepare(fetcher)
        fetcher.files[pluginAddress] = nil
        let scheduler = AutomaticUpdateCoordinator(engine: engine, schedulesAutomatically: false)
        await scheduler.configure(refreshMarkets: false, checkPluginUpdates: true)
        let now = Date()
        await scheduler.checkIfDue(now: now)
        let count = fetcher.requests.count
        await scheduler.checkIfDue(now: now.addingTimeInterval(30))
        #expect(fetcher.requests.count == count)
        #expect(await engine.registry.record(PackageFixture.manifest().id)?.updateState == .updateFailed)
    }

    @Test func disablingCancelsAnAutomaticRunAndWakeDoesNotReenter() async throws {
        let base = FakeFetcher()
        base.files[marketAddress] = fixture.market(id: "org.example.market")
        base.files["https://example.com/second.json"] = fixture.market(id: "org.example.second")
        let fetcher = PausingMarketFetcher(base: base)
        let engine = try fixture.engine(fetcher)
        _ = try await engine.markets.addMarket(try await engine.markets.resolve(marketAddress))
        _ = try await engine.markets.addMarket(try await engine.markets.resolve("https://example.com/second.json"))
        let originalRefresh = await engine.markets.markets().first { $0.marketID == "org.example.market" }?.lastRefreshAt
        let scheduler = AutomaticUpdateCoordinator(engine: engine, schedulesAutomatically: false)
        await fetcher.pauseNext(marketAddress)
        await scheduler.configure(refreshMarkets: true, checkPluginUpdates: false)
        let work = Task { await scheduler.checkIfDue() }
        await fetcher.waitUntilPaused()
        #expect(await scheduler.status().refreshingMarkets)
        await scheduler.checkIfDue()
        await scheduler.stop()
        await fetcher.resume()
        await work.value
        #expect(!(await scheduler.status().refreshingMarkets))
        #expect(base.requests.filter { $0 == "https://example.com/second.json" }.count == 1)
        #expect(await engine.markets.markets().first { $0.marketID == "org.example.market" }?.lastRefreshAt == originalRefresh)
    }
}
