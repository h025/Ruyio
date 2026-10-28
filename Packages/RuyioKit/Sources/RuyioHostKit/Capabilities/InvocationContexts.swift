import Foundation
import RuyioCore
import RuyioProtocol

/// Host-issued file references bound to one plugin, one execution, a lifetime and a use budget
/// (plan §10 `contextRef`). Plugins cannot widen access by sending arbitrary paths.
public final class InvocationContexts: @unchecked Sendable {
    public struct Grant: Sendable {
        public var url: URL
        public var pluginID: PluginID
        public var executionID: ExecutionID
        public var expiresAt: Date
        public var remainingUses: Int
        public var fileIdentity: FileIdentity?
        /// Screen location where files written into this directory should be placed (Desktop right-click).
        public var placement: CGPoint?
    }

    /// Device + inode captured when the grant was issued, re-checked before use (TOCTOU).
    public struct FileIdentity: Sendable, Hashable {
        public var device: Int
        public var inode: UInt64

        public static func of(_ url: URL) -> FileIdentity? {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            return FileIdentity(device: Int(info.st_dev), inode: UInt64(info.st_ino))
        }
    }

    private let lock = NSLock()
    private var grants: [String: Grant] = [:]
    private var ended: [ExecutionID: Date] = [:]
    private var running: [ExecutionID: PluginID] = [:]
    public var lifetime: TimeInterval = 600
    public var uses: Int = 64

    public init() {}

    public func issue(_ url: URL, for pluginID: PluginID, execution: ExecutionID, placement: CGPoint? = nil) -> FileRef {
        let ref = UUID().uuidString.lowercased()
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let grant = Grant(url: url.standardizedFileURL, pluginID: pluginID, executionID: execution,
                          expiresAt: Date().addingTimeInterval(lifetime), remainingUses: uses,
                          fileIdentity: FileIdentity.of(url), placement: placement)
        lock.withLock {
            purgeExpired()
            grants[ref] = grant
        }
        return FileRef(ref: ref, path: url.path, name: url.lastPathComponent, isDirectory: values?.isDirectory ?? false,
                       isPackage: values?.isPackage ?? false)
    }

    /// Resolves a reference for a plugin; fails for foreign, expired, exhausted or swapped targets.
    public func resolve(_ fileRef: FileRef, for pluginID: PluginID) throws -> URL {
        try lock.withLock {
            guard var grant = grants[fileRef.ref], grant.pluginID == pluginID else {
                throw RuyioError(.contextExpired, objectID: fileRef.name, recovery: .retry, diagnostic: "unknown file reference")
            }
            guard grant.expiresAt > Date(), grant.remainingUses > 0 else {
                grants[fileRef.ref] = nil
                throw RuyioError(.contextExpired, objectID: fileRef.name, recovery: .retry)
            }
            if let identity = grant.fileIdentity, FileIdentity.of(grant.url) != identity {
                throw RuyioError(.contextExpired, objectID: fileRef.name, recovery: .retry, diagnostic: "target changed")
            }
            grant.remainingUses -= 1
            grants[fileRef.ref] = grant
            return grant.url
        }
    }

    /// Re-checks a reference already resolved in this request without consuming a use, so one batched
    /// write of N items costs one use, not N + 1.
    public func isStillValid(_ fileRef: FileRef, for pluginID: PluginID) -> Bool {
        lock.withLock {
            guard let grant = grants[fileRef.ref], grant.pluginID == pluginID, grant.expiresAt > Date() else { return false }
            if let identity = grant.fileIdentity, FileIdentity.of(grant.url) != identity { return false }
            return true
        }
    }

    /// Marks an action execution as running for a plugin until `revokeAll(for:)` ends it.
    public func begin(_ execution: ExecutionID, for pluginID: PluginID) {
        lock.withLock { running[execution] = pluginID }
    }

    /// True while the plugin's own action execution runs: user-initiated work such as a screen capture
    /// is only available inside it.
    public func isRunning(_ execution: ExecutionID?, for pluginID: PluginID) -> Bool {
        guard let execution else { return false }
        return lock.withLock { running[execution] == pluginID && ended[execution] == nil }
    }

    public func revokeAll(for execution: ExecutionID) {
        lock.withLock {
            running[execution] = nil
            grants = grants.filter { $0.value.executionID != execution }
            let cutoff = Date().addingTimeInterval(-3600)
            ended = ended.filter { $0.value > cutoff }
            ended[execution] = Date()
        }
    }

    /// True once the execution finished, timed out or was cancelled. Work that waited on the user
    /// (a chooser, a confirmation) checks this before acting, so a timed-out request never acts late.
    public func hasEnded(_ execution: ExecutionID?) -> Bool {
        guard let execution else { return false }
        return lock.withLock { ended[execution] != nil }
    }

    /// The placement recorded for a directory reference of this plugin, while the reference is valid.
    public func placement(of fileRef: FileRef, for pluginID: PluginID) -> CGPoint? {
        lock.withLock {
            guard let grant = grants[fileRef.ref], grant.pluginID == pluginID, grant.expiresAt > Date() else { return nil }
            return grant.placement
        }
    }

    public func revokeAll(pluginID: PluginID) {
        lock.withLock { grants = grants.filter { $0.value.pluginID != pluginID } }
    }

    private func purgeExpired() {
        let now = Date()
        grants = grants.filter { $0.value.expiresAt > now }
    }
}
