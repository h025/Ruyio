import Foundation
import RuyioCore
import RuyioPersistence
import RuyioProtocol

/// System actions the host performs on a plugin's behalf. Implemented with AppKit by the app.
public protocol SystemBridge: AnyObject, Sendable {
    /// Writes items to the general pasteboard with a Ruyio origin marker; returns the new changeCount.
    func writePasteboard(_ items: [[String: Data]], originToken: String) async throws -> Int
    func openWebLink(_ url: URL) async throws
    func openTerminal(at directories: [URL]) async throws
    func open(_ targets: [URL], withApplicationBundleID bundleID: String) async throws
    func reveal(_ urls: [URL]) async
    /// Asks the user to confirm a batch before it runs (e.g. opening several Terminal windows).
    func confirmBatch(title: String, count: Int) async -> Bool
    /// Lets the user pick an application for a role; returns its bundle ID.
    func chooseApplication(role: String) async -> String?
    func toggleFinderHiddenFiles() async throws -> Bool
}

/// Opens per-plugin stores bound to the session's identity, mode and generation (plan §8.3).
public final class StoreProvider: @unchecked Sendable {
    private let paths: AppPaths
    private let lock = NSLock()
    private var stores: [String: PluginStore] = [:]
    private let identity: @Sendable (PluginID) -> String
    public var excludeFromBackup: @Sendable (PluginID) -> Bool

    public init(paths: AppPaths, identity: @escaping @Sendable (PluginID) -> String, excludeFromBackup: @escaping @Sendable (PluginID) -> Bool = { _ in true }) {
        self.paths = paths
        self.identity = identity
        self.excludeFromBackup = excludeFromBackup
    }

    public func store(pluginID: PluginID, generation: Int, development: Bool, readOnly: Bool = false) throws -> PluginStore {
        let directory = paths.dataDirectory(identity: identity(pluginID), generation: generation, development: development)
        let key = directory.path + (readOnly ? "#ro" : "")
        return try lock.withLock {
            if let store = stores[key] { return store }
            let store = try PluginStore(directory: directory, readOnly: readOnly)
            let root = directory.deletingLastPathComponent()
            try? BackupPolicy.setExcludedFromBackup(excludeFromBackup(pluginID), at: root)
            stores[key] = store
            return store
        }
    }

    public func store(for session: SessionInfo) throws -> PluginStore {
        try store(pluginID: session.pluginID, generation: session.dataGeneration, development: session.isDevelopment,
                  readOnly: session.runtimeMode == .health)
    }

    public func dataRoot(pluginID: PluginID, development: Bool) -> URL {
        (development ? paths.developmentDataRoot : paths.dataRoot).appendingPathComponent(identity(pluginID), isDirectory: true)
    }

    public func close(pluginID: PluginID) {
        let prefix = identity(pluginID)
        lock.withLock { stores = stores.filter { !$0.key.contains("/\(prefix)/") } }
    }
}

/// Routes plugin-initiated requests to storage and capability brokers after permission checks.
public final class HostServices: PluginServiceHandler, @unchecked Sendable {
    public let stores: StoreProvider
    public let fileBroker: FileBroker
    public let contexts: InvocationContexts
    private let database: HostDatabase
    private weak var bridge: SystemBridge?
    private let lock = NSLock()
    private var eventSinks: [@Sendable (Envelope, SessionInfo) -> Void] = []
    /// Blocking SQLite work runs here, never on the cooperative thread pool.
    private let storageQueue = DispatchQueue(label: "ruyio.storage", qos: .userInitiated, attributes: .concurrent)

    public init(stores: StoreProvider, fileBroker: FileBroker, contexts: InvocationContexts, database: HostDatabase, bridge: SystemBridge?) {
        self.stores = stores
        self.fileBroker = fileBroker
        self.contexts = contexts
        self.database = database
        self.bridge = bridge
    }

    public func setBridge(_ bridge: SystemBridge) { lock.withLock { self.bridge = bridge } }

    public func addEventSink(_ sink: @escaping @Sendable (Envelope, SessionInfo) -> Void) {
        lock.withLock { eventSinks.append(sink) }
    }

    public func handleEvent(_ envelope: Envelope, session: SessionInfo) {
        let sinks = lock.withLock { eventSinks }
        for sink in sinks { sink(envelope, session) }
    }

    public func handleRequest(_ envelope: Envelope, session: SessionInfo) async throws -> JSONValue {
        if envelope.method.hasPrefix(Method.storagePrefix) {
            return try await withCheckedThrowingContinuation { continuation in
                storageQueue.async {
                    continuation.resume(with: Result { try self.handleStorage(envelope, session: session) })
                }
            }
        }
        if envelope.method.hasPrefix(Method.capabilityPrefix) {
            // Migration and health sessions get no side-effect capabilities (plan §8.3).
            guard session.runtimeMode == .normal else {
                throw RuyioError(.permissionDenied, objectID: envelope.method, diagnostic: "not available in \(session.runtimeMode.rawValue) mode")
            }
            if let permission = CapabilityMethod.permission(for: envelope.method), !session.declares(permission) {
                throw RuyioError(.permissionNotDeclared, objectID: permission.rawValue)
            }
            return try await handleCapability(envelope, session: session)
        }
        throw RuyioError(.invalidRequest, diagnostic: envelope.method)
    }

    private func handleStorage(_ envelope: Envelope, session: SessionInfo) throws -> JSONValue {
        let store = try stores.store(for: session)
        let readOnly = session.runtimeMode == .health
        let writes: Set<String> = [StorageMethod.put, StorageMethod.delete, StorageMethod.batch, StorageMethod.blobPut]
        if readOnly && writes.contains(envelope.method) {
            throw RuyioError(.permissionDenied, diagnostic: "read-only health session")
        }
        do {
            switch envelope.method {
            case StorageMethod.put:
                try store.put(try JSONCoding.decode(StoredDocument.self, from: envelope.payload))
                return .null
            case StorageMethod.get:
                let key = try JSONCoding.decode(StorageKey.self, from: envelope.payload)
                guard let doc = try store.get(collection: key.collection, id: key.id) else { return .null }
                return try JSONCoding.value(doc)
            case StorageMethod.delete:
                let key = try JSONCoding.decode(StorageKey.self, from: envelope.payload)
                try store.delete(collection: key.collection, id: key.id)
                return .null
            case StorageMethod.query:
                return try JSONCoding.value(try store.query(try JSONCoding.decode(StorageQuery.self, from: envelope.payload)))
            case StorageMethod.count:
                return .number(Double(try store.count(try JSONCoding.decode(StorageQuery.self, from: envelope.payload))))
            case StorageMethod.batch:
                try store.batch(try JSONCoding.decode(StorageBatch.self, from: envelope.payload).operations)
                return .null
            case StorageMethod.blobPut:
                return try JSONCoding.value(try store.appendUpload(try JSONCoding.decode(BlobPutRequest.self, from: envelope.payload)))
            case StorageMethod.blobGet:
                return try JSONCoding.value(try store.readBlob(try JSONCoding.decode(BlobGetRequest.self, from: envelope.payload)))
            case StorageMethod.usage:
                return try JSONCoding.value(try store.usage())
            default:
                throw RuyioError(.invalidRequest, diagnostic: envelope.method)
            }
        } catch let error as RuyioError {
            throw error
        } catch is DecodingError {
            throw RuyioError(.invalidRequest, diagnostic: "malformed \(envelope.method)")
        } catch {
            throw RuyioError(.storageFailure, retryable: true, diagnostic: String(describing: error))
        }
    }

    private func handleCapability(_ envelope: Envelope, session: SessionInfo) async throws -> JSONValue {
        guard let bridge = lock.withLock({ self.bridge }) else { throw RuyioError(.internalError, diagnostic: "no system bridge") }
        let pluginID = session.pluginID
        switch envelope.method {
        case CapabilityMethod.clipboardWrite:
            let request = try JSONCoding.decode(ClipboardWriteRequest.self, from: envelope.payload)
            let store = try stores.store(for: session)
            var items: [[String: Data]] = []
            for item in request.items.prefix(256) {
                var representations: [String: Data] = [:]
                for rep in item.representations {
                    guard Self.isAllowedPasteboardType(rep.type) else { continue }
                    if let text = rep.text { representations[rep.type] = Data(text.utf8) }
                    else if let blob = rep.blobID { representations[rep.type] = try store.blobData(blob) }
                }
                if !representations.isEmpty { items.append(representations) }
            }
            guard !items.isEmpty else { throw RuyioError(.invalidRequest, diagnostic: "nothing to write") }
            let count = try await bridge.writePasteboard(items, originToken: request.originToken)
            return try JSONCoding.value(ClipboardWriteReply(changeCount: count))

        case CapabilityMethod.openWebLink:
            let request = try JSONCoding.decode(WebLinkRequest.self, from: envelope.payload)
            try await bridge.openWebLink(try Self.validatedWebLink(request.url))
            return .null

        case CapabilityMethod.openTerminalDirectory:
            let request = try JSONCoding.decode(DirectoryRequest.self, from: envelope.payload)
            // Terminal only ever receives directories: files map to their parent; links and packages are refused.
            let urls = try request.directories.map { try Self.terminalDirectory(for: try contexts.resolve($0, for: pluginID)) }
            let unique = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
            guard !unique.isEmpty else { throw RuyioError(.invalidRequest) }
            if unique.count > 1, !(await bridge.confirmBatch(title: "terminal", count: unique.count)) {
                throw RuyioError(.cancelled)
            }
            try await bridge.openTerminal(at: unique)
            return .null

        case CapabilityMethod.openInConfiguredApplication:
            let request = try JSONCoding.decode(ConfiguredApplicationRequest.self, from: envelope.payload)
            guard ["editor"].contains(request.role) else { throw RuyioError(.invalidRequest, diagnostic: "unknown role") }
            let urls = try request.targets.map { try contexts.resolve($0, for: pluginID) }
            let key = "app.\(request.role)"
            var bundleID = (try? database.pluginSettings(pluginID))?[key]?.stringValue
            if bundleID == nil {
                bundleID = await bridge.chooseApplication(role: request.role)
                if let chosen = bundleID { try database.setPluginSetting(pluginID, key: key, value: .string(chosen)) }
            }
            guard let bundleID else { throw RuyioError(.cancelled, recovery: .chooseApplication) }
            do {
                try await bridge.open(urls, withApplicationBundleID: bundleID)
            } catch {
                // The configured app was removed: ask again and continue the same task (PRD §19.18).
                guard let chosen = await bridge.chooseApplication(role: request.role) else { throw RuyioError(.cancelled, recovery: .chooseApplication) }
                try database.setPluginSetting(pluginID, key: key, value: .string(chosen))
                try await bridge.open(urls, withApplicationBundleID: chosen)
            }
            return .null

        case CapabilityMethod.fileWrite:
            let request = try JSONCoding.decode(FileWriteRequest.self, from: envelope.payload)
            let reply = try await fileBroker.write(request, pluginID: pluginID, operationID: envelope.operationID, executionID: envelope.executionID)
            if request.revealAfterWrite {
                let written = reply.outcomes.compactMap(\.finalPath).map { URL(fileURLWithPath: $0) }
                if !written.isEmpty { await bridge.reveal(written) }
            }
            return try JSONCoding.value(reply)

        case CapabilityMethod.fileReveal:
            // Only files this plugin created through the file broker may be revealed.
            let request = try JSONCoding.decode(RevealRequest.self, from: envelope.payload)
            let allowed = fileBroker.revealablePaths(for: pluginID)
            let urls = request.paths.prefix(64).filter { allowed.contains($0) }.map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { throw RuyioError(.permissionDenied, diagnostic: "path not produced by this plugin") }
            await bridge.reveal(urls)
            return .null

        case CapabilityMethod.finderToggleHiddenFiles:
            return .bool(try await bridge.toggleFinderHiddenFiles())

        default:
            throw RuyioError(.invalidRequest, diagnostic: envelope.method)
        }
    }

    static func terminalDirectory(for url: URL) throws -> URL {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw RuyioError(.contextExpired, objectID: url.lastPathComponent) }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            if (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                throw RuyioError(.invalidRequest, objectID: url.lastPathComponent, diagnostic: "packages cannot be opened in Terminal")
            }
            return url
        case S_IFREG:
            return url.deletingLastPathComponent()
        default:
            throw RuyioError(.invalidRequest, objectID: url.lastPathComponent, diagnostic: "unsupported file type for Terminal")
        }
    }

    /// Only http(s) without embedded credentials (plan §10). `javascript:`, `file:` and nested schemes are refused.
    public static func validatedWebLink(_ raw: String) throws -> URL {
        guard raw.count <= 4096, let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.user == nil, components.password == nil,
              let host = components.host, !host.isEmpty, let url = components.url else {
            throw RuyioError(.invalidRequest, diagnostic: "link rejected")
        }
        return url
    }

    /// Pasteboard types a plugin may write. Blocks types that could impersonate other apps' internal state.
    static func isAllowedPasteboardType(_ type: String) -> Bool {
        let allowedPrefixes = ["public.", "com.apple.", "org.nspasteboard.", "app.ruyio.", "Apple ", "NeXT "]
        return type.count <= 256 && allowedPrefixes.contains { type.hasPrefix($0) }
    }
}
