import Darwin
import Foundation
import Testing
@testable import RuyioHostKit
import RuyioCore

/// Controls when the real supervisor's timer fires; plugin sessions are real fixture processes.
private final class SupervisorIdleClock: @unchecked Sendable {
    private struct Waiter {
        var deadline: ContinuousClock.Instant
        var continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var waiters: [UUID: Waiter] = [:]
    private var scheduled = 0
    private var inspections = 0

    var clock: PluginSupervisor.IdleClock {
        .init(now: { [self] in
            lock.withLock { inspections += 1; return instant }
        }, sleep: { [self] deadline in try await wait(until: deadline) })
    }

    var scheduledCount: Int { lock.withLock { scheduled } }
    var inspectionCount: Int { lock.withLock { inspections } }
    var waitingCount: Int { lock.withLock { waiters.count } }
    var nextDeadline: ContinuousClock.Instant? { lock.withLock { waiters.values.map(\.deadline).min() } }

    private func wait(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = lock.withLock {
                    guard !Task.isCancelled else { return true }
                    scheduled += 1
                    waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) { lock.withLock { instant += duration } }

    func fireNext() {
        let waiter = lock.withLock { () -> Waiter? in
            guard let next = waiters.min(by: { $0.value.deadline < $1.value.deadline }) else { return nil }
            waiters[next.key] = nil
            instant = max(instant, next.value.deadline)
            return next.value
        }
        waiter?.continuation.resume()
    }
}

@Suite(.serialized)
struct PluginSupervisorIdleTests {
    private func makeSupervisor(clock: SupervisorIdleClock, background: Bool = false) async -> (PluginSupervisor, FakeServices) {
        let services = FakeServices()
        let supervisor = PluginSupervisor(services: services, locale: "en", idleClock: clock.clock)
        await supervisor.register(PluginLaunchSpec(manifest: Fixture.manifest(), executable: Fixture.testPluginExecutable,
                                                  isDevelopment: true, isBackground: background))
        return (supervisor, services)
    }

    @Test func repeatedLeaseChangesNeverRunCancelledIdleChecks() async throws {
        let clock = SupervisorIdleClock()
        let (supervisor, services) = await makeSupervisor(clock: clock)
        let session = try await supervisor.ensureRunning(Fixture.pluginID)
        #expect(await Fixture.waitUntil { clock.waitingCount == 1 })
        for _ in 0..<12 {
            let lease = try await supervisor.acquireLease(Fixture.pluginID)
            #expect(lease === session)
            #expect(clock.waitingCount == 0)
            await supervisor.release(lease)
            #expect(await Fixture.waitUntil { clock.waitingCount == 1 })
        }
        // No clock deadline has fired. Cancellation must not inspect sessions or schedule replacement work.
        try await Task.sleep(for: .milliseconds(80))
        #expect(clock.inspectionCount == 0)
        #expect(clock.scheduledCount == 13)
        #expect(session.isAlive)
        await supervisor.stopAll()
        #expect(clock.waitingCount == 0)
        withExtendedLifetime(services) {}
    }

    @Test func idleDeadlineActuallyStopsTheUnleasedProcess() async throws {
        let clock = SupervisorIdleClock()
        let (supervisor, services) = await makeSupervisor(clock: clock)
        let session = try await supervisor.ensureRunning(Fixture.pluginID)
        let pid = try #require(session.pid)
        #expect(await Fixture.waitUntil { clock.waitingCount == 1 })
        let deadline = try #require(clock.nextDeadline)
        #expect(deadline - session.lastActivity == PluginSupervisor.idleTimeout)
        clock.fireNext()
        #expect(await Fixture.waitUntil { !session.isAlive && !Fixture.isAlive(pid) })
        #expect(await supervisor.isRunning(Fixture.pluginID) == false)
        #expect(clock.waitingCount == 0)
        #expect(clock.inspectionCount == 1)
        await supervisor.stopAll()
        withExtendedLifetime(services) {}
    }

    @Test func leasesSuspendIdleTimersUntilTheLastHolderReleases() async throws {
        let clock = SupervisorIdleClock()
        let (supervisor, services) = await makeSupervisor(clock: clock)
        let first = try await supervisor.acquireLease(Fixture.pluginID)
        let second = try await supervisor.acquireLease(Fixture.pluginID)
        #expect(first === second)
        clock.advance(by: .seconds(60))
        let scheduled = clock.scheduledCount
        try await Task.sleep(for: .milliseconds(80))
        #expect(clock.waitingCount == 0)
        #expect(clock.scheduledCount == scheduled)
        #expect(clock.inspectionCount == 0)
        #expect(first.isAlive)
        await supervisor.release(first)
        #expect(clock.waitingCount == 0)
        await supervisor.release(second)
        #expect(await Fixture.waitUntil { clock.waitingCount == 1 })
        clock.fireNext()
        #expect(await Fixture.waitUntil { !first.isAlive })
        await supervisor.stopAll()
        withExtendedLifetime(services) {}
    }

    @Test func backgroundPluginsNeverCreateIdlePollingTimers() async throws {
        let clock = SupervisorIdleClock()
        let (supervisor, services) = await makeSupervisor(clock: clock, background: true)
        let session = try await supervisor.ensureRunning(Fixture.pluginID)
        for _ in 0..<12 {
            let lease = try await supervisor.acquireLease(Fixture.pluginID)
            await supervisor.release(lease)
        }
        clock.advance(by: .seconds(3600))
        try await Task.sleep(for: .milliseconds(80))
        #expect(clock.scheduledCount == 0)
        #expect(clock.waitingCount == 0)
        #expect(clock.inspectionCount == 0)
        #expect(session.isAlive)
        await supervisor.stopAll()
        withExtendedLifetime(services) {}
    }

    @Test func hostActivityMovesTheDeadlineWithoutPolling() async throws {
        let clock = SupervisorIdleClock()
        let (supervisor, services) = await makeSupervisor(clock: clock)
        let session = try await supervisor.ensureRunning(Fixture.pluginID)
        #expect(await Fixture.waitUntil { clock.waitingCount == 1 })
        let originalDeadline = try #require(clock.nextDeadline)
        _ = try await session.invoke(Fixture.invocation("echo"), execution: ExecutionID(), operation: nil,
                                     registryGeneration: 1, timeout: .seconds(2))
        #expect(session.lastActivity + PluginSupervisor.idleTimeout > originalDeadline)
        clock.fireNext()
        #expect(await Fixture.waitUntil { clock.waitingCount == 1 })
        #expect(session.isAlive)
        #expect(clock.nextDeadline == session.lastActivity + PluginSupervisor.idleTimeout)
        #expect(clock.inspectionCount == 1)
        clock.fireNext()
        #expect(await Fixture.waitUntil { !session.isAlive })
        await supervisor.stopAll()
        withExtendedLifetime(services) {}
    }

    @Test func stoppingAnExpiredSessionPreservesTheRemainingSessionsTimer() async throws {
        let clock = SupervisorIdleClock()
        let (supervisor, services) = await makeSupervisor(clock: clock)
        let first = try await supervisor.ensureRunning(Fixture.pluginID)
        #expect(await Fixture.waitUntil { clock.waitingCount == 1 })
        // A distinct bundled manifest lets the existing fixture executable host a second real identity.
        let otherID = "org.ruyio.idle-second"
        let package = try PackageFixture.build(sandbox: false, id: otherID)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        let executable = package.deletingLastPathComponent()
            .appendingPathComponent("Test.ruyioplugin/Test.app/Contents/MacOS/RuyioTestPlugin")
        await supervisor.register(PluginLaunchSpec(manifest: PackageFixture.manifest(id: otherID), executable: executable,
                                                  isDevelopment: true, isBackground: false))
        let second = try await supervisor.ensureRunning(PluginID(otherID))
        #expect(await Fixture.waitUntil { clock.scheduledCount == 2 && clock.waitingCount == 1 })
        #expect(first.lastActivity < second.lastActivity)
        clock.fireNext()
        #expect(await Fixture.waitUntil { !first.isAlive && clock.waitingCount == 1 })
        try await Task.sleep(for: .milliseconds(80))
        #expect(second.isAlive)
        #expect(clock.nextDeadline == second.lastActivity + PluginSupervisor.idleTimeout)
        // The old reaper must not cancel/recreate the timer stop() scheduled before it suspended.
        #expect(clock.scheduledCount == 3)
        #expect(clock.inspectionCount == 1)
        clock.fireNext()
        #expect(await Fixture.waitUntil { !second.isAlive })
        #expect(clock.waitingCount == 0)
        await supervisor.stopAll()
        withExtendedLifetime(services) {}
    }
}
