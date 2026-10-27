import Foundation

/// Generic document storage API (plan §11.1). No raw SQL, ATTACH or paths ever cross the boundary.
public enum StorageMethod {
    public static let put = "storage.put"
    public static let get = "storage.get"
    public static let delete = "storage.delete"
    public static let query = "storage.query"
    public static let count = "storage.count"
    public static let batch = "storage.batch"
    public static let blobPut = "storage.blob.put"
    public static let blobGet = "storage.blob.get"
    public static let usage = "storage.usage"
}

public struct StoredDocument: Codable, Sendable, Hashable {
    public var collection: String
    public var id: String
    public var body: JSONValue
    /// Indexed scalar fields usable in filters (≤ 32 per document).
    public var fields: [String: JSONValue]
    /// Normalized text for substring search (CJK-safe trigram index).
    public var searchText: String?
    /// Descending sort key, e.g. last-used timestamp.
    public var sortKey: Double
    /// Blob IDs this document references; unreferenced blobs are garbage collected.
    public var blobIDs: [String]

    public init(collection: String, id: String, body: JSONValue, fields: [String: JSONValue] = [:],
                searchText: String? = nil, sortKey: Double = 0, blobIDs: [String] = []) {
        self.collection = collection
        self.id = id
        self.body = body
        self.fields = fields
        self.searchText = searchText
        self.sortKey = sortKey
        self.blobIDs = blobIDs
    }
}

public struct StorageKey: Codable, Sendable, Hashable {
    public var collection: String
    public var id: String
    public init(collection: String, id: String) {
        self.collection = collection
        self.id = id
    }
}

public struct StorageFilter: Codable, Sendable, Hashable {
    public enum Op: String, Codable, Sendable { case equals, notEquals, lessThan, greaterThan, isNull, isNotNull }
    public var field: String
    public var op: Op
    public var value: JSONValue
    public init(field: String, op: Op = .equals, value: JSONValue = .null) {
        self.field = field
        self.op = op
        self.value = value
    }
}

public struct StorageQuery: Codable, Sendable, Hashable {
    public var collection: String
    public var filters: [StorageFilter]
    public var search: String?
    public var limit: Int
    /// Opaque cursor returned by the previous page.
    public var cursor: String?
    public var ascending: Bool

    public init(collection: String, filters: [StorageFilter] = [], search: String? = nil, limit: Int = 50, cursor: String? = nil, ascending: Bool = false) {
        self.collection = collection
        self.filters = filters
        self.search = search
        self.limit = limit
        self.cursor = cursor
        self.ascending = ascending
    }
}

public struct StoragePage: Codable, Sendable, Hashable {
    public var documents: [StoredDocument]
    public var nextCursor: String?
    public init(documents: [StoredDocument], nextCursor: String?) {
        self.documents = documents
        self.nextCursor = nextCursor
    }
}

public enum StorageOperation: Codable, Sendable, Hashable {
    case put(StoredDocument)
    case delete(StorageKey)

    private enum CodingKeys: String, CodingKey { case type, document, key }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "put": self = .put(try c.decode(StoredDocument.self, forKey: .document))
        case "delete": self = .delete(try c.decode(StorageKey.self, forKey: .key))
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown op \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .put(let doc): try c.encode("put", forKey: .type); try c.encode(doc, forKey: .document)
        case .delete(let key): try c.encode("delete", forKey: .type); try c.encode(key, forKey: .key)
        }
    }
}

public struct StorageBatch: Codable, Sendable, Hashable {
    public var operations: [StorageOperation]
    public init(operations: [StorageOperation]) { self.operations = operations }
}

public struct BlobPutRequest: Codable, Sendable, Hashable {
    /// Base64 chunk; total blob size limited by quota. Chunks ≤ 64 KiB raw (plan §8.2).
    public var uploadID: String?
    public var chunk: Data
    public var isFinal: Bool
    public init(uploadID: String?, chunk: Data, isFinal: Bool) {
        self.uploadID = uploadID
        self.chunk = chunk
        self.isFinal = isFinal
    }
}

public struct BlobPutReply: Codable, Sendable, Hashable {
    public var uploadID: String
    public var blobID: String?
    public init(uploadID: String, blobID: String?) {
        self.uploadID = uploadID
        self.blobID = blobID
    }
}

public struct BlobGetRequest: Codable, Sendable, Hashable {
    public var blobID: String
    public var offset: Int
    public var length: Int
    public init(blobID: String, offset: Int, length: Int) {
        self.blobID = blobID
        self.offset = offset
        self.length = length
    }
}

public struct BlobGetReply: Codable, Sendable, Hashable {
    public var chunk: Data
    public var totalSize: Int
    public init(chunk: Data, totalSize: Int) {
        self.chunk = chunk
        self.totalSize = totalSize
    }
}

public struct StorageUsage: Codable, Sendable, Hashable {
    public var documentCount: Int
    public var bytes: Int64
    public var quotaBytes: Int64
    public init(documentCount: Int, bytes: Int64, quotaBytes: Int64) {
        self.documentCount = documentCount
        self.bytes = bytes
        self.quotaBytes = quotaBytes
    }
}

public enum StorageLimits {
    public static let maxFieldsPerDocument = 32
    public static let maxDocumentsPerPlugin = 100_000
    public static let blobChunkBytes = 64 * 1024
    public static let maxQueryLimit = 200
    public static let pluginActiveQuotaBytes: Int64 = 1_342_177_280 // 1.25 GiB
}
