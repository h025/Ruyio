import AppKit

/// Cut, copy, paste, select all, undo and redo for whatever has keyboard focus. macOS routes them through
/// the Edit menu's key equivalents; the floating panels do not become main and Ruyio is usually not the
/// active app while they are open, so they apply these themselves.
@MainActor
enum StandardEditing {
    /// The editing command for a key event. Letters follow the active layout, as menus do; key codes cover
    /// layouts whose letters are not Latin.
    static func action(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let letter = event.charactersIgnoringModifiers?.lowercased()
        func key(_ character: String, _ code: UInt16) -> Bool {
            letter == character || (letter.map { !$0.unicodeScalars.allSatisfy(\.isASCII) } ?? true) && event.keyCode == code
        }
        switch flags {
        case [.command] where key("x", 7): return #selector(NSText.cut(_:))
        case [.command] where key("c", 8): return #selector(NSText.copy(_:))
        case [.command] where key("v", 9): return #selector(NSText.paste(_:))
        case [.command] where key("a", 0): return #selector(NSText.selectAll(_:))
        case [.command, .option, .shift] where key("v", 9): return #selector(NSTextView.pasteAsPlainText(_:))
        case [.command] where key("z", 6): return Selector(("undo:"))
        case [.command, .shift] where key("z", 6): return Selector(("redo:"))
        default: return nil
        }
    }

    /// Whether the focused responder would act on the command now: text with a selection to copy, an
    /// editable field to paste into, selectable preview text. The window itself does not count.
    static func canPerform(_ action: Selector, in window: NSWindow) -> Bool {
        guard let target = NSApp.target(forAction: action, to: nil, from: window) as? NSResponder,
              target !== window, target !== NSApp else { return false }
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
        if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
        return true
    }

    /// Performs the command on the focused responder; false when nothing focused would take it.
    static func perform(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let action = action(for: event), canPerform(action, in: window) else { return false }
        return NSApp.sendAction(action, to: nil, from: window)
    }

    /// The commands that focused text takes before a plugin's shortcut on the same keys. Undo is not among
    /// them: in a list, ⌘Z restores the item just deleted, not the last change to the search text.
    static func precedesPluginShortcuts(_ action: Selector) -> Bool {
        [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:)),
         #selector(NSTextView.pasteAsPlainText(_:))].contains(action)
    }
}

/// The application, Edit and Window menus every Mac app has. Without an Edit menu, ⌘C, ⌘V, ⌘X and ⌘A do
/// nothing in text fields.
@MainActor
enum MainMenu {
    static func make(_ l: L10n, settings: Selector, help: Selector) -> NSMenu {
        let bar = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            bar.addItem(holder)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }

        _ = submenu("Ruyio", [
            item(l.t("关于 Ruyio", "About Ruyio"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(l.openSettings, settings, ","),
            .separator(),
            item(l.t("隐藏 Ruyio", "Hide Ruyio"), #selector(NSApplication.hide(_:)), "h"),
            item(l.t("隐藏其他", "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(l.t("全部显示", "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(l.quit("Ruyio"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        // macOS adds dictation and the emoji picker to the menu it recognizes as Edit.
        _ = submenu(l.t("编辑", "Edit"), [
            item(l.t("撤销", "Undo"), Selector(("undo:")), "z"),
            item(l.t("重做", "Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(l.t("剪切", "Cut"), #selector(NSText.cut(_:)), "x"),
            item(l.t("拷贝", "Copy"), #selector(NSText.copy(_:)), "c"),
            item(l.t("粘贴", "Paste"), #selector(NSText.paste(_:)), "v"),
            item(l.t("粘贴并匹配样式", "Paste and Match Style"), #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item(l.t("删除", "Delete"), #selector(NSText.delete(_:))),
            item(l.t("全选", "Select All"), #selector(NSText.selectAll(_:)), "a"),
        ])
        let window = submenu(l.t("窗口", "Window"), [
            item(l.t("最小化", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(l.t("缩放", "Zoom"), #selector(NSWindow.performZoom(_:))),
            item(l.t("关闭", "Close"), #selector(NSWindow.performClose(_:)), "w"),
            .separator(),
            item(l.t("前置全部窗口", "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        let helpMenu = submenu(l.t("帮助", "Help"), [item(l.t("Ruyio 使用说明", "Ruyio Help"), help)])
        NSApp.windowsMenu = window
        NSApp.helpMenu = helpMenu
        return bar
    }
}
