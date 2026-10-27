import Foundation
import Testing
@testable import RuyioPersistence
import RuyioProtocol
import RuyioCore

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ruyio-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct PluginStoreTests {
    func makeStore(quota: Int64 = StorageLimits.pluginActiveQuotaBytes) throws -> PluginStore {
        try PluginStore(directory: temporaryDirectory(), quotaBytes: quota)
    }

    func doc(_ id: String, text: String, kind: String = "text", favorite: Bool = false, sort: Double) -> StoredDocument {
        StoredDocument(collection: "records", id: id, body: ["text": .string(text)], fields: ["kind": .string(kind), "favorite": .bool(favorite)],
                       searchText: text, sortKey: sort)
    }

    @Test func putGetDelete() throws {
        let store = try makeStore()
        try store.put(doc("1", text: "hello", sort: 1))
        let loaded = try #require(try store.get(collection: "records", id: "1"))
        #expect(loaded.body["text"] == "hello")
        #expect(loaded.fields["favorite"] == .number(0))
        try store.delete(collection: "records", id: "1")
        #expect(try store.get(collection: "records", id: "1") == nil)
    }

    @Test func chineseSubstringSearchAndShortQueries() throws {
        let store = try makeStore()
        try store.batch([
            .put(doc("1", text: "项目会议纪要：下周发布 Ruyio", sort: 3)),
            .put(doc("2", text: "https://example.com/剪贴板", kind: "url", sort: 2)),
            .put(doc("3", text: "Design.sketch", kind: "file", sort: 1)),
        ])
        #expect(try store.query(StorageQuery(collection: "records", search: "会议纪要")).documents.map(\.id) == ["1"])
        #expect(try store.query(StorageQuery(collection: "records", search: "纪要")).documents.map(\.id) == ["1"])
        #expect(try store.query(StorageQuery(collection: "records", search: "会")).documents.map(\.id) == ["1"])
        #expect(try store.query(StorageQuery(collection: "records", search: "RUYIO")).documents.map(\.id) == ["1"])
        #expect(try store.query(StorageQuery(collection: "records", search: "剪贴板")).documents.map(\.id) == ["2"])
        // FTS operators in user input are treated literally.
        #expect(try store.query(StorageQuery(collection: "records", search: "\"OR*")).documents.isEmpty)
    }

    @Test func filtersCombineWithSearch() throws {
        let store = try makeStore()
        try store.batch([
            .put(doc("1", text: "alpha note", kind: "text", favorite: true, sort: 3)),
            .put(doc("2", text: "alpha link", kind: "url", sort: 2)),
            .put(doc("3", text: "beta note", kind: "text", sort: 1)),
        ])
        let page = try store.query(StorageQuery(collection: "records", filters: [StorageFilter(field: "kind", value: "text")], search: "alpha"))
        #expect(page.documents.map(\.id) == ["1"])
        let favorites = try store.query(StorageQuery(collection: "records", filters: [StorageFilter(field: "favorite", value: true)]))
        #expect(favorites.documents.map(\.id) == ["1"])
        let notFavorite = try store.count(StorageQuery(collection: "records", filters: [StorageFilter(field: "favorite", op: .notEquals, value: true)]))
        #expect(notFavorite == 2)
    }

    @Test func keysetPagination() throws {
        let store = try makeStore()
        try store.batch((0..<25).map { .put(doc("id\($0)", text: "item \($0)", sort: Double($0 / 2))) })
        var seen: [String] = []
        var cursor: String?
        repeat {
            let page = try store.query(StorageQuery(collection: "records", limit: 7, cursor: cursor))
            seen += page.documents.map(\.id)
            cursor = page.nextCursor
        } while cursor != nil
        #expect(seen.count == 25)
        #expect(Set(seen).count == 25)
    }

    @Test func tenThousandRecordSearchIsFast() throws {
        let store = try makeStore()
        var ops: [StorageOperation] = []
        for i in 0..<10_000 {
            let text = i % 3 == 0 ? "会议记录 第\(i)条 Ruyio" : (i % 3 == 1 ? "https://example.com/page/\(i)" : "Report-\(i).pdf")
            ops.append(.put(doc("r\(i)", text: text, kind: i % 3 == 1 ? "url" : "text", sort: Double(i))))
        }
        try store.batch(ops)
        let clock = ContinuousClock()
        var worst = Duration.zero
        for query in ["会议记录", "第99", "example.com/page/42", "Report-77", "ruyio", "会"] {
            let elapsed = try clock.measure { _ = try store.query(StorageQuery(collection: "records", search: query, limit: 50)) }
            worst = max(worst, elapsed)
        }
        #expect(worst < .milliseconds(150), "worst query took \(worst)")
    }

    @Test func blobLifecycleAndGarbageCollection() throws {
        let store = try makeStore()
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        var uploadID: String?
        var blobID: String?
        var offset = 0
        while offset < payload.count {
            let end = min(offset + StorageLimits.blobChunkBytes, payload.count)
            let reply = try store.appendUpload(BlobPutRequest(uploadID: uploadID, chunk: payload.subdata(in: offset..<end), isFinal: end == payload.count))
            uploadID = reply.uploadID
            blobID = reply.blobID
            offset = end
        }
        let id = try #require(blobID)
        #expect(try store.blobData(id) == payload)
        var record = doc("img", text: "image", kind: "image", sort: 1)
        record.blobIDs = [id]
        try store.put(record)
        #expect(try store.collectGarbage(now: Date().addingTimeInterval(3600)) == 0)
        try store.delete(collection: "records", id: "img")
        #expect(try store.collectGarbage(now: Date().addingTimeInterval(3600)) == 1)
        #expect(throws: (any Error).self) { _ = try store.blobData(id) }
        // Blob directory is excluded from Spotlight by name and blobs have no extension.
        #expect(store.directory.appendingPathComponent("Blobs.noindex").hasDirectoryPath)
    }

    @Test func rejectsUnknownBlobReferenceAndBadIDs() throws {
        let store = try makeStore()
        var record = doc("x", text: "x", sort: 1)
        record.blobIDs = [String(repeating: "a", count: 64)]
        #expect(throws: RuyioError.self) { try store.put(record) }
        record.blobIDs = ["../../etc/passwd"]
        #expect(throws: RuyioError.self) { try store.put(record) }
    }

    @Test func quotaRejectsGrowthButAllowsDeletion() throws {
        let store = try makeStore(quota: 2_000)
        try store.put(doc("1", text: String(repeating: "a", count: 500), sort: 1))
        #expect(throws: RuyioError.self) { try store.put(doc("2", text: String(repeating: "b", count: 2_000), sort: 2)) }
        #expect(try store.get(collection: "records", id: "2") == nil)
        try store.delete(collection: "records", id: "1")
        #expect(try store.usage().bytes == 0)
    }

    @Test func compactRemovesDeletedContentFromDisk() throws {
        let store = try makeStore()
        let secret = "SECRET-\(UUID().uuidString)"
        try store.put(doc("s", text: secret, sort: 1))
        try store.delete(collection: "records", id: "s")
        try store.compact(vacuum: true)
        let files = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
        for file in files where file.lastPathComponent.hasPrefix("Store.sqlite") {
            let data = (try? Data(contentsOf: file)) ?? Data()
            #expect(data.range(of: Data(secret.utf8)) == nil, "\(file.lastPathComponent) still contains deleted text")
        }
    }
}

struct HostDatabaseTests {
    @Test func settingsAndOperations() throws {
        let db = try HostDatabase()
        try db.setSetting("language", "zh-Hans")
        #expect(try db.setting("language", as: String.self) == "zh-Hans")
        let op = OperationRecord(operationID: "op1", pluginID: "app.ruyio.finder-essentials", actionID: "new-text-file", executionID: "e1", phase: .intent, intent: "{}")
        try db.saveOperation(op)
        #expect(try db.unresolvedOperations().count == 1)
        var done = op
        done.phase = .completed
        try db.saveOperation(done)
        #expect(try db.unresolvedOperations().isEmpty)
        try db.pruneOperations(olderThan: Date().addingTimeInterval(60))
        #expect(try db.operation(OperationID(rawValue: "op1")) == nil)
    }

    @Test func usageAndHotkeys() throws {
        let db = try HostDatabase()
        let ref = ActionRef(pluginID: PluginID("app.ruyio.clipboard-history"), actionID: ActionID("show-history"))
        try db.recordUsage(ref)
        try db.recordUsage(ref)
        #expect(try db.usage().first?.count == 2)
        try db.saveHotkey(HotkeyRecord(pluginID: ref.pluginID.rawValue, actionID: ref.actionID.rawValue, shortcut: nil, isCustom: true))
        #expect(try db.hotkeys().first?.shortcut == nil)
    }
}
