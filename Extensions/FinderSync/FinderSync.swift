import AppKit
import FinderSync
import RuyioProtocol

/// Ruyio's Finder Sync Extension (PRD §7.3, plan §13). It only reads the pre-built snapshot and writes
/// frozen click requests; it never loads plugin code, queries a database or touches the network.
final class FinderSync: FIFinderSync {
    private var snapshot: FinderMenuSnapshot?
    private var lastSnapshotDate: Date?
    private var pending: [Int: (group: FinderMenuSnapshot.Group, item: FinderMenuSnapshot.Item, childID: String?)] = [:]
    /// Tags carry the menu build they belong to, so a click on an older menu never maps to a newer item.
    private var menuBuild = 0
    /// Target and selection the menu was built for. A click sends these, not a fresh query: for a click on a
    /// folder's background Finder reports the folder (or earlier-selected items) as selected by then, which
    /// would no longer match the "nothing selected" context the item was offered for.
    private var menuTarget: URL?
    private var menuSelection: [URL] = []

    override init() {
        super.init()
        // Manage the user's home and mounted volumes; actual write access is checked by the host.
        var directories: Set<URL> = [URL(fileURLWithPath: "/")]
        if let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) {
            directories.formUnion(volumes)
        }
        FIFinderSyncController.default().directoryURLs = directories
        loadSnapshot()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<FinderSync>.fromOpaque(observer).takeUnretainedValue().loadSnapshot()
        }, FinderWire.snapshotNotification as CFString, nil, .deliverImmediately)
    }

    private var containerURL: URL? { FinderWire.channelDirectory(infoDictionary: Bundle.main.infoDictionary) }

    /// Async-safe: reads a small JSON file into memory; menu building only filters memory (plan §13.1).
    func loadSnapshot() {
        guard let url = containerURL?.appendingPathComponent(FinderWire.snapshotFileName),
              let data = try? Data(contentsOf: url),
              let decoded = try? FinderWire.decoder().decode(FinderMenuSnapshot.self, from: data) else { return }
        // Unknown wire versions only offer "Open Ruyio" (plan §13.3.1).
        if decoded.wireSchemaVersion != FinderWire.wireSchemaVersion { snapshot = nil; return }
        snapshot = decoded
        lastSnapshotDate = Date()
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else { return nil }
        let controller = FIFinderSyncController.default()
        let target = controller.targetedURL()
        let selection = menuKind == .contextualMenuForItems ? (controller.selectedItemURLs() ?? []) : []
        let menu = NSMenu(title: "")
        pending.removeAll()
        menuBuild = (menuBuild + 1) % 1_000
        menuTarget = target
        menuSelection = selection

        guard let snapshot else {
            let item = NSMenuItem(title: "Ruyio › Open Ruyio to Load", action: #selector(openHost(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return menu
        }
        let directories = selection.filter(Self.isDirectory)
        let context = FinderContextMatcher.Context(
            targetIsDirectory: menuKind == .contextualMenuForContainer || (target.map(Self.isDirectory) ?? false),
            selectionCount: selection.count, selectionHasDirectories: !directories.isEmpty,
            selectionHasFiles: directories.count < selection.count, clipboardKinds: snapshot.clipboardKinds)

        let root = NSMenu(title: snapshot.rootTitle)
        var tag = menuBuild * 10_000 + 1
        for group in snapshot.groups {
            let submenu = NSMenu(title: group.title)
            for item in group.items where FinderContextMatcher.applies(item, to: context) {
                if let children = item.children {
                    // Dynamic children expand inline inside the plugin group: no fourth level (PRD §7.3).
                    for child in children {
                        submenu.addItem(menuItem(child.title, tag: tag))
                        pending[tag] = (group, item, child.id)
                        tag += 1
                    }
                } else {
                    submenu.addItem(menuItem(item.title, tag: tag))
                    pending[tag] = (group, item, nil)
                    tag += 1
                }
            }
            // Empty plugin groups are hidden (PRD §19.17).
            guard !submenu.items.isEmpty else { continue }
            let groupItem = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            groupItem.submenu = submenu
            root.addItem(groupItem)
        }
        // The root menu exists only when at least one action applies.
        guard !root.items.isEmpty else { return nil }
        let rootItem = NSMenuItem(title: snapshot.rootTitle, action: nil, keyEquivalent: "")
        rootItem.submenu = root
        rootItem.image = NSImage(named: "MenuBarIcon")
        menu.addItem(rootItem)
        return menu
    }

    /// The sandbox may refuse resource values for arbitrary files; Finder folder URLs end with "/".
    static func isDirectory(_ url: URL) -> Bool {
        url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func menuItem(_ title: String, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
    }

    /// Freezes the click (target, selection, action, snapshot version) and hands it to the host.
    @objc private func runMenuItem(_ sender: NSMenuItem) {
        guard sender.tag / 10_000 == menuBuild, let entry = pending[sender.tag], let snapshot else { return }
        let request = FinderRequest(pluginID: entry.group.pluginID, actionID: entry.item.actionID, dynamicItemID: entry.childID,
                                    targetDirectory: menuTarget?.path, selection: menuSelection.map(\.path),
                                    snapshotGeneration: snapshot.generation)
        guard let directory = containerURL?.appendingPathComponent(FinderWire.requestsDirectoryName, isDirectory: true),
              let data = try? FinderWire.encoder().encode(request), data.count <= FinderWire.maxRequestBytes else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(request.requestID).tmp")
        let final = directory.appendingPathComponent("\(request.requestID).json")
        do {
            try data.write(to: temp, options: .atomic)
            try FileManager.default.moveItem(at: temp, to: final)
        } catch {
            return
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(FinderWire.requestNotification as CFString), nil, nil, true)
        wakeHost()
    }

    @objc private func openHost(_ sender: Any?) { wakeHost() }

    /// Launches the containing app by location; no URL scheme is registered as a call channel (plan §13.2).
    /// Only launches a host that is not running: the request notification already reaches a running one,
    /// and opening a running app is a reopen event that brings up its main window.
    private func wakeHost() {
        if let extensionID = Bundle.main.bundleIdentifier, let dot = extensionID.lastIndex(of: "."),
           !NSRunningApplication.runningApplications(withBundleIdentifier: String(extensionID[..<dot])).isEmpty {
            return
        }
        let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: host, configuration: configuration)
    }
}
