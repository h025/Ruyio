import Foundation
import GRDB
import RuyioCore
import RuyioProtocol

/// One plugin's private document store and blob directory for one data generation (plan §11.1–11.5).
///
/// Plugins reach it only through `storage.*` messages; no SQL, ATTACH or file path ever crosses the
/// boundary. Search text uses an FTS5 trigram index so Chinese substrings work; queries shorter than
/// three characters fall back to a bounded LIKE scan with exact confirmation.
public final class PluginStore: Sendable {
    public let directory: URL
    public let quotaBytes: Int64
    private let dbQueue: DatabaseQueue
    private let blobsDirectory: URL
    private let uploadsDirectory: URL
    private let uploads = UploadTable()

    public static let maxUploadBytes = 128 << 20
    public static let unreferencedBlobGrace: TimeInterval = 600

    public init(directory: URL, quotaBytes: Int64 = StorageLimits.pluginActiveQuotaBytes, readOnly: Bool = false) throws {
        self.directory = directory
        self.quotaBytes = quotaBytes
        self.blobsDirectory = directory.appendingPathComponent("Blobs.noindex", isDirectory: true)
        self.uploadsDirectory = directory.appendingPathComponent("Uploads.noindex", isDirectory: true)
        let fm = FileManager.default
        if !readOnly {
            for url in [directory, blobsDirectory, uploadsDirectory] {
                try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
        var config = Configuration()
        config.readonly = readOnly
        config.prepareDatabase { db in
            // Unicode case folding for search confirmation; SQLite's lower() only folds ASCII.
            db.add(function: PluginStore.foldFunction)
            // Deleted content must not linger in free pages (plan §11.4).
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        dbQueue = try DatabaseQueue(path: directory.appendingPathComponent("Store.sqlite").path, configuration: config)
        if !readOnly { try Self.migrator.migrate(dbQueue) }
        // Abandoned uploads from a previous run are reclaimed (plan §11.5).
        if !readOnly, let leftovers = try? fm.contentsOfDirectory(at: uploadsDirectory, includingPropertiesForKeys: nil) {
            for url in leftovers { try? fm.removeItem(at: url) }
        }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE document (
                    collection TEXT NOT NULL,
                    id TEXT NOT NULL,
                    body TEXT NOT NULL,
                    search_text TEXT,
                    sort_key REAL NOT NULL DEFAULT 0,
                    size INTEGER NOT NULL,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (collection, id)
                );
                CREATE INDEX document_sort ON document(collection, sort_key, id);
                CREATE TABLE field (
                    collection TEXT NOT NULL,
                    id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    value_text TEXT,
                    value_num REAL,
                    PRIMARY KEY (collection, id, name)
                );
                CREATE INDEX field_text ON field(collection, name, value_text);
                CREATE INDEX field_num ON field(collection, name, value_num);
                CREATE VIRTUAL TABLE document_fts USING fts5(search_text, collection UNINDEXED, doc_id UNINDEXED, tokenize = 'trigram');
                CREATE TABLE blob (
                    id TEXT PRIMARY KEY,
                    size INTEGER NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE TABLE blob_ref (
                    collection TEXT NOT NULL,
                    doc_id TEXT NOT NULL,
                    blob_id TEXT NOT NULL,
                    PRIMARY KEY (collection, doc_id, blob_id)
                );
                CREATE INDEX blob_ref_blob ON blob_ref(blob_id);
                """)
        }
        migrator.registerMigration("v2-index-accounting") { db in
            let keys = try Row.fetchAll(db, sql: "SELECT collection, id FROM document")
            for key in keys {
                let collection: String = key[0]
                let id: String = key[1]
                if let document = try Self.load(db, collection: collection, id: id) {
                    let size = try Self.accountedSize(document, body: Self.encodeBody(document.body))
                    try db.execute(sql: "UPDATE document SET size = ? WHERE collection = ? AND id = ?", arguments: [size, collection, id])
                }
            }
        }
        return migrator
    }

    // MARK: Documents

    /// SQLite's structural check; an update never commits onto a damaged candidate database.
    public func quickCheck() throws {
        let result = try dbQueue.read { db in try String.fetchOne(db, sql: "PRAGMA quick_check") }
        guard result == "ok" else { throw RuyioError(.storageFailure, diagnostic: "candidate store failed integrity check") }
    }

    public func put(_ document: StoredDocument) throws {
        try batch([.put(document)])
    }

    public func get(collection: String, id: String) throws -> StoredDocument? {
        try dbQueue.read { db in try Self.load(db, collection: collection, id: id) }
    }

    public func delete(collection: String, id: String) throws {
        try batch([.delete(StorageKey(collection: collection, id: id))])
    }

    /// Applies all operations in one transaction; nothing is written if any operation is invalid.
    public func batch(_ operations: [StorageOperation]) throws {
        for case .put(let document) in operations { try Self.validate(document) }
        let quota = quotaBytes
        try dbQueue.write { db in
            var growth: Int64 = 0
            for operation in operations {
                switch operation {
                case .put(let document):
                    let body = try Self.encodeBody(document.body)
                    let size = Self.accountedSize(document, body: body)
                    let previous = try Int64.fetchOne(db, sql: "SELECT size FROM document WHERE collection = ? AND id = ?",
                                                      arguments: [document.collection, document.id]) ?? 0
                    growth += size - previous
                    try Self.write(db, document: document, body: body, size: size)
                case .delete(let key):
                    try Self.remove(db, collection: key.collection, id: key.id)
                }
            }
            if growth > 0 {
                let used = try Self.usedBytes(db)
                if used > quota {
                    throw RuyioError(.storageQuotaExceeded, retryable: false, dataEffect: .unmodified,
                                     diagnostic: "used \(used) of \(quota)")
                }
            }
            let documents = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document") ?? 0
            if documents > StorageLimits.maxDocumentsPerPlugin {
                throw RuyioError(.storageQuotaExceeded, diagnostic: "document count limit")
            }
        }
    }

    public func query(_ query: StorageQuery) throws -> StoragePage {
        let limit = max(1, min(query.limit, StorageLimits.maxQueryLimit))
        return try dbQueue.read { db in
            var clauses = ["d.collection = ?"]
            var arguments: StatementArguments = [query.collection]
            Self.appendFilters(query.filters, to: &clauses, arguments: &arguments)
            if let search = query.search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
                if search.count >= 3 {
                    clauses.append("d.rowid IN (SELECT d2.rowid FROM document_fts f JOIN document d2 ON d2.collection = f.collection AND d2.id = f.doc_id WHERE document_fts MATCH ? AND f.collection = ?)")
                    arguments += [Self.ftsPhrase(search), query.collection]
                }
                // Confirmation (and the whole match for 1–2 characters) on the stored text.
                clauses.append("instr(ruyio_fold(d.search_text), ?) > 0")
                arguments += [Self.fold(search)]
            }
            if let cursor = query.cursor.flatMap(Cursor.decode) {
                if query.ascending {
                    clauses.append("(d.sort_key > ? OR (d.sort_key = ? AND d.id > ?))")
                } else {
                    clauses.append("(d.sort_key < ? OR (d.sort_key = ? AND d.id < ?))")
                }
                arguments += [cursor.sortKey, cursor.sortKey, cursor.id]
            }
            let order = query.ascending ? "ASC" : "DESC"
            let sql = "SELECT d.collection, d.id FROM document d WHERE \(clauses.joined(separator: " AND ")) ORDER BY d.sort_key \(order), d.id \(order) LIMIT ?"
            arguments += [limit + 1]
            let keys = try Row.fetchAll(db, sql: sql, arguments: arguments).map { row -> (String, String) in (row[0], row[1]) }
            var documents: [StoredDocument] = []
            var encodedBytes = 4096 // Page/cursor metadata, including the longest permitted document ID.
            for (collection, id) in keys.prefix(limit) {
                if let doc = try Self.load(db, collection: collection, id: id) {
                    let size = try JSONCoding.encoder().encode(doc).count + 1
                    if documents.isEmpty {
                        // Documents written before the write-time ceiling may exceed the page budget; one per
                        // page still fits a frame, so they stay readable and deletable instead of failing every query.
                        guard size + 4096 <= Framing.maxFrameBytes - 64 * 1024 else {
                            throw RuyioError(.frameTooLarge, objectID: id, diagnostic: "document exceeds query response budget; move large values to blobs")
                        }
                    } else if encodedBytes + size > StorageLimits.maxQueryResponseBytes {
                        break
                    }
                    documents.append(doc)
                    encodedBytes += size
                }
            }
            var next: String?
            if keys.count > documents.count, let last = documents.last {
                next = Cursor(sortKey: last.sortKey, id: last.id).encoded
            }
            return StoragePage(documents: documents, nextCursor: next)
        }
    }

    public func count(_ query: StorageQuery) throws -> Int {
        try dbQueue.read { db in
            var clauses = ["d.collection = ?"]
            var arguments: StatementArguments = [query.collection]
            Self.appendFilters(query.filters, to: &clauses, arguments: &arguments)
            if let search = query.search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
                clauses.append("instr(ruyio_fold(d.search_text), ?) > 0")
                arguments += [Self.fold(search)]
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document d WHERE \(clauses.joined(separator: " AND "))", arguments: arguments) ?? 0
        }
    }

    public func usage() throws -> StorageUsage {
        try dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM document") ?? 0
            return StorageUsage(documentCount: count, bytes: try Self.usedBytes(db), quotaBytes: quotaBytes)
        }
    }

    // MARK: Blobs

    /// Appends a chunk to an upload; on the final chunk the blob is committed atomically.
    public func appendUpload(_ request: BlobPutRequest) throws -> BlobPutReply {
        guard request.chunk.count <= StorageLimits.blobChunkBytes else {
            throw RuyioError(.invalidRequest, diagnostic: "chunk too large")
        }
        let uploadID = request.uploadID ?? UUID().uuidString.lowercased()
        guard uploadID.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { throw RuyioError(.invalidRequest) }
        let url = uploadsDirectory.appendingPathComponent(uploadID)
        let size = try uploads.append(id: uploadID, data: request.chunk, to: url, limit: Self.maxUploadBytes)
        guard request.isFinal else { return BlobPutReply(uploadID: uploadID, blobID: nil) }

        let blobID = Self.newBlobID()
        let destination = blobURL(blobID)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try uploads.finish(id: uploadID)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.moveItem(at: url, to: destination)
        let quota = quotaBytes
        do {
            try dbQueue.write { db in
                try db.execute(sql: "INSERT INTO blob (id, size, created_at) VALUES (?, ?, ?)",
                               arguments: [blobID, size, Date().timeIntervalSince1970])
                let used = try Self.usedBytes(db)
                if used > quota { throw RuyioError(.storageQuotaExceeded, diagnostic: "blob exceeds quota") }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return BlobPutReply(uploadID: uploadID, blobID: blobID)
    }

    public func readBlob(_ request: BlobGetRequest) throws -> BlobGetReply {
        guard Self.isValidBlobID(request.blobID),
              try dbQueue.read({ db in try Bool.fetchOne(db, sql: "SELECT 1 FROM blob WHERE id = ?", arguments: [request.blobID]) }) == true
        else { throw RuyioError(.storageFailure, objectID: request.blobID, diagnostic: "unknown blob") }
        let url = blobURL(request.blobID)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = Int(try handle.seekToEnd())
        let offset = max(0, min(request.offset, total))
        try handle.seek(toOffset: UInt64(offset))
        let length = max(0, min(request.length, StorageLimits.blobChunkBytes, total - offset))
        let chunk = try handle.read(upToCount: length) ?? Data()
        return BlobGetReply(chunk: chunk, totalSize: total)
    }

    /// Whole-blob read for the host's own use (e.g. pasteboard write-back).
    public func blobData(_ blobID: String, maxBytes: Int = 64 << 20) throws -> Data {
        guard Self.isValidBlobID(blobID) else { throw RuyioError(.invalidRequest) }
        let url = blobURL(blobID)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else { throw RuyioError(.storageFailure, diagnostic: "blob too large") }
        return try Data(contentsOf: url)
    }

    /// Deletes unreferenced blobs older than the upload grace period. Returns removed count.
    @discardableResult
    public func collectGarbage(now: Date = Date()) throws -> Int {
        let cutoff = now.timeIntervalSince1970 - Self.unreferencedBlobGrace
        let orphans: [String] = try dbQueue.write { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM blob WHERE created_at < ? AND NOT EXISTS (SELECT 1 FROM blob_ref r WHERE r.blob_id = blob.id)
                """, arguments: [cutoff])
            for id in ids { try db.execute(sql: "DELETE FROM blob WHERE id = ?", arguments: [id]) }
            return ids
        }
        for id in orphans { try? FileManager.default.removeItem(at: blobURL(id)) }
        return orphans.count
    }

    /// Reclaims space and drops deleted content from WAL, FTS segments and free pages (plan §11.4).
    public func compact(vacuum: Bool) throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "INSERT INTO document_fts(document_fts) VALUES('optimize')")
            if vacuum { try db.execute(sql: "VACUUM") }
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    static let foldFunction = DatabaseFunction("ruyio_fold", argumentCount: 1, pure: true) { values in
        String.fromDatabaseValue(values[0]).map(fold)
    }

    /// Consistent copy for update backups; never copies a live db/WAL pair (plan §15.2).
    public func backup(to destination: URL) throws {
        let target = try DatabaseQueue(path: destination.path)
        try dbQueue.backup(to: target)
    }

    // MARK: Internals

    private func blobURL(_ id: String) -> URL {
        blobsDirectory.appendingPathComponent(String(id.prefix(2)), isDirectory: true).appendingPathComponent(id)
    }

    static func newBlobID() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func isValidBlobID(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func validate(_ document: StoredDocument) throws {
        guard !document.collection.isEmpty, document.collection.count <= 64, document.collection.utf8.count <= 256,
              !document.id.isEmpty, document.id.count <= 256, document.id.utf8.count <= 1024 else {
            throw RuyioError(.invalidRequest, diagnostic: "invalid collection or id")
        }
        guard document.fields.count <= StorageLimits.maxFieldsPerDocument else {
            throw RuyioError(.invalidRequest, diagnostic: "too many indexed fields")
        }
        for (name, value) in document.fields {
            guard !name.isEmpty, name.utf8.count <= StorageLimits.maxFieldNameBytes else {
                throw RuyioError(.invalidRequest, diagnostic: "invalid indexed field name")
            }
            switch value {
            case .string(let text):
                guard text.utf8.count <= StorageLimits.maxFieldValueBytes else {
                    throw RuyioError(.invalidRequest, diagnostic: "indexed field value too large")
                }
            case .number(let number):
                guard number.isFinite else { throw RuyioError(.invalidRequest, diagnostic: "non-finite indexed number") }
            case .bool, .null: break
            default: throw RuyioError(.invalidRequest, diagnostic: "indexed fields must be scalar")
            }
        }
        guard document.sortKey.isFinite else { throw RuyioError(.invalidRequest, diagnostic: "non-finite sort key") }
        guard document.body.depth <= Framing.maxJSONDepth else { throw RuyioError(.invalidRequest, diagnostic: "body too deep") }
        // Every stored document must fit a query page with room to spare; large values belong in blobs.
        guard try JSONCoding.encoder().encode(document).count <= StorageLimits.maxDocumentBytes else {
            throw RuyioError(.invalidRequest, diagnostic: "document too large; move large values to blobs")
        }
        for blobID in document.blobIDs where !isValidBlobID(blobID) {
            throw RuyioError(.invalidRequest, diagnostic: "invalid blob reference")
        }
    }

    static func encodeBody(_ body: JSONValue) throws -> String {
        String(decoding: try JSONCoding.encoder().encode(body), as: UTF8.self)
    }

    /// Charge data plus space reserved for its SQLite tables, keys and indexes. Trigram text reserves
    /// postings/term space per scalar so adding searchable/indexed data can never be free in quota.
    static func accountedSize(_ document: StoredDocument, body: String) -> Int64 {
        let keyBytes = document.collection.utf8.count + document.id.utf8.count
        var size = body.utf8.count + 128 + keyBytes * 3
        if let text = document.searchText, !text.isEmpty {
            size += text.utf8.count * 2 + text.unicodeScalars.count * 24 + keyBytes + 64
        }
        for (name, value) in document.fields {
            let valueBytes = value.stringValue?.utf8.count ?? 8
            size += 128 + keyBytes * 4 + name.utf8.count * 4 + valueBytes * 2
        }
        size += Set(document.blobIDs).count * (128 + keyBytes * 2 + 64 * 3)
        return Int64(size)
    }

    static func write(_ db: Database, document: StoredDocument, body: String, size: Int64) throws {
        try remove(db, collection: document.collection, id: document.id, keepBlobRefs: false)
        try db.execute(sql: """
            INSERT INTO document (collection, id, body, search_text, sort_key, size, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [document.collection, document.id, body, document.searchText, document.sortKey, size, Date().timeIntervalSince1970])
        for (name, value) in document.fields {
            var text: String?
            var number: Double?
            switch value {
            case .string(let s): text = s
            case .number(let n): number = n
            case .bool(let b): number = b ? 1 : 0
            case .null: break
            default: throw RuyioError(.invalidRequest, diagnostic: "indexed field \(name) must be scalar")
            }
            try db.execute(sql: "INSERT INTO field (collection, id, name, value_text, value_num) VALUES (?, ?, ?, ?, ?)",
                           arguments: [document.collection, document.id, name, text, number])
        }
        if let search = document.searchText, !search.isEmpty {
            try db.execute(sql: "INSERT INTO document_fts (search_text, collection, doc_id) VALUES (?, ?, ?)",
                           arguments: [search, document.collection, document.id])
        }
        for blobID in Set(document.blobIDs) {
            guard try Bool.fetchOne(db, sql: "SELECT 1 FROM blob WHERE id = ?", arguments: [blobID]) == true else {
                throw RuyioError(.invalidRequest, diagnostic: "unknown blob reference")
            }
            try db.execute(sql: "INSERT INTO blob_ref (collection, doc_id, blob_id) VALUES (?, ?, ?)",
                           arguments: [document.collection, document.id, blobID])
        }
    }

    static func remove(_ db: Database, collection: String, id: String, keepBlobRefs: Bool = false) throws {
        try db.execute(sql: "DELETE FROM document WHERE collection = ? AND id = ?", arguments: [collection, id])
        try db.execute(sql: "DELETE FROM field WHERE collection = ? AND id = ?", arguments: [collection, id])
        try db.execute(sql: "DELETE FROM document_fts WHERE collection = ? AND doc_id = ?", arguments: [collection, id])
        if !keepBlobRefs {
            try db.execute(sql: "DELETE FROM blob_ref WHERE collection = ? AND doc_id = ?", arguments: [collection, id])
        }
    }

    static func load(_ db: Database, collection: String, id: String) throws -> StoredDocument? {
        guard let row = try Row.fetchOne(db, sql: "SELECT body, search_text, sort_key FROM document WHERE collection = ? AND id = ?",
                                         arguments: [collection, id]) else { return nil }
        let bodyText: String = row["body"]
        let body = try JSONCoding.decoder().decode(JSONValue.self, from: Data(bodyText.utf8))
        var fields: [String: JSONValue] = [:]
        for fieldRow in try Row.fetchAll(db, sql: "SELECT name, value_text, value_num FROM field WHERE collection = ? AND id = ?",
                                          arguments: [collection, id]) {
            let name: String = fieldRow["name"]
            if let text: String = fieldRow["value_text"] { fields[name] = .string(text) }
            else if let number: Double = fieldRow["value_num"] { fields[name] = .number(number) }
            else { fields[name] = .null }
        }
        let blobs = try String.fetchAll(db, sql: "SELECT blob_id FROM blob_ref WHERE collection = ? AND doc_id = ? ORDER BY blob_id",
                                        arguments: [collection, id])
        return StoredDocument(collection: collection, id: id, body: body, fields: fields, searchText: row["search_text"],
                              sortKey: row["sort_key"], blobIDs: blobs)
    }

    static func usedBytes(_ db: Database) throws -> Int64 {
        let docs = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) FROM document") ?? 0
        let blobs = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) FROM blob") ?? 0
        return docs + blobs
    }

    static func appendFilters(_ filters: [StorageFilter], to clauses: inout [String], arguments: inout StatementArguments) {
        for filter in filters {
            let base = "SELECT 1 FROM field f WHERE f.collection = d.collection AND f.id = d.id AND f.name = ?"
            switch filter.op {
            case .isNull:
                clauses.append("NOT EXISTS (\(base) AND (f.value_text IS NOT NULL OR f.value_num IS NOT NULL))")
                arguments += [filter.field]
            case .isNotNull:
                clauses.append("EXISTS (\(base) AND (f.value_text IS NOT NULL OR f.value_num IS NOT NULL))")
                arguments += [filter.field]
            case .equals, .notEquals, .lessThan, .greaterThan:
                let op: String = switch filter.op { case .equals: "="; case .notEquals: "!="; case .lessThan: "<"; default: ">" }
                let column: String
                let value: DatabaseValueConvertible?
                switch filter.value {
                case .string(let s): column = "value_text"; value = s
                case .number(let n): column = "value_num"; value = n
                case .bool(let b): column = "value_num"; value = b ? 1.0 : 0.0
                default: column = "value_text"; value = nil
                }
                if filter.op == .notEquals {
                    clauses.append("NOT EXISTS (\(base) AND f.\(column) = ?)")
                } else {
                    clauses.append("EXISTS (\(base) AND f.\(column) \(op) ?)")
                }
                arguments += [filter.field, value]
            }
        }
    }

    /// Quotes user text as a single FTS5 phrase so operators in the query are never interpreted.
    static func ftsPhrase(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    struct Cursor: Codable {
        var sortKey: Double
        var id: String
        var encoded: String { (try? JSONEncoder().encode(self))?.base64EncodedString() ?? "" }
        static func decode(_ raw: String) -> Cursor? {
            Data(base64Encoded: raw).flatMap { try? JSONDecoder().decode(Cursor.self, from: $0) }
        }
    }
}

/// Tracks in-progress uploads per store; enforces the per-upload size limit.
final class UploadTable: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [String: Int] = [:]
    private var started: [String: Date] = [:]
    private var files: [String: URL] = [:]
    /// Plan §11.5: at most 2 concurrent uploads, 128 MiB staged per plugin, abandoned after 10 minutes.
    static let maxActive = 2
    static let maxStagedBytes = 128 << 20
    static let expiry: TimeInterval = 600

    func append(id: String, data: Data, to url: URL, limit: Int) throws -> Int {
        try lock.withLock {
            let now = Date()
            for (key, date) in started where now.timeIntervalSince(date) > Self.expiry && key != id {
                if let file = files[key] { try? FileManager.default.removeItem(at: file) }
                sizes[key] = nil; started[key] = nil; files[key] = nil
            }
            let current = sizes[id] ?? 0
            if current == 0 && sizes.count >= Self.maxActive {
                throw RuyioError(.storageQuotaExceeded, retryable: true, diagnostic: "too many concurrent uploads")
            }
            let staged = sizes.values.reduce(0, +)
            guard current + data.count <= limit, staged + data.count <= Self.maxStagedBytes else {
                sizes[id] = nil; started[id] = nil; files[id] = nil
                try? FileManager.default.removeItem(at: url)
                throw RuyioError(.storageQuotaExceeded, diagnostic: "upload exceeds staging limits")
            }
            if current == 0 { started[id] = now; files[id] = url }
            if current == 0 {
                guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    throw RuyioError(.storageFailure, diagnostic: "cannot create upload")
                }
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
            sizes[id] = current + data.count
            return current + data.count
        }
    }

    func finish(id: String) throws {
        lock.withLock {
            sizes[id] = nil
            started[id] = nil
            files[id] = nil
        }
    }
}
