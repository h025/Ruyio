import Foundation
import RuyioCore
import RuyioPersistence

/// Background metadata checks only. This coordinator never downloads or installs plugin or app code.
public actor AutomaticUpdateCoordinator {
    public struct Status: Sendable {
        public var lastMarketAttempt: Date?
        public var lastPluginAttempt: Date?
        public var refreshingMarkets: Bool
        public var checkingPlugins: Bool
    }

    private enum Job: String, CaseIterable, Sendable {
        case markets, plugins, app
        var settingKey: String { "updates.automatic.\(rawValue).lastAttempt" }
    }

    private let engine: HostEngine
    private let appUpdates: AppUpdateService?
    private let interval: TimeInterval
    /// After a network failure (often just woken from sleep, offline) the job runs again this soon.
    static let retryAfterFailure: TimeInterval = 30 * 60
    /// At launch, or when a check is switched on, a job runs unless it ran this recently: updates show up
    /// right after a restart, while restarting again and again does not become a stream of requests.
    static let launchGap: TimeInterval = 15 * 60
    private let schedulesAutomatically: Bool
    private var enabled: Set<Job> = []
    private var attempts: [Job: Date] = [:]
    private var generations: [Job: UInt64] = [:]
    private var timers: [Job: Task<Void, Never>] = [:]
    private var running: [Job: Task<Void, Never>] = [:]

    /// `schedulesAutomatically: false` lets tests drive the same due checks with a controlled clock.
    public init(engine: HostEngine, appUpdates: AppUpdateService? = nil, interval: TimeInterval = 6 * 60 * 60, schedulesAutomatically: Bool = true) {
        self.engine = engine
        self.appUpdates = appUpdates
        self.interval = max(1, interval)
        self.schedulesAutomatically = schedulesAutomatically
        for job in Job.allCases {
            attempts[job] = try? engine.database.setting(job.settingKey, as: Date.self)
        }
    }

    public func configure(refreshMarkets: Bool, checkPluginUpdates: Bool, checkAppUpdates: Bool = false) {
        configure(.markets, enabled: refreshMarkets)
        configure(.plugins, enabled: checkPluginUpdates)
        configure(.app, enabled: checkAppUpdates && appUpdates != nil)
    }

    private func configure(_ job: Job, enabled shouldEnable: Bool) {
        guard enabled.contains(job) != shouldEnable else { return }
        generations[job, default: 0] &+= 1
        timers.removeValue(forKey: job)?.cancel()
        running.removeValue(forKey: job)?.cancel()
        if shouldEnable {
            enabled.insert(job)
            if schedulesAutomatically { startTimer(job) }
        } else {
            enabled.remove(job)
        }
    }

    public func stop() {
        configure(refreshMarkets: false, checkPluginUpdates: false)
    }

    public func status() -> Status {
        Status(lastMarketAttempt: attempts[.markets], lastPluginAttempt: attempts[.plugins],
               refreshingMarkets: running[.markets] != nil, checkingPlugins: running[.plugins] != nil)
    }

    /// Startup timers and wake notifications share this persisted rate limit and reentrancy guard. `atLaunch`
    /// is the timers' first round: due after `launchGap` rather than the full interval.
    public func checkIfDue(now: Date = Date(), atLaunch: Bool = false) async {
        let gap = atLaunch ? Self.launchGap : nil
        let market = beginIfDue(.markets, now: now, gap: gap)
        let plugins = beginIfDue(.plugins, now: now, gap: gap)
        let app = beginIfDue(.app, now: now, gap: gap)
        await market?.value
        await plugins?.value
        await app?.value
    }

    private func startTimer(_ job: Job) {
        let generation = generations[job, default: 0]
        timers[job] = Task { [weak self] in
            var gap: TimeInterval? = Self.launchGap
            while !Task.isCancelled {
                let work = await self?.beginIfDue(job, now: Date(), gap: gap)
                gap = nil
                await work?.value
                guard let delay = await self?.nextDelay(job, generation: generation) else { return }
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }
        }
    }

    private func nextDelay(_ job: Job, generation: UInt64) -> TimeInterval? {
        guard enabled.contains(job), generations[job, default: 0] == generation else { return nil }
        guard let attempt = attempts[job] else { return interval }
        return max(1, interval - Date().timeIntervalSince(attempt))
    }

    /// `gap`: how long since the last attempt makes the job due; the regular interval unless given.
    private func beginIfDue(_ job: Job, now: Date, gap: TimeInterval? = nil) -> Task<Void, Never>? {
        guard enabled.contains(job), running[job] == nil else { return nil }
        if let previous = attempts[job], now >= previous, now.timeIntervalSince(previous) < (gap ?? interval) { return nil }
        // Persist attempts, including failures, so restart/wake never becomes a retry storm.
        do { try engine.database.setSetting(job.settingKey, now) }
        catch { return nil }
        attempts[job] = now
        let generation = generations[job, default: 0]
        let task = Task { [weak self] in
            guard let self else { return }
            let succeeded = await self.perform(job, generation: generation)
            if !succeeded { await self.retrySooner(job, attemptedAt: now, generation: generation) }
            await self.finished(job, generation: generation)
        }
        running[job] = task
        return task
    }

    private func retrySooner(_ job: Job, attemptedAt: Date, generation: UInt64) {
        guard generations[job, default: 0] == generation else { return }
        let adjusted = attemptedAt.addingTimeInterval(min(0, Self.retryAfterFailure - interval))
        guard (try? engine.database.setSetting(job.settingKey, adjusted)) != nil else { return }
        attempts[job] = adjusted
    }

    private func finished(_ job: Job, generation: UInt64) {
        if generations[job, default: 0] == generation { running[job] = nil }
    }

    private func canContinue(_ job: Job, generation: UInt64) -> Bool {
        !Task.isCancelled && enabled.contains(job) && generations[job, default: 0] == generation
    }

    /// Returns false when a network failure suggests trying again before the regular interval.
    private func perform(_ job: Job, generation: UInt64) async -> Bool {
        guard canContinue(job, generation: generation) else { return true }
        var succeeded = true
        switch job {
        case .markets:
            for market in await engine.markets.markets() where market.enabled && market.state != "conflicted" {
                guard canContinue(job, generation: generation) else { return true }
                if let refreshed = await engine.markets.refresh(market.marketID), refreshed.lastError?.hasPrefix(ErrorCode.networkFailure.rawValue) == true {
                    succeeded = false
                }
            }
        case .plugins:
            for id in await engine.registry.installedIDs() {
                guard canContinue(job, generation: generation) else { return true }
                guard let record = await engine.registry.record(id), record.installationState == .installed,
                      !record.isDevelopment, record.updateChannel != .development, record.updateChannel != .none else { continue }
                guard canContinue(job, generation: generation) else { return true }
                if case .unavailable(let error) = await engine.checkForUpdateResult(id), error.code == .networkFailure { succeeded = false }
            }
        case .app:
            // Only finds out; downloading and installing always wait for the user (A41). The launch check
            // made just before is reused rather than repeated.
            do { _ = try await appUpdates?.check(reusingWithin: 5 * 60) }
            catch let error as RuyioError where error.code == .networkFailure { succeeded = false }
            catch {}
        }
        return succeeded
    }
}
