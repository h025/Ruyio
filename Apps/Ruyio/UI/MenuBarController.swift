import AppKit
import RuyioCore
import RuyioHostKit
import RuyioProtocol

/// Single host status item (PRD §7.4, interaction §15). Plugin groups appear only while enabled.
@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private var item: NSStatusItem?
    var runAction: ((MenuBarItem) -> Void)?
    var openPalette: (() -> Void)?
    var openPage: ((Page) -> Void)?

    init(model: AppModel) {
        self.model = model
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Self.icon(paused: false)
            item.button?.setAccessibilityLabel("Ruyio")
            self.item = item
            rebuild()
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    static func icon(paused: Bool, attention: Bool = false) -> NSImage? {
        let image = Bundle.main.image(forResource: "MenuBarIcon") ?? NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Ruyio")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        guard paused || attention, let base = image else { return image }
        let symbol = NSImage(systemSymbolName: attention ? "exclamationmark.circle.fill" : "pause.circle.fill", accessibilityDescription: nil)
        let size = NSSize(width: 18, height: 18)
        let composed = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            symbol?.draw(in: NSRect(x: 10, y: 0, width: 8, height: 8))
            return true
        }
        composed.isTemplate = true
        return composed
    }

    func rebuild() {
        guard let item else { return }
        let l = model.l
        let menu = NSMenu()
        let palette = NSMenuItem(title: l.openCommandPalette, action: #selector(openPaletteAction), keyEquivalent: "")
        palette.target = self
        if let raw = model.settings.commandPaletteShortcut, let shortcut = KeyShortcut(manifestString: raw) { Self.apply(shortcut, to: palette) }
        menu.addItem(palette)

        var paused = false
        var attention = false
        let groups = model.snapshot.entries.menuBar
        if !groups.isEmpty { menu.addItem(.separator()) }
        for group in groups {
            let header = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            if let report = group.status, let text = report.statusText {
                let status = NSMenuItem(title: "  " + text, action: nil, keyEquivalent: "")
                status.isEnabled = false
                menu.addItem(status)
                if report.captureState == .userPaused { paused = true }
                if report.captureState == .blockedBySystem || report.captureState == .failed { attention = true }
            }
            for entry in group.items {
                let title = captureToggleTitle(for: entry, status: group.status) ?? entry.title
                let menuItem = NSMenuItem(title: "  " + title, action: #selector(runItem(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = entry.ref.description
                if let shortcut = entry.shortcut { Self.apply(shortcut, to: menuItem) }
                menu.addItem(menuItem)
            }
        }
        menu.addItem(.separator())
        for (title, page) in [(l.openPlugins, Page.plugins), (l.openSettings, Page.general)] {
            let entry = NSMenuItem(title: title, action: #selector(openPageAction(_:)), keyEquivalent: page == .general ? "," : "")
            entry.target = self
            entry.representedObject = page.rawValue
            menu.addItem(entry)
        }
        if model.appUpdates != nil {
            let title = model.appUpdatePhase.available.map { l.installUpdateMenu($0.version.description) } ?? l.checkForUpdates
            let update = NSMenuItem(title: title, action: #selector(appUpdateAction), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }
        let quit = NSMenuItem(title: l.quit("Ruyio"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        item.button?.image = Self.icon(paused: paused, attention: attention)
    }

    /// `menuRole: captureToggle` titles follow the real capture state (interaction §10.5).
    private func captureToggleTitle(for entry: MenuBarItem, status: PluginStatusReport?) -> String? {
        guard let manifest = model.summary(entry.ref.pluginID)?.manifest,
              manifest.action(entry.ref.actionID)?.presentation(.menuBar)?.menuRole == "captureToggle" else { return nil }
        let l = model.l
        switch status?.captureState {
        case .recording?: return l.pauseRecording
        case .blockedBySystem?: return l.openSystemSettings
        case .failed?, .unknown?: return l.recheck
        default: return l.resumeRecording
        }
    }

    static func apply(_ shortcut: KeyShortcut, to item: NSMenuItem) {
        item.keyEquivalent = shortcut.key == "space" ? " " : shortcut.key
        var mask: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { mask.insert(.command) }
        if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
        if shortcut.modifiers.contains(.option) { mask.insert(.option) }
        if shortcut.modifiers.contains(.control) { mask.insert(.control) }
        item.keyEquivalentModifierMask = mask
    }

    @objc private func openPaletteAction() { openPalette?() }

    @objc private func appUpdateAction() {
        if let item = model.appUpdatePhase.available {
            model.installAppUpdate(item)
        } else {
            openPage?(.general)
            model.checkForAppUpdate()
        }
    }

    @objc private func openPageAction(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let page = Page(rawValue: raw) { openPage?(page) }
    }

    @objc private func runItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = model.snapshot.entries.menuBar.flatMap(\.items).first(where: { $0.ref.description == id }) else { return }
        if captureToggleTitle(for: entry, status: model.summary(entry.ref.pluginID)?.report) == model.l.openSystemSettings {
            SystemSettings.openPasteboardPrivacy()
        }
        runAction?(entry)
    }
}
