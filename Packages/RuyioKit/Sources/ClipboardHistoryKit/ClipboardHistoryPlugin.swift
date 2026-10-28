import AppKit
import Foundation
import RuyioPluginSDK

/// Official Clipboard History plugin (PRD §8, plan §12). Runs sandboxed in its own process.
public final class ClipboardHistoryPlugin: RuyioPlugin, @unchecked Sendable {
    public struct Settings: Codable, Sendable, Hashable {
        public var recording = true
        public var retentionDays = CaptureLimits.defaultRetentionDays
        public var maxRecords = CaptureLimits.defaultMaxRecords
        public var pastePlain = false
        public var autoPaste = true
        public var ignoredApps: [String] = []
    }

    struct ViewState {
        var revision = 0
        var query = ""
        var filter = "all"
        var selection: String?
        var cursor: String?
        var items: [ClipRecord] = []
        var pendingUndo: (token: String, recordID: String, expires: Date)?
    }

    let context: PluginContext
    private let lock = NSLock()
    private var settings = Settings()
    private var captureState: CaptureState = .userPaused
    private var captureDetail: String?
    private var view = ViewState()
    private var pendingSettings: Settings?
    private var capturesSinceCleanup = 0
    private var monitor: CaptureMonitor?
    private var maintenanceTask: Task<Void, Never>?
    /// Textual representations above this size are stored as blobs: an inline body must fit one IPC frame.
    static let inlineTextLimit = 256 * 1024

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

    public func shutdown() async {
        lock.withLock { maintenanceTask }?.cancel()
        await MainActor.run { monitor?.stop() }
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
            let existing = try await context.storage.query(StorageQuery(collection: ClipRecord.collection, filters: [
                StorageFilter(field: "fingerprint", value: .string(fingerprint)),
            ], limit: 1)).documents.first
            if let existing, var record = try? ClipRecord(from: existing) {
                // Same content again: move to top and count it (Maccy semantics; PRD §8.2 de-dup).
                record.lastCopiedAt = now
                record.copyCount += 1
                record.deletedAt = nil
                record.sourceApp = clip.sourceApp ?? record.sourceApp
                record.sourceBundleID = clip.sourceBundleID ?? record.sourceBundleID
                try await context.storage.put(try record.document())
            } else {
                let record = try await makeRecord(clip, kind: kind, fingerprint: fingerprint, date: now)
                try await context.storage.put(try record.document())
            }
        } catch {
            // A full store stops every later capture, so it becomes the capture state (and "Recheck" re-probes);
            // a single item that could not be saved does not.
            if (error as? RuyioError)?.code == .storageQuotaExceeded {
                captureStateChanged(.failed, ErrorCode.storageQuotaExceeded.rawValue)
            }
            return
        }
        capturesSinceCleanup += 1
        if capturesSinceCleanup >= 25 {
            capturesSinceCleanup = 0
            await applyRetention()
        }
        await publishDynamicItems()
        refreshOpenView()
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
        return record
    }

    // MARK: Retention (PRD §8.4, §19.16)

    func recordsToPrune(_ settings: Settings, now: Date = Date()) async throws -> [String] {
        var ids: [String] = []
        let cutoff = now.addingTimeInterval(-Double(settings.retentionDays) * 86_400).timeIntervalSince1970
        let base = [StorageFilter(field: "favorite", value: false)]
        var cursor: String?
        repeat {
            let page = try await context.storage.query(StorageQuery(collection: ClipRecord.collection,
                                                                    filters: base + [StorageFilter(field: "lastCopiedAt", op: .lessThan, value: .number(cutoff))],
                                                                    limit: 200, cursor: cursor))
            ids += page.documents.map(\.id)
            cursor = page.nextCursor
        } while cursor != nil && ids.count < 50_000
        let total = try await context.storage.count(StorageQuery(collection: ClipRecord.collection, filters: base))
        let remaining = total - ids.count
        if remaining > settings.maxRecords {
            var excess = remaining - settings.maxRecords
            var oldestCursor: String?
            let pruned = Set(ids)
            while excess > 0 {
                let page = try await context.storage.query(StorageQuery(collection: ClipRecord.collection, filters: base, limit: 200,
                                                                        cursor: oldestCursor, ascending: true))
                for doc in page.documents where !pruned.contains(doc.id) && excess > 0 {
                    ids.append(doc.id)
                    excess -= 1
                }
                oldestCursor = page.nextCursor
                if oldestCursor == nil { break }
            }
        }
        return ids
    }

    func applyRetention() async {
        let current = lock.withLock { settings }
        guard let ids = try? await recordsToPrune(current) else { return }
        await deleteRecords(ids)
    }

    func deleteRecords(_ ids: [String]) async {
        for chunk in stride(from: 0, to: ids.count, by: 200).map({ Array(ids[$0..<min($0 + 200, ids.count)]) }) {
            try? await context.storage.batch(chunk.map { .delete(StorageKey(collection: ClipRecord.collection, id: $0)) })
        }
    }

    func purgeExpiredSoftDeletes() async {
        guard let page = try? await context.storage.query(StorageQuery(collection: ClipRecord.collection,
                                                                       filters: [StorageFilter(field: "deleted", value: true)], limit: 200)) else { return }
        let expired = page.documents.compactMap { try? ClipRecord(from: $0) }
            .filter { ($0.deletedAt ?? .distantFuture).timeIntervalSinceNow < -CaptureLimits.undoWindow }.map(\.id)
        await deleteRecords(expired)
    }

    // MARK: Finder dynamic items (metadata titles only, PRD §19.17)

    func publishDynamicItems() async {
        guard let page = try? await context.storage.query(StorageQuery(collection: ClipRecord.collection,
                                                                       filters: [StorageFilter(field: "deleted", value: false)], limit: 12)) else { return }
        let s = strings
        let records = page.documents.compactMap { try? ClipRecord(from: $0) }
        let recent = records.filter { $0.kind != .file }.prefix(5)
        let items = recent.map { record -> DynamicItemsReport.Item in
            var title = s.saveAsFilePrefix + s.kindName(record.kind) + " · " + record.lastCopiedAt.clock(locale: context.locale)
            if let app = record.sourceApp { title += " · " + app }
            return DynamicItemsReport.Item(id: record.id, title: title, kind: record.kind.filter)
        }
        let kinds = records.first.map { [$0.kind.filter] } ?? []
        context.publishDynamicItems(DynamicItemsReport(provider: "recentItems", items: Array(items), clipboardKinds: kinds))
    }

    public func dynamicItems(provider: String) async throws -> DynamicItemsReport {
        await publishDynamicItems()
        return DynamicItemsReport(provider: provider, items: [])
    }

    // MARK: Actions

    public func perform(_ invocation: ActionInvocation, execution: ExecutionID, operation: OperationID?) async throws -> ActionResult {
        switch invocation.actionID.rawValue {
        case "show-history":
            return .succeeded(.openView(Self.historyView))
        case "toggle-recording":
            await toggleRecording()
            return .succeeded()
        case "paste-recent":
            return try await saveToFinder(invocation, operation: operation)
        default:
            throw RuyioError(.actionNotFound, objectID: invocation.actionID.rawValue)
        }
    }

    func toggleRecording() async {
        let (state, recording) = lock.withLock { (captureState, settings.recording) }
        if state == .blockedBySystem || state == .failed || state == .unknown {
            await MainActor.run { monitor?.recheck() }
            return
        }
        var updated = lock.withLock { settings }
        updated.recording = !recording
        await saveSettings(updated)
        await MainActor.run { updated.recording ? monitor?.start() : monitor?.pause() }
    }

    /// Writes a frozen history record into the Finder target directory through the host file broker.
    func saveToFinder(_ invocation: ActionInvocation, operation: OperationID?) async throws -> ActionResult {
        guard let directory = invocation.finder?.targetDirectory, let id = invocation.finder?.dynamicItemID,
              let doc = try await context.storage.get(collection: ClipRecord.collection, id: id),
              let record = try? ClipRecord(from: doc), record.deletedAt == nil else {
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

    func saveSettings(_ updated: Settings) async {
        lock.withLock { settings = updated }
        if let body = try? JSONCoding.value(updated) {
            try? await context.storage.put(StoredDocument(collection: Self.settingsKey.collection, id: Self.settingsKey.id, body: body))
        }
        await MainActor.run { monitor?.ignoredBundleIDs = Set(updated.ignoredApps) }
    }

    // MARK: Views

    public func openView(_ request: ViewOpenRequest) async throws -> ViewDocument {
        switch request.viewID {
        case Self.historyView:
            // The previous search is not kept across sessions (PRD §19.15).
            lock.withLock { view = ViewState(revision: view.revision + 1) }
            try await reloadItems()
            return try await historyDocument(selectFirst: true)
        case Self.settingsView:
            return settingsDocument()
        default:
            throw RuyioError(.invalidRequest, diagnostic: "unknown view \(request.viewID)")
        }
    }

    public func closeView(_ viewID: String) async {
        if viewID == Self.historyView { await commitPendingDelete(force: true) }
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
            guard let itemID, let record = try await record(itemID) else { return ViewEventReply(document: nil) }
            let current = lock.withLock { settings }
            let plain = actionID == "paste-plain" || (actionID == "paste" && current.pastePlain)
            let reply = try await context.capabilities.writeClipboard(clipboardRequest(for: record, plainText: plain))
            await MainActor.run { monitor?.noteOwnWrite(changeCount: reply.changeCount) }
            var updated = record
            updated.lastCopiedAt = Date()
            try? await context.storage.put(try updated.document())
            Task { await publishDynamicItems() }
            let autoPaste = actionID != "copy-only" && current.autoPaste
            return ViewEventReply(document: nil, effect: .closeAndPaste(plainText: plain, autoPaste: autoPaste))
        case "favorite":
            guard let itemID, var record = try await record(itemID) else { return ViewEventReply(document: nil) }
            record.favorite.toggle()
            try await context.storage.put(try record.document())
            try await reloadItems(keepSelection: true)
            return ViewEventReply(document: try await historyDocument(selectFirst: false))
        case "delete":
            guard let itemID, var record = try await record(itemID) else { return ViewEventReply(document: nil) }
            await commitPendingDelete(force: true)
            record.deletedAt = Date()
            try await context.storage.put(try record.document())
            let token = UUID().uuidString
            let next = lock.withLock { () -> String? in
                let index = view.items.firstIndex { $0.id == itemID }
                view.items.removeAll { $0.id == itemID }
                view.pendingUndo = (token, itemID, Date().addingTimeInterval(CaptureLimits.undoWindow))
                guard let index, !view.items.isEmpty else { return nil }
                return view.items[min(index, view.items.count - 1)].id
            }
            lock.withLock { view.selection = next }
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
            var ids: [String] = []
            var cursor: String?
            repeat {
                let page = try await context.storage.query(StorageQuery(collection: ClipRecord.collection, filters: [StorageFilter(field: "favorite", value: false)],
                                                                        limit: 200, cursor: cursor))
                ids += page.documents.map(\.id)
                cursor = page.nextCursor
            } while cursor != nil
            await deleteRecords(ids)
            try await reloadItems()
            await publishDynamicItems()
            return ViewEventReply(document: try await historyDocument(selectFirst: true), effect: .notice(s.t("已清空 \(ids.count) 条记录", "Cleared \(ids.count) items")))
        case "resume", "pause", "recheck":
            await toggleRecording()
            return ViewEventReply(document: try await historyDocument(selectFirst: false))
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
            if plainText {
                // Plain paste writes only plain text; file URLs are kept so file pastes still work (Maccy #962).
                reps = reps.filter { $0.type == PasteboardRules.text || $0.type == PasteboardRules.fileURL }
            }
            if !reps.isEmpty { items.append(PasteboardItemPayload(representations: reps)) }
        }
        return ClipboardWriteRequest(items: items, originToken: UUID().uuidString)
    }

    func record(_ id: String) async throws -> ClipRecord? {
        guard let doc = try await context.storage.get(collection: ClipRecord.collection, id: id) else { return nil }
        return try ClipRecord(from: doc)
    }

    func commitPendingDelete(force: Bool, token: String? = nil) async {
        let target = lock.withLock { () -> String? in
            guard let pending = view.pendingUndo else { return nil }
            if let token, token != pending.token { return nil }
            guard force || pending.expires <= Date() else { return nil }
            view.pendingUndo = nil
            return pending.recordID
        }
        guard let target else { return }
        try? await context.storage.delete(collection: ClipRecord.collection, id: target)
        refreshOpenView()
    }

    func undoDelete(_ token: String) async throws {
        let target = lock.withLock { () -> String? in
            guard let pending = view.pendingUndo, pending.token == token else { return nil }
            view.pendingUndo = nil
            return pending.recordID
        }
        guard let target, var record = try await record(target) else { return }
        record.deletedAt = nil
        try await context.storage.put(try record.document())
        try await reloadItems()
        lock.withLock { view.selection = target }
        await publishDynamicItems()
    }

    func currentQuery() -> StorageQuery {
        lock.withLock {
            var filters = [StorageFilter(field: "deleted", value: false)]
            switch view.filter {
            case "text", "image", "url", "file": filters.append(StorageFilter(field: "kind", value: .string(view.filter)))
            case "favorite": filters.append(StorageFilter(field: "favorite", value: true))
            default: break
            }
            return StorageQuery(collection: ClipRecord.collection, filters: filters, search: view.query.isEmpty ? nil : view.query,
                                limit: UISchemaLimits.firstPageSize)
        }
    }

    func reloadItems(keepSelection: Bool = false) async throws {
        let page = try await context.storage.query(currentQuery())
        let records = page.documents.compactMap { try? ClipRecord(from: $0) }
        lock.withLock {
            view.items = records
            view.cursor = page.nextCursor
            if !keepSelection || !records.contains(where: { $0.id == view.selection }) { view.selection = records.first?.id }
        }
    }

    func loadNextPage() async throws {
        guard let cursor = lock.withLock({ view.cursor }) else { return }
        var query = currentQuery()
        query.cursor = cursor
        let page = try await context.storage.query(query)
        let records = page.documents.compactMap { try? ClipRecord(from: $0) }
        lock.withLock {
            view.items += records
            view.cursor = page.nextCursor
        }
    }

    private func refreshOpenView() {
        Task { [weak self] in
            guard let self else { return }
            try? await self.reloadItems(keepSelection: true)
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
            case .text: symbol = "doc.plaintext"
            case .richText: symbol = "doc.richtext"
            case .image: symbol = "photo"
            case .url: symbol = "link"
            case .file: symbol = "doc"
            }
            var subtitle = record.lastCopiedAt.relative(locale: locale)
            if let app = record.sourceApp { subtitle = app + " · " + subtitle }
            return ListItem(id: record.id, title: record.title.isEmpty ? s.kindName(record.kind) : record.title, subtitle: subtitle,
                            symbol: symbol, thumbnailBlobID: record.thumbnailBlobID, isFavorite: record.favorite,
                            accessibilityLabel: "\(s.kindName(record.kind)), \(record.title), \(subtitle)",
                            actions: [
                                ItemAction(id: "paste", title: s.paste, shortcut: "return", isDefault: true),
                                ItemAction(id: "paste-plain", title: s.pastePlain, shortcut: "option+return"),
                                ItemAction(id: "copy-only", title: s.copyOnly, shortcut: "command+return"),
                                ItemAction(id: "favorite", title: record.favorite ? s.unfavorite : s.favorite, shortcut: "command+d", symbol: "star"),
                                ItemAction(id: "delete", title: s.delete, shortcut: "command+delete", symbol: "trash", isDestructive: true),
                            ])
        }
        let selected = items.first { $0.id == selection } ?? (selectFirst ? items.first : nil)
        let preview: UINode? = selected.map { previewNode($0, strings: s) }
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
            filters: [FilterOption(id: "all", title: s.all), FilterOption(id: "text", title: s.text), FilterOption(id: "image", title: s.image),
                      FilterOption(id: "url", title: s.link), FilterOption(id: "file", title: s.file), FilterOption(id: "favorite", title: s.favorites)],
            selectedFilter: filter,
            list: ListSpec(items: rows, selection: selected?.id, nextCursor: cursor, empty: empty),
            preview: preview,
            footerActions: [
                ItemAction(id: "paste", title: s.paste, shortcut: "return", isDefault: true),
                ItemAction(id: "paste-plain", title: s.pastePlain, shortcut: "option+return"),
                ItemAction(id: "copy-only", title: s.copyOnly, shortcut: "command+return"),
                ItemAction(id: "favorite", title: s.favorite, shortcut: "command+d"),
                ItemAction(id: "delete", title: s.delete, shortcut: "command+delete", isDestructive: true),
                ItemAction(id: "clear-unfavorited", title: s.clearUnfavorited, isDestructive: true),
            ],
            banner: banner,
            undo: undo.map { UndoSpec(text: s.deleted, token: $0.0, expiresAt: $0.2) })
        return ViewDocument(viewID: Self.historyView, revision: revision, title: context.localized("name", "Clipboard History"), root: .collection(spec))
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
                children.append(.image(ImageSpec(blobID: blob, pixelWidth: record.imageSize?[0], pixelHeight: record.imageSize?[1], accessibilityLabel: record.title)))
            }
            if let size = record.imageSize { rows.append(KeyValueRow(key: s.dimensions, value: "\(size[0]) × \(size[1])")) }
        case .file:
            rows.append(KeyValueRow(key: s.count, value: String(record.fileNames?.count ?? 0)))
            children.append(.text(TextSpec((record.filePaths ?? []).joined(separator: "\n"), style: .monospaced)))
        case .url:
            children.append(.text(TextSpec(record.plainText() ?? record.title, style: .body)))
        case .text, .richText:
            children.append(.text(TextSpec(String((record.plainText() ?? record.title).prefix(20_000)), style: .body)))
        }
        children.append(.keyValue(rows))
        return .stack(StackSpec(children: children))
    }

    // MARK: Settings view

    func settingsDocument(error: String? = nil) -> ViewDocument {
        let s = strings
        let current = lock.withLock { settings }
        return ViewDocument(viewID: Self.settingsView, revision: Int(Date().timeIntervalSince1970), title: nil, root: .form(FormSpec(fields: [
            FieldSpec(id: "recording", label: s.settingsRecording, kind: .toggle, value: .bool(current.recording)),
            FieldSpec(id: "retentionDays", label: s.settingsRetentionDays, kind: .stepper, value: .number(Double(current.retentionDays)), minimum: 1, maximum: 3650, step: 1),
            FieldSpec(id: "maxRecords", label: s.settingsMaxRecords, kind: .stepper, value: .number(Double(current.maxRecords)), minimum: 100, maximum: 50_000, step: 100),
            FieldSpec(id: "pastePlain", label: s.settingsPasteMode, kind: .picker, value: .string(current.pastePlain ? "plain" : "original"),
                      options: [.init(id: "original", title: s.settingsOriginal), .init(id: "plain", title: s.settingsPlain)]),
            FieldSpec(id: "autoPaste", label: s.settingsAfterPaste, kind: .picker, value: .string(current.autoPaste ? "auto" : "copy"),
                      options: [.init(id: "auto", title: s.settingsAutoPaste), .init(id: "copy", title: s.settingsCopyOnly)]),
            FieldSpec(id: "ignoredApps", label: s.settingsIgnoredApps, kind: .textEditor, value: .string(current.ignoredApps.joined(separator: "\n")),
                      placeholder: "com.agilebits.onepassword7", error: error),
        ], submitTitle: s.settingsSave)))
    }

    func handleSettingsEvent(_ event: ViewEvent) async throws -> ViewEventReply {
        let s = strings
        switch event {
        case .submit(let values):
            var updated = lock.withLock { settings }
            updated.recording = values["recording"]?.boolValue ?? updated.recording
            updated.retentionDays = max(1, values["retentionDays"]?.intValue ?? updated.retentionDays)
            updated.maxRecords = max(100, values["maxRecords"]?.intValue ?? updated.maxRecords)
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
            return ViewEventReply(document: settingsDocument(), effect: .notice(s.settingsSaved))
        case .invoke("apply-settings", _):
            guard let pending = lock.withLock({ () -> Settings? in defer { pendingSettings = nil }; return pendingSettings }) else {
                return ViewEventReply(document: settingsDocument())
            }
            try await apply(pending)
            return ViewEventReply(document: settingsDocument(), effect: .notice(s.settingsSaved))
        default:
            return ViewEventReply(document: nil)
        }
    }

    func apply(_ updated: Settings) async throws {
        let previous = lock.withLock { settings }
        await saveSettings(updated)
        if updated.recording != previous.recording {
            await MainActor.run { updated.recording ? monitor?.start() : monitor?.pause() }
        }
        await applyRetention()
        await publishDynamicItems()
    }
}
