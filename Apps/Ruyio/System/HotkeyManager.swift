import AppKit
import Carbon.HIToolbox
import RuyioCore
import RuyioHostKit

/// Central global-hotkey registry using RegisterEventHotKey (plan §13.5). No global key logging.
/// Saved preferences and real registration state are kept apart; failures are reported, never hidden.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var keys: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyManager.shared.handlers[id]?() } }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    /// Replaces the full set of registrations and returns the state of each key.
    func apply(_ bindings: [(key: String, shortcut: KeyShortcut, handler: () -> Void)]) -> [String: HotkeyRegistrationState] {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
        keys.removeAll()
        var states: [String: HotkeyRegistrationState] = [:]
        var seen: [KeyShortcut: String] = [:]
        for binding in bindings {
            if seen[binding.shortcut] != nil { states[binding.key] = .conflict; continue }
            if binding.shortcut.rejection() != nil { states[binding.key] = .unavailable; continue }
            guard let code = Self.keyCode(binding.shortcut.key) else { states[binding.key] = .unavailable; continue }
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(code), Self.carbonModifiers(binding.shortcut.modifiers),
                                             EventHotKeyID(signature: OSType(0x5259_494F), id: id), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[id] = ref
                handlers[id] = binding.handler
                keys[binding.key] = id
                seen[binding.shortcut] = binding.key
                states[binding.key] = .registered
            } else {
                // Taken by macOS or another app: keep the user's choice but show "Unavailable" (PRD §19.12).
                states[binding.key] = .unavailable
            }
        }
        return states
    }

    static func carbonModifiers(_ modifiers: KeyShortcut.Modifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    static func keyCode(_ key: String) -> Int? {
        let fixed: [String: Int] = [
            "space": kVK_Space, "return": kVK_Return, "escape": kVK_Escape, "delete": kVK_Delete, "tab": kVK_Tab,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period, "slash": kVK_ANSI_Slash, "semicolon": kVK_ANSI_Semicolon,
            "quote": kVK_ANSI_Quote, "leftbracket": kVK_ANSI_LeftBracket, "rightbracket": kVK_ANSI_RightBracket,
            "backslash": kVK_ANSI_Backslash, "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "grave": kVK_ANSI_Grave,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
            "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        ]
        if let code = fixed[key] { return code }
        guard key.count == 1, let character = key.first else { return nil }
        // Hotkeys follow the physical layout of the current input source for letters and digits; layouts
        // without Latin letters (Cyrillic, Greek…) fall back to the ANSI position, as paste does.
        if let code = KeyboardLayout.keyCode(for: character) { return Int(code) }
        return ansi[key]
    }

    static let ansi: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
        "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]

    /// Named keys by key code (punctuation, arrows, function keys), so ⇧⌘1 or ⌘, record as written.
    static let namedKeys: [Int: String] = [
        kVK_Space: "space", kVK_Return: "return", kVK_ANSI_KeypadEnter: "return", kVK_Delete: "delete", kVK_Tab: "tab", kVK_UpArrow: "up", kVK_DownArrow: "down",
        kVK_LeftArrow: "left", kVK_RightArrow: "right", kVK_ANSI_Comma: "comma", kVK_ANSI_Period: "period", kVK_ANSI_Slash: "slash",
        kVK_ANSI_Semicolon: "semicolon", kVK_ANSI_Quote: "quote", kVK_ANSI_LeftBracket: "leftbracket", kVK_ANSI_RightBracket: "rightbracket",
        kVK_ANSI_Backslash: "backslash", kVK_ANSI_Minus: "minus", kVK_ANSI_Equal: "equal", kVK_ANSI_Grave: "grave",
        kVK_F1: "f1", kVK_F2: "f2", kVK_F3: "f3", kVK_F4: "f4", kVK_F5: "f5", kVK_F6: "f6", kVK_F7: "f7", kVK_F8: "f8",
        kVK_F9: "f9", kVK_F10: "f10", kVK_F11: "f11", kVK_F12: "f12",
    ]

    /// Translates a key-down event into a shortcut for the recorder (PRD §19.12).
    static func shortcut(from event: NSEvent) -> KeyShortcut? {
        var modifiers: KeyShortcut.Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if let name = namedKeys[Int(event.keyCode)], KeyShortcut.knownKeys.contains(name) { return KeyShortcut(key: name, modifiers: modifiers) }
        // The character the key produces with no modifiers on the current layout: ⇧1 records as "1", not "!".
        let base = event.characters(byApplyingModifiers: [])?.lowercased()
        if let chars = base, chars.count == 1, KeyShortcut.knownKeys.contains(chars) { return KeyShortcut(key: chars, modifiers: modifiers) }
        if let letter = ansi.first(where: { $0.value == Int(event.keyCode) })?.key { return KeyShortcut(key: letter, modifiers: modifiers) }
        return nil
    }
}
