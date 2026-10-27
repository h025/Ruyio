import Darwin
import Foundation
import RuyioCore

/// Bidirectional length-prefixed JSON RPC over a pair of file descriptors (anonymous pipes).
///
/// Reading happens on a dedicated thread so EOF is noticed even when the owner's main thread is
/// blocked (plan §8.1: a plugin stuck in a promised-pasteboard read must still exit when the host dies).
public final class RPCPeer: @unchecked Sendable {
    public typealias RequestHandler = @Sendable (Envelope) async throws -> JSONValue
    public typealias EventHandler = @Sendable (Envelope) -> Void
    public typealias CloseHandler = @Sendable (RuyioError?) -> Void

    public let label: String
    public let maxInFlight: Int

    private let readFD: Int32
    private let writeFD: Int32
    private let lock = NSLock()
    private let writeQueue: DispatchQueue
    private var pending: [String: CheckedContinuation<Envelope, Error>] = [:]
    private var closed = false
    private var started = false
    private var onRequest: RequestHandler?
    private var onEvent: EventHandler?
    private var onClose: CloseHandler?
    private var allowedIncoming: (@Sendable (String, Envelope.Kind) -> Bool)?

    public init(readFD: Int32, writeFD: Int32, label: String, maxInFlight: Int = 16) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.label = label
        self.maxInFlight = maxInFlight
        self.writeQueue = DispatchQueue(label: "ruyio.rpc.write.\(label)")
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
    }

    /// Starts the reader thread. Handlers run on arbitrary threads.
    public func start(
        allowIncoming: (@Sendable (String, Envelope.Kind) -> Bool)? = nil,
        onRequest: @escaping RequestHandler,
        onEvent: @escaping EventHandler,
        onClose: @escaping CloseHandler
    ) {
        lock.lock()
        precondition(!started, "RPCPeer started twice")
        started = true
        self.allowedIncoming = allowIncoming
        self.onRequest = onRequest
        self.onEvent = onEvent
        self.onClose = onClose
        lock.unlock()

        let thread = Thread { [self] in readLoop() }
        thread.name = "ruyio.rpc.read.\(label)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    // MARK: Sending

    public func request(
        _ method: String, payload: JSONValue = .null, executionID: ExecutionID? = nil,
        operationID: OperationID? = nil, registryGeneration: Int? = nil, timeout: Duration = .seconds(10)
    ) async throws -> JSONValue {
        let envelope = Envelope(kind: .request, method: method, executionID: executionID, operationID: operationID,
                                registryGeneration: registryGeneration, payload: payload)
        let reply: Envelope = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: RuyioError(.pluginCrashed, diagnostic: "connection closed"))
                return
            }
            if pending.count >= maxInFlight {
                lock.unlock()
                continuation.resume(throwing: RuyioError(.invalidRequest, retryable: true, diagnostic: "too many in-flight requests"))
                return
            }
            pending[envelope.messageID] = continuation
            lock.unlock()

            do {
                try write(envelope)
            } catch {
                failPending(envelope.messageID, error: error)
                return
            }
            let id = envelope.messageID
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.failPending(id, error: RuyioError(.requestTimeout, retryable: true, diagnostic: method))
            }
        }
        if let error = reply.error { throw error }
        return reply.payload
    }

    public func request<P: Encodable, R: Decodable>(
        _ method: String, _ payload: P, as: R.Type, executionID: ExecutionID? = nil,
        operationID: OperationID? = nil, timeout: Duration = .seconds(10)
    ) async throws -> R {
        let value = try await request(method, payload: JSONCoding.value(payload), executionID: executionID,
                                      operationID: operationID, timeout: timeout)
        do {
            return try JSONCoding.decode(R.self, from: value)
        } catch {
            throw RuyioError(.invalidRequest, diagnostic: "undecodable reply to \(method)")
        }
    }

    public func send(event method: String, payload: JSONValue = .null, executionID: ExecutionID? = nil) {
        let envelope = Envelope(kind: .event, method: method, executionID: executionID, payload: payload)
        try? write(envelope)
    }

    public func send<P: Encodable>(event method: String, _ payload: P, executionID: ExecutionID? = nil) {
        guard let value = try? JSONCoding.value(payload) else { return }
        send(event: method, payload: value, executionID: executionID)
    }

    /// Closes both descriptors and fails all pending requests.
    public func close(reason: RuyioError? = nil) {
        let handler: CloseHandler?
        let waiting: [CheckedContinuation<Envelope, Error>]
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        waiting = Array(pending.values)
        pending.removeAll()
        handler = onClose
        lock.unlock()

        Darwin.close(readFD)
        writeQueue.sync { _ = Darwin.close(writeFD) }
        let error = reason ?? RuyioError(.pluginCrashed, diagnostic: "connection closed")
        for continuation in waiting { continuation.resume(throwing: error) }
        handler?(reason)
    }

    // MARK: Internals

    private func write(_ envelope: Envelope) throws {
        let frame = try Framing.encode(envelope)
        var failure: Error?
        writeQueue.sync {
            frame.withUnsafeBytes { raw in
                guard var pointer = raw.baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let written = Darwin.write(writeFD, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        failure = RuyioError(.pluginCrashed, diagnostic: "write failed errno=\(errno)")
                        return
                    }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
            }
        }
        if let failure {
            close(reason: failure as? RuyioError)
            throw failure
        }
    }

    private func failPending(_ id: String, error: Error) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func readLoop() {
        var decoder = FrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
            if count == 0 { close(reason: nil); return }
            if count < 0 {
                if errno == EINTR { continue }
                close(reason: isClosed ? nil : RuyioError(.pluginCrashed, diagnostic: "read failed errno=\(errno)"))
                return
            }
            decoder.append(Data(buffer[0..<count]))
            do {
                while let envelope = try decoder.next() { dispatch(envelope) }
            } catch let error as RuyioError {
                // Decoding violations end only this session (plan §8.2).
                close(reason: error)
                return
            } catch {
                close(reason: RuyioError(.invalidRequest))
                return
            }
        }
    }

    private func dispatch(_ envelope: Envelope) {
        lock.lock()
        let allowed = allowedIncoming
        let requestHandler = onRequest
        let eventHandler = onEvent
        lock.unlock()

        switch envelope.kind {
        case .response:
            guard let id = envelope.replyTo else { return }
            lock.lock()
            let continuation = pending.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(returning: envelope)
        case .event:
            guard allowed?(envelope.method, .event) ?? true else { return }
            eventHandler?(envelope)
        case .request:
            guard allowed?(envelope.method, .request) ?? true, let requestHandler else {
                reply(to: envelope, payload: .null, error: RuyioError(.invalidRequest, diagnostic: "method not allowed: \(envelope.method)"))
                return
            }
            Task {
                do {
                    let payload = try await requestHandler(envelope)
                    reply(to: envelope, payload: payload, error: nil)
                } catch let error as RuyioError {
                    reply(to: envelope, payload: .null, error: error)
                } catch {
                    reply(to: envelope, payload: .null, error: RuyioError(.internalError, diagnostic: String(describing: error)))
                }
            }
        }
    }

    private func reply(to request: Envelope, payload: JSONValue, error: RuyioError?) {
        let response = Envelope(kind: .response, method: request.method, replyTo: request.messageID,
                                executionID: request.executionID, operationID: request.operationID,
                                payload: payload, error: error)
        try? write(response)
    }
}
