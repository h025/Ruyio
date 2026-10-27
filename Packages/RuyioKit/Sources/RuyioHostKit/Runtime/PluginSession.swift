import Darwin
import Foundation
import RuyioCore
import RuyioProtocol

/// Facts the host binds to a session; the plugin cannot choose them (plan §8.3).
public struct SessionInfo: Sendable, Hashable {
    public var pluginID: PluginID
    public var manifest: PluginManifest
    public var runtimeMode: RuntimeMode
    public var dataGeneration: Int
    public var isDevelopment: Bool

    public init(pluginID: PluginID, manifest: PluginManifest, runtimeMode: RuntimeMode, dataGeneration: Int, isDevelopment: Bool) {
        self.pluginID = pluginID
        self.manifest = manifest
        self.runtimeMode = runtimeMode
        self.dataGeneration = dataGeneration
        self.isDevelopment = isDevelopment
    }

    public func declares(_ permission: Permission) -> Bool { manifest.permissions.contains(permission) }
}

/// Host-side handling of plugin-initiated requests and events.
public protocol PluginServiceHandler: AnyObject, Sendable {
    func handleRequest(_ envelope: Envelope, session: SessionInfo) async throws -> JSONValue
    func handleEvent(_ envelope: Envelope, session: SessionInfo)
}

/// One running plugin process with an authenticated, versioned channel.
public final class PluginSession: @unchecked Sendable {
    public let info: SessionInfo
    public let executable: URL
    public private(set) var negotiatedIPC: Int = 0
    public private(set) var negotiatedUISchema: Int = 0

    private let lock = NSLock()
    private var process: PluginProcess?
    private var peer: RPCPeer?
    private var terminationHandlers: [@Sendable (RuyioError?) -> Void] = []
    private var terminated = false
    private var terminationReason: RuyioError?
    private var stopping = false
    private weak var services: PluginServiceHandler?
    private var _lastActivity = ContinuousClock.now

    public static let handshakeTimeout: Duration = .seconds(3)
    /// First launch of a sandboxed bundle creates its container; allow more time once (plan §8.1 table).
    public static let firstLaunchHandshakeTimeout: Duration = .seconds(15)
    public static let stopGrace: Duration = .seconds(2)

    public init(info: SessionInfo, executable: URL, services: PluginServiceHandler) {
        self.info = info
        self.executable = executable
        self.services = services
    }

    public var pid: pid_t? { lock.withLock { process?.pid } }
    public var isAlive: Bool { lock.withLock { !terminated && peer != nil } }
    public var lastActivity: ContinuousClock.Instant { lock.withLock { _lastActivity } }

    /// Runs immediately when the session has already ended, so a fast crash is never missed.
    public func onTermination(_ handler: @escaping @Sendable (RuyioError?) -> Void) {
        let (ended, reason) = lock.withLock { () -> (Bool, RuyioError?) in
            if terminated { return (true, terminationReason) }
            terminationHandlers.append(handler)
            return (false, nil)
        }
        if ended { handler(reason) }
    }

    /// Spawns the process and completes the handshake, or throws and leaves nothing running.
    public func start(locale: String, firstLaunch: Bool = false) async throws {
        let process = try PluginProcess.spawn(executable: executable, options: .init(locale: locale))
        let peer = RPCPeer(readFD: process.readFD, writeFD: process.writeFD, label: info.pluginID.rawValue)
        lock.withLock {
            self.process = process
            self.peer = peer
        }
        process.onExit { [weak self] status in
            self?.didTerminate(RuyioError(.pluginCrashed, objectID: self?.info.pluginID.rawValue, diagnostic: "exit status \(status)"))
        }
        let info = self.info
        peer.start(
            allowIncoming: { method, kind in
                switch kind {
                case .response: return true
                case .event: return Method.pluginToHostEvents.contains(method)
                case .request: return method.hasPrefix(Method.storagePrefix) || method.hasPrefix(Method.capabilityPrefix)
                }
            },
            onRequest: { [weak self] envelope in
                guard let self, let services = self.services else { throw RuyioError(.internalError) }
                self.touch()
                return try await services.handleRequest(envelope, session: info)
            },
            onEvent: { [weak self] envelope in
                guard let self else { return }
                self.touch()
                self.services?.handleEvent(envelope, session: info)
            },
            onClose: { [weak self] reason in
                self?.channelClosed(reason)
            }
        )

        let nonce = UUID().uuidString
        let hello = HelloRequest(nonce: nonce, hostVersion: HostInfo.version, ipcVersions: HostInfo.supportedIPCVersions,
                                 uiSchemaVersions: HostInfo.supportedUISchemaVersions, expectedPluginID: info.pluginID,
                                 locale: locale, runtimeMode: info.runtimeMode)
        do {
            let reply = try await peer.request(Method.hello, hello, as: HelloReply.self,
                                         timeout: firstLaunch ? Self.firstLaunchHandshakeTimeout : Self.handshakeTimeout)
            // The self-reported ID never replaces signature checks; it must merely agree with them.
            guard reply.nonce == nonce, reply.pluginID == info.pluginID, reply.version == info.manifest.version,
                  HostInfo.supportedIPCVersions.contains(reply.ipcVersion),
                  HostInfo.supportedUISchemaVersions.contains(reply.uiSchemaVersion) else {
                throw RuyioError(.handshakeFailed, objectID: info.pluginID.rawValue, diagnostic: "hello mismatch")
            }
            negotiatedIPC = reply.ipcVersion
            negotiatedUISchema = reply.uiSchemaVersion
        } catch let error as RuyioError {
            await kill()
            if error.code == .requestTimeout { throw RuyioError(.handshakeTimeout, objectID: info.pluginID.rawValue, retryable: true) }
            throw error
        }
        touch()
    }

    // MARK: Requests to the plugin

    public func invoke(_ invocation: ActionInvocation, execution: ExecutionID, operation: OperationID?, registryGeneration: Int,
                       timeout: Duration = .seconds(10)) async throws -> ActionResult {
        let peer = try activePeer()
        touch()
        defer { touch() }
        let value = try await peer.request(Method.actionInvoke, payload: JSONCoding.value(invocation), executionID: execution,
                                           operationID: operation, registryGeneration: registryGeneration, timeout: timeout)
        return try JSONCoding.decode(ActionResult.self, from: value)
    }

    public func cancel(_ execution: ExecutionID) {
        peer?.send(event: Method.actionCancel, executionID: execution)
    }

    public func openView(_ request: ViewOpenRequest) async throws -> ViewDocument {
        let peer = try activePeer()
        touch()
        let document = try await peer.request(Method.viewOpen, request, as: ViewDocument.self)
        try UISchemaLimits.validate(document)
        return document
    }

    public func viewEvent(_ request: ViewEventRequest) async throws -> ViewEventReply {
        let peer = try activePeer()
        touch()
        let reply = try await peer.request(Method.viewEvent, request, as: ViewEventReply.self)
        if let document = reply.document { try UISchemaLimits.validate(document) }
        return reply
    }

    public func closeView(_ viewID: String) {
        peer?.send(event: Method.viewClose, payload: ["viewID": .string(viewID)])
    }

    public func dynamicItems(provider: String) async throws -> DynamicItemsReport {
        let peer = try activePeer()
        return try await peer.request(Method.dynamicItems, ["provider": provider], as: DynamicItemsReport.self)
    }

    public func sendLocale(_ locale: String) {
        peer?.send(event: Method.localeChanged, payload: ["locale": .string(locale)])
    }

    public func sendSettings(_ settings: [String: JSONValue]) {
        peer?.send(event: Method.settingsChanged, payload: .object(settings))
    }

    public func ping() async -> Bool {
        guard let peer = try? activePeer() else { return false }
        return (try? await peer.request(Method.lifecyclePing, timeout: .seconds(2))) == .bool(true)
    }

    /// Graceful stop: ask, wait, then escalate (plan §8.1 table).
    public func stop() async {
        let (peer, process) = lock.withLock { () -> (RPCPeer?, PluginProcess?) in
            stopping = true
            return (self.peer, self.process)
        }
        if let peer, !peer.isClosed {
            _ = try? await peer.request(Method.lifecycleShutdown, timeout: Self.stopGrace)
        }
        peer?.close()
        await process?.terminate(grace: Self.stopGrace)
    }

    /// Immediate termination for hung or misbehaving plugins.
    public func kill() async {
        let (peer, process) = lock.withLock { (self.peer, self.process) }
        peer?.close()
        await process?.terminate(grace: .milliseconds(200))
    }

    /// Closes only the pipes, leaving the process to notice EOF on its own (simulates host death).
    func closeChannelForTesting() async {
        let peer = lock.withLock { () -> RPCPeer? in
            stopping = true
            return self.peer
        }
        peer?.close()
    }

    // MARK: Internals

    private func activePeer() throws -> RPCPeer {
        try lock.withLock {
            guard !terminated, let peer, !peer.isClosed else {
                throw RuyioError(.pluginCrashed, objectID: info.pluginID.rawValue, retryable: true)
            }
            return peer
        }
    }

    private func touch() {
        lock.withLock { _lastActivity = .now }
    }

    /// EOF alone does not say whether the plugin crashed; decide from the exit status, and kill a
    /// process that closed its channel but keeps running.
    private func channelClosed(_ reason: RuyioError?) {
        let (isStopping, process) = lock.withLock { (stopping, self.process) }
        if let reason { didTerminate(reason); return }
        if isStopping { didTerminate(nil); return }
        guard let process else { didTerminate(nil); return }
        let id = info.pluginID.rawValue
        process.onExit { [weak self] status in
            self?.didTerminate(RuyioError(.pluginCrashed, objectID: id, retryable: true, diagnostic: "unexpected exit status \(status)"))
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            if !process.hasExited { await process.terminate(grace: .milliseconds(200)) }
        }
    }

    private func didTerminate(_ reason: RuyioError?) {
        let (handlers, process, peer, wasStopping): ([@Sendable (RuyioError?) -> Void], PluginProcess?, RPCPeer?, Bool) = lock.withLock {
            if terminated { return ([], nil, nil, stopping) }
            terminated = true
            terminationReason = stopping ? nil : reason
            let handlers = terminationHandlers
            terminationHandlers.removeAll()
            return (handlers, self.process, self.peer, stopping)
        }
        peer?.close()
        if let process, !process.hasExited {
            Task { await process.terminate(grace: .milliseconds(500)) }
        }
        let error = wasStopping ? nil : reason
        for handler in handlers { handler(error) }
    }
}
