import Foundation
import RuyioCore
import RuyioProtocol

/// Everything a plugin may ask of the host. Each call is checked by the host against the manifest.
public final class PluginContext: @unchecked Sendable {
    public let manifest: PluginManifest
    public let storage: StorageClient
    public let capabilities: CapabilityClient

    private let peer: RPCPeer
    private let lock = NSLock()
    private var _locale: String
    private var _runtimeMode: RuntimeMode
    private var _settings: [String: JSONValue]

    init(manifest: PluginManifest, peer: RPCPeer, locale: String, runtimeMode: RuntimeMode) {
        self.manifest = manifest
        self.peer = peer
        self._locale = locale
        self._runtimeMode = runtimeMode
        self._settings = [:]
        self.storage = StorageClient(peer: peer)
        self.capabilities = CapabilityClient(peer: peer)
    }

    public var pluginID: PluginID { manifest.id }

    public var locale: String {
        lock.lock(); defer { lock.unlock() }
        return _locale
    }

    public var runtimeMode: RuntimeMode {
        lock.lock(); defer { lock.unlock() }
        return _runtimeMode
    }

    /// Latest settings pushed by the host (values edited through the host-rendered settings form).
    public var settings: [String: JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return _settings
    }

    func update(locale: String) {
        lock.lock(); _locale = locale; lock.unlock()
    }

    func update(runtimeMode: RuntimeMode) {
        lock.lock(); _runtimeMode = runtimeMode; lock.unlock()
    }

    func update(settings: [String: JSONValue]) {
        lock.lock(); _settings = settings; lock.unlock()
    }

    /// Localized string from the manifest tables with the standard fallback chain.
    public func localized(_ key: String, _ fallback: String) -> String {
        manifest.localized(key, locale: locale, fallback: fallback).text
    }

    public var isChinese: Bool { locale.lowercased().hasPrefix("zh") }

    public func reportProgress(_ progress: ActionProgress, execution: ExecutionID) {
        peer.send(event: Method.actionProgress, progress, executionID: execution)
    }

    /// Pushes a new revision of an open view (host drops stale revisions).
    public func updateView(_ document: ViewDocument) {
        peer.send(event: Method.viewUpdate, document)
    }

    public func publishStatus(_ report: PluginStatusReport) {
        peer.send(event: Method.statusPublish, report)
    }

    /// Publishes dynamic Finder children; titles must be metadata, never content (PRD §19.17).
    public func publishDynamicItems(_ report: DynamicItemsReport) {
        peer.send(event: Method.snapshotPublish, report)
    }
}

public final class StorageClient: Sendable {
    private let peer: RPCPeer
    init(peer: RPCPeer) { self.peer = peer }

    public func put(_ document: StoredDocument) async throws {
        _ = try await peer.request(StorageMethod.put, payload: JSONCoding.value(document))
    }

    public func get(collection: String, id: String) async throws -> StoredDocument? {
        let value = try await peer.request(StorageMethod.get, payload: JSONCoding.value(StorageKey(collection: collection, id: id)))
        if value == .null { return nil }
        return try JSONCoding.decode(StoredDocument.self, from: value)
    }

    public func delete(collection: String, id: String) async throws {
        _ = try await peer.request(StorageMethod.delete, payload: JSONCoding.value(StorageKey(collection: collection, id: id)))
    }

    public func query(_ query: StorageQuery) async throws -> StoragePage {
        try await peer.request(StorageMethod.query, query, as: StoragePage.self)
    }

    public func count(_ query: StorageQuery) async throws -> Int {
        try await peer.request(StorageMethod.count, query, as: Int.self)
    }

    public func batch(_ operations: [StorageOperation]) async throws {
        _ = try await peer.request(StorageMethod.batch, payload: JSONCoding.value(StorageBatch(operations: operations)), timeout: .seconds(30))
    }

    public func usage() async throws -> StorageUsage {
        try await peer.request(StorageMethod.usage, payload: .null).decoded(as: StorageUsage.self)
    }

    /// Uploads bytes in 64 KiB chunks and returns an opaque blob ID.
    public func putBlob(_ data: Data) async throws -> String {
        var uploadID: String?
        var offset = 0
        repeat {
            let end = min(offset + StorageLimits.blobChunkBytes, data.count)
            let chunk = data.subdata(in: offset..<end)
            let isFinal = end == data.count
            let reply = try await peer.request(
                StorageMethod.blobPut, BlobPutRequest(uploadID: uploadID, chunk: chunk, isFinal: isFinal), as: BlobPutReply.self
            )
            uploadID = reply.uploadID
            if isFinal {
                guard let blobID = reply.blobID else { throw RuyioError(.storageFailure, diagnostic: "missing blob id") }
                return blobID
            }
            offset = end
        } while true
    }

    public func getBlob(_ blobID: String, maxBytes: Int = 64 << 20) async throws -> Data {
        var result = Data()
        var offset = 0
        while true {
            let reply = try await peer.request(
                StorageMethod.blobGet, BlobGetRequest(blobID: blobID, offset: offset, length: StorageLimits.blobChunkBytes),
                as: BlobGetReply.self
            )
            guard reply.totalSize <= maxBytes else { throw RuyioError(.storageFailure, diagnostic: "blob too large") }
            result.append(reply.chunk)
            offset += reply.chunk.count
            if offset >= reply.totalSize || reply.chunk.isEmpty { return result }
        }
    }
}

public final class CapabilityClient: Sendable {
    private let peer: RPCPeer
    init(peer: RPCPeer) { self.peer = peer }

    @discardableResult
    public func writeClipboard(_ request: ClipboardWriteRequest) async throws -> ClipboardWriteReply {
        try await peer.request(CapabilityMethod.clipboardWrite, request, as: ClipboardWriteReply.self)
    }

    public func openWebLink(_ url: String) async throws {
        _ = try await peer.request(CapabilityMethod.openWebLink, payload: JSONCoding.value(WebLinkRequest(url: url)))
    }

    public func openTerminal(directories: [FileRef]) async throws {
        _ = try await peer.request(CapabilityMethod.openTerminalDirectory, payload: JSONCoding.value(DirectoryRequest(directories: directories)))
    }

    public func openInConfiguredApplication(role: String, targets: [FileRef]) async throws {
        _ = try await peer.request(
            CapabilityMethod.openInConfiguredApplication,
            payload: JSONCoding.value(ConfiguredApplicationRequest(role: role, targets: targets))
        )
    }

    /// Host-mediated atomic file creation (plan §13.3). The operation ID makes retries idempotent.
    public func writeFiles(_ request: FileWriteRequest, operation: OperationID) async throws -> FileWriteReply {
        try await peer.request(CapabilityMethod.fileWrite, request, as: FileWriteReply.self, operationID: operation, timeout: .seconds(120))
    }

    public func reveal(paths: [String]) async throws {
        _ = try await peer.request(CapabilityMethod.fileReveal, payload: JSONCoding.value(RevealRequest(paths: paths)))
    }

    public func toggleHiddenFiles() async throws -> Bool {
        try await peer.request(CapabilityMethod.finderToggleHiddenFiles, payload: .null).decoded(as: Bool.self)
    }
}

extension JSONValue {
    func decoded<T: Decodable>(as type: T.Type) throws -> T { try JSONCoding.decode(T.self, from: self) }
}
