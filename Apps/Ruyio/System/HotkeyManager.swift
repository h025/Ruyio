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
        // Hotkeys follow the physical layout of the current input source for letters and digits.
        if let code = KeyboardLayout.keyCode(for: character) { return Int(code) }
        return nil
    }

    /// Translates a key-down event into a shortcut for the recorder (PRD §19.12).
    static func shortcut(from event: NSEvent) -> KeyShortcut? {
        var modifiers: KeyShortcut.Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        let special: [UInt16: String] = [UInt16(kVK_Space): "space", UInt16(kVK_Return): "return", UInt16(kVK_Tab): "tab"]
        if let name = special[event.keyCode] { return KeyShortcut(key: name, modifiers: modifiers) }
        for n in 1...12 where Int(event.keyCode) == keyCode("f\(n)") { return KeyShortcut(key: "f\(n)", modifiers: modifiers) }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1, KeyShortcut.knownKeys.contains(chars) else { return nil }
        return KeyShortcut(key: chars, modifiers: modifiers)
    }
}
