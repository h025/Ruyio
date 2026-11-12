import AppKit
import Foundation

@objc(RuyioMediaDecoding) protocol RuyioMediaDecoding {
    func decodeThumbnail(_ data: Data, maxPixel: Int, reply: @escaping (Data?, Int, Int) -> Void)
}

private typealias DecodedPixels = (Data?, Int, Int)

/// Host side of the sandboxed media decoder (R43). Untrusted bytes are decoded only by the service;
/// the host validates and wraps its fixed-format BGRA buffer, or returns a placeholder on failure.
public final class MediaDecoderClient: @unchecked Sendable {
    public static let shared = MediaDecoderClient()
    private struct Connection {
        let id: UUID
        let value: NSXPCConnection
    }
    private let lock = NSLock()
    private var connection: Connection?
    private let connectionFactory: @Sendable () -> NSXPCConnection
    private let deadlineClock: DeadlineClock

    struct DeadlineClock: Sendable {
        var now: @Sendable () -> ContinuousClock.Instant
        var sleep: @Sendable (ContinuousClock.Instant) async throws -> Void

        static let continuous = DeadlineClock(now: { .now }, sleep: { deadline in
            try await ContinuousClock().sleep(until: deadline)
        })
    }

    init(connectionFactory: @escaping @Sendable () -> NSXPCConnection = {
        NSXPCConnection(serviceName: "app.ruyio.mac.MediaDecoder")
    }, deadlineClock: DeadlineClock = .continuous) {
        self.connectionFactory = connectionFactory
        self.deadlineClock = deadlineClock
    }

    deinit { connection?.value.invalidate() }

    private func proxy(_ onError: @escaping (Error) -> Void) -> (RuyioMediaDecoding, UUID)? {
        let connection = lock.withLock { () -> Connection in
            if let connection { return connection }
            let id = UUID()
            let value = connectionFactory()
            value.remoteObjectInterface = NSXPCInterface(with: RuyioMediaDecoding.self)
            value.invalidationHandler = { [weak self] in _ = self?.removeConnection(id) }
            let created = Connection(id: id, value: value)
            self.connection = created
            value.resume()
            return created
        }
        // Proxy errors may precede invalidation delivery. A retry must already see a fresh connection.
        // Fetch outside the lock so even a synchronous error callback cannot re-enter that lock.
        let id = connection.id
        let decoder = connection.value.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.removeConnection(id)?.invalidate()
            onError(error)
        } as? RuyioMediaDecoding
        return decoder.map { ($0, id) }
    }

    /// A delayed callback from a discarded connection must never remove its replacement.
    private func removeConnection(_ id: UUID) -> NSXPCConnection? {
        lock.withLock {
            guard connection?.id == id else { return nil }
            defer { connection = nil }
            return connection?.value
        }
    }

    public func image(from data: Data, maxPixel: Int = 1024) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let limit = max(16, min(maxPixel, 8192))
        let deadline = deadlineClock.now() + .seconds(5)
        let operation = DecodeOperation()
        let result: DecodedPixels = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard operation.begin(continuation) else { return }
                guard let (decoder, connectionID) = proxy({ _ in operation.finish() }) else {
                    operation.finish()
                    return
                }
                operation.startDeadline(at: deadline, clock: deadlineClock) { [weak self] in
                    // Remove the stuck connection before resuming the caller, so its retry uses a new one.
                    self?.removeConnection(connectionID)?.invalidate()
                }
                guard operation.isPending else { return }
                decoder.decodeThumbnail(data, maxPixel: limit) { pixels, width, height in
                    operation.finish((pixels, width, height))
                }
            }
        } onCancel: {
            // This only abandons this reply; other consumers keep using the shared XPC connection.
            operation.finish()
        }
        let (pixels, width, height) = result
        guard !Task.isCancelled, let pixels, width > 0, height > 0, width <= limit, height <= limit,
              pixels.count == width * height * 4,
              let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    /// Owns one continuation and its deadline, including cancellation before registration or scheduling.
    private final class DecodeOperation: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var continuation: CheckedContinuation<DecodedPixels, Never>?
        private var deadlineTask: Task<Void, Never>?

        var isPending: Bool { lock.withLock { !completed } }

        func begin(_ continuation: CheckedContinuation<DecodedPixels, Never>) -> Bool {
            let accepted = lock.withLock {
                guard !completed else { return false }
                self.continuation = continuation
                return true
            }
            if !accepted { continuation.resume(returning: (nil, 0, 0)) }
            return accepted
        }

        func startDeadline(at deadline: ContinuousClock.Instant, clock: DeadlineClock,
                           onTimeout: @escaping @Sendable () -> Void) {
            lock.withLock {
                guard !completed else { return }
                deadlineTask = Task<Void, Never> { [weak self] in
                    do { try await clock.sleep(deadline) }
                    catch { return }
                    self?.finish(beforeResume: onTimeout)
                }
            }
        }

        @discardableResult
        func finish(_ result: DecodedPixels = (nil, 0, 0), beforeResume: (() -> Void)? = nil) -> Bool {
            let waiting = lock.withLock { () -> (CheckedContinuation<DecodedPixels, Never>?, Task<Void, Never>?)? in
                guard !completed else { return nil }
                completed = true
                defer { continuation = nil; deadlineTask = nil }
                return (continuation, deadlineTask)
            }
            guard let (continuation, deadlineTask) = waiting else { return false }
            deadlineTask?.cancel()
            beforeResume?()
            continuation?.resume(returning: result)
            return true
        }
    }
}
