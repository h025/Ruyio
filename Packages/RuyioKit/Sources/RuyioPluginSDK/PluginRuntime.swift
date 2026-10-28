import Darwin
import Foundation
import RuyioCore
import RuyioProtocol

/// Plugin process entry point. Owns the IPC channel and the process lifetime.
public enum PluginRuntime {
    public static let sdkVersion = "1.0.0-experimental"

    /// Runs the plugin until the host closes the channel. Never returns.
    ///
    /// stdin/stdout are moved to private descriptors and fd 1 is pointed at /dev/null so a stray
    /// `print` can never corrupt the frame stream (plan §8.2: logs must not go to stdout).
    public static func run<P: RuyioPlugin>(_ type: P.Type, manifest explicitManifest: PluginManifest? = nil) -> Never {
        let readFD = dup(STDIN_FILENO)
        let writeFD = dup(STDOUT_FILENO)
        let devNull = open("/dev/null", O_RDWR)
        if devNull >= 0 {
            dup2(devNull, STDIN_FILENO)
            dup2(devNull, STDOUT_FILENO)
            if devNull > STDERR_FILENO { close(devNull) }
        }
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)

        guard readFD >= 0, writeFD >= 0, let manifest = explicitManifest ?? loadBundledManifest() else {
            _exit(EX_CONFIG)
        }

        let peer = RPCPeer(readFD: readFD, writeFD: writeFD, label: manifest.id.rawValue)
        let host = PluginHost<P>(manifest: manifest, peer: peer)
        host.start()
        // AppKit services such as NSPasteboard and timers need a running main run loop.
        RunLoop.main.run()
        _exit(0)
    }

    /// Reads `Contents/Resources/manifest.json` of the running bundle.
    public static func loadBundledManifest(bundle: Bundle = .main) -> PluginManifest? {
        guard let url = bundle.url(forResource: "manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? ManifestValidator.decode(data)
    }
}

/// Dispatches host messages to the plugin instance.
final class PluginHost<P: RuyioPlugin>: @unchecked Sendable {
    private let manifest: PluginManifest
    private let peer: RPCPeer
    private let lock = NSLock()
    private var plugin: P?
    private var context: PluginContext?
    private var handshakeDone = false
    private var running: [ExecutionID: Task<ActionResult, Never>] = [:]

    init(manifest: PluginManifest, peer: RPCPeer) {
        self.manifest = manifest
        self.peer = peer
    }

    func start() {
        peer.start(
            allowIncoming: { method, kind in
                switch kind {
                case .request:
                    return [Method.hello, Method.actionInvoke, Method.viewOpen, Method.viewEvent, Method.dynamicItems,
                            Method.lifecycleShutdown, Method.lifecyclePing, Method.lifecycleMigrate, Method.lifecycleHealth].contains(method)
                case .event:
                    return [Method.actionCancel, Method.viewClose, Method.localeChanged, Method.settingsChanged].contains(method)
                case .response:
                    return true
                }
            },
            onRequest: { [self] envelope in try await handleRequest(envelope) },
            onEvent: { [self] envelope in handleEvent(envelope) },
            onClose: { _ in
                // Host gone: stop immediately, even if the main thread is blocked (plan §8.1).
                _exit(0)
            }
        )
    }

    private func requireReady() throws -> (P, PluginContext) {
        lock.lock(); defer { lock.unlock() }
        guard handshakeDone, let plugin, let context else {
            throw RuyioError(.handshakeFailed, diagnostic: "request before hello")
        }
        return (plugin, context)
    }

    private func handleRequest(_ envelope: Envelope) async throws -> JSONValue {
        switch envelope.method {
        case Method.hello:
            return try await hello(envelope)
        case Method.lifecyclePing:
            return .bool(true)
        case Method.lifecycleMigrate, Method.lifecycleHealth:
            let (plugin, context) = try requireReady()
            let request = try JSONCoding.decode(DataPreparationRequest.self, from: envelope.payload)
            guard request.sourceSchemaVersion >= 0, request.targetSchemaVersion == manifest.storageSchemaVersion else {
                throw RuyioError(.invalidRequest, diagnostic: "data preparation schema mismatch")
            }
            if envelope.method == Method.lifecycleMigrate {
                guard context.runtimeMode == .migration else { throw RuyioError(.permissionDenied) }
                try await plugin.migrateData(request)
            } else {
                guard context.runtimeMode == .health else { throw RuyioError(.permissionDenied) }
                try await plugin.checkHealth(request)
            }
            return .bool(true)
        case Method.lifecycleShutdown:
            if let plugin = lock.withLock({ self.plugin }) { await plugin.shutdown() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { _exit(0) }
            return .bool(true)
        case Method.actionInvoke:
            let (plugin, _) = try requireReady()
            let invocation = try JSONCoding.decode(ActionInvocation.self, from: envelope.payload)
            guard manifest.action(invocation.actionID) != nil else {
                throw RuyioError(.actionNotFound, objectID: invocation.actionID.rawValue)
            }
            let execution = envelope.executionID ?? ExecutionID()
            let operation = envelope.operationID
            let task = Task<ActionResult, Never> {
                do {
                    return try await plugin.perform(invocation, execution: execution, operation: operation)
                } catch is CancellationError {
                    return ActionResult(state: .cancelled)
                } catch let error as RuyioError {
                    var e = error
                    e.executionID = execution
                    return .failed(e)
                } catch {
                    return .failed(RuyioError(.actionFailed, executionID: execution, diagnostic: String(describing: error)))
                }
            }
            lock.withLock { running[execution] = task }
            let result = await task.value
            lock.withLock { running[execution] = nil }
            return try JSONCoding.value(result)
        case Method.viewOpen:
            let (plugin, _) = try requireReady()
            let request = try JSONCoding.decode(ViewOpenRequest.self, from: envelope.payload)
            let document = try await plugin.openView(request)
            try UISchemaLimits.validate(document)
            return try JSONCoding.value(document)
        case Method.viewEvent:
            let (plugin, _) = try requireReady()
            let request = try JSONCoding.decode(ViewEventRequest.self, from: envelope.payload)
            let reply = try await plugin.handleViewEvent(request)
            if let document = reply.document { try UISchemaLimits.validate(document) }
            return try JSONCoding.value(reply)
        case Method.dynamicItems:
            let (plugin, _) = try requireReady()
            let provider = envelope.payload["provider"]?.stringValue ?? ""
            return try JSONCoding.value(try await plugin.dynamicItems(provider: provider))
        default:
            throw RuyioError(.invalidRequest, diagnostic: envelope.method)
        }
    }

    private func hello(_ envelope: Envelope) async throws -> JSONValue {
        let request = try JSONCoding.decode(HelloRequest.self, from: envelope.payload)
        guard request.expectedPluginID == manifest.id else {
            throw RuyioError(.handshakeFailed, diagnostic: "plugin id mismatch")
        }
        guard let ipc = negotiateVersion(host: request.ipcVersions, plugin: manifest.supportedIPC),
              let schema = negotiateVersion(host: request.uiSchemaVersions, plugin: manifest.supportedUISchema) else {
            throw RuyioError(.incompatibleProtocol)
        }
        let context = PluginContext(manifest: manifest, peer: peer, locale: request.locale, runtimeMode: request.runtimeMode)
        let plugin = P(context: context)
        lock.withLock {
            self.context = context
            self.plugin = plugin
            self.handshakeDone = true
        }
        if request.runtimeMode == .normal {
            Task { await plugin.start() }
        }
        return try JSONCoding.value(HelloReply(nonce: request.nonce, pluginID: manifest.id, version: manifest.version,
                                               ipcVersion: ipc, uiSchemaVersion: schema, sdkVersion: PluginRuntime.sdkVersion))
    }

    private func handleEvent(_ envelope: Envelope) {
        switch envelope.method {
        case Method.actionCancel:
            if let id = envelope.executionID { lock.withLock { running[id] }?.cancel() }
        case Method.viewClose:
            guard let plugin = lock.withLock({ self.plugin }), let id = envelope.payload["viewID"]?.stringValue else { return }
            Task { await plugin.closeView(id) }
        case Method.localeChanged:
            guard let plugin = lock.withLock({ self.plugin }), let locale = envelope.payload["locale"]?.stringValue else { return }
            lock.withLock { context }?.update(locale: locale)
            Task { await plugin.localeChanged(locale) }
        case Method.settingsChanged:
            guard let plugin = lock.withLock({ self.plugin }), let settings = envelope.payload.objectValue else { return }
            lock.withLock { context }?.update(settings: settings)
            Task { await plugin.settingsChanged(settings) }
        default:
            break
        }
    }
}
