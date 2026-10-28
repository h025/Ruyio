import AppKit
import FinderSync
import RuyioCore
import RuyioHostKit
import RuyioProtocol

/// AppKit implementation of host-mediated capabilities (plan §10). No shell, no arbitrary executables.
final class SystemBridgeImpl: SystemBridge, @unchecked Sendable {
    weak var model: AppModel?

    func writePasteboard(_ items: [[String: Data]], originToken: String) async throws -> Int {
        try await MainActor.run {
            guard !items.isEmpty, items.allSatisfy({ !$0.isEmpty }) else {
                throw RuyioError(.invalidRequest, diagnostic: "empty pasteboard item")
            }
            var objects: [NSPasteboardItem] = []
            for representations in items {
                let item = NSPasteboardItem()
                for (type, data) in representations {
                    guard item.setData(data, forType: NSPasteboard.PasteboardType(type)) else {
                        throw RuyioError(.actionFailed, diagnostic: "cannot prepare pasteboard representation")
                    }
                }
                // Origin marker lets Clipboard History ignore its own write-back (Maccy pattern).
                guard item.setString(originToken, forType: NSPasteboard.PasteboardType("app.ruyio.origin")) else {
                    throw RuyioError(.actionFailed, diagnostic: "cannot prepare pasteboard marker")
                }
                objects.append(item)
            }
            try ClipboardWriteValidator.validateFileReferences(items)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.writeObjects(objects) else {
                throw RuyioError(.actionFailed, retryable: true, dataEffect: .partial, diagnostic: "pasteboard write failed")
            }
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
        await MainActor.run { FileReveal.reveal(urls) }
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

    func captureScreen() async throws -> CapturedScreen {
        try await CaptureService.shared.capture(model: await MainActor.run { model })
    }

    func place(_ urls: [URL], at location: CGPoint) async {
        await DesktopPlacement.place(urls, at: location)
    }

    func pinImage(_ data: Data, scale: Double, pluginID: PluginID) async throws {
        // The bytes come from the plugin's store: decode them in the sandboxed service, never in the host.
        guard let image = await MediaDecoderClient.shared.image(from: data, maxPixel: 8192) else {
            throw RuyioError(.invalidRequest, diagnostic: "not a decodable image")
        }
        let manifest = await model?.engine.registry.manifest(pluginID)
        await MainActor.run {
            let l = model?.l ?? L10n("en")
            let name = manifest?.displayName(locale: model?.language ?? "en").text ?? pluginID.rawValue
            PinnedImages.shared.pin(image, scale: scale, pluginName: name, l: l)
        }
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

enum FileReveal {
    /// Selects files in Finder, except those directly on the Desktop: they are already in view there, and
    /// Finder would open an extra window to select them.
    @MainActor static func reveal(_ urls: [URL]) {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath().path
        let shown = urls.filter { $0.deletingLastPathComponent().resolvingSymlinksInPath().path != desktop }
        if !shown.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(shown) }
    }
}

enum SystemSettings {
    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openFilesAndFolders() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
    }

    static func openScreenRecording() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openPasteboardPrivacy() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
