import Darwin
import Foundation
import Testing
@testable import RuyioProtocol
import RuyioCore

/// Exercises production request completion with deadlines that only fire when the test advances them.
private final class RequestTestClock: @unchecked Sendable {
    private struct Waiter {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var waiters: [UUID: Waiter] = [:]
    private var stopped = false
    private var attempts = 0
    private var finished = 0
    private var peak = 0

    var clock: RPCPeer.RequestClock {
        .init(now: { [self] in lock.withLock { instant } },
              sleep: { [self] deadline in try await wait(until: deadline) })
    }

    var attemptCount: Int { lock.withLock { attempts } }
    var finishedCount: Int { lock.withLock { finished } }
    var waitingCount: Int { lock.withLock { waiters.count } }
    var peakWaitingCount: Int { lock.withLock { peak } }

    private func wait(until deadline: ContinuousClock.Instant) async throws {
        // Count even a task cancelled before its first instruction, so zero waiters cannot pass early.
        lock.withLock { attempts += 1 }
        defer { lock.withLock { finished += 1 } }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Void, Error>? = lock.withLock {
                    if stopped || Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= instant { return .success(()) }
                    waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                    peak = max(peak, waiters.count)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func fireNext() {
        let waiter = lock.withLock { () -> Waiter? in
            guard let next = waiters.min(by: { $0.value.deadline < $1.value.deadline }) else { return nil }
            waiters[next.key] = nil
            instant = max(instant, next.value.deadline)
            return next.value
        }
        waiter?.continuation.resume()
    }

    func cancelAll() {
        let remaining = lock.withLock {
            stopped = true
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for waiter in remaining { waiter.continuation.resume(throwing: CancellationError()) }
    }
}

private final class ReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entered = 0

    var enteredCount: Int { lock.withLock { entered } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                entered += 1
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func open() {
        let remaining = lock.withLock {
            opened = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in remaining { waiter.resume() }
    }
}

private struct DeadlinePeers {
    let client: RPCPeer
    let server: RPCPeer

    init(clock: RequestTestClock, maxInFlight: Int = 16,
         handler: @escaping RPCPeer.RequestHandler) throws {
        var incoming: [Int32] = [0, 0], outgoing: [Int32] = [0, 0]
        try #require(pipe(&incoming) == 0)
        guard pipe(&outgoing) == 0 else {
            Darwin.close(incoming[0]); Darwin.close(incoming[1])
            throw RuyioError(.internalError, diagnostic: "could not create test pipe")
        }
        client = RPCPeer(readFD: outgoing[0], writeFD: incoming[1], label: "deadline-client",
                         maxInFlight: maxInFlight, requestClock: clock.clock)
        server = RPCPeer(readFD: incoming[0], writeFD: outgoing[1], label: "deadline-server")
        server.start(onRequest: handler, onEvent: { _ in }, onClose: { _ in })
        client.start(onRequest: { _ in .null }, onEvent: { _ in }, onClose: { _ in })
    }

    func close() { client.close(); server.close() }
}

@Suite(.serialized)
struct RPCDeadlineTests {
    private func eventually(_ predicate: () -> Bool) async -> Bool {
        let limit = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < limit {
            do { try await Task.sleep(for: .milliseconds(1)) }
            catch { return false }
        }
        return predicate()
    }

    private func expectFailure(_ result: Result<JSONValue, Error>, code: ErrorCode,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        switch result {
        case .success(let value): Issue.record("Expected \(code), got \(value)", sourceLocation: sourceLocation)
        case .failure(let error): #expect((error as? RuyioError)?.code == code, sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: [false, true])
    func repliesCancelStartedDeadlines(remoteError: Bool) async throws {
        let clock = RequestTestClock(), gate = ReplyGate()
        let peers = try DeadlinePeers(clock: clock) { request in
            await gate.wait()
            if remoteError { throw RuyioError(.invalidRequest, diagnostic: "synthetic remote error") }
            return request.payload
        }
        defer { gate.open(); peers.close(); clock.cancelAll() }
        let request = Task { try await peers.client.request("echo", payload: "synthetic", timeout: .seconds(60)) }
        try #require(await eventually { clock.waitingCount == 1 && gate.enteredCount == 1 })
        gate.open()
        let result = await request.result
        if remoteError { expectFailure(result, code: .invalidRequest) }
        else { #expect(try result.get() == "synthetic") }
        // No deadline has fired; a completed request must release its sleeping task immediately.
        #expect(await eventually { clock.finishedCount == 1 && clock.waitingCount == 0 })
        #expect(!peers.client.isClosed)
    }

    @Test func oversizedLocalRequestCancelsItsDeadlineAndKeepsConnectionUsable() async throws {
        let clock = RequestTestClock()
        let peers = try DeadlinePeers(clock: clock) { $0.payload }
        defer { peers.close(); clock.cancelAll() }
        let large = Task {
            try await peers.client.request("large", payload: .string(String(repeating: "x", count: Framing.maxFrameBytes)),
                                           timeout: .seconds(60))
        }
        expectFailure(await large.result, code: .frameTooLarge)
        #expect(await eventually { clock.attemptCount == 1 && clock.finishedCount == 1 && clock.waitingCount == 0 })
        #expect(try await peers.client.request("echo", payload: 42, timeout: .seconds(60)) == 42)
        #expect(await eventually { clock.attemptCount == 2 && clock.finishedCount == 2 && clock.waitingCount == 0 })
    }

    @Test func closeCancelsEveryDeadlineAndRejectedRequestsNeverScheduleOne() async throws {
        let clock = RequestTestClock(), gate = ReplyGate()
        let peers = try DeadlinePeers(clock: clock, maxInFlight: 4) { request in
            await gate.wait()
            return request.payload
        }
        defer { gate.open(); peers.close(); clock.cancelAll() }
        let requests = (0..<4).map { index in
            Task { try await peers.client.request("echo", payload: .number(Double(index)), timeout: .seconds(60)) }
        }
        try #require(await eventually { clock.waitingCount == 4 && gate.enteredCount == 4 })
        let overflow = Task { try await peers.client.request("overflow", timeout: .seconds(60)) }
        expectFailure(await overflow.result, code: .invalidRequest)
        #expect(clock.attemptCount == 4)
        peers.client.close()
        for request in requests { expectFailure(await request.result, code: .pluginCrashed) }
        #expect(await eventually { clock.finishedCount == 4 && clock.waitingCount == 0 })
        let closed = Task { try await peers.client.request("closed", timeout: .seconds(60)) }
        expectFailure(await closed.result, code: .pluginCrashed)
        #expect(clock.attemptCount == 4)
    }

    @Test func timeoutReleasesOnlyItsSlotAndLateRepliesCannotCompleteOtherRequests() async throws {
        let clock = RequestTestClock(), firstGate = ReplyGate(), secondGate = ReplyGate(), replacementGate = ReplyGate()
        let peers = try DeadlinePeers(clock: clock, maxInFlight: 2) { request in
            switch request.method {
            case "first": await firstGate.wait()
            case "second": await secondGate.wait()
            default: await replacementGate.wait()
            }
            return request.payload
        }
        defer { firstGate.open(); secondGate.open(); replacementGate.open(); peers.close(); clock.cancelAll() }
        let first = Task { try await peers.client.request("first", payload: "late", timeout: .seconds(1)) }
        try #require(await eventually { clock.waitingCount == 1 && firstGate.enteredCount == 1 })
        let second = Task { try await peers.client.request("second", payload: "second", timeout: .seconds(2)) }
        try #require(await eventually { clock.waitingCount == 2 && secondGate.enteredCount == 1 })
        clock.fireNext()
        expectFailure(await first.result, code: .requestTimeout)
        #expect(clock.waitingCount == 1)
        let replacement = Task { try await peers.client.request("replacement", payload: "replacement", timeout: .seconds(3)) }
        try #require(await eventually { clock.waitingCount == 2 && replacementGate.enteredCount == 1 })
        firstGate.open()
        secondGate.open()
        #expect(try await second.value == "second")
        replacementGate.open()
        #expect(try await replacement.value == "replacement")
        #expect(await eventually { clock.attemptCount == 3 && clock.finishedCount == 3 && clock.waitingCount == 0 })
        #expect(!peers.client.isClosed)
    }

    @Test(arguments: [Duration.zero, .seconds(-1)])
    func alreadyExpiredDeadlinesCannotRaceTheirRegistration(timeout: Duration) async throws {
        let clock = RequestTestClock(), gate = ReplyGate()
        let peers = try DeadlinePeers(clock: clock) { request in await gate.wait(); return request.payload }
        defer { gate.open(); peers.close(); clock.cancelAll() }
        let request = Task { try await peers.client.request("expired", timeout: timeout) }
        expectFailure(await request.result, code: .requestTimeout)
        #expect(await eventually { clock.attemptCount == 1 && clock.finishedCount == 1 && clock.waitingCount == 0 })
    }

    @Test func responseTimeoutAndCloseCompeteWithoutDoubleCompletion() async throws {
        for _ in 0..<20 {
            let clock = RequestTestClock(), gate = ReplyGate()
            let peers = try DeadlinePeers(clock: clock) { request in await gate.wait(); return request.payload }
            defer { gate.open(); peers.close(); clock.cancelAll() }
            let request = Task { try await peers.client.request("race", payload: "ok", timeout: .seconds(60)) }
            try #require(await eventually { clock.waitingCount == 1 && gate.enteredCount == 1 })
            await withTaskGroup(of: Void.self) { group in
                group.addTask { gate.open() }
                group.addTask { clock.fireNext() }
                group.addTask { peers.client.close() }
            }
            switch await request.result {
            case .success(let value): #expect(value == "ok")
            case .failure(let error):
                let code = (error as? RuyioError)?.code
                #expect(code == .requestTimeout || code == .pluginCrashed)
            }
            #expect(await eventually { clock.finishedCount == 1 && clock.waitingCount == 0 })
        }
    }

    @Test func rapidSuccessfulRequestsLeaveNoTasksWaitingForOriginalDeadlines() async throws {
        let clock = RequestTestClock()
        let peers = try DeadlinePeers(clock: clock) { $0.payload }
        defer { peers.close(); clock.cancelAll() }
        for index in 0..<200 {
            let payload = JSONValue.number(Double(index))
            #expect(try await peers.client.request("echo", payload: payload, timeout: .seconds(60)) == payload)
        }
        #expect(await eventually { clock.attemptCount == 200 && clock.finishedCount == 200 && clock.waitingCount == 0 })
        #expect(clock.peakWaitingCount <= 1)
    }
}
