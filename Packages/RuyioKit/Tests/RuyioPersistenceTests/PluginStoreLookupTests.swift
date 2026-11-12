import Foundation
import RuyioCore
import RuyioProtocol
@testable import RuyioPersistence
import Testing

struct PluginStoreLookupTests {
    @Test func selectiveAndBroadTextMatchesKeepBothPaginationDirections() throws {
        let store = try PluginStoreTests().makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        for count in [2, 32, 33, 80] {
            let ids = (0..<count).map { String(format: "group-%03d-item-%03d", count, $0) }
            try store.batch(ids.map {
                .put(StoredDocument(collection: "records", id: $0, body: .null, fields: ["group": .string(String(count))], sortKey: 1))
            })
            for ascending in [true, false] {
                var query = StorageQuery(collection: "records", filters: [StorageFilter(field: "group", value: .string(String(count)))],
                                         limit: 7, ascending: ascending)
                #expect(try store.count(query) == count)
                var seen: [String] = []
                for _ in 0..<30 {
                    let page = try store.query(query)
                    seen += page.documents.map(\.id)
                    query.cursor = page.nextCursor
                    if query.cursor == nil { break }
                }
                #expect(query.cursor == nil)
                #expect(seen == (ascending ? ids : Array(ids.reversed())))
                #expect(try store.count(query) == count, "count ignores page cursors and limits")
            }
        }
    }

    @Test func selectiveTextCandidatesPreserveNumericBooleanNullAndNegationSemantics() throws {
        let store = try PluginStoreTests().makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let values: [(String, [String: JSONValue])] = [
            ("a", ["score": 1, "flag": true, "optional": .null, "tag": "text"]),
            ("b", ["score": 2, "flag": false, "optional": "present", "tag": "text"]),
            ("c", ["score": 3, "tag": ""]),
            ("d", ["flag": .null, "optional": 0]),
            ("e", ["score": 0, "flag": true, "optional": 0, "tag": "text"]),
            ("f", ["score": 2, "flag": false, "optional": .null, "tag": "text"]),
        ]
        try store.batch(values.map { id, fields in
            var fields = fields
            fields["kind"] = "text"
            fields["lookup"] = "shared"
            return .put(StoredDocument(collection: "records", id: id, body: .null, fields: fields))
        } + (0..<50).map {
            .put(StoredDocument(collection: "records", id: "other-\($0)", body: .null, fields: ["kind": "text"]))
        })
        // The broad first equality must not prevent a later selective equality from being used.
        let base = [StorageFilter(field: "kind", value: "text"), StorageFilter(field: "lookup", value: "shared")]
        let cases: [(StorageFilter, [String])] = [
            (StorageFilter(field: "flag", value: true), ["e", "a"]),
            (StorageFilter(field: "flag", value: 1), ["e", "a"]),
            (StorageFilter(field: "flag", op: .notEquals, value: true), ["f", "d", "c", "b"]),
            (StorageFilter(field: "score", op: .lessThan, value: 2), ["e", "a"]),
            (StorageFilter(field: "score", op: .greaterThan, value: 1), ["f", "c", "b"]),
            (StorageFilter(field: "score", value: 2), ["f", "b"]),
            (StorageFilter(field: "optional", op: .isNull), ["f", "c", "a"]),
            (StorageFilter(field: "optional", op: .isNotNull), ["e", "d", "b"]),
            (StorageFilter(field: "tag", value: ""), ["c"]),
            (StorageFilter(field: "tag", op: .notEquals, value: "text"), ["d", "c"]),
            (StorageFilter(field: "flag", value: .null), []),
            (StorageFilter(field: "flag", op: .notEquals, value: .null), ["f", "e", "d", "c", "b", "a"]),
        ]
        for (filter, expected) in cases {
            let query = StorageQuery(collection: "records", filters: base + [filter])
            #expect(try store.query(query).documents.map(\.id) == expected, "filter: \(filter)")
            #expect(try store.count(query) == expected.count, "filter: \(filter)")
        }
    }

    @Test func indexedCandidatesStayInsideTheCollectionAndCombineWithSearch() throws {
        let store = try PluginStoreTests().makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let value = "needle'\"?😀"
        try store.batch([
            .put(StoredDocument(collection: "records", id: "one", body: .null, fields: ["lookup": .string(value)], searchText: "ALPHA 会议纪要", sortKey: 1)),
            .put(StoredDocument(collection: "records", id: "two", body: .null, fields: ["lookup": .string(value)], searchText: "beta 备注", sortKey: 2)),
            .put(StoredDocument(collection: "other", id: "one", body: .null, fields: ["lookup": .string(value)], searchText: "ALPHA 会议纪要", sortKey: 100)),
            .put(StoredDocument(collection: "records", id: "three", body: .null, fields: ["lookup": "different"], searchText: "ALPHA", sortKey: 3)),
        ])
        let filters = [StorageFilter(field: "lookup", value: .string(value))]
        for search in ["alpha", "会", "会议纪要"] {
            let query = StorageQuery(collection: "records", filters: filters, search: search)
            #expect(try store.query(query).documents.map(\.id) == ["one"])
            #expect(try store.count(query) == 1)
        }
        for search in ["not present", "\"OR*"] {
            let query = StorageQuery(collection: "records", filters: filters, search: search)
            #expect(try store.query(query).documents.isEmpty)
            #expect(try store.count(query) == 0)
        }
        let absent = StorageQuery(collection: "records", filters: [StorageFilter(field: "lookup", value: "absent")], limit: 1)
        #expect(try store.query(absent) == StoragePage(documents: [], nextCursor: nil))
        #expect(try store.count(absent) == 0)
    }

    @Test func selectiveCandidatePaginationHonorsTheResponseByteBudget() throws {
        let store = try PluginStoreTests().makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let body = JSONValue.string(String(repeating: "x", count: 300_000))
        try store.batch(["a", "b", "c"].map {
            .put(StoredDocument(collection: "records", id: $0, body: body, fields: ["lookup": "shared"]))
        })
        var query = StorageQuery(collection: "records", filters: [StorageFilter(field: "lookup", value: "shared")])
        let first = try store.query(query)
        #expect(first.documents.map(\.id) == ["c", "b"])
        let cursor = try #require(first.nextCursor)
        query.cursor = cursor
        let second = try store.query(query)
        #expect(second.documents.map(\.id) == ["a"] && second.nextCursor == nil)
        #expect(try store.count(query) == 3)
    }
}
