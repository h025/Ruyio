import Foundation
import RuyioCore
import RuyioProtocol

/// Host side of the Finder channel: publishes menu snapshots ahead of time and consumes click
/// requests from the App Group queue (plan §13.1–13.2). Finder never waits for a plugin.
public final class FinderBridge: @unchecked Sendable {
    public let containerURL: URL
    private let lock = NSLock()
    private var projection: EntryProjection = .empty
    private var dynamicItems: [String: (DynamicItemsReport, Date)] = [:]
    private var clipboardKinds: [String] = []
    private var locale = "en"
    private var strings: [String: String] = [:]
    private var consumed: [String: Date] = [:]
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "ruyio.finder.bridge")
    private var handler: (@Sendable (FinderRequest, InvocationRequest) async -> Void)?
    private var rejectHandler: (@Sendable (FinderRequest, RuyioError) -> Void)?
    private var writeScheduled = false

    public init(containerURL: URL) {
        self.containerURL = containerURL
        try? FileManager.default.createDirectory(at: requestsURL, withIntermediateDirectories: true)
    }

    public var snapshotURL: URL { containerURL.appendingPathComponent(FinderWire.snapshotFileName) }
    public var requestsURL: URL { containerURL.appendingPathComponent(FinderWire.requestsDirectoryName, isDirectory: true) }

    public func onRequest(_ handler: @escaping @Sendable (FinderRequest, InvocationRequest) async -> Void,
                          rejected: @escaping @Sendable (FinderRequest, RuyioError) -> Void) {
        lock.withLock {
            self.handler = handler
            self.rejectHandler = rejected
        }
    }

    // MARK: Snapshot publishing

    public func update(projection: EntryProjection, locale: String, strings: [String: String]) {
        lock.withLock {
            self.projection = projection
            self.locale = locale
            self.strings = strings
        }
        scheduleWrite()
    }

    public func update(dynamicItems report: DynamicItemsReport, pluginID: PluginID) {
        lock.withLock {
            dynamicItems["\(pluginID.rawValue)#\(report.provider)"] = (report, Date())
            if !report.clipboardKinds.isEmpty || report.provider == "recentItems" { clipboardKinds = report.clipboardKinds }
        }
        scheduleWrite()
    }

    /// Exclusion rule changes must remove stale entries immediately (plan §13.1).
    public func invalidateDynamicItems(pluginID: PluginID) {
        lock.withLock { dynamicItems = dynamicItems.filter { !$0.key.hasPrefix(pluginID.rawValue + "#") } }
        scheduleWrite()
    }

    public func buildSnapshot() -> FinderMenuSnapshot {
        lock.withLock {
            var groups: [FinderMenuSnapshot.Group] = []
            var dynamicDate: Date?
            for group in projection.finder {
                var items: [FinderMenuSnapshot.Item] = []
                for entry in group.items where entry.visible {
                    var children: [FinderMenuSnapshot.Child]?
                    if let provider = entry.childrenProvider {
                        let stored = dynamicItems["\(group.pluginID.rawValue)#\(provider)"]
                        if let (report, date) = stored, Date().timeIntervalSince(date) < FinderWire.dynamicTTL {
                            children = report.items.map { FinderMenuSnapshot.Child(id: $0.id, title: $0.title) }
                            dynamicDate = max(dynamicDate ?? date, date)
                        } else {
                            children = []
                        }
                    }
                    items.append(FinderMenuSnapshot.Item(
                        actionID: entry.ref.actionID.rawValue, title: entry.title, targets: entry.contexts.targets,
                        selection: entry.contexts.selection, requiresWritableTarget: entry.contexts.requiresWritableTarget ?? false,
                        requiresClipboardKind: entry.contexts.requiresClipboardKind, children: children,
                        needsInput: entry.title.hasSuffix("…")))
                }
                if !items.isEmpty { groups.append(FinderMenuSnapshot.Group(pluginID: group.pluginID.rawValue, title: group.title, items: items)) }
            }
            return FinderMenuSnapshot(generation: projection.generation, dynamicGeneratedAt: dynamicDate, locale: locale,
                                      groups: groups, clipboardKinds: clipboardKinds, strings: strings)
        }
    }

    private func scheduleWrite() {
        let shouldSchedule = lock.withLock { () -> Bool in
            if writeScheduled { return false }
            writeScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.writeSnapshot() }
    }

    public func writeSnapshot() {
        lock.withLock { writeScheduled = false }
        let snapshot = buildSnapshot()
        guard let data = try? FinderWire.encoder().encode(snapshot) else { return }
        let temp = containerURL.appendingPathComponent(".snapshot-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(snapshotURL, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            try? data.write(to: snapshotURL, options: .atomic)
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(FinderWire.snapshotNotification as CFString), nil, nil, true)
    }

    // MARK: Request intake

    public func startListening() {
        let fd = open(requestsURL.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename], queue: queue)
            source.setEventHandler { [weak self] in self?.drainQueue() }
            source.setCancelHandler { close(fd) }
            source.resume()
            lock.withLock { self.source = source }
        }
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let bridge = Unmanaged<FinderBridge>.fromOpaque(observer).takeUnretainedValue()
            bridge.queue.async { bridge.drainQueue() }
        }, FinderWire.requestNotification as CFString, nil, .deliverImmediately)
        queue.async { [weak self] in self?.drainQueue() }
    }

    public func stopListening() {
        lock.withLock { source?.cancel(); source = nil }
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }

    /// Reads, validates and consumes every pending request exactly once.
    public func drainQueue(now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(at: requestsURL, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for file in files where file.pathExtension == "json" {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let data = size <= FinderWire.maxRequestBytes ? (try? Data(contentsOf: file)) : nil
            // Consume first: a duplicate wake-up must never execute the same click twice.
            try? FileManager.default.removeItem(at: file)
            guard let data, let request = try? FinderWire.decoder().decode(FinderRequest.self, from: data) else { continue }
            process(request, now: now)
        }
        lock.withLock { consumed = consumed.filter { now.timeIntervalSince($0.value) < 3600 } }
    }

    func process(_ request: FinderRequest, now: Date) {
        let (handler, reject, alreadySeen) = lock.withLock { () -> (( @Sendable (FinderRequest, InvocationRequest) async -> Void)?, (@Sendable (FinderRequest, RuyioError) -> Void)?, Bool) in
            let seen = consumed[request.requestID] != nil
            consumed[request.requestID] = now
            return (self.handler, self.rejectHandler, seen)
        }
        guard !alreadySeen else { return }
        guard request.wireSchemaVersion == FinderWire.wireSchemaVersion else {
            reject?(request, RuyioError(.incompatibleProtocol, diagnostic: "finder wire \(request.wireSchemaVersion)"))
            return
        }
        // Expired clicks are not replayed; the user must click again (PRD §19.17).
        guard now.timeIntervalSince(request.createdAt) <= FinderWire.requestTTL, request.createdAt <= now.addingTimeInterval(5) else {
            reject?(request, RuyioError(.contextExpired, recovery: .retry))
            return
        }
        guard let pluginID = PluginID(rawValue: request.pluginID), let actionID = ActionID(rawValue: request.actionID) else {
            reject?(request, RuyioError(.invalidRequest))
            return
        }
        let target = request.targetDirectory.map { URL(fileURLWithPath: $0) }
        let selection = request.selection.map { URL(fileURLWithPath: $0) }
        for url in [target].compactMap({ $0 }) + selection where !url.path.hasPrefix("/") || url.path.contains("/../") {
            reject?(request, RuyioError(.invalidRequest))
            return
        }
        // Re-validate against the current snapshot, not the one the extension clicked on (plan §13.1–13.2):
        // the action must still be offered, apply to the real target and selection, and a dynamic child
        // must still be a live, non-excluded item.
        let current = buildSnapshot()
        guard let group = current.groups.first(where: { $0.pluginID == request.pluginID }),
              let item = group.items.first(where: { $0.actionID == request.actionID }) else {
            reject?(request, RuyioError(.contextExpired, recovery: .retry, diagnostic: "action no longer offered"))
            return
        }
        let isDirectory: (URL) -> Bool = { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let directories = selection.filter(isDirectory)
        let context = FinderContextMatcher.Context(
            targetIsDirectory: target.map(isDirectory) ?? false, selectionCount: selection.count,
            selectionHasDirectories: !directories.isEmpty, selectionHasFiles: directories.count < selection.count,
            clipboardKinds: current.clipboardKinds)
        guard FinderContextMatcher.applies(item, to: context) else {
            reject?(request, RuyioError(.contextExpired, recovery: .retry, diagnostic: "context no longer matches"))
            return
        }
        if let child = request.dynamicItemID, item.children?.contains(where: { $0.id == child }) != true {
            reject?(request, RuyioError(.contextExpired, recovery: .retry, diagnostic: "item no longer available"))
            return
        }
        if item.children != nil && request.dynamicItemID == nil {
            reject?(request, RuyioError(.invalidRequest))
            return
        }
        if item.requiresWritableTarget, let target, !FileManager.default.isWritableFile(atPath: target.path) {
            reject?(request, RuyioError(.fileAccessDenied, objectID: target.lastPathComponent, recovery: .openSystemSettings))
            return
        }
        let invocation = InvocationRequest(ref: ActionRef(pluginID: pluginID, actionID: actionID), entry: .finderContextMenu,
                                           finder: FinderTargets(targetDirectory: target, selection: selection, dynamicItemID: request.dynamicItemID))
        if let handler { Task { await handler(request, invocation) } }
    }
}
