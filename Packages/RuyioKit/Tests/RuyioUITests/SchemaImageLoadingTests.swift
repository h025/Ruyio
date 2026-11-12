import AppKit
import RuyioCore
import RuyioProtocol
@testable import RuyioUI
import Testing

@MainActor
struct SchemaImageLoadingTests {
    private func context(gate: ThumbnailGate, preview: ((String) async -> NSImage?)? = nil) -> SchemaContext {
        SchemaContext(pluginID: PluginID("org.example.image-loading"),
                      document: ViewDocument(viewID: "images", revision: 1, root: .loading),
                      strings: SchemaStrings(submit: "", cancel: "", undo: "", loading: "", choose: ""),
                      sendEvent: { _, _ in }, loadBlob: { await gate.load($0) }, loadPreviewBlob: preview)
    }

    @Test func cancellationReturnsAndReleasesContextWithoutWaitingForTheLoader() async throws {
        let gate = ThumbnailGate()
        defer { gate.finishAll() }
        var context: SchemaContext? = context(gate: gate)
        weak var observedContext = context
        let returned = ThumbnailSignal()
        let task = Task { [context = context!] in
            let result = await context.image("abandoned")
            returned.signal()
            return result
        }
        try #require(await gate.waitForStarts(1))
        task.cancel()
        let cancelled = await returned.wait()
        #expect(cancelled)
        if !cancelled { gate.finishAll() }
        #expect(await task.value == nil)
        context = nil
        #expect(observedContext == nil)
        #expect(await gate.waitForCancellation(0))
        #expect(gate.active == 1)
    }

    @Test func oneCancelledConsumerReturnsWhileAnotherStillWaitsForTheSameImage() async throws {
        let gate = ThumbnailGate()
        defer { gate.finishAll() }
        let context = context(gate: gate)
        let returned = ThumbnailSignal()
        let first = Task {
            let result = await context.image("shared")
            returned.signal()
            return result
        }
        try #require(await gate.waitForStarts(1))
        let entered = ThumbnailSignal()
        let second = Task { entered.signal(); return await context.image("shared") }
        try #require(await entered.wait())
        first.cancel()
        let cancelled = await returned.wait()
        #expect(cancelled)
        if !cancelled { gate.finishAll() }
        #expect(await first.value == nil)
        #expect(gate.ids == ["shared"])
        #expect(gate.cancelled.isEmpty)
        let image = NSImage(size: NSSize(width: 32, height: 32))
        gate.finish(0, with: image)
        #expect(await second.value === image)
        #expect(await context.image("shared") === image)
        #expect(gate.ids.count == 1)
    }

    @Test func thumbnailConcurrencyIsBoundedAndQueuedCancellationSkipsTheLoader() async throws {
        let gate = ThumbnailGate()
        defer { gate.finishAll() }
        let context = context(gate: gate)
        let first = (0..<4).map { id in Task { await context.image(String(id)) } }
        try #require(await gate.waitForStarts(4))
        let entered = ThumbnailSignal()
        let queued = Task { entered.signal(); return await context.image("queued") }
        try #require(await entered.wait())
        let nextEntered = ThumbnailSignal()
        let next = Task { nextEntered.signal(); return await context.image("next") }
        try #require(await nextEntered.wait())
        queued.cancel()
        gate.finish(0)
        try #require(await gate.waitForStarts(5))
        #expect(gate.ids.last == "next")
        gate.finishAll()
        for task in first { _ = await task.value }
        #expect(await queued.value == nil)
        _ = await next.value
        #expect(gate.peak == 4)
        #expect(!gate.ids.contains("queued"))
    }

    @Test func cancelledNoncooperativeLoadsKeepTheirSlotsUntilTheyReallyEnd() async throws {
        let gate = ThumbnailGate()
        defer { gate.finishAll() }
        let context = context(gate: gate)
        let returned = (0..<4).map { _ in ThumbnailSignal() }
        let tasks = (0..<4).map { id in
            Task {
                let result = await context.image(String(id))
                returned[id].signal()
                return result
            }
        }
        try #require(await gate.waitForStarts(4))
        let entered = ThumbnailSignal()
        let next = Task { entered.signal(); return await context.image("next") }
        try #require(await entered.wait())
        tasks.forEach { $0.cancel() }
        for signal in returned {
            let cancelled = await signal.wait()
            #expect(cancelled)
            if !cancelled { gate.finishAll() }
        }
        for index in 0..<4 { #expect(await gate.waitForCancellation(index)) }
        #expect(gate.active == 4)
        #expect(gate.ids.count == 4)
        gate.finish(0)
        try #require(await gate.waitForStarts(5))
        #expect(gate.active == 4)
        #expect(gate.peak == 4)
        gate.finishAll()
        for task in tasks { #expect(await task.value == nil) }
        _ = await next.value
    }

    @Test func aLateAbandonedResultCannotReplaceTheRetriedImagesCache() async throws {
        let gate = ThumbnailGate()
        defer { gate.finishAll() }
        let context = context(gate: gate)
        let returned = ThumbnailSignal()
        let old = Task {
            let result = await context.image("retry")
            returned.signal()
            return result
        }
        try #require(await gate.waitForStarts(1))
        old.cancel()
        try #require(await returned.wait())
        let retry = Task { await context.image("retry") }
        try #require(await gate.waitForStarts(2))
        let fresh = NSImage(size: NSSize(width: 32, height: 32))
        let stale = NSImage(size: NSSize(width: 16, height: 16))
        // Finish the abandoned generation while the retry is still waiting.
        gate.finish(0, with: stale)
        try #require(await gate.waitForFinishes(1))
        gate.finish(1, with: fresh)
        #expect(await retry.value === fresh)
        #expect(await old.value == nil)
        #expect(await context.image("retry") === fresh)
        #expect(gate.ids == ["retry", "retry"])
    }

    @Test func queuedLoadsStartInOrderAndFailuresFreeCapacity() async throws {
        let gate = ThumbnailGate()
        defer { gate.finishAll() }
        let scheduler = ImageLoadScheduler(limit: 1) { await gate.load($0) }
        let first = Task { await scheduler.image("first") }
        try #require(await gate.waitForStarts(1))
        let enteredSecond = ThumbnailSignal()
        let second = Task { enteredSecond.signal(); return await scheduler.image("second") }
        try #require(await enteredSecond.wait())
        let enteredThird = ThumbnailSignal()
        let third = Task { enteredThird.signal(); return await scheduler.image("third") }
        try #require(await enteredThird.wait())
        gate.finish(0)
        try #require(await gate.waitForStarts(2))
        #expect(gate.ids == ["first", "second"])
        gate.finish(1)
        try #require(await gate.waitForStarts(3))
        #expect(gate.ids == ["first", "second", "third"])
        gate.finish(2)
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        #expect(await third.value == nil)
        let retry = Task { await scheduler.image("first") }
        try #require(await gate.waitForStarts(4))
        gate.finish(3)
        #expect(await retry.value == nil)
        #expect(gate.peak == 1)
    }

    @Test func aResultAfterAllConsumersCancelIsNotCached() async throws {
        let gate = ThumbnailGate()
        defer { gate.finishAll() }
        let context = context(gate: gate)
        let returned = ThumbnailSignal()
        let first = Task {
            let result = await context.image("unused")
            returned.signal()
            return result
        }
        try #require(await gate.waitForStarts(1))
        first.cancel()
        try #require(await returned.wait())
        gate.finish(0, with: NSImage(size: NSSize(width: 16, height: 16)))
        try #require(await gate.waitForFinishes(1))
        let next = Task { await context.image("unused") }
        try #require(await gate.waitForStarts(2))
        gate.finish(1)
        #expect(await first.value == nil)
        #expect(await next.value == nil)
        #expect(gate.ids == ["unused", "unused"])
    }

    @Test func previewsWithoutADedicatedLoaderReuseTheThumbnailCache() async throws {
        let gate = ThumbnailGate()
        defer { gate.finishAll() }
        let context = context(gate: gate)
        let task = Task { await context.previewImage("preview") }
        try #require(await gate.waitForStarts(1))
        let image = NSImage(size: NSSize(width: 32, height: 32))
        gate.finish(0, with: image)
        #expect(await task.value === image)
        #expect(await context.image("preview") === image)
        #expect(gate.ids == ["preview"])
    }

    @Test func aRequestCancelledBeforeItEntersTheContextDoesNotLoad() async throws {
        let gate = ThumbnailGate()
        defer { gate.finishAll() }
        let context = context(gate: gate)
        let entered = ThumbnailSignal()
        let proceed = ThumbnailSignal()
        let task = Task {
            entered.signal()
            _ = await proceed.wait()
            return await context.image("cancelled")
        }
        try #require(await entered.wait())
        task.cancel()
        proceed.signal()
        #expect(await task.value == nil)
        #expect(gate.ids.isEmpty)
    }

    @Test func cancellationFromAnotherExecutorDuringRegistrationDoesNotStrandConsumers() async throws {
        let gate = ThumbnailGate()
        defer { gate.finishAll() }
        let context = context(gate: gate)
        for id in 0..<100 {
            let returned = ThumbnailSignal()
            let task = Task {
                let result = await context.image(String(id))
                returned.signal()
                return result
            }
            await Task.detached { task.cancel() }.value
            // Bound each cancellation after it was issued, not the scheduling of 100 detached tasks.
            let completed = await returned.wait()
            #expect(completed)
            if !completed { gate.finishAll() }
            #expect(await task.value == nil)
        }
        #expect(gate.peak <= 4)
    }

    @Test func originalPreviewsRemainIndependentOfSaturatedThumbnailLoadsAndCache() async throws {
        let gate = ThumbnailGate()
        defer { gate.finishAll() }
        let image = NSImage(size: NSSize(width: 32, height: 32))
        var previews = 0
        let context = context(gate: gate, preview: { _ in previews += 1; return image })
        let tasks = (0..<4).map { id in Task { await context.image(String(id)) } }
        try #require(await gate.waitForStarts(4))
        #expect(await context.previewImage("original") === image)
        #expect(await context.previewImage("original") === image)
        #expect(previews == 2)
        #expect(gate.ids.count == 4)
        gate.finishAll()
        for task in tasks { _ = await task.value }
    }
}

/// Bounded waits keep a broken implementation from hanging the whole package test run.
@MainActor
private final class ThumbnailSignal {
    private var signalled = false
    private var waiters: [UUID: (CheckedContinuation<Bool, Never>, Task<Void, Never>)] = [:]

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for (continuation, deadline) in pending.values {
            deadline.cancel()
            continuation.resume(returning: true)
        }
    }

    func wait() async -> Bool {
        if signalled { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.waiters.removeValue(forKey: id)?.0.resume(returning: false)
            }
            waiters[id] = (continuation, deadline)
        }
    }
}

/// Intentionally ignores cancellation and can return a stale image after it, like an in-flight IPC.
@MainActor
private final class ThumbnailGate {
    private(set) var ids: [String] = []
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var cancelled: Set<Int> = []
    private var finishes = 0
    private var draining = false
    private var pending: [Int: CheckedContinuation<NSImage?, Never>] = [:]
    private var starts: [Int: ThumbnailSignal] = [:]
    private var ends: [Int: ThumbnailSignal] = [:]
    private var cancellations: [Int: ThumbnailSignal] = [:]

    func load(_ blobID: String) async -> NSImage? {
        let index = ids.count
        ids.append(blobID)
        active += 1
        peak = max(peak, active)
        let result: NSImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if draining { continuation.resume(returning: nil) } else { pending[index] = continuation }
                starts[ids.count]?.signal()
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelled.insert(index)
                self.cancellations[index]?.signal()
            }
        }
        active -= 1
        finishes += 1
        ends[finishes]?.signal()
        return result
    }

    func waitForStarts(_ count: Int) async -> Bool {
        if ids.count >= count { return true }
        let signal = starts[count, default: ThumbnailSignal()]
        starts[count] = signal
        return await signal.wait()
    }

    func waitForFinishes(_ count: Int) async -> Bool {
        if finishes >= count { return true }
        let signal = ends[count, default: ThumbnailSignal()]
        ends[count] = signal
        return await signal.wait()
    }

    func waitForCancellation(_ index: Int) async -> Bool {
        if cancelled.contains(index) { return true }
        let signal = cancellations[index, default: ThumbnailSignal()]
        cancellations[index] = signal
        return await signal.wait()
    }

    func finish(_ index: Int, with image: NSImage? = nil) {
        pending.removeValue(forKey: index)?.resume(returning: image)
    }

    func finishAll() {
        draining = true
        let requests = pending
        pending.removeAll()
        requests.values.forEach { $0.resume(returning: nil) }
    }
}
