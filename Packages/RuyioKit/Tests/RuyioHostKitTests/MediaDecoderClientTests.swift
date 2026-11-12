import AppKit
import Foundation
import Testing
@testable import RuyioHostKit

private final class DecodeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func signal() { lock.withLock { count += 1 } }
}

/// The transport is a real anonymous XPC connection; only the decoder's replies are controlled.
private final class ControlledDecoder: NSObject, RuyioMediaDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [UInt8: (Data?, Int, Int) -> Void] = [:]
    private var limits: [UInt8: Int] = [:]
    private var automatic = false

    func replyAutomatically() { lock.withLock { automatic = true } }

    func decodeThumbnail(_ data: Data, maxPixel: Int, reply: @escaping (Data?, Int, Int) -> Void) {
        guard let id = data.first else { reply(nil, 0, 0); return }
        let immediate = lock.withLock {
            limits[id] = maxPixel
            if automatic { return true }
            replies[id] = reply
            return false
        }
        if immediate { reply(Data(repeating: 0x7f, count: 16 * 16 * 4), 16, 16) }
    }

    func received(_ id: UInt8) -> Bool { lock.withLock { limits[id] != nil } }
    func limit(for id: UInt8) -> Int? { lock.withLock { limits[id] } }

    func reply(to id: UInt8, pixels: Data? = Data(repeating: 0x7f, count: 16 * 16 * 4), width: Int = 16, height: Int = 16) {
        let reply = lock.withLock { replies.removeValue(forKey: id) }
        reply?(pixels, width, height)
    }

    func finishAll() {
        let remaining = lock.withLock {
            defer { replies.removeAll() }
            return Array(replies.values)
        }
        for reply in remaining { reply(nil, 0, 0) }
    }
}

private final class DecoderFixture: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let service = ControlledDecoder()
    private let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var clients: [NSXPCConnection] = []
    private var servers: [NSXPCConnection] = []

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    var connectionCount: Int { lock.withLock { clients.count } }
    var firstConnection: NSXPCConnection? { lock.withLock { clients.first } }

    func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        lock.withLock { clients.append(connection) }
        return connection
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: RuyioMediaDecoding.self)
        connection.exportedObject = service
        lock.withLock { servers.append(connection) }
        connection.resume()
        return true
    }

    func stop() {
        service.finishAll()
        let connections = lock.withLock {
            defer { clients.removeAll(); servers.removeAll() }
            return clients + servers
        }
        for connection in connections { connection.invalidate() }
        listener.invalidate()
    }
}

@Suite(.serialized)
struct MediaDecoderClientTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(1)) }
            catch { return false }
        }
        return condition()
    }

    @Test func anOldInvalidationCannotDiscardTheReplacementConnection() async throws {
        let fixture = DecoderFixture()
        defer { fixture.stop() }
        let client = MediaDecoderClient(connectionFactory: { fixture.makeConnection() })
        let first = Task { await client.image(from: Data([1])) }
        try #require(await eventually { fixture.service.received(1) })
        let old = try #require(fixture.firstConnection)
        let delayedInvalidation = try #require(old.invalidationHandler)
        let invalidated = DecodeLatch()
        // Deliver the real old connection's callback later, after its timeout creates a replacement.
        old.invalidationHandler = { invalidated.signal() }
        #expect(await first.value == nil)
        try #require(await eventually { invalidated.value == 1 })
        let second = Task { await client.image(from: Data([2])) }
        try #require(await eventually { fixture.service.received(2) })
        #expect(fixture.connectionCount == 2)
        delayedInvalidation()
        let third = Task { await client.image(from: Data([3])) }
        try #require(await eventually { fixture.service.received(3) })
        #expect(fixture.connectionCount == 2)
        fixture.service.reply(to: 2)
        fixture.service.reply(to: 3)
        #expect(await second.value != nil)
        #expect(await third.value != nil)
    }
}

private final class DecodeDeadlineClock: @unchecked Sendable {
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

    var clock: MediaDecoderClient.DeadlineClock {
        .init(now: { [self] in lock.withLock { instant } },
              sleep: { [self] deadline in try await wait(until: deadline) })
    }
    var attemptCount: Int { lock.withLock { attempts } }
    var finishedCount: Int { lock.withLock { finished } }
    var waitingCount: Int { lock.withLock { waiters.count } }
    var peakWaitingCount: Int { lock.withLock { peak } }

    private func wait(until deadline: ContinuousClock.Instant) async throws {
        lock.withLock { attempts += 1 }
        defer { lock.withLock { finished += 1 } }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = lock.withLock {
                    guard !stopped, !Task.isCancelled else { return true }
                    waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                    peak = max(peak, waiters.count)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
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

extension MediaDecoderClientTests {
    @Test func successfulRepliesCancelDeadlinesAndReuseTheConnection() async throws {
        let fixture = DecoderFixture(), clock = DecodeDeadlineClock()
        defer { fixture.stop(); clock.cancelAll() }
        let client = MediaDecoderClient(connectionFactory: { fixture.makeConnection() }, deadlineClock: clock.clock)
        let first = Task { await client.image(from: Data([1]), maxPixel: 0) }
        try #require(await eventually { fixture.service.received(1) && clock.waitingCount == 1 })
        #expect(fixture.service.limit(for: 1) == 16)
        fixture.service.reply(to: 1)
        #expect(await first.value?.size == NSSize(width: 16, height: 16))
        #expect(await eventually { clock.attemptCount == 1 && clock.finishedCount == 1 && clock.waitingCount == 0 })
        let second = Task { await client.image(from: Data([2]), maxPixel: Int.max) }
        try #require(await eventually { fixture.service.received(2) && clock.waitingCount == 1 })
        #expect(fixture.service.limit(for: 2) == 8192)
        fixture.service.reply(to: 2)
        #expect(await second.value != nil)
        #expect(await eventually { clock.attemptCount == 2 && clock.finishedCount == 2 && clock.waitingCount == 0 })
        #expect(fixture.connectionCount == 1)
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func invalidPixelRepliesAreRejectedAndStillCancelTheirDeadline(kind: Int) async throws {
        let fixture = DecoderFixture(), clock = DecodeDeadlineClock()
        defer { fixture.stop(); clock.cancelAll() }
        let client = MediaDecoderClient(connectionFactory: { fixture.makeConnection() }, deadlineClock: clock.clock)
        let request = Task { await client.image(from: Data([1]), maxPixel: 16) }
        try #require(await eventually { fixture.service.received(1) && clock.waitingCount == 1 })
        switch kind {
        case 0: fixture.service.reply(to: 1, pixels: nil)
        case 1: fixture.service.reply(to: 1, width: 0)
        case 2: fixture.service.reply(to: 1, height: -1)
        case 3: fixture.service.reply(to: 1, width: Int.max)
        default: fixture.service.reply(to: 1, pixels: Data([0]))
        }
        #expect(await request.value == nil)
        #expect(await eventually { clock.attemptCount == 1 && clock.finishedCount == 1 && clock.waitingCount == 0 })
    }

    @Test func connectionFailureResolvesAllRepliesAndCancelsTheirDeadlines() async throws {
        let fixture = DecoderFixture(), clock = DecodeDeadlineClock()
        defer { fixture.stop(); clock.cancelAll() }
        let client = MediaDecoderClient(connectionFactory: { fixture.makeConnection() }, deadlineClock: clock.clock)
        let first = Task { await client.image(from: Data([1])) }
        let second = Task { await client.image(from: Data([2])) }
        try #require(await eventually { fixture.service.received(1) && fixture.service.received(2) && clock.waitingCount == 2 })
        try #require(fixture.firstConnection).invalidate()
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        #expect(await eventually { clock.attemptCount == 2 && clock.finishedCount == 2 && clock.waitingCount == 0 })
        let retry = Task { await client.image(from: Data([3])) }
        try #require(await eventually { fixture.service.received(3) && clock.waitingCount == 1 })
        fixture.service.reply(to: 3)
        #expect(await retry.value != nil)
        #expect(fixture.connectionCount == 2)
        #expect(await eventually { clock.attemptCount == 3 && clock.finishedCount == 3 && clock.waitingCount == 0 })
    }

    @Test func aTimeoutDiscardsTheStuckConnectionBeforeTheRetry() async throws {
        let fixture = DecoderFixture(), clock = DecodeDeadlineClock()
        defer { fixture.stop(); clock.cancelAll() }
        let client = MediaDecoderClient(connectionFactory: { fixture.makeConnection() }, deadlineClock: clock.clock)
        let first = Task { await client.image(from: Data([1])) }
        try #require(await eventually { fixture.service.received(1) && clock.waitingCount == 1 })
        clock.fireNext()
        #expect(await first.value == nil)
        let retry = Task { await client.image(from: Data([2])) }
        try #require(await eventually { fixture.service.received(2) && clock.waitingCount == 1 })
        fixture.service.reply(to: 1)
        fixture.service.reply(to: 2)
        #expect(await retry.value != nil)
        #expect(fixture.connectionCount == 2)
        #expect(await eventually { clock.attemptCount == 2 && clock.finishedCount == 2 && clock.waitingCount == 0 })
    }

    @Test func cancellationBeforeCallingNeverOpensAConnectionOrSchedulesADeadline() async {
        let fixture = DecoderFixture(), clock = DecodeDeadlineClock()
        defer { fixture.stop(); clock.cancelAll() }
        let client = MediaDecoderClient(connectionFactory: { fixture.makeConnection() }, deadlineClock: clock.clock)
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.image(from: Data([1]))
        }
        #expect(await request.value == nil)
        #expect(fixture.connectionCount == 0)
        #expect(clock.attemptCount == 0)
    }

    @Test func cancellingOneDecodeLeavesOtherConsumersAndTheirConnectionUsable() async throws {
        let fixture = DecoderFixture(), clock = DecodeDeadlineClock()
        defer { fixture.stop(); clock.cancelAll() }
        let client = MediaDecoderClient(connectionFactory: { fixture.makeConnection() }, deadlineClock: clock.clock)
        let first = Task { await client.image(from: Data([1])) }
        let second = Task { await client.image(from: Data([2])) }
        try #require(await eventually { fixture.service.received(1) && fixture.service.received(2) && clock.waitingCount == 2 })
        first.cancel()
        #expect(await first.value == nil)
        #expect(await eventually { clock.finishedCount == 1 && clock.waitingCount == 1 })
        fixture.service.reply(to: 1)
        fixture.service.reply(to: 2)
        #expect(await second.value != nil)
        #expect(fixture.connectionCount == 1)
        #expect(await eventually { clock.attemptCount == 2 && clock.finishedCount == 2 && clock.waitingCount == 0 })
    }

    @Test func cancellationBetweenTheInitialCheckAndRegistrationCannotLoseTheContinuation() async {
        let fixture = DecoderFixture(), clock = DecodeDeadlineClock()
        defer { fixture.stop(); clock.cancelAll() }
        let originalClock = clock.clock
        let cancellationClock = MediaDecoderClient.DeadlineClock(now: {
            withUnsafeCurrentTask { $0?.cancel() }
            return originalClock.now()
        }, sleep: originalClock.sleep)
        let client = MediaDecoderClient(connectionFactory: { fixture.makeConnection() }, deadlineClock: cancellationClock)
        let request = Task { await client.image(from: Data([1])) }
        #expect(await request.value == nil)
        #expect(fixture.connectionCount == 0)
        #expect(clock.attemptCount == 0)
    }

    @Test func cancellationDuringConnectionSetupCannotLeaveAnUnownedTimerOrSendTheDecode() async {
        let fixture = DecoderFixture(), clock = DecodeDeadlineClock()
        defer { fixture.stop(); clock.cancelAll() }
        let client = MediaDecoderClient(connectionFactory: {
            withUnsafeCurrentTask { $0?.cancel() }
            return fixture.makeConnection()
        }, deadlineClock: clock.clock)
        let request = Task { await client.image(from: Data([1])) }
        #expect(await request.value == nil)
        #expect(fixture.connectionCount == 1)
        #expect(!fixture.service.received(1))
        #expect(clock.attemptCount == 0)
    }

    @Test func aBurstOfSuccessfulDecodesLeavesNoDeadlineTasksBehind() async throws {
        let fixture = DecoderFixture(), clock = DecodeDeadlineClock()
        fixture.service.replyAutomatically()
        defer { fixture.stop(); clock.cancelAll() }
        let client = MediaDecoderClient(connectionFactory: { fixture.makeConnection() }, deadlineClock: clock.clock)
        for index in 0..<100 {
            #expect(await client.image(from: Data([UInt8(index)])) != nil)
        }
        #expect(await eventually { clock.attemptCount == 100 && clock.finishedCount == 100 && clock.waitingCount == 0 })
        #expect(clock.peakWaitingCount <= 1)
        #expect(fixture.connectionCount == 1)
    }

    @Test func replyTimeoutAndCancellationCompeteWithoutDoubleCompletion() async throws {
        for _ in 0..<20 {
            let fixture = DecoderFixture(), clock = DecodeDeadlineClock()
            defer { fixture.stop(); clock.cancelAll() }
            let client = MediaDecoderClient(connectionFactory: { fixture.makeConnection() }, deadlineClock: clock.clock)
            let request = Task { await client.image(from: Data([1])) }
            try #require(await eventually { fixture.service.received(1) && clock.waitingCount == 1 })
            await withTaskGroup(of: Void.self) { group in
                group.addTask { fixture.service.reply(to: 1) }
                group.addTask { clock.fireNext() }
                group.addTask { request.cancel() }
            }
            let result = await request.value
            #expect(result == nil || result?.size == NSSize(width: 16, height: 16))
            #expect(await eventually { clock.attemptCount == 1 && clock.finishedCount == 1 && clock.waitingCount == 0 })
        }
    }
}
