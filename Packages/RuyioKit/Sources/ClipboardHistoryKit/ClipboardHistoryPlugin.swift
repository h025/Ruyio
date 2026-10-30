import AppKit
import Foundation
import RuyioPluginSDK

/// Official Clipboard History plugin (PRD §8, plan §12). Runs sandboxed in its own process.
public final class ClipboardHistoryPlugin: RuyioPlugin, @unchecked Sendable {
    public struct Settings: Codable, Sendable, Hashable {
        public var recording = true
        public var retentionDays = CaptureLimits.defaultRetentionDays
        public var maxRecords = CaptureLimits.defaultMaxRecords
        /// Disk space for the whole history, favourites included; the oldest unfavourited items go first.
        public var maxMegabytes = CaptureLimits.defaultMaxMegabytes
        public var pastePlain = false
        public var autoPaste = true
        public var ignoredApps: [String] = []

        public init() {}

        /// Keys a newer version added keep their defaults: settings saved by an older one must survive, not
        /// fail to decode and silently fall back to defaults altogether.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Settings()
            recording = try c.decodeIfPresent(Bool.self, forKey: .recording) ?? defaults.recording
            retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? defaults.retentionDays
            maxRecords = try c.decodeIfPresent(Int.self, forKey: .maxRecords) ?? defaults.maxRecords
            maxMegabytes = try c.decodeIfPresent(Int.self, forKey: .maxMegabytes) ?? defaults.maxMegabytes
            pastePlain = try c.decodeIfPresent(Bool.self, forKey: .pastePlain) ?? defaults.pastePlain
            autoPaste = try c.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? defaults.autoPaste
            ignoredApps = try c.decodeIfPresent([String].self, forKey: .ignoredApps) ?? defaults.ignoredApps
        }
    }

    struct ViewState {
        var revision = 0
        var query = ""
        var filter = "all"
        var selection: String?
        /// Cursor after the last loaded record; the host asks for the next page when the list reaches it.
        var cursor: String?
        /// Start cursor and record count of each page in the window (newest first).
        var pageStarts: [String?] = []
        var pageCounts: [Int] = []
        /// Start cursors of newer pages that slid out of the window, most recent last.
        var droppedPages: [String?] = []
        var loadingPage = false
        var items: [ClipRecord] = []
        var pendingUndo: (token: String, recordID: String, expires: Date)?
    }

    let context: PluginContext
    private let lock = NSLock()
    private var settings = Settings()
    private var captureState: CaptureState = .userPaused
    private var captureDetail: String?
    private var view = ViewState()
    private var viewGeneration = 0
    /// Open/close pairs, not a flag: a late `viewClose` from the previous session must not mark a newly
    /// opened history as closed (events and requests are delivered concurrently).
    private var historyOpenCount = 0
    private var historyIsOpen: Bool { historyOpenCount > 0 }
    private var dynamicGeneration = 0
    private var unavailableFiles: Set<String> = []
    private let mutations = ClipboardMutationQueue()
    private let settingsMutations = ClipboardMutationQueue()
    private var pendingSettings: Settings?
    private var capturesSinceCleanup = 0
    private var monitor: CaptureMonitor?
    private var maintenanceTask: Task<Void, Never>?
    /// Textual representations above this size are stored as blobs: an inline body must fit one IPC frame.
    static let inlineTextLimit = 256 * 1024
    /// Infinite scroll keeps at most this many pages loaded; older scrolling slides the window so the
    /// rows plus preview stay under the 500-node schema limit.
    static let windowPages = 8

    static let historyView = "history"
    static let settingsView = "settings"
    static let settingsKey = StorageKey(collection: "settings", id: "main")

    public init(context: PluginContext) {
        self.context = context
    }

    var strings: Strings { Strings(locale: context.locale) }

    // MARK: Lifecycle

    public func start() async {
        if let stored = try? await context.storage.get(collection: Self.settingsKey.collection, id: Self.settingsKey.id),
           let decoded = try? JSONCoding.decode(Settings.self, from: stored.body) {
            lock.withLock { settings = decoded }
        }
        await purgeExpiredSoftDeletes()
        await applyRetention()
        await MainActor.run { self.setUpMonitor() }
        Task { await self.flagJSONInEarlierRecords() }
        await publishDynamicItems()
        // Retention is a promise about the past, not about the next copy: enforce it on a clock too.
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard let self, !Task.isCancelled else { return }
                await self.purgeExpiredSoftDeletes()
                await self.applyRetention()
                await self.publishDynamicItems()
                self.refreshOpenView()
            }
        }
        lock.withLock { maintenanceTask = task }
    }

    /// Records captured before JSON detection get their flag once, so the JSON filter finds them too.
    func flagJSONInEarlierRecords() async {
        let marker = StorageKey(collection: Self.settingsKey.collection, id: "json-detection-v1")
        guard (try? await context.storage.get(collection: marker.collection, id: marker.id)) == nil else { return }
        var cursor: String?
        repeat {
            guard let page = try? await context.storage.query(StorageQuery(
                collection: ClipRecord.collection, filters: [StorageFilter(field: "kind", value: .string("text"))], limit: 200, cursor: cursor))
            else { return }
            for document in page.documents {
                guard let record = try? ClipRecord(from: document), record.isJSON == nil,
                      let text = record.plainText(), JSONDetection.isStructured(text) else { continue }
                try? await mutations.run {
                    guard var current = try await self.record(record.id), current.isJSON == nil else { return }
                    current.isJSON = true
                    try await self.context.storage.put(try current.document())
                }
            }
            cursor = page.nextCursor
        } while cursor != nil
        try? await context.storage.put(StoredDocument(collection: marker.collection, id: marker.id, body: .bool(true)))
        refreshOpenView()
    }

    public func shutdown() async {
        lock.withLock { maintenanceTask }?.cancel()
        await MainActor.run { monitor?.stop() }
    }

    /// Update verification must inspect the prepared generation without enabling capture.
    public func checkHealth(_ request: DataPreparationRequest) async throws {
        if let stored = try await context.storage.get(collection: Self.settingsKey.collection, id: Self.settingsKey.id) {
            _ = try JSONCoding.decode(Settings.self, from: stored.body)
        }
        // The history skips a record it cannot decode, so one bad record must not block every update; a
        // newest page with nothing readable means the new code cannot read this data at all.
        let page = try await context.storage.query(StorageQuery(collection: ClipRecord.collection, limit: 200))
        if !page.documents.isEmpty, !page.documents.contains(where: { (try? ClipRecord(from: $0)) != nil }) {
            throw RuyioError(.storageFailure, diagnostic: "history records are unreadable")
        }
    }

    /// Status text, Finder item titles and an open view are all re-rendered in the new language.
    public func localeChanged(_ locale: String) async {
        let (state, detail) = lock.withLock { (captureState, captureDetail) }
        captureStateChanged(state, detail)
        await publishDynamicItems()
        refreshOpenView()
    }

    @MainActor
    private func setUpMonitor() {
        let monitor = CaptureMonitor()
        monitor.ignoredBundleIDs = Set(lock.withLock { settings.ignoredApps })
        monitor.onStateChange = { [weak self] state, detail in self?.captureStateChanged(state, detail) }
        monitor.onCapture = { [weak self] clip in
            guard let self else { return }
            Task { await self.store(clip) }
        }
        self.monitor = monitor
        if lock.withLock({ settings.recording }) { monitor.start() } else { monitor.pause() }
    }

    private func captureStateChanged(_ state: CaptureState, _ detail: String?) {
        lock.withLock {
            captureState = state
            captureDetail = detail
        }
        let s = strings
        let text: String
        switch state {
        case .recording: text = s.t("正在记录", "Recording")
        case .userPaused: text = s.t("记录已暂停", "Paused")
        case .blockedBySystem: text = s.t("系统阻止读取", "Blocked by macOS")
        case .suspended: text = s.t("已挂起", "Suspended")
        case .failed: text = s.t("记录失败", "Recording failed")
        case .unknown: text = s.t("状态未知", "Status unknown")
        }
        context.publishStatus(PluginStatusReport(captureState: state, statusText: text, detail: detail))
        refreshOpenView()
    }

    // MARK: Capture

    func store(_ clip: CapturedClip) async {
        let fingerprint = PasteboardRules.fingerprint(items: clip.items)
        guard let kind = PasteboardRules.kind(of: clip.items) else { return }
        let now = Date()
        do {
            let handled = try await mutations.run { () -> Bool in
                guard !self.isIgnored(clip.sourceBundleID) else { return true }
                return try await self.recopyExisting(fingerprint: fingerprint, clip: clip, date: now)
            }
            if !handled {
                // Blob uploads and thumbnails happen outside the queue so paste, delete and undo never wait
                // behind a large capture. Orphaned blobs of a record that lost the race are collected later.
                let record = try await makeRecord(clip, kind: kind, fingerprint: fingerprint, date: now)
                try await mutations.run {
                    guard !self.isIgnored(clip.sourceBundleID) else { return }
                    if try await self.recopyExisting(fingerprint: fingerprint, clip: clip, date: now) { return }
                    try await self.context.storage.put(try record.document())
                }
            }
        } catch {
            // A full store first makes room from the oldest unfavourited records: this item is lost, the next
            // one fits. Only when favourites alone fill it does recording stop (and "Recheck" re-probes);
            // a single item that could not be saved does not.
            if (error as? RuyioError)?.code == .storageQuotaExceeded, await !makeRoom() {
                captureStateChanged(.failed, ErrorCode.storageQuotaExceeded.rawValue)
            }
            return
        }
        let needsCleanup = lock.withLock { () -> Bool in
            capturesSinceCleanup += 1
            if capturesSinceCleanup < 25 { return false }
            capturesSinceCleanup = 0
            return true
        }
        if needsCleanup {
            await applyRetention()
        }
        await publishDynamicItems()
        refreshOpenView()
    }

    /// Same content again: move to top and count it (Maccy semantics; PRD §8.2 de-dup). Call inside `mutations`.
    private func recopyExisting(fingerprint: String, clip: CapturedClip, date: Date) async throws -> Bool {
        let existing = try await context.storage.query(StorageQuery(collection: ClipRecord.collection, filters: [
            StorageFilter(field: "fingerprint", value: .string(fingerprint)),
        ], limit: 1)).documents.first
        guard let existing, var record = try? ClipRecord(from: existing) else { return false }
        record.lastCopiedAt = date
        record.copyCount += 1
        record.deletedAt = nil
        record.sourceApp = clip.sourceApp ?? record.sourceApp
        record.sourceBundleID = clip.sourceBundleID ?? record.sourceBundleID
        try await context.storage.put(try record.document())
        lock.withLock {
            if view.pendingUndo?.recordID == record.id { view.pendingUndo = nil }
        }
        return true
    }

    func makeRecord(_ clip: CapturedClip, kind: PasteboardRules.Kind, fingerprint: String, date: Date) async throws -> ClipRecord {
        var items: [ClipRecord.Item] = []
        var thumbnail: String?
        var preview: String?
        var imageSize: [Int]?
        var fileNames: [String] = []
        var filePaths: [String] = []
        var searchParts: [String] = []
        var titleSource: String?
        for item in clip.items {
            var representations: [ClipRecord.Representation] = []
            for type in item.keys.sorted() {
                guard let data = item[type] else { continue }
                let isTextual = [PasteboardRules.text, PasteboardRules.url, PasteboardRules.fileURL, PasteboardRules.html].contains(type)
                if isTextual, let string = String(data: data, encoding: .utf8) {
                    if data.count <= Self.inlineTextLimit {
                        representations.append(.init(type: type, text: string, blobID: nil, byteCount: data.count))
                    } else {
                        // Large text keeps its full bytes in a blob; title and search still use the text.
                        representations.append(.init(type: type, text: nil, blobID: try await context.storage.putBlob(data), byteCount: data.count))
                    }
                    if type == PasteboardRules.text { titleSource = string } else if type == PasteboardRules.url && titleSource == nil { titleSource = string }
                    if type == PasteboardRules.text || type == PasteboardRules.url { searchParts.append(ClipText.searchText(for: string)) }
                    if type == PasteboardRules.fileURL, let url = URL(string: string) {
                        fileNames.append(url.lastPathComponent)
                        filePaths.append(url.path)
                    }
                } else {
                    let blob = try await context.storage.putBlob(data)
                    representations.append(.init(type: type, text: nil, blobID: blob, byteCount: data.count))
                    if PasteboardRules.imageTypes.contains(type), thumbnail == nil, let thumb = ImageThumbnails.png(from: data, maxPixel: 256) {
                        thumbnail = try await context.storage.putBlob(thumb.png)
                        imageSize = [thumb.width, thumb.height]
                        if let large = ImageThumbnails.png(from: data, maxPixel: 1024) {
                            preview = try await context.storage.putBlob(large.png)
                        }
                    }
                }
            }
            items.append(.init(representations: representations))
        }
        let s = strings
        let title: String
        switch kind {
        case .file: title = s.filesTitle(fileNames.first ?? s.kindName(.file), fileNames.count)
        case .image: title = imageSize.map { s.imageTitle($0[0], $0[1]) } ?? s.kindName(.image)
        default:
            title = ClipText.title(for: titleSource ?? "")
        }
        searchParts.append(contentsOf: fileNames)
        if let app = clip.sourceApp { searchParts.append(app) }
        var record = ClipRecord(id: UUID().uuidString.lowercased(), kind: kind, items: items, fingerprint: fingerprint, title: title,
                                searchText: searchParts.joined(separator: "\n"), sourceApp: clip.sourceApp, sourceBundleID: clip.sourceBundleID, date: date)
        record.thumbnailBlobID = thumbnail
        record.previewBlobID = preview
        record.imageSize = imageSize
        record.fileNames = fileNames.isEmpty ? nil : fileNames
        record.filePaths = filePaths.isEmpty ? nil : filePaths
        // Decided on the full text, before large text moves to blobs.
        if kind == .text || kind == .richText { record.isJSON = record.plainText().map(JSONDetection.isStructured) ?? false }
        let storage = context.storage
        try await Self.fitDocument(&record) { try await storage.putBlob($0) }
        return record
    }

    /// A long rich copy (an article's text plus its HTML) can outgrow one stored document. Its largest
    /// inline texts move to blobs, as single large texts already do, until the record fits a history page.
    static func fitDocument(_ record: inout ClipRecord, putBlob: (Data) async throws -> String) async throws {
        var inline = record.items.indices.flatMap { i in record.items[i].representations.indices.map { (i, $0) } }
            .filter { record.items[$0.0].representations[$0.1].text != nil }
            .sorted { record.items[$0.0].representations[$0.1].byteCount > record.items[$1.0].representations[$1.1].byteCount }
        var size = try JSONCoding.encoder().encode(record.document()).count
        while size > StorageLimits.maxDocumentBytes, !inline.isEmpty {
            let (i, j) = inline.removeFirst()
            let text = record.items[i].representations[j].text ?? ""
            record.items[i].representations[j].blobID = try await putBlob(Data(text.utf8))
            record.items[i].representations[j].text = nil
            // Estimate from the moved text alone; measure the whole record again only once it seems to fit.
            size -= try JSONCoding.encoder().encode(text).count - 96
            if size <= StorageLimits.maxDocumentBytes { size = try JSONCoding.encoder().encode(record.document()).count }
        }
    }

    // MARK: Retention (PRD §8.4, §19.16)

    /// Unfavourited records past the retention days, beyond the record limit, or, oldest first, beyond the
    /// disk space (A45). `byteLimit` overrides the setting, to make room when the store is full.
    func recordsToPrune(_ settings: Settings, byteLimit: Int64? = nil, now: Date = Date()) async throws -> [String] {
        var ids: [String] = []
        var chosen: Set<String> = []
        var freed: Int64 = 0
        func choose(_ document: StoredDocument) {
            guard chosen.insert(document.id).inserted else { return }
            ids.append(document.id)
            freed += (try? ClipRecord(from: document)).map { Int64($0.byteCount) } ?? 0
        }
        let cutoff = now.addingTimeInterval(-Double(settings.retentionDays) * 86_400).timeIntervalSince1970
        let base = [StorageFilter(field: "favorite", value: false)]
        var cursor: String?
        repeat {
            let page = try await context.storage.query(StorageQuery(collection: ClipRecord.collection,
                                                                    filters: base + [StorageFilter(field: "lastCopiedAt", op: .lessThan, value: .number(cutoff))],
                                                                    limit: 200, cursor: cursor))
            page.documents.forEach(choose)
            cursor = page.nextCursor
        } while cursor != nil && ids.count < 50_000
        let total = try await context.storage.count(StorageQuery(collection: ClipRecord.collection, filters: base))
        var excess = total - ids.count - settings.maxRecords
        // Over the space limit, the oldest go down to 90 % of it, so the next captures do not prune again at once.
        let limit = byteLimit ?? (Int64(settings.maxMegabytes) << 20)
        let used = try await context.storage.usage().bytes
        var overSpace = used - freed > limit ? used - freed - limit * 9 / 10 : 0
        var oldestCursor: String?
        while excess > 0 || overSpace > 0 {
            let page = try await context.storage.query(StorageQuery(collection: ClipRecord.collection, filters: base, limit: 200,
                                                                    cursor: oldestCursor, ascending: true))
            for document in page.documents where !chosen.contains(document.id) && (excess > 0 || overSpace > 0) {
                let before = freed
                choose(document)
                excess -= 1
                overSpace -= freed - before
            }
            oldestCursor = page.nextCursor
            if oldestCursor == nil { break }
        }
        return ids
    }

    func applyRetention() async {
        let current = lock.withLock { settings }
        _ = try? await prune(current)
    }

    /// Chooses and deletes in one mutation, so a record favourited or copied again meanwhile is never pruned.
    /// Returns how many records went.
    @discardableResult
    func prune(_ settings: Settings, byteLimit: Int64? = nil) async throws -> Int {
        try await mutations.run {
            let ids = try await self.recordsToPrune(settings, byteLimit: byteLimit)
            try await self.deleteBatch(ids)
            return ids.count
        }
    }

    /// The store refused a capture as full: the oldest unfavourited records make room, down to three
    /// quarters of the quota or the space setting, whichever is lower. False when nothing could go.
    func makeRoom() async -> Bool {
        let current = lock.withLock { settings }
        guard let quota = try? await context.storage.usage().quotaBytes else { return false }
        let limit = min(Int64(current.maxMegabytes) << 20, quota * 3 / 4)
        return ((try? await prune(current, byteLimit: limit)) ?? 0) > 0
    }

    /// Call inside `mutations`.
    private func deleteBatch(_ ids: [String]) async throws {
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            try await context.storage.batch(chunk.map { .delete(StorageKey(collection: ClipRecord.collection, id: $0)) })
        }
    }

    func purgeExpiredSoftDeletes() async {
        try? await mutations.run {
            var cursor: String?
            repeat {
                let page = try await context.storage.query(StorageQuery(collection: ClipRecord.collection,
                    filters: [StorageFilter(field: "deleted", value: true)], limit: 200, cursor: cursor))
                let expired = page.documents.compactMap { try? ClipRecord(from: $0) }
                    .filter { ($0.deletedAt ?? .distantFuture).timeIntervalSinceNow < -CaptureLimits.undoWindow }.map(\.id)
                if !expired.isEmpty {
                    try await context.storage.batch(expired.map { .delete(StorageKey(collection: ClipRecord.collection, id: $0)) })
                }
                cursor = page.nextCursor
            } while cursor != nil
        }
    }

    // MARK: Finder dynamic items (metadata titles only, PRD §19.17)

    func publishDynamicItems() async {
        let generation = lock.withLock { dynamicGeneration += 1; return dynamicGeneration }
        guard let report = try? await recentItemsReport(provider: "recentItems") else { return }
        lock.withLock {
            guard dynamicGeneration == generation else { return }
            context.publishDynamicItems(report)
        }
    }

    private func isIgnored(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return lock.withLock { settings.ignoredApps.contains(bundleID) }
    }

    private func recentItemsReport(provider: String) async throws -> DynamicItemsReport {
        let ignored = lock.withLock { Set(settings.ignoredApps) }
        var records: [ClipRecord] = []
        var cursor: String?
        var pages = 0
        // File records never become Finder items; a history mostly from ignored apps is scanned only so far.
        repeat {
            let page = try await context.storage.query(StorageQuery(collection: ClipRecord.collection,
                filters: [StorageFilter(field: "deleted", value: false), StorageFilter(field: "kind", op: .notEquals, value: .string(PasteboardRules.Kind.file.filter))],
                limit: 50, cursor: cursor))
            records += page.documents.compactMap { try? ClipRecord(from: $0) }
                .filter { $0.kind != .file && !ignored.contains($0.sourceBundleID ?? "") }
            cursor = page.nextCursor
            pages += 1
        } while records.count < 5 && cursor != nil && pages < 4
        let s = strings
        let recent = records.prefix(5)
        let items = recent.map { record -> DynamicItemsReport.Item in
            var title = s.saveAsFilePrefix + s.kindName(record.kind) + " · " + record.lastCopiedAt.clock(locale: context.locale)
            if let app = record.sourceApp { title += " · " + app }
            return DynamicItemsReport.Item(id: record.id, title: title, kind: record.kind.filter)
        }
        let kinds = records.first.map { [$0.kind.filter] } ?? []
        return DynamicItemsReport(provider: provider, items: Array(items), clipboardKinds: kinds)
    }

    public func dynamicItems(provider: String) async throws -> DynamicItemsReport {
        try await recentItemsReport(provider: provider)
    }

    // MARK: Actions

    public func perform(_ invocation: ActionInvocation, execution: ExecutionID, operation: OperationID?) async throws -> ActionResult {
        switch invocation.actionID.rawValue {
        case "show-history":
            return .succeeded(.openView(Self.historyView))
        case "toggle-recording":
            try await toggleRecording()
            return .succeeded()
        case "paste-recent":
            return try await saveToFinder(invocation, operation: operation)
        default:
            throw RuyioError(.actionNotFound, objectID: invocation.actionID.rawValue)
        }
    }

    func toggleRecording() async throws {
        let (state, recording) = lock.withLock { (captureState, settings.recording) }
        if state == .blockedBySystem || state == .failed || state == .unknown {
            await MainActor.run { monitor?.recheck() }
            return
        }
        try await saveSettings { $0.recording = !recording }
    }

    /// Writes a frozen history record into the Finder target directory through the host file broker.
    func saveToFinder(_ invocation: ActionInvocation, operation: OperationID?) async throws -> ActionResult {
        guard let directory = invocation.finder?.targetDirectory, let id = invocation.finder?.dynamicItemID,
              let doc = try await context.storage.get(collection: ClipRecord.collection, id: id),
              let record = try? ClipRecord(from: doc), record.deletedAt == nil, !isIgnored(record.sourceBundleID) else {
            throw RuyioError(.contextExpired, recovery: .retry)
        }
        let item = try fileItem(for: record)
        let reply = try await context.capabilities.writeFiles(FileWriteRequest(directory: directory, items: [item], conflictPolicy: .ask),
                                                             operation: operation ?? OperationID())
        guard let outcome = reply.outcomes.first else { throw RuyioError(.fileWriteFailed) }
        switch outcome.status {
        case .written: return .succeeded(.notice(strings.t("已保存到 Finder", "Saved in Finder")))
        case .skipped, .cancelled: return ActionResult(state: .cancelled)
        default: throw RuyioError(ErrorCode(rawValue: outcome.errorCode ?? ErrorCode.fileWriteFailed.rawValue), objectID: outcome.requestedName)
        }
    }

    func fileItem(for record: ClipRecord) throws -> FileWriteItem {
        let stamp = Self.fileStamp(record.lastCopiedAt)
        let reps = record.items.first?.representations ?? []
        switch record.kind {
        case .url:
            let link = reps.first { $0.type == PasteboardRules.url }?.text ?? record.plainText() ?? ""
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>URL</key><string>\(Self.xmlEscape(link.trimmingCharacters(in: .whitespacesAndNewlines)))</string></dict></plist>
            """
            return FileWriteItem(fileName: Self.savedFileName(.url, stamp: stamp, ext: "webloc", strings: strings), source: .text(plist))
        case .image:
            let ordered = [PasteboardRules.png, PasteboardRules.jpeg, PasteboardRules.heic, PasteboardRules.tiff]
            for type in ordered {
                if let rep = reps.first(where: { $0.type == type }), let blob = rep.blobID {
                    let ext = type == PasteboardRules.jpeg ? "jpg" : (type == PasteboardRules.heic ? "heic" : (type == PasteboardRules.tiff ? "tiff" : "png"))
                    return FileWriteItem(fileName: Self.savedFileName(.image, stamp: stamp, ext: ext, strings: strings), source: .blob(blob))
                }
            }
            throw RuyioError(.fileWriteFailed, diagnostic: "image data missing")
        case .text, .richText:
            let name = Self.savedFileName(record.kind, stamp: stamp, ext: "txt", strings: strings)
            // Large text lives in a blob (see `inlineTextLimit`); save the full bytes, not the title.
            if let blob = reps.first(where: { $0.type == PasteboardRules.text })?.blobID { return FileWriteItem(fileName: name, source: .blob(blob)) }
            return FileWriteItem(fileName: name, source: .text(record.plainText() ?? record.title))
        case .file:
            throw RuyioError(.invalidRequest, diagnostic: "file records are pasted from the history panel")
        }
    }

    /// Default name from content type and time, in the UI language (PRD §19.17). Rich text is saved as plain text.
    static func savedFileName(_ kind: PasteboardRules.Kind, stamp: String, ext: String, strings: Strings) -> String {
        "\(strings.kindName(kind == .richText ? .text : kind)) \(stamp).\(ext)"
    }

    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Settings

    func saveSettings(_ updated: Settings) async throws {
        try await saveSettings { $0 = updated }
    }

    /// Reads the current settings inside the queue, so concurrent changes (menu toggle, settings form) never
    /// write back each other's stale values.
    func saveSettings(_ change: @escaping @Sendable (inout Settings) -> Void) async throws {
        try await settingsMutations.run {
            var updated = lock.withLock { settings }
            change(&updated)
            let body = try JSONCoding.value(updated)
            try await context.storage.put(StoredDocument(collection: Self.settingsKey.collection, id: Self.settingsKey.id, body: body))
            let previous = lock.withLock { () -> Settings in
                let previous = settings
                settings = updated
                dynamicGeneration += 1
                return previous
            }
            await MainActor.run {
                monitor?.ignoredBundleIDs = Set(updated.ignoredApps)
                if previous.recording != updated.recording { updated.recording ? monitor?.start() : monitor?.pause() }
            }
            await publishDynamicItems()
        }
    }

    // MARK: Views

    public func openView(_ request: ViewOpenRequest) async throws -> ViewDocument {
        switch request.viewID {
        case Self.historyView:
            // The previous search is not kept across sessions (PRD §19.15).
            lock.withLock { view = ViewState(revision: view.revision + 1); viewGeneration += 1; historyOpenCount += 1 }
            do {
                try await reloadItems()
                return try await historyDocument(selectFirst: true)
            } catch {
                // The host only closes views that opened successfully.
                lock.withLock { historyOpenCount = max(0, historyOpenCount - 1) }
                throw error
            }
        case Self.settingsView:
            return await settingsDocument()
        default:
            throw RuyioError(.invalidRequest, diagnostic: "unknown view \(request.viewID)")
        }
    }

    public func closeView(_ viewID: String) async {
        if viewID == Self.historyView {
            lock.withLock { historyOpenCount = max(0, historyOpenCount - 1); viewGeneration += 1 }
            await commitPendingDelete(force: true)
        }
    }

    public func handleViewEvent(_ request: ViewEventRequest) async throws -> ViewEventReply {
        if request.viewID == Self.settingsView { return try await handleSettingsEvent(request.event) }
        switch request.event {
        case .searchChanged(let text):
            lock.withLock { view.query = text; view.cursor = nil }
            try await reloadItems()
            return ViewEventReply(document: try await historyDocument(selectFirst: true))
        case .filterChanged(let filter):
            lock.withLock { view.filter = filter; view.cursor = nil }
            try await reloadItems()
            return ViewEventReply(document: try await historyDocument(selectFirst: true))
        case .selectionChanged(let id):
            lock.withLock { view.selection = id }
            return ViewEventReply(document: try await historyDocument(selectFirst: false))
        case .loadNextPage:
            try await loadNextPage()
            return ViewEventReply(document: try await historyDocument(selectFirst: false))
        case .undo(let token):
            try await undoDelete(token)
            return ViewEventReply(document: try await historyDocument(selectFirst: false))
        case .invoke(let actionID, let itemID):
            return try await invokeItemAction(actionID, itemID: itemID ?? lock.withLock { view.selection })
        case .cancel, .submit, .fieldChanged:
            return ViewEventReply(document: nil)
        }
    }

    func invokeItemAction(_ actionID: String, itemID: String?) async throws -> ViewEventReply {
        let s = strings
        switch actionID {
        case "paste", "paste-plain", "copy-only":
            guard let itemID, let record = try await record(itemID), record.deletedAt == nil else { return ViewEventReply(document: nil) }
            let current = lock.withLock { settings }
            let plain = supportsPlainText(record) && (actionID == "paste-plain" || (actionID == "paste" && current.pastePlain))
            let reply: ClipboardWriteReply
            do {
                reply = try await context.capabilities.writeClipboard(clipboardRequest(for: record, plainText: plain))
            } catch let error as RuyioError where record.kind == .file && error.code == .fileAccessDenied {
                lock.withLock { unavailableFiles.insert(itemID); view.selection = itemID }
                return ViewEventReply(document: try await historyDocument(selectFirst: false),
                                      effect: .notice(s.t("文件已移动、删除或无法访问，可以复制路径。", "The files were moved, deleted, or are inaccessible. You can copy their paths.")))
            }
            _ = lock.withLock { unavailableFiles.remove(itemID) }
            await MainActor.run { monitor?.noteOwnWrite(changeCount: reply.changeCount) }
            try? await mutations.run {
                guard var updated = try await self.record(itemID), updated.deletedAt == nil else { return }
                updated.lastCopiedAt = Date()
                try await context.storage.put(try updated.document())
            }
            Task { await publishDynamicItems() }
            let autoPaste = actionID != "copy-only" && current.autoPaste
            return ViewEventReply(document: nil, effect: .closeAndPaste(plainText: plain, autoPaste: autoPaste))
        case "copy-paths":
            guard let itemID, let record = try await record(itemID), record.kind == .file,
                  let paths = record.filePaths, !paths.isEmpty else { return ViewEventReply(document: nil) }
            let request = ClipboardWriteRequest(items: [PasteboardItemPayload(representations: [
                PasteboardRepresentation(type: PasteboardRules.text, text: paths.joined(separator: "\n"))
            ])], originToken: UUID().uuidString)
            let reply = try await context.capabilities.writeClipboard(request)
            await MainActor.run { monitor?.noteOwnWrite(changeCount: reply.changeCount) }
            return ViewEventReply(document: nil, effect: .notice(s.t("已复制文件路径", "File paths copied")))
        case "favorite":
            guard let itemID else { return ViewEventReply(document: nil) }
            try await mutations.run {
                guard var record = try await record(itemID), record.deletedAt == nil else { return }
                record.favorite.toggle()
                try await context.storage.put(try record.document())
            }
            try await reloadItems(keepSelection: true, resetPage: false)
            return ViewEventReply(document: try await historyDocument(selectFirst: false))
        case "delete":
            guard let itemID else { return ViewEventReply(document: nil) }
            await commitPendingDelete(force: true)
            let token = UUID().uuidString
            try await mutations.run {
                guard var record = try await record(itemID) else { return }
                record.deletedAt = Date()
                try await context.storage.put(try record.document())
                lock.withLock {
                    viewGeneration += 1
                    view.loadingPage = false
                    let index = view.items.firstIndex { $0.id == itemID }
                    view.items.removeAll { $0.id == itemID }
                    view.pendingUndo = (token, itemID, Date().addingTimeInterval(CaptureLimits.undoWindow))
                    view.selection = index.flatMap { view.items.isEmpty ? nil : view.items[min($0, view.items.count - 1)].id }
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(CaptureLimits.undoWindow))
                await self?.commitPendingDelete(force: false, token: token)
            }
            Task { await publishDynamicItems() }
            return ViewEventReply(document: try await historyDocument(selectFirst: false))
        case "clear-unfavorited":
            let total = try await context.storage.count(StorageQuery(collection: ClipRecord.collection, filters: [
                StorageFilter(field: "favorite", value: false), StorageFilter(field: "deleted", value: false)]))
            let favorites = try await context.storage.count(StorageQuery(collection: ClipRecord.collection, filters: [StorageFilter(field: "favorite", value: true)]))
            return ViewEventReply(document: nil, effect: .confirm(ConfirmSpec(title: s.clearConfirmTitle, message: s.clearConfirmMessage(total, favorites),
                                                                               confirmTitle: s.clear, confirmActionID: "confirm-clear-unfavorited", isDestructive: true)))
        case "confirm-clear-unfavorited":
            let ids = try await mutations.run { () -> [String] in
                var ids: [String] = []
                var cursor: String?
                repeat {
                    let page = try await self.context.storage.query(StorageQuery(collection: ClipRecord.collection,
                        filters: [StorageFilter(field: "favorite", value: false)], limit: 200, cursor: cursor))
                    ids += page.documents.map(\.id)
                    cursor = page.nextCursor
                } while cursor != nil
                try await self.deleteBatch(ids)
                return ids
            }
            try await reloadItems()
            await publishDynamicItems()
            return ViewEventReply(document: try await historyDocument(selectFirst: true), effect: .notice(s.t("已清空 \(ids.count) 条记录", "Cleared \(ids.count) items")))
        case "resume", "pause", "recheck":
            try await toggleRecording()
            return ViewEventReply(document: try await historyDocument(selectFirst: false))
        case "previous-page":
            try await loadPreviousPage()
            return ViewEventReply(document: try await historyDocument(selectFirst: false))
        case "newest":
            try await reloadItems()
            return ViewEventReply(document: try await historyDocument(selectFirst: true))
        case "clear-filters":
            lock.withLock { view.query = ""; view.filter = "all" }
            try await reloadItems()
            return ViewEventReply(document: try await historyDocument(selectFirst: true))
        default:
            return ViewEventReply(document: nil)
        }
    }

    func clipboardRequest(for record: ClipRecord, plainText: Bool) -> ClipboardWriteRequest {
        var items: [PasteboardItemPayload] = []
        for item in record.items {
            var reps = item.representations.map { PasteboardRepresentation(type: $0.type, text: $0.text, blobID: $0.blobID) }
            if plainText && supportsPlainText(record) {
                // Plain paste writes only plain text; file URLs are kept so file pastes still work (Maccy #962).
                reps = reps.filter { $0.type == PasteboardRules.text || $0.type == PasteboardRules.fileURL }
            }
            if !reps.isEmpty { items.append(PasteboardItemPayload(representations: reps)) }
        }
        return ClipboardWriteRequest(items: items, originToken: UUID().uuidString)
    }

    private func supportsPlainText(_ record: ClipRecord) -> Bool {
        record.kind != .image && record.kind != .file && record.items.contains {
            $0.representations.contains { $0.type == PasteboardRules.text }
        }
    }

    func record(_ id: String) async throws -> ClipRecord? {
        guard let doc = try await context.storage.get(collection: ClipRecord.collection, id: id) else { return nil }
        return try ClipRecord(from: doc)
    }

    func commitPendingDelete(force: Bool, token: String? = nil) async {
        try? await mutations.run {
            let pending = lock.withLock { () -> (token: String, recordID: String, expires: Date)? in
                guard let pending = view.pendingUndo else { return nil }
                if let token, token != pending.token { return nil }
                guard force || pending.expires <= Date() else { return nil }
                return pending
            }
            guard let pending else { return }
            if let record = try await record(pending.recordID), record.deletedAt != nil {
                try await context.storage.delete(collection: ClipRecord.collection, id: pending.recordID)
            }
            lock.withLock { if view.pendingUndo?.token == pending.token { view.pendingUndo = nil } }
        }
        refreshOpenView()
    }

    func undoDelete(_ token: String) async throws {
        let target = try await mutations.run { () -> String? in
            guard let target = lock.withLock({ view.pendingUndo?.token == token ? view.pendingUndo?.recordID : nil }),
                  var record = try await record(target) else { return nil }
            record.deletedAt = nil
            try await context.storage.put(try record.document())
            lock.withLock { if view.pendingUndo?.token == token { view.pendingUndo = nil } }
            return target
        }
        guard let target else { return }
        try await reloadItems(keepSelection: true, resetPage: false)
        lock.withLock { if view.items.contains(where: { $0.id == target }) { view.selection = target } }
        await publishDynamicItems()
    }

    func currentQuery() -> StorageQuery {
        lock.withLock { query(for: view) }
    }

    private func query(for state: ViewState) -> StorageQuery {
        var filters = [StorageFilter(field: "deleted", value: false)]
        switch state.filter {
        case "text", "image", "url", "file": filters.append(StorageFilter(field: "kind", value: .string(state.filter)))
        case "json": filters.append(StorageFilter(field: "json", value: true))
        case "favorite": filters.append(StorageFilter(field: "favorite", value: true))
        default: break
        }
        return StorageQuery(collection: ClipRecord.collection, filters: filters, search: state.query.isEmpty ? nil : state.query,
                            limit: UISchemaLimits.firstPageSize)
    }

    /// Reloads the current window in place (or from the newest record with `resetPage`), covering at least
    /// as many records as are loaded now so the list never shrinks under the user.
    func reloadItems(keepSelection: Bool = false, resetPage: Bool = true) async throws {
        let (base, start, minimum, generation) = lock.withLock { () -> (StorageQuery, String?, Int, Int) in
            viewGeneration += 1
            view.loadingPage = false
            if resetPage { view.pageStarts = []; view.pageCounts = []; view.droppedPages = [] }
            return (query(for: view), view.pageStarts.first ?? nil, resetPage ? 0 : view.items.count, viewGeneration)
        }
        var records: [ClipRecord] = []
        var starts: [String?] = []
        var counts: [Int] = []
        var cursor = start
        repeat {
            var query = base
            query.cursor = cursor
            let page = try await context.storage.query(query)
            let decoded = page.documents.compactMap { try? ClipRecord(from: $0) }
            starts.append(cursor)
            counts.append(decoded.count)
            records += decoded
            cursor = page.nextCursor
        } while cursor != nil && records.count < minimum && starts.count < Self.windowPages
        lock.withLock {
            guard viewGeneration == generation else { return }
            view.items = records
            view.pageStarts = starts
            view.pageCounts = counts
            view.cursor = cursor
            if !keepSelection || !records.contains(where: { $0.id == view.selection }) { view.selection = records.first?.id }
        }
    }

    /// Appends the next page (scrolling or ↓ past the last row); beyond the window the newest page slides out.
    func loadNextPage() async throws {
        let request = lock.withLock { () -> (generation: Int, query: StorageQuery)? in
            guard !view.loadingPage, let cursor = view.cursor else { return nil }
            view.loadingPage = true
            viewGeneration += 1
            var query = query(for: view)
            query.cursor = cursor
            return (viewGeneration, query)
        }
        guard let request else { return }
        do {
            let page = try await context.storage.query(request.query)
            let records = page.documents.compactMap { try? ClipRecord(from: $0) }
            lock.withLock {
                guard viewGeneration == request.generation else { return }
                view.items += records
                view.pageStarts.append(request.query.cursor)
                view.pageCounts.append(records.count)
                view.cursor = page.nextCursor
                if view.pageStarts.count > Self.windowPages {
                    let dropped = view.pageCounts.removeFirst()
                    view.droppedPages.append(view.pageStarts.removeFirst())
                    view.items.removeFirst(min(dropped, view.items.count))
                }
                if !view.items.contains(where: { $0.id == view.selection }) { view.selection = view.items.first?.id }
                view.loadingPage = false
            }
        } catch {
            lock.withLock { if viewGeneration == request.generation { view.loadingPage = false } }
            throw error
        }
    }

    /// Brings back the newer page that last slid out of the window; the oldest page drops off the end.
    func loadPreviousPage() async throws {
        let request = lock.withLock { () -> (generation: Int, query: StorageQuery)? in
            guard !view.loadingPage, let start = view.droppedPages.last else { return nil }
            view.loadingPage = true
            viewGeneration += 1
            var query = query(for: view)
            query.cursor = start
            return (viewGeneration, query)
        }
        guard let request else { return }
        do {
            let page = try await context.storage.query(request.query)
            let records = page.documents.compactMap { try? ClipRecord(from: $0) }
            lock.withLock {
                guard viewGeneration == request.generation else { return }
                view.droppedPages.removeLast()
                view.items.insert(contentsOf: records, at: 0)
                view.pageStarts.insert(request.query.cursor, at: 0)
                view.pageCounts.insert(records.count, at: 0)
                if view.pageStarts.count > Self.windowPages {
                    let dropped = view.pageCounts.removeLast()
                    view.cursor = view.pageStarts.removeLast()
                    view.items.removeLast(min(dropped, view.items.count))
                }
                view.selection = records.last?.id ?? view.selection
                view.loadingPage = false
            }
        } catch {
            lock.withLock { if viewGeneration == request.generation { view.loadingPage = false } }
            throw error
        }
    }

    private func refreshOpenView() {
        Task { [weak self] in
            guard let self, self.lock.withLock({ self.historyIsOpen && !self.view.loadingPage }) else { return }
            try? await self.reloadItems(keepSelection: true, resetPage: false)
            guard self.lock.withLock({ self.historyIsOpen }) else { return }
            if let document = try? await self.historyDocument(selectFirst: false) { self.context.updateView(document) }
        }
    }

    func historyDocument(selectFirst: Bool) async throws -> ViewDocument {
        let s = strings
        let locale = context.locale
        let (state, revision, query, filter, selection, items, cursor, undo, detail) = lock.withLock { () -> (CaptureState, Int, String, String, String?, [ClipRecord], String?, (String, String, Date)?, String?) in
            view.revision += 1
            return (captureState, view.revision, view.query, view.filter, view.selection, view.items, view.cursor,
                    view.pendingUndo.map { ($0.token, $0.recordID, $0.expires) }, captureDetail)
        }
        let rows = items.map { record -> ListItem in
            let symbol: String
            switch record.kind {
            case .text: symbol = record.isJSON == true ? "curlybraces" : "doc.plaintext"
            case .richText: symbol = record.isJSON == true ? "curlybraces" : "doc.richtext"
            case .image: symbol = "photo"
            case .url: symbol = "link"
            case .file: symbol = "doc"
            }
            var subtitle = record.lastCopiedAt.relative(locale: locale)
            if let app = record.sourceApp { subtitle = app + " · " + subtitle }
            return ListItem(id: record.id, title: record.title.isEmpty ? s.kindName(record.kind) : record.title, subtitle: subtitle,
                            symbol: symbol, thumbnailBlobID: record.thumbnailBlobID, isFavorite: record.favorite,
                            accessibilityLabel: "\(s.kindName(record.kind)), \(record.title), \(subtitle)",
                            actions: itemActions(for: record))
        }
        // Plugin and host always agree on the selected row, so the preview and actions never go blank.
        let selected = items.first { $0.id == selection } ?? items.first
        lock.withLock { if !view.items.contains(where: { $0.id == view.selection }) { view.selection = view.items.first?.id } }
        let preview: UINode? = selected.map { previewNode($0, strings: s) }
        var footerActions = selected.map { itemActions(for: $0) } ?? []
        if lock.withLock({ !view.droppedPages.isEmpty }) {
            // Only after scrolling far enough for newer rows to slide out of the window.
            footerActions.append(ItemAction(id: "previous-page", title: s.t("显示更新的记录", "Show Newer Items"), symbol: "chevron.up"))
            footerActions.append(ItemAction(id: "newest", title: s.t("回到最新", "Back to Newest"), symbol: "arrow.up.to.line"))
        }
        // Handled by the host: opens this plugin's settings in Ruyio's window.
        footerActions.append(ItemAction(id: "host.open-plugin-settings", title: s.openSettings, symbol: "gearshape"))
        footerActions.append(ItemAction(id: "clear-unfavorited", title: s.clearUnfavorited, isDestructive: true))
        var banner: BannerSpec?
        switch state {
        case .recording: banner = nil
        case .userPaused: banner = BannerSpec(text: s.pausedBanner, tone: .info, actions: [ItemAction(id: "resume", title: s.resume)])
        case .blockedBySystem:
            banner = BannerSpec(text: detail == "ask" ? s.askBanner : s.blockedBanner, tone: .warning,
                                actions: [ItemAction(id: "host.open-privacy-settings", title: s.openSystemSettings), ItemAction(id: "recheck", title: s.recheck)])
        case .suspended: banner = BannerSpec(text: s.suspendedBanner, tone: .info)
        case .failed: banner = BannerSpec(text: s.failedBanner + (detail ?? ""), tone: .critical, actions: [ItemAction(id: "recheck", title: s.retry)])
        case .unknown: banner = BannerSpec(text: s.unknownBanner, tone: .warning, actions: [ItemAction(id: "recheck", title: s.recheck)])
        }
        let empty: EmptySpec = (query.isEmpty && filter == "all")
            ? EmptySpec(title: s.emptyTitle)
            : EmptySpec(title: s.noResults, action: ItemAction(id: "clear-filters", title: s.clearFilters))
        let spec = CollectionSpec(
            searchText: query, searchPlaceholder: s.searchPlaceholder,
            filters: [FilterOption(id: "all", title: s.all), FilterOption(id: "text", title: s.text), FilterOption(id: "json", title: s.json),
                      FilterOption(id: "image", title: s.image),
                      FilterOption(id: "url", title: s.link), FilterOption(id: "file", title: s.file), FilterOption(id: "favorite", title: s.favorites)],
            selectedFilter: filter,
            // Infinite scroll over a bounded window keeps every entry reachable within the schema limits.
            list: ListSpec(items: rows, selection: selected?.id, nextCursor: cursor, empty: empty),
            preview: preview,
            footerActions: footerActions,
            banner: banner,
            undo: undo.map { UndoSpec(text: s.deleted, token: $0.0, expiresAt: $0.2) })
        return ViewDocument(viewID: Self.historyView, revision: revision, title: context.localized("name", "Clipboard History"), root: .collection(spec))
    }

    private func itemActions(for record: ClipRecord) -> [ItemAction] {
        let s = strings
        var actions = [ItemAction(id: "paste", title: s.paste, shortcut: "return", isDefault: true)]
        if supportsPlainText(record) { actions.append(ItemAction(id: "paste-plain", title: s.pastePlain, shortcut: "option+return")) }
        actions.append(ItemAction(id: "copy-only", title: s.copyOnly, shortcut: "command+return"))
        if record.kind == .file {
            actions.append(ItemAction(id: "copy-paths", title: s.t("复制路径", "Copy paths"), symbol: "doc.on.doc"))
        }
        actions.append(ItemAction(id: "favorite", title: record.favorite ? s.unfavorite : s.favorite, shortcut: "command+d", symbol: "star"))
        actions.append(ItemAction(id: "delete", title: s.delete, shortcut: "command+delete", symbol: "trash", isDestructive: true))
        return actions
    }

    func previewNode(_ record: ClipRecord, strings s: Strings) -> UINode {
        var rows = [KeyValueRow(key: s.copiedAt, value: record.lastCopiedAt.clock(locale: context.locale))]
        if let app = record.sourceApp { rows.insert(KeyValueRow(key: s.source, value: app), at: 0) }
        if record.copyCount > 1 { rows.append(KeyValueRow(key: s.times, value: String(record.copyCount))) }
        rows.append(KeyValueRow(key: s.size, value: ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file)))
        var children: [UINode] = []
        switch record.kind {
        case .image:
            if let blob = record.previewBlobID ?? record.thumbnailBlobID {
                let original = record.items.lazy.flatMap(\.representations).first { PasteboardRules.imageTypes.contains($0.type) && $0.blobID != nil }?.blobID
                children.append(.image(ImageSpec(blobID: blob, pixelWidth: record.imageSize?[0], pixelHeight: record.imageSize?[1], accessibilityLabel: record.title, originalBlobID: original)))
            }
            if let size = record.imageSize { rows.append(KeyValueRow(key: s.dimensions, value: "\(size[0]) × \(size[1])")) }
        case .file:
            rows.append(KeyValueRow(key: s.count, value: String(record.fileNames?.count ?? 0)))
            if lock.withLock({ unavailableFiles.contains(record.id) }) {
                children.append(.text(TextSpec(s.t("文件已移动、删除或无法访问，请使用“复制路径”。", "The files were moved, deleted, or are inaccessible. Use Copy paths."), style: .body)))
            }
            children.append(.text(TextSpec((record.filePaths ?? []).joined(separator: "\n"), style: .monospaced)))
        case .url:
            children.append(.text(TextSpec(record.plainText() ?? record.title, style: .body)))
        case .text, .richText:
            if record.isJSON == true, let text = record.plainText() {
                // The host indents and colours it; the cut keeps the view well inside one message.
                children.append(.json(String(text.prefix(100_000))))
            } else {
                children.append(.text(TextSpec(String((record.plainText() ?? record.title).prefix(20_000)), style: .body)))
            }
        }
        children.append(.keyValue(rows))
        return .stack(StackSpec(children: children))
    }

    // MARK: Settings view

    func settingsDocument(error: String? = nil) async -> ViewDocument {
        let s = strings
        let current = lock.withLock { settings }
        let records = (try? await context.storage.count(StorageQuery(collection: ClipRecord.collection,
                                                                     filters: [StorageFilter(field: "deleted", value: false)]))) ?? 0
        let used = (try? await context.storage.usage().bytes) ?? 0
        return ViewDocument(viewID: Self.settingsView, revision: Int(Date().timeIntervalSince1970), title: nil, root: .form(FormSpec(fields: [
            FieldSpec(id: "recording", label: s.settingsRecording, kind: .toggle, value: .bool(current.recording)),
            FieldSpec(id: "retentionDays", label: s.settingsRetentionDays, kind: .stepper, value: .number(Double(current.retentionDays)), minimum: 1, maximum: 3650, step: 1),
            FieldSpec(id: "maxRecords", label: s.settingsMaxRecords, kind: .stepper, value: .number(Double(current.maxRecords)), minimum: 100, maximum: 50_000, step: 100),
            FieldSpec(id: "maxMegabytes", label: s.settingsMaxMegabytes, kind: .stepper, value: .number(Double(current.maxMegabytes)),
                      minimum: Double(CaptureLimits.maxMegabytesRange.lowerBound), maximum: Double(CaptureLimits.maxMegabytesRange.upperBound), step: 100),
            FieldSpec(id: "pastePlain", label: s.settingsPasteMode, kind: .picker, value: .string(current.pastePlain ? "plain" : "original"),
                      options: [.init(id: "original", title: s.settingsOriginal), .init(id: "plain", title: s.settingsPlain)]),
            FieldSpec(id: "autoPaste", label: s.settingsAfterPaste, kind: .picker, value: .string(current.autoPaste ? "auto" : "copy"),
                      options: [.init(id: "auto", title: s.settingsAutoPaste), .init(id: "copy", title: s.settingsCopyOnly)]),
            FieldSpec(id: "ignoredApps", label: s.settingsIgnoredApps, kind: .textEditor, value: .string(current.ignoredApps.joined(separator: "\n")),
                      placeholder: "com.agilebits.onepassword7", error: error),
        ], submitTitle: s.settingsSave, footnote: s.usageFootnote(records: records, bytes: used, limitMegabytes: current.maxMegabytes))))
    }

    func handleSettingsEvent(_ event: ViewEvent) async throws -> ViewEventReply {
        let s = strings
        switch event {
        case .submit(let values):
            var updated = lock.withLock { settings }
            updated.recording = values["recording"]?.boolValue ?? updated.recording
            updated.retentionDays = max(1, values["retentionDays"]?.intValue ?? updated.retentionDays)
            updated.maxRecords = max(100, values["maxRecords"]?.intValue ?? updated.maxRecords)
            updated.maxMegabytes = min(max(values["maxMegabytes"]?.intValue ?? updated.maxMegabytes, CaptureLimits.maxMegabytesRange.lowerBound),
                                       CaptureLimits.maxMegabytesRange.upperBound)
            updated.pastePlain = values["pastePlain"]?.stringValue == "plain"
            updated.autoPaste = values["autoPaste"]?.stringValue != "copy"
            if let apps = values["ignoredApps"]?.stringValue {
                updated.ignoredApps = apps.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            // Deleting effects are previewed before they apply (PRD §19.16).
            let affected = try await recordsToPrune(updated).count
            if affected > 0 {
                lock.withLock { pendingSettings = updated }
                return ViewEventReply(document: nil, effect: .confirm(ConfirmSpec(title: s.settingsSave, message: s.retentionPreview(affected),
                                                                                   confirmTitle: s.clear, confirmActionID: "apply-settings", isDestructive: true)))
            }
            try await apply(updated)
            return ViewEventReply(document: await settingsDocument(), effect: .notice(s.settingsSaved))
        case .invoke("apply-settings", _):
            guard let pending = lock.withLock({ () -> Settings? in defer { pendingSettings = nil }; return pendingSettings }) else {
                return ViewEventReply(document: await settingsDocument())
            }
            try await apply(pending)
            return ViewEventReply(document: await settingsDocument(), effect: .notice(s.settingsSaved))
        default:
            return ViewEventReply(document: nil)
        }
    }

    func apply(_ updated: Settings) async throws {
        try await saveSettings(updated)
        // The settings are saved; a failed cleanup is retried by the hourly maintenance, not reported as a failed save.
        _ = try? await prune(updated)
        await publishDynamicItems()
    }
}
