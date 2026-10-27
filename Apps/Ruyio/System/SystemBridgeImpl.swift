import AppKit
import FinderSync
import RuyioCore
import RuyioHostKit
import RuyioProtocol

/// AppKit implementation of host-mediated capabilities (plan §10). No shell, no arbitrary executables.
final class SystemBridgeImpl: SystemBridge, @unchecked Sendable {
    weak var model: AppModel?

    func writePasteboard(_ items: [[String: Data]], originToken: String) async throws -> Int {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            var objects: [NSPasteboardItem] = []
            for representations in items {
                let item = NSPasteboardItem()
                for (type, data) in representations { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
                // Origin marker lets Clipboard History ignore its own write-back (Maccy pattern).
                item.setString(originToken, forType: NSPasteboard.PasteboardType("app.ruyio.origin"))
                objects.append(item)
            }
            pasteboard.writeObjects(objects)
            return pasteboard.changeCount
        }
    }

    func openWebLink(_ url: URL) async throws {
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }

    func openTerminal(at directories: [URL]) async throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw RuyioError(.pluginLaunchFailed, objectID: "com.apple.Terminal", recovery: .chooseApplication)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Opening a folder URL with Terminal starts a shell in that folder; no AppleScript or path interpolation.
        try await NSWorkspace.shared.open(directories, withApplicationAt: terminal, configuration: configuration)
    }

    func open(_ targets: [URL], withApplicationBundleID bundleID: String) async throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw RuyioError(.pluginLaunchFailed, objectID: bundleID, recovery: .chooseApplication)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await NSWorkspace.shared.open(targets, withApplicationAt: app, configuration: configuration)
    }

    func reveal(_ urls: [URL]) async {
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func confirmBatch(title: String, count: Int) async -> Bool {
        await MainActor.run {
            let l = model?.l ?? L10n("en")
            let alert = NSAlert()
            alert.messageText = l.openTerminalConfirm(count)
            alert.addButton(withTitle: l.continueAction)
            alert.addButton(withTitle: l.cancel)
            NSApp.activate()
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    func chooseApplication(role: String) async -> String? {
        await MainActor.run {
            let l = model?.l ?? L10n("en")
            let panel = NSOpenPanel()
            panel.message = l.chooseApp(role)
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.canChooseDirectories = false
            NSApp.activate()
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return Bundle(url: url)?.bundleIdentifier
        }
    }

    /// P0-06 not achieved with a public, reliable API: show the Finder shortcut instead of
    /// `defaults write` + `killall Finder` (forbidden by plan §13.4). Decision A19.
    func toggleFinderHiddenFiles() async throws -> Bool {
        await MainActor.run { model?.show(model?.l.hiddenFilesHowTo ?? "") }
        throw RuyioError(.cancelled, diagnostic: "hidden files: instructions shown")
    }
}

enum FinderExtensionStatus {
    static var isEnabled: Bool { FIFinderSyncController.isExtensionEnabled }

    static func showManagementInterface() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    /// Running from a disk image or an unmoved download breaks extension registration (R25).
    static var isTranslocated: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }
}

enum SystemSettings {
    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openFilesAndFolders() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
    }

    static func openPasteboardPrivacy() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
