import Foundation
import GRDB
import RuyioCore
import RuyioProtocol

/// Host.sqlite (plan §11.1): installation records, entry preferences, hotkeys, settings, operation
/// receipts and usage. The single write path for installed state is `PluginRegistry`.
public final class HostDatabase: Sendable {
    let dbQueue: DatabaseQueue

    public init(url: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
        dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    /// In-memory database for tests.
    public init() throws {
        dbQueue = try DatabaseQueue()
        try Self.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "installed_plugin") { t in
                t.primaryKey("pluginID", .text)
                t.column("manifest", .text).notNull()
                t.column("installPath", .text).notNull()
                t.column("executablePath", .text).notNull()
                t.column("version", .text).notNull()
                t.column("teamID", .text)
                t.column("signingIdentifier", .text)
                t.column("isDevelopment", .boolean).notNull().defaults(to: false)
                t.column("isDefault", .boolean).notNull().defaults(to: false)
                t.column("installationState", .text).notNull()
                t.column("activationState", .text).notNull()
                t.column("updateState", .text).notNull()
                t.column("sourceState", .text).notNull()
                t.column("updateChannel", .text).notNull()
                t.column("source", .text)
                t.column("artifactSHA256", .text)
                t.column("dataGeneration", .integer).notNull().defaults(to: 1)
                t.column("enabledPreference", .boolean).notNull().defaults(to: true)
                t.column("lastErrorCode", .text)
                t.column("installedAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "uninstalled_default") { t in
                t.primaryKey("pluginID", .text)
                t.column("uninstalledAt", .datetime).notNull()
                t.column("keptData", .boolean).notNull()
            }
            try db.create(table: "entry_preference") { t in
                t.column("pluginID", .text).notNull()
                t.column("actionID", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("visible", .boolean).notNull()
                t.column("orderIndex", .integer)
                t.primaryKey(["pluginID", "actionID", "kind"])
            }
            try db.create(table: "finder_group_order") { t in
                t.primaryKey("pluginID", .text)
                t.column("orderIndex", .integer).notNull()
            }
            try db.create(table: "hotkey") { t in
                t.column("pluginID", .text).notNull()
                t.column("actionID", .text).notNull()
                t.column("shortcut", .text)
                t.column("isCustom", .boolean).notNull()
                t.primaryKey(["pluginID", "actionID"])
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.create(table: "plugin_setting") { t in
                t.column("pluginID", .text).notNull()
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
                t.primaryKey(["pluginID", "key"])
            }
            try db.create(table: "operation") { t in
                t.primaryKey("operationID", .text)
                t.column("pluginID", .text).notNull()
                t.column("actionID", .text)
                t.column("executionID", .text)
                t.column("phase", .text).notNull()
                t.column("intent", .text).notNull()
                t.column("receipt", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "action_usage") { t in
                t.column("pluginID", .text).notNull()
                t.column("actionID", .text).notNull()
                t.column("count", .integer).notNull()
                t.column("lastUsedAt", .datetime).notNull()
                t.primaryKey(["pluginID", "actionID"])
            }
        }
        migrator.registerMigration("v2-markets") { db in
            try db.create(table: "market") { t in
                t.primaryKey("marketID", .text)
                t.column("name", .text).notNull()
                t.column("inputURL", .text).notNull()
                t.column("canonicalURL", .text).notNull()
                t.column("githubRepoID", .integer)
                t.column("ref", .text)
                t.column("commitSHA", .text)
                t.column("enabled", .boolean).notNull()
                t.column("state", .text).notNull()
                t.column("lastRefreshAt", .datetime)
                t.column("lastError", .text)
                t.column("index", .text)
                t.column("addedAt", .datetime).notNull()
            }
            try db.create(table: "seen_version") { t in
                t.column("pluginID", .text).notNull()
                t.column("sourceKey", .text).notNull()
                t.column("version", .text).notNull()
                t.primaryKey(["pluginID", "sourceKey"])
            }
        }
        return migrator
    }

    /// Consistent backup used before host migrations (plan §19.1).
    public func backup(to url: URL) throws {
        let target = try DatabaseQueue(path: url.path)
        try dbQueue.backup(to: target)
    }
}

// MARK: - Records

public struct InstalledPluginRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "installed_plugin"

    public var pluginID: String
    public var manifest: String
    public var installPath: String
    public var executablePath: String
    public var version: String
    public var teamID: String?
    public var signingIdentifier: String?
    public var isDevelopment: Bool
    public var isDefault: Bool
    public var installationState: InstallationState
    public var activationState: ActivationState
    public var updateState: UpdateState
    public var sourceState: SourceState
    public var updateChannel: UpdateChannel
    public var source: String?
    public var artifactSHA256: String?
    public var dataGeneration: Int
    public var enabledPreference: Bool
    public var lastErrorCode: String?
    public var installedAt: Date
    public var updatedAt: Date

    public init(manifest: PluginManifest, installPath: URL, executablePath: URL, teamID: String?, signingIdentifier: String?,
                isDevelopment: Bool, isDefault: Bool, updateChannel: UpdateChannel, source: String? = nil, artifactSHA256: String? = nil) throws {
        pluginID = manifest.id.rawValue
        self.manifest = String(decoding: try JSONCoding.encoder().encode(manifest), as: UTF8.self)
        self.installPath = installPath.path
        self.executablePath = executablePath.path
        version = manifest.version.description
        self.teamID = teamID
        self.signingIdentifier = signingIdentifier
        self.isDevelopment = isDevelopment
        self.isDefault = isDefault
        installationState = .installed
        activationState = .disabled
        updateState = .none
        sourceState = .linked
        self.updateChannel = updateChannel
        self.source = source
        self.artifactSHA256 = artifactSHA256
        dataGeneration = 1
        enabledPreference = true
        installedAt = Date()
        updatedAt = Date()
    }

    public func decodedManifest() throws -> PluginManifest {
        try JSONCoding.decoder().decode(PluginManifest.self, from: Data(manifest.utf8))
    }

    public var status: PluginStatus {
        PluginStatus(installation: installationState, activation: activationState, update: updateState, source: sourceState,
                     updateChannel: updateChannel, isDevelopment: isDevelopment, lastErrorCode: lastErrorCode)
    }
}

public struct UninstalledDefaultRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "uninstalled_default"
    public var pluginID: String
    public var uninstalledAt: Date
    public var keptData: Bool
    public init(pluginID: String, uninstalledAt: Date = Date(), keptData: Bool) {
        self.pluginID = pluginID
        self.uninstalledAt = uninstalledAt
        self.keptData = keptData
    }
}

public struct EntryPreferenceRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "entry_preference"
    public var pluginID: String
    public var actionID: String
    public var kind: PresentationKind
    public var visible: Bool
    public var orderIndex: Int?
    public init(pluginID: String, actionID: String, kind: PresentationKind, visible: Bool, orderIndex: Int? = nil) {
        self.pluginID = pluginID
        self.actionID = actionID
        self.kind = kind
        self.visible = visible
        self.orderIndex = orderIndex
    }
}

public struct FinderGroupOrderRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "finder_group_order"
    public var pluginID: String
    public var orderIndex: Int
}

public struct HotkeyRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "hotkey"
    public var pluginID: String
    public var actionID: String
    /// Manifest-style string; nil means explicitly cleared.
    public var shortcut: String?
    public var isCustom: Bool
    public init(pluginID: String, actionID: String, shortcut: String?, isCustom: Bool) {
        self.pluginID = pluginID
        self.actionID = actionID
        self.shortcut = shortcut
        self.isCustom = isCustom
    }
}

public struct OperationRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "operation"
    public enum Phase: String, Codable, Sendable { case intent, staged, committed, completed, unknown, failed, resolved }
    public var operationID: String
    public var pluginID: String
    public var actionID: String?
    public var executionID: String?
    public var phase: Phase
    /// Private operation data (may contain paths); never written to general logs.
    public var intent: String
    public var receipt: String?
    public var createdAt: Date
    public var updatedAt: Date
    public init(operationID: String, pluginID: String, actionID: String?, executionID: String?, phase: Phase, intent: String, receipt: String? = nil) {
        self.operationID = operationID
        self.pluginID = pluginID
        self.actionID = actionID
        self.executionID = executionID
        self.phase = phase
        self.intent = intent
        self.receipt = receipt
        createdAt = Date()
        updatedAt = Date()
    }
}

public struct ActionUsageRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "action_usage"
    public var pluginID: String
    public var actionID: String
    public var count: Int
    public var lastUsedAt: Date
}

public struct MarketRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "market"
    public var marketID: String
    public var name: String
    public var inputURL: String
    public var canonicalURL: String
    public var githubRepoID: Int64?
    public var ref: String?
    public var commitSHA: String?
    public var enabled: Bool
    public var state: String
    public var lastRefreshAt: Date?
    public var lastError: String?
    public var index: String?
    public var addedAt: Date
    public init(marketID: String, name: String, inputURL: String, canonicalURL: String, githubRepoID: Int64? = nil, ref: String? = nil,
                commitSHA: String? = nil, enabled: Bool = true, state: String = "active", index: String? = nil) {
        self.marketID = marketID
        self.name = name
        self.inputURL = inputURL
        self.canonicalURL = canonicalURL
        self.githubRepoID = githubRepoID
        self.ref = ref
        self.commitSHA = commitSHA
        self.enabled = enabled
        self.state = state
        self.index = index
        addedAt = Date()
    }
}

extension InstallationState: DatabaseValueConvertible {}
extension ActivationState: DatabaseValueConvertible {}
extension UpdateState: DatabaseValueConvertible {}
extension SourceState: DatabaseValueConvertible {}
extension UpdateChannel: DatabaseValueConvertible {}
extension PresentationKind: DatabaseValueConvertible {}
extension OperationRecord.Phase: DatabaseValueConvertible {}

// MARK: - Queries

public extension HostDatabase {
    func installedPlugins() throws -> [InstalledPluginRecord] {
        try dbQueue.read { db in try InstalledPluginRecord.order(Column("pluginID")).fetchAll(db) }
    }

    func installedPlugin(_ id: PluginID) throws -> InstalledPluginRecord? {
        try dbQueue.read { db in try InstalledPluginRecord.fetchOne(db, key: id.rawValue) }
    }

    func save(_ record: InstalledPluginRecord) throws {
        var copy = record
        copy.updatedAt = Date()
        try dbQueue.write { db in try copy.save(db) }
    }

    func deleteInstalledPlugin(_ id: PluginID) throws {
        try dbQueue.write { db in
            _ = try InstalledPluginRecord.deleteOne(db, key: id.rawValue)
            try db.execute(sql: "DELETE FROM entry_preference WHERE pluginID = ?", arguments: [id.rawValue])
            try db.execute(sql: "DELETE FROM finder_group_order WHERE pluginID = ?", arguments: [id.rawValue])
        }
    }

    func uninstalledDefaults() throws -> [UninstalledDefaultRecord] {
        try dbQueue.read { db in try UninstalledDefaultRecord.fetchAll(db) }
    }

    func markDefaultUninstalled(_ id: PluginID, keptData: Bool) throws {
        try dbQueue.write { db in try UninstalledDefaultRecord(pluginID: id.rawValue, keptData: keptData).save(db) }
    }

    func clearDefaultUninstalled(_ id: PluginID) throws {
        try dbQueue.write { db in _ = try UninstalledDefaultRecord.deleteOne(db, key: id.rawValue) }
    }

    func entryPreferences(for id: PluginID? = nil) throws -> [EntryPreferenceRecord] {
        try dbQueue.read { db in
            if let id { return try EntryPreferenceRecord.filter(Column("pluginID") == id.rawValue).fetchAll(db) }
            return try EntryPreferenceRecord.fetchAll(db)
        }
    }

    func saveEntryPreferences(_ records: [EntryPreferenceRecord]) throws {
        try dbQueue.write { db in for record in records { try record.save(db) } }
    }

    func resetFinderLayout() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE entry_preference SET orderIndex = NULL WHERE kind = ?", arguments: [PresentationKind.finderContextMenu.rawValue])
            try db.execute(sql: "DELETE FROM finder_group_order")
        }
    }

    func finderGroupOrder() throws -> [String: Int] {
        try dbQueue.read { db in
            Dictionary(uniqueKeysWithValues: try FinderGroupOrderRecord.fetchAll(db).map { ($0.pluginID, $0.orderIndex) })
        }
    }

    func saveFinderGroupOrder(_ order: [PluginID]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM finder_group_order")
            for (index, id) in order.enumerated() { try FinderGroupOrderRecord(pluginID: id.rawValue, orderIndex: index).insert(db) }
        }
    }

    func hotkeys() throws -> [HotkeyRecord] {
        try dbQueue.read { db in try HotkeyRecord.fetchAll(db) }
    }

    func saveHotkey(_ record: HotkeyRecord) throws {
        try dbQueue.write { db in try record.save(db) }
    }

    func deleteHotkey(pluginID: String, actionID: String) throws {
        try dbQueue.write { db in _ = try HotkeyRecord.deleteOne(db, key: ["pluginID": pluginID, "actionID": actionID]) }
    }

    func setting<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        try dbQueue.read { db in
            guard let raw = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key]) else { return nil }
            return try JSONCoding.decoder().decode(T.self, from: Data(raw.utf8))
        }
    }

    func setSetting<T: Encodable>(_ key: String, _ value: T) throws {
        let raw = String(decoding: try JSONCoding.encoder().encode(value), as: UTF8.self)
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [key, raw])
        }
    }

    func pluginSettings(_ id: PluginID) throws -> [String: JSONValue] {
        try dbQueue.read { db in
            var result: [String: JSONValue] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, value FROM plugin_setting WHERE pluginID = ?", arguments: [id.rawValue]) {
                let raw: String = row["value"]
                result[row["key"]] = try JSONCoding.decoder().decode(JSONValue.self, from: Data(raw.utf8))
            }
            return result
        }
    }

    func setPluginSetting(_ id: PluginID, key: String, value: JSONValue) throws {
        let raw = String(decoding: try JSONCoding.encoder().encode(value), as: UTF8.self)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO plugin_setting (pluginID, key, value) VALUES (?, ?, ?)
                ON CONFLICT(pluginID, key) DO UPDATE SET value = excluded.value
                """, arguments: [id.rawValue, key, raw])
        }
    }

    // Operations (plan §13.3)

    func operation(_ id: OperationID) throws -> OperationRecord? {
        try dbQueue.read { db in try OperationRecord.fetchOne(db, key: id.rawValue) }
    }

    func saveOperation(_ record: OperationRecord) throws {
        var copy = record
        copy.updatedAt = Date()
        try dbQueue.write { db in try copy.save(db) }
    }

    func unresolvedOperations(pluginID: PluginID? = nil) throws -> [OperationRecord] {
        try dbQueue.read { db in
            var request = OperationRecord.filter([OperationRecord.Phase.unknown.rawValue, OperationRecord.Phase.intent.rawValue,
                                                  OperationRecord.Phase.staged.rawValue].contains(Column("phase")))
            if let pluginID { request = request.filter(Column("pluginID") == pluginID.rawValue) }
            return try request.fetchAll(db)
        }
    }

    /// Completed receipts are kept 7 days; unresolved ones until the user handles them.
    func pruneOperations(olderThan date: Date) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM operation WHERE phase IN ('completed', 'failed', 'resolved') AND updatedAt < ?", arguments: [date])
        }
    }

    // Usage for command palette suggestions

    func recordUsage(_ ref: ActionRef) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO action_usage (pluginID, actionID, count, lastUsedAt) VALUES (?, ?, 1, ?)
                ON CONFLICT(pluginID, actionID) DO UPDATE SET count = count + 1, lastUsedAt = excluded.lastUsedAt
                """, arguments: [ref.pluginID.rawValue, ref.actionID.rawValue, Date()])
        }
    }

    func usage() throws -> [ActionUsageRecord] {
        try dbQueue.read { db in try ActionUsageRecord.order(Column("lastUsedAt").desc).fetchAll(db) }
    }

    // Markets

    func markets() throws -> [MarketRecord] {
        try dbQueue.read { db in try MarketRecord.order(Column("addedAt")).fetchAll(db) }
    }

    func saveMarket(_ record: MarketRecord) throws {
        try dbQueue.write { db in try record.save(db) }
    }

    func deleteMarket(_ id: String) throws {
        try dbQueue.write { db in _ = try MarketRecord.deleteOne(db, key: id) }
    }

    func seenVersion(pluginID: String, sourceKey: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT version FROM seen_version WHERE pluginID = ? AND sourceKey = ?", arguments: [pluginID, sourceKey])
        }
    }

    func recordSeenVersion(pluginID: String, sourceKey: String, version: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO seen_version (pluginID, sourceKey, version) VALUES (?, ?, ?)
                ON CONFLICT(pluginID, sourceKey) DO UPDATE SET version = excluded.version
                """, arguments: [pluginID, sourceKey, version])
        }
    }
}
