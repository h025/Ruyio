import AppKit

/// Bounds thumbnail work before the host reads blob data, independently of the completed-image cache.
@MainActor
final class ImageLoadScheduler {
    private struct Request: Sendable {
        let id: UUID
        var waiters: [UUID: ImageLoadWaiter]
    }

    private let loader: (String) async -> NSImage?
    private let limit: Int
    private var cache = ImageMemoryCache()
    private var requests: [String: Request] = [:]
    private var queue: [(id: UUID, blobID: String)] = []
    private var active: [UUID: Task<Void, Never>] = [:]

    init(limit: Int = 4, loader: @escaping (String) async -> NSImage?) {
        self.limit = max(1, limit)
        self.loader = loader
    }

    deinit {
        active.values.forEach { $0.cancel() }
        for request in requests.values {
            request.waiters.values.forEach { _ = $0.finish(nil) }
        }
    }

    func image(_ blobID: String) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cache.image(for: blobID) { return image }
        let waiter = ImageLoadWaiter()
        let image = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard waiter.install(continuation) else { return }
                enqueue(blobID, waiter: waiter)
            }
        } onCancel: { [weak self] in
            // Resolve independently of MainActor cleanup, including cancellation before registration.
            waiter.cancel()
            Task { @MainActor [weak self] in self?.removeWaiter(blobID, waiterID: waiter.id) }
        }
        return Task.isCancelled ? nil : image
    }

    private func enqueue(_ blobID: String, waiter: ImageLoadWaiter) {
        guard !waiter.isCancelled else { return }
        if let request = requests[blobID], request.waiters.values.contains(where: { !$0.isCancelled }) {
            requests[blobID]?.waiters[waiter.id] = waiter
        } else {
            // The cancellation callback may still be waiting on MainActor. Never join its old task.
            if let previous = requests.removeValue(forKey: blobID) { abandon(previous) }
            let request = Request(id: UUID(), waiters: [waiter.id: waiter])
            requests[blobID] = request
            queue.append((request.id, blobID))
        }
        startAvailable()
    }

    private func removeWaiter(_ blobID: String, waiterID: UUID) {
        guard var request = requests[blobID], request.waiters.removeValue(forKey: waiterID) != nil else { return }
        request.waiters = request.waiters.filter { !$0.value.isCancelled }
        if request.waiters.isEmpty {
            requests.removeValue(forKey: blobID)
            abandon(request)
        } else {
            requests[blobID] = request
        }
    }

    private func abandon(_ request: Request) {
        queue.removeAll { $0.id == request.id }
        // A noncooperative loader still occupies its slot until it actually returns.
        active[request.id]?.cancel()
    }

    private func startAvailable() {
        while active.count < limit, !queue.isEmpty {
            let next = queue.removeFirst()
            guard let request = requests[next.blobID], request.id == next.id else { continue }
            guard request.waiters.values.contains(where: { !$0.isCancelled }) else {
                requests.removeValue(forKey: next.blobID)
                continue
            }
            let loader = self.loader
            active[next.id] = Task { @MainActor [weak self] in
                let image: NSImage?
                if Task.isCancelled { image = nil } else { image = await loader(next.blobID) }
                self?.complete(next.blobID, requestID: next.id, image: image)
            }
        }
    }

    private func complete(_ blobID: String, requestID: UUID, image: NSImage?) {
        active.removeValue(forKey: requestID)
        defer { startAvailable() }
        guard let request = requests[blobID], request.id == requestID else { return }
        requests.removeValue(forKey: blobID)
        var delivered = false
        for waiter in request.waiters.values {
            if waiter.finish(image) { delivered = true }
        }
        // An abandoned generation cannot populate the cache or replace a later retry's result.
        if delivered, let image { cache.insert(image, for: blobID) }
    }
}

/// The continuation and cancellation flag share a lock because onCancel can run on any executor.
private final class ImageLoadWaiter: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<NSImage?, Never>?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func install(_ continuation: CheckedContinuation<NSImage?, Never>) -> Bool {
        let accepted = lock.withLock {
            guard !cancelled else { return false }
            self.continuation = continuation
            return true
        }
        if !accepted { continuation.resume(returning: nil) }
        return accepted
    }

    func cancel() {
        let pending = lock.withLock {
            cancelled = true
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: nil)
    }

    /// Returns whether completion won the race with cancellation for an installed consumer.
    @discardableResult
    func finish(_ image: NSImage?) -> Bool {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: image)
        return pending != nil
    }
}
