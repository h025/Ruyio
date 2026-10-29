import Foundation
import CryptoKit
import RuyioCore

/// Resolved storage roots (plan §11.1). Never hard-codes a user name.
public struct AppPaths: Sendable {
    public let applicationSupport: URL
    public let caches: URL

    public init(applicationSupport: URL, caches: URL) {
        self.applicationSupport = applicationSupport
        self.caches = caches
    }

    /// Standard per-user locations.
    public static func standard(fileManager: FileManager = .default) throws -> AppPaths {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Ruyio", isDirectory: true)
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Ruyio", isDirectory: true)
        let paths = AppPaths(applicationSupport: support, caches: caches)
        try paths.ensureDirectories()
        return paths
    }

    public var hostDatabase: URL { applicationSupport.appendingPathComponent("Host.sqlite") }
    public var pluginsRoot: URL { applicationSupport.appendingPathComponent("Plugins", isDirectory: true) }
    public var dataRoot: URL { applicationSupport.appendingPathComponent("Data", isDirectory: true) }
    public var developmentDataRoot: URL { applicationSupport.appendingPathComponent("Data-dev", isDirectory: true) }
    public var transactionsRoot: URL { applicationSupport.appendingPathComponent("Transactions", isDirectory: true) }
    public var logs: URL { applicationSupport.appendingPathComponent("Logs", isDirectory: true) }
    public var downloads: URL { caches.appendingPathComponent("Downloads", isDirectory: true) }
    public var marketMetadata: URL { caches.appendingPathComponent("MarketMetadata", isDirectory: true) }
    public var thumbnails: URL { caches.appendingPathComponent("Thumbnails.noindex", isDirectory: true) }

    /// Data partition for one plugin identity and generation. Development plugins never share it (PRD §13).
    public func dataDirectory(identity: String, generation: Int, development: Bool) -> URL {
        (development ? developmentDataRoot : dataRoot)
            .appendingPathComponent(identity, isDirectory: true)
            .appendingPathComponent(String(generation), isDirectory: true)
    }

    public func ensureDirectories(fileManager: FileManager = .default) throws {
        for url in [applicationSupport, pluginsRoot, dataRoot, developmentDataRoot, transactionsRoot, logs, caches, downloads, marketMetadata, thumbnails] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// Stable directory name derived from a verified identity, not from untrusted manifest strings.
    /// `publisherID` is a Team ID or a `cert:` certificate fingerprint (`PublisherID`).
    public static func identityDirectoryName(pluginID: PluginID, publisherID: String?) -> String {
        let publisher = (publisherID?.isEmpty == false) ? publisherID! : "unsigned"
        let safePublisher = publisher.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        return "\(pluginID.rawValue)~\(safePublisher)"
    }

    /// Persistent data belongs to the complete signing identity, including its designated identifier.
    public static func dataIdentityDirectoryName(pluginID: PluginID, publisherID: String?, signingIdentifier: String?) -> String {
        let components = [publisherID ?? "", signingIdentifier ?? ""]
        let identity = components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(pluginID.rawValue)~\(digest)"
    }
}

public enum BackupPolicy {
    /// Update every explicitly marked identity root as well as both parent roots. Kept data is included.
    public static func setIncludedInBackup(_ included: Bool, paths: AppPaths) throws {
        var targets: [URL] = []
        for root in [paths.dataRoot, paths.developmentDataRoot] {
            targets.append(root)
            let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            for child in children {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true && values.isSymbolicLink != true { targets.append(child) }
            }
        }
        var previous: [(URL, Bool)] = []
        do {
            for target in targets {
                var current = target
                current.removeCachedResourceValue(forKey: .isExcludedFromBackupKey)
                let value = try current.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
                previous.append((target, value))
                try setExcludedFromBackup(!included, at: target)
            }
        } catch {
            for (target, excluded) in previous.reversed() { try? setExcludedFromBackup(excluded, at: target) }
            throw error
        }
    }

    /// Applies Time Machine exclusion to a directory tree root (plan §11.4).
    public static func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        var target = url
        try target.setResourceValues(values)
    }

    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        // The attribute that `isExcludedFromBackup` writes, read directly rather than through cached URL
        // resource values. Setting it applies asynchronously: a read right after a change can be stale
        // for a few milliseconds (measured: a few percent of changes).
        getxattr(url.path, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}
