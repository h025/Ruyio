import Foundation
import RuyioPluginSDK

/// One history entry. Large representations live in blobs; the document holds metadata and text.
public struct ClipRecord: Codable, Sendable, Hashable, Identifiable {
    public struct Representation: Codable, Sendable, Hashable {
        public var type: String
        public var text: String?
        public var blobID: String?
        public var byteCount: Int
    }

    public struct Item: Codable, Sendable, Hashable {
        public var representations: [Representation]
    }

    public var id: String
    public var kind: PasteboardRules.Kind
    public var items: [Item]
    public var fingerprint: String
    public var title: String
    public var searchText: String
    public var sourceApp: String?
    public var sourceBundleID: String?
    public var firstCopiedAt: Date
    public var lastCopiedAt: Date
    public var copyCount: Int
    public var favorite: Bool
    public var deletedAt: Date?
    public var thumbnailBlobID: String?
    public var previewBlobID: String?
    public var imageSize: [Int]?
    public var fileNames: [String]?
    public var filePaths: [String]?

    public static let collection = "records"

    public var allBlobIDs: [String] {
        var ids = items.flatMap { $0.representations.compactMap(\.blobID) }
        if let thumbnailBlobID { ids.append(thumbnailBlobID) }
        if let previewBlobID { ids.append(previewBlobID) }
        return Array(Set(ids)).sorted()
    }

    public var byteCount: Int { items.flatMap(\.representations).reduce(0) { $0 + $1.byteCount } }

    public func plainText() -> String? {
        for item in items {
            if let text = item.representations.first(where: { $0.type == PasteboardRules.text })?.text { return text }
        }
        return nil
    }

    public func document() throws -> StoredDocument {
        StoredDocument(
            collection: Self.collection, id: id, body: try JSONCoding.value(self),
            fields: [
                "kind": .string(kind.filter),
                "favorite": .bool(favorite),
                "deleted": .bool(deletedAt != nil),
                "fingerprint": .string(fingerprint),
                "lastCopiedAt": .number(lastCopiedAt.timeIntervalSince1970),
            ],
            searchText: searchText, sortKey: lastCopiedAt.timeIntervalSince1970, blobIDs: allBlobIDs)
    }

    public init(from document: StoredDocument) throws {
        self = try JSONCoding.decode(ClipRecord.self, from: document.body)
    }

    public init(id: String, kind: PasteboardRules.Kind, items: [Item], fingerprint: String, title: String, searchText: String,
                sourceApp: String?, sourceBundleID: String?, date: Date) {
        self.id = id
        self.kind = kind
        self.items = items
        self.fingerprint = fingerprint
        self.title = title
        self.searchText = searchText
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        firstCopiedAt = date
        lastCopiedAt = date
        copyCount = 1
        favorite = false
    }
}

/// Text helpers for titles and search (Maccy shortens titles to 1k characters for layout performance).
public enum ClipText {
    public static func title(for text: String, limit: Int = 200) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? text
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = String(trimmed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        return safe.count > limit ? String(safe.prefix(limit)) + "…" : safe
    }

    public static func searchText(for text: String) -> String {
        String(text.prefix(64 * 1024))
    }
}
