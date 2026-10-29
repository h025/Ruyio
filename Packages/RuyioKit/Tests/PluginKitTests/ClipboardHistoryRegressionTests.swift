import Darwin
import Foundation
import Testing
@testable import ClipboardHistoryKit
@testable import RuyioPluginSDK

/// Real RPC, synthetic documents/capabilities: these tests never start capture or touch the clipboard.
private final class ClipboardFixture: @unchecked Sendable {
    let host = ClipboardMemoryHost()
    let server: RPCPeer
    let client: RPCPeer
    let plugin: ClipboardHistoryPlugin

    init() throws {
        var incoming: [Int32] = [0, 0], outgoing: [Int32] = [0, 0]
        guard pipe(&incoming) == 0, pipe(&outgoing) == 0 else { throw RuyioError(.internalError) }
        server = RPCPeer(readFD: incoming[0], writeFD: outgoing[1], label: "clipboard-test-host")
        client = RPCPeer(readFD: outgoing[0], writeFD: incoming[1], label: "clipboard-test-plugin")
        plugin = ClipboardHistoryPlugin(context: PluginContext(manifest: try Repo.manifest("ClipboardHistory"),
            peer: client, locale: "en", runtimeMode: .normal))
        let host = host
        server.start(onRequest: { try await host.handle($0) }, onEvent: { host.event($0) }, onClose: { _ in })
        client.start(onRequest: { _ in .null }, onEvent: { _ in }, onClose: { _ in })
    }

    func close() { client.close(); server.close() }

    func clip(_ text: String = "example") -> CapturedClip {
        CapturedClip(items: [[PasteboardRules.text: Data(text.utf8)]], sourceApp: "Example",
                     sourceBundleID: "example.source", changeCount: 1, skippedOversize: false)
    }

    /// Records 0…count-1, oldest first, copied recently enough to stay within the retention days.
    func seed(_ count: Int, megabytesEach: Int? = nil, favorites: Set<Int> = []) async throws {
        let template = try await plugin.makeRecord(clip(), kind: .text, fingerprint: "template", date: Date())
        let recent = Date().timeIntervalSince1970 - 3600
        for i in 0..<count {
            var record = template
            record.id = "record-\(i)"
            record.lastCopiedAt = Date(timeIntervalSince1970: megabytesEach == nil ? Double(i) : recent + Double(i))
            if let megabytesEach { record.items[0].representations[0].byteCount = megabytesEach << 20 }
            record.favorite = favorites.contains(i)
            try host.insert(record.document())
        }
    }

    func remaining() -> [String] {
        host.lock.withLock { host.docs.values.filter { $0.collection == ClipRecord.collection }.map(\.id) }.sorted {
            Int($0.dropFirst(7))! < Int($1.dropFirst(7))!
        }
    }
}

private actor QueryBarrier {
    private var entered = false
    private var entrance: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        entrance?.resume(); entrance = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entrance = $0 }
    }

    func release() { continuation?.resume(); continuation = nil }
}

private final class ClipboardMemoryHost: @unchecked Sendable {
    let lock = NSLock()
    var docs: [String: StoredDocument] = [:]
    var reports: [DynamicItemsReport] = []
    var writes: [ClipboardWriteRequest] = []
    var failSettings = false
    /// Quota reported by `storage.usage`; usage itself is the sum of the records' sizes, as on disk.
    var quotaBytes: Int64 = 1_342_177_280
    var denyFileURLs = false
    var delayedSearch: String?
    let queryBarrier = QueryBarrier()

    func insert(_ document: StoredDocument) { lock.withLock { docs[document.collection + "/" + document.id] = document } }

    func matches(_ document: StoredDocument, query: StorageQuery) -> Bool {
        guard document.collection == query.collection else { return false }
        if let search = query.search, !(document.searchText ?? "").contains(search) { return false }
        return query.filters.allSatisfy { filter in
            let value = document.fields[filter.field] ?? .null
            switch filter.op {
            case .equals: return value == filter.value
            case .notEquals: return value != filter.value
            case .lessThan: return (value.doubleValue ?? 0) < (filter.value.doubleValue ?? 0)
            case .greaterThan: return (value.doubleValue ?? 0) > (filter.value.doubleValue ?? 0)
            case .isNull: return value == .null
            case .isNotNull: return value != .null
            }
        }
    }

    func handle(_ envelope: Envelope) async throws -> JSONValue {
        if envelope.method == StorageMethod.query {
            let query = try JSONCoding.decode(StorageQuery.self, from: envelope.payload)
            let (page, delay) = lock.withLock {
                let matching = docs.values.filter { matches($0, query: query) }.sorted {
                    query.ascending ? $0.sortKey < $1.sortKey : $0.sortKey > $1.sortKey
                }
                let offset = Int(query.cursor ?? "0") ?? 0
                let slice = Array(matching.dropFirst(offset).prefix(query.limit))
                return (StoragePage(documents: slice, nextCursor: offset + slice.count < matching.count ? String(offset + slice.count) : nil),
                        query.search != nil && query.search == delayedSearch)
            }
            if delay { await queryBarrier.suspend() }
            return try JSONCoding.value(page)
        }
        return try lock.withLock {
            switch envelope.method {
            case StorageMethod.put:
                let document = try JSONCoding.decode(StoredDocument.self, from: envelope.payload)
                if document.collection == "settings" && failSettings { throw RuyioError(.storageFailure) }
                docs[document.collection + "/" + document.id] = document
                return .null
            case StorageMethod.get:
                let key = try JSONCoding.decode(StorageKey.self, from: envelope.payload)
                return try docs[key.collection + "/" + key.id].map { try JSONCoding.value($0) } ?? .null
            case StorageMethod.delete:
                let key = try JSONCoding.decode(StorageKey.self, from: envelope.payload)
                docs.removeValue(forKey: key.collection + "/" + key.id)
                return .null
            case StorageMethod.batch:
                let batch = try JSONCoding.decode(StorageBatch.self, from: envelope.payload)
                for operation in batch.operations {
                    switch operation {
                    case .delete(let key): docs.removeValue(forKey: key.collection + "/" + key.id)
                    case .put(let document): docs[document.collection + "/" + document.id] = document
                    }
                }
                return .null
            case StorageMethod.count:
                let query = try JSONCoding.decode(StorageQuery.self, from: envelope.payload)
                return .number(Double(docs.values.filter { matches($0, query: query) }.count))
            case StorageMethod.usage:
                let clips = docs.values.filter { $0.collection == ClipRecord.collection }
                let bytes = clips.compactMap { try? ClipRecord(from: $0) }.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
                return try JSONCoding.value(StorageUsage(documentCount: clips.count, bytes: bytes, quotaBytes: quotaBytes))
            case CapabilityMethod.clipboardWrite:
                let request = try JSONCoding.decode(ClipboardWriteRequest.self, from: envelope.payload)
                if denyFileURLs && request.items.contains(where: { $0.representations.contains { $0.type == PasteboardRules.fileURL } }) {
                    throw RuyioError(.fileAccessDenied)
                }
                writes.append(request)
                return try JSONCoding.value(ClipboardWriteReply(changeCount: writes.count))
            default: throw RuyioError(.invalidRequest, diagnostic: envelope.method)
            }
        }
    }

    func event(_ envelope: Envelope) {
        if envelope.method == Method.snapshotPublish,
           let report = try? JSONCoding.decode(DynamicItemsReport.self, from: envelope.payload) {
            lock.withLock { reports.append(report) }
        }
    }
}

struct ClipboardHistoryRegressionTests {
    @Test func healthCheckToleratesOneBadRecordButRejectsUnreadableDataWithoutCapture() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.close() }
        let request = DataPreparationRequest(sourceSchemaVersion: 1, targetSchemaVersion: 1)
        // Like the history itself, a single undecodable record does not block an update…
        try await fixture.seed(5)
        fixture.host.insert(StoredDocument(collection: "records", id: "broken", body: .string("corrupt"), sortKey: 1e12))
        try await fixture.plugin.checkHealth(request)
        // …but data the new code cannot read at all does.
        let unreadable = try ClipboardFixture()
        defer { unreadable.close() }
        unreadable.host.insert(StoredDocument(collection: "records", id: "broken", body: .string("corrupt")))
        await #expect(throws: RuyioError.self) { try await unreadable.plugin.checkHealth(request) }
        #expect(fixture.host.lock.withLock { fixture.host.writes.isEmpty })
        #expect(fixture.host.lock.withLock { fixture.host.docs.count } == 6)
    }

    @Test func ignoredSourceDisappearsAndStaleFinderActionIsRejected() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.close() }
        await fixture.plugin.store(fixture.clip())
        let before = try await fixture.plugin.dynamicItems(provider: "recentItems")
        let id = try #require(before.items.first?.id)
        var settings = ClipboardHistoryPlugin.Settings()
        settings.ignoredApps = ["example.source"]
        try await fixture.plugin.saveSettings(settings)
        #expect(try await fixture.plugin.dynamicItems(provider: "recentItems").items.isEmpty)
        let invocation = ActionInvocation(actionID: ActionID("paste-recent"), entry: .finderContextMenu,
            finder: FinderInvocationContext(targetDirectory: FileRef(ref: "test", path: "/test", name: "test", isDirectory: true),
                selection: [], dynamicItemID: id), locale: "en")
        do {
            _ = try await fixture.plugin.saveToFinder(invocation, operation: nil)
            Issue.record("Excluded source should invalidate an old Finder menu item")
        } catch let error as RuyioError { #expect(error.code == .contextExpired) }
    }

    @Test func recopySurvivesOldDeletionAndConcurrentCommit() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.close() }
        let clip = fixture.clip()
        await fixture.plugin.store(clip)
        var id = try #require(try await fixture.plugin.dynamicItems(provider: "recentItems").items.first?.id)
        _ = try await fixture.plugin.invokeItemAction("delete", itemID: id)
        await fixture.plugin.store(clip)
        await fixture.plugin.commitPendingDelete(force: true)
        #expect(try await fixture.plugin.record(id)?.deletedAt == nil)
        #expect(try await fixture.plugin.record(id) != nil)
        _ = try await fixture.plugin.invokeItemAction("delete", itemID: id)
        async let recopy: Void = fixture.plugin.store(clip)
        async let commit: Void = fixture.plugin.commitPendingDelete(force: true)
        _ = await (recopy, commit)
        id = try #require(try await fixture.plugin.dynamicItems(provider: "recentItems").items.first?.id)
        #expect(try await fixture.plugin.record(id) != nil)
    }

    @Test func failedSettingsSaveDoesNotChangeMemoryOrDeleteHistory() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.close() }
        try await fixture.seed(1)
        fixture.host.lock.withLock { fixture.host.failSettings = true }
        var updated = ClipboardHistoryPlugin.Settings()
        updated.recording = false
        updated.retentionDays = 1
        updated.ignoredApps = ["example.source"]
        do {
            try await fixture.plugin.apply(updated)
            Issue.record("The failed settings write must reach the caller")
        } catch let error as RuyioError { #expect(error.code == .storageFailure) }
        let document = await fixture.plugin.settingsDocument()
        guard case .form(let form) = document.root else { Issue.record("Expected settings form"); return }
        #expect(form.fields.first { $0.id == "recording" }?.value == .bool(true))
        #expect(form.fields.first { $0.id == "ignoredApps" }?.value == .string(""))
        #expect(try await fixture.plugin.record("record-0") != nil)
    }

    @Test func settingsFromBeforeASettingExistedKeepTheirValues() throws {
        let saved = Data(#"{"recording":false,"retentionDays":60,"maxRecords":800,"pastePlain":true,"autoPaste":false,"ignoredApps":["a.b"]}"#.utf8)
        let settings = try JSONCoding.decoder().decode(ClipboardHistoryPlugin.Settings.self, from: saved)
        #expect(settings.retentionDays == 60 && settings.maxRecords == 800 && !settings.recording && settings.pastePlain)
        #expect(settings.ignoredApps == ["a.b"])
        #expect(settings.maxMegabytes == CaptureLimits.defaultMaxMegabytes)
    }

    @Test func overTheSpaceLimitTheOldestRegularItemsGo() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.close() }
        // 20 items of 10 MB, the oldest a favourite: 200 MB against a 100 MB limit.
        try await fixture.seed(20, megabytesEach: 10, favorites: [0])
        var settings = ClipboardHistoryPlugin.Settings()
        settings.maxMegabytes = 100
        #expect(try await fixture.plugin.prune(settings) == 11)
        // Down to 90 MB: the favourite and the 8 newest stay.
        #expect(fixture.remaining() == ["record-0"] + (12..<20).map { "record-\($0)" })

        // The settings form shows what is left.
        guard case .form(let form) = await fixture.plugin.settingsDocument().root else { Issue.record("Expected settings form"); return }
        #expect(form.footnote?.contains("9") == true)
        #expect(form.fields.contains { $0.id == "maxMegabytes" })
    }

    @Test func aFullStoreMakesRoomInsteadOfStoppingUnlessOnlyFavouritesRemain() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.close() }
        try await fixture.seed(20, megabytesEach: 10)
        // The store holds 200 MB and its quota is 100 MB: room down to 90 % of three quarters of it.
        fixture.host.lock.withLock { fixture.host.quotaBytes = 100 << 20 }
        #expect(await fixture.plugin.makeRoom())
        #expect(fixture.remaining().count == 6)

        let favourites = try ClipboardFixture()
        defer { favourites.close() }
        try await favourites.seed(5, megabytesEach: 30, favorites: Set(0..<5))
        favourites.host.lock.withLock { favourites.host.quotaBytes = 100 << 20 }
        #expect(await !favourites.plugin.makeRoom(), "favourites are never removed to make room")
        #expect(favourites.remaining().count == 5)
    }

    @Test func scrollingReachesAllHistoryWithinSchemaLimitAndKeepsSelection() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.close() }
        try await fixture.seed(550)
        var document = try await fixture.plugin.openView(ViewOpenRequest(viewID: "history", locale: "en"))
        var seen: Set<String> = []
        var loads = 0
        while true {
            try UISchemaLimits.validate(document)
            guard case .collection(let collection) = document.root else { Issue.record("Expected collection"); return }
            #expect(collection.list.items.count <= 50 * ClipboardHistoryPlugin.windowPages)
            seen.formUnion(collection.list.items.map(\.id))
            // The host asks for more when the list reaches its end (scrolling or ↓ on the last row).
            guard let cursor = collection.list.nextCursor else { break }
            let selected = collection.list.selection
            document = try #require(try await fixture.plugin.handleViewEvent(ViewEventRequest(viewID: "history", revision: 0, event: .loadNextPage(cursor: cursor))).document)
            guard case .collection(let next) = document.root else { Issue.record("Expected collection"); return }
            if loads < ClipboardHistoryPlugin.windowPages - 1 { #expect(next.list.selection == selected, "loading more never moves the selection") }
            loads += 1
        }
        #expect(seen.count == 550)
        guard case .collection(let end) = document.root else { Issue.record("Expected collection"); return }
        #expect(end.list.items.last?.id == "record-0")
        // Newer rows slid out of the window and can be brought back step by step or all at once.
        #expect(end.footerActions.contains { $0.id == "previous-page" } && end.footerActions.contains { $0.id == "newest" })
        while case .collection(let current) = document.root, current.footerActions.contains(where: { $0.id == "previous-page" }) {
            document = try #require(try await fixture.plugin.invokeItemAction("previous-page", itemID: nil).document)
            try UISchemaLimits.validate(document)
        }
        guard case .collection(let first) = document.root else { Issue.record("Expected collection"); return }
        #expect(first.list.items.first?.id == "record-549")
    }

    @Test func undoOnALaterPageKeepsTheWindowAndSelectsTheRestoredRecord() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.close() }
        try await fixture.seed(120)
        var document = try await fixture.plugin.openView(ViewOpenRequest(viewID: "history", locale: "en"))
        guard case .collection(let first) = document.root, let cursor = first.list.nextCursor else { Issue.record("Expected more pages"); return }
        document = try #require(try await fixture.plugin.handleViewEvent(ViewEventRequest(viewID: "history", revision: 0, event: .loadNextPage(cursor: cursor))).document)
        _ = try await fixture.plugin.handleViewEvent(ViewEventRequest(viewID: "history", revision: 0, event: .selectionChanged("record-30")))
        let deleted = try #require(try await fixture.plugin.invokeItemAction("delete", itemID: "record-30").document)
        guard case .collection(let afterDelete) = deleted.root, let undo = afterDelete.undo else { Issue.record("Expected undo"); return }
        document = try #require(try await fixture.plugin.handleViewEvent(ViewEventRequest(viewID: "history", revision: 0, event: .undo(token: undo.token))).document)
        guard case .collection(let restored) = document.root else { Issue.record("Expected collection"); return }
        #expect(restored.list.items.count == 100)
        #expect(restored.list.selection == "record-30")
        #expect(restored.footerActions.contains { $0.id == "paste" })
    }

    @Test func lateSearchResponseCannotOverwriteLatestSearch() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.close() }
        for text in ["older", "newer"] {
            let record = try await fixture.plugin.makeRecord(fixture.clip(text), kind: .text, fingerprint: text, date: Date())
            try fixture.host.insert(record.document())
        }
        _ = try await fixture.plugin.openView(ViewOpenRequest(viewID: "history", locale: "en"))
        fixture.host.lock.withLock { fixture.host.delayedSearch = "older" }
        let oldTask = Task {
            try await fixture.plugin.handleViewEvent(ViewEventRequest(viewID: "history", revision: 1, event: .searchChanged("older")))
        }
        await fixture.host.queryBarrier.waitUntilEntered()
        _ = try await fixture.plugin.handleViewEvent(ViewEventRequest(viewID: "history", revision: 1, event: .searchChanged("newer")))
        await fixture.host.queryBarrier.release()
        _ = try await oldTask.value
        let document = try await fixture.plugin.historyDocument(selectFirst: true)
        guard case .collection(let collection) = document.root else { Issue.record("Expected collection"); return }
        #expect(collection.searchText == "newer")
        #expect(collection.list.items.map(\.title) == ["newer"])
    }

    @Test func defaultPlainPasteKeepsImagesAndMissingFilesOfferCopyPaths() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.close() }
        var settings = ClipboardHistoryPlugin.Settings()
        settings.pastePlain = true
        try await fixture.plugin.saveSettings(settings)
        let image = ClipRecord(id: "image", kind: .image, items: [.init(representations: [
            .init(type: PasteboardRules.png, text: nil, blobID: "synthetic-image", byteCount: 10)
        ])], fingerprint: "image", title: "Image", searchText: "Image", sourceApp: nil, sourceBundleID: nil, date: Date())
        try fixture.host.insert(image.document())
        let pasted = try await fixture.plugin.invokeItemAction("paste", itemID: "image")
        #expect(pasted.effect == .closeAndPaste(plainText: false, autoPaste: true))
        #expect(fixture.host.lock.withLock { fixture.host.writes.last?.items.first?.representations.first?.type } == PasteboardRules.png)
        let file = CapturedClip(items: [[PasteboardRules.fileURL: Data("file:///missing/report.txt".utf8)]],
            sourceApp: nil, sourceBundleID: nil, changeCount: 1, skippedOversize: false)
        let record = try await fixture.plugin.makeRecord(file, kind: .file, fingerprint: "file", date: Date())
        try fixture.host.insert(record.document())
        _ = try await fixture.plugin.openView(ViewOpenRequest(viewID: "history", locale: "en"))
        fixture.host.lock.withLock { fixture.host.denyFileURLs = true }
        let failed = try await fixture.plugin.invokeItemAction("paste", itemID: record.id)
        #expect(failed.document != nil)
        guard case .notice = failed.effect else { Issue.record("Missing files should keep the view open with a notice"); return }
        _ = try await fixture.plugin.invokeItemAction("copy-paths", itemID: record.id)
        #expect(fixture.host.lock.withLock { fixture.host.writes.last?.items.first?.representations.first?.text } == "/missing/report.txt")
    }
    @Test func longRichCopyMovesItsLargestTextsToBlobsUntilTheRecordFits() async throws {
        // About 85k Chinese characters of article text plus its HTML, each under the single-text inline limit.
        let text = String(repeating: "长文剪贴板历史测试", count: 9_500)
        let html = "<p>" + String(repeating: "<span class=\"x\">长文</span>", count: 3_000) + "</p>"
        var record = ClipRecord(id: "long", kind: .richText, items: [.init(representations: [
            .init(type: PasteboardRules.text, text: text, blobID: nil, byteCount: text.utf8.count),
            .init(type: PasteboardRules.html, text: html, blobID: nil, byteCount: html.utf8.count),
        ])], fingerprint: "long", title: "长文", searchText: ClipText.searchText(for: text), sourceApp: nil, sourceBundleID: nil, date: Date())
        #expect(try JSONCoding.encoder().encode(record.document()).count > StorageLimits.maxDocumentBytes)
        var blobs: [Data] = []
        try await ClipboardHistoryPlugin.fitDocument(&record) { blobs.append($0); return "blob-\(blobs.count)" }
        #expect(try JSONCoding.encoder().encode(record.document()).count <= StorageLimits.maxDocumentBytes)
        let reps = record.items[0].representations
        // Largest first and only as much as needed: the article text moves out with its exact bytes.
        #expect(reps[0].text == nil && reps[0].blobID == "blob-1")
        #expect(blobs == [Data(text.utf8)])
        #expect(reps[1].text == html)
    }
}

extension ClipboardHistoryRegressionTests {
    @Test func onlyWholeObjectsAndArraysCountAsJSON() {
        for text in [#"{"a": 1}"#, "  [1, 2, {\"b\": null}]\n", "{}", "[]"] { #expect(JSONDetection.isStructured(text), "\(text)") }
        for text in ["42", "true", #""quoted""#, "{not json}", "[1, 2", "plain words", #"{"a": 1} trailing"#] {
            #expect(!JSONDetection.isStructured(text), "\(text)")
        }
    }

    @Test func jsonIsFlaggedFilteredAndPreviewedAsJSON() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.close() }
        let source = #"{"b": 1, "a": [true, null]}"#
        let json = try await fixture.plugin.makeRecord(fixture.clip(source), kind: .text, fingerprint: "json", date: Date(timeIntervalSince1970: 2))
        let plain = try await fixture.plugin.makeRecord(fixture.clip("just words"), kind: .text, fingerprint: "plain", date: Date(timeIntervalSince1970: 1))
        #expect(json.isJSON == true && plain.isJSON == false)
        fixture.host.insert(try json.document())
        fixture.host.insert(try plain.document())
        _ = try await fixture.plugin.openView(ViewOpenRequest(viewID: "history", locale: "en"))
        let reply = try await fixture.plugin.handleViewEvent(ViewEventRequest(viewID: "history", revision: 0, event: .filterChanged("json")))
        guard case .collection(let collection)? = reply.document?.root else { Issue.record("Expected collection"); return }
        #expect(collection.filters.map(\.id) == ["all", "text", "json", "image", "url", "file", "favorite"])
        #expect(collection.list.items.map(\.id) == [json.id])
        #expect(collection.list.items.first?.symbol == "curlybraces")
        guard case .stack(let stack)? = collection.preview else { Issue.record("Expected preview"); return }
        #expect(stack.children.contains(.json(source)))
    }

    @Test func recordsFromBeforeDetectionAreFlaggedOnce() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.close() }
        var old = try await fixture.plugin.makeRecord(fixture.clip(#"[{"id": 1}]"#), kind: .text, fingerprint: "old", date: Date())
        old.isJSON = nil
        var words = try await fixture.plugin.makeRecord(fixture.clip("words"), kind: .text, fingerprint: "words", date: Date())
        words.isJSON = nil
        fixture.host.insert(try old.document())
        fixture.host.insert(try words.document())
        await fixture.plugin.flagJSONInEarlierRecords()
        let stored = fixture.host.lock.withLock { fixture.host.docs }
        #expect(stored["records/\(old.id)"]?.fields["json"] == .bool(true))
        #expect(stored["records/\(words.id)"]?.fields["json"] == .bool(false))
        #expect(stored["settings/json-detection-v1"] != nil)
    }
}
