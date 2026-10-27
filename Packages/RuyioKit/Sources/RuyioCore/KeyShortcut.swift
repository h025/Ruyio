import Foundation

/// Platform-neutral keyboard shortcut. Key is a lowercase key name ("v", "space", "f5").
public struct KeyShortcut: Hashable, Codable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Codable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public var key: String
    public var modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// Parses manifest strings such as "command+shift+v".
    public init?(manifestString: String) {
        let parts = manifestString.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty else { return nil }
        var modifiers: Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "command", "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "option", "alt", "opt": modifiers.insert(.option)
            case "control", "ctrl": modifiers.insert(.control)
            default: return nil
            }
        }
        guard KeyShortcut.knownKeys.contains(key) else { return nil }
        self.init(key: key, modifiers: modifiers)
    }

    public var manifestString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("control") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("command") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// Display form using macOS symbols, e.g. "⇧⌘V". Symbols are never translated.
    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case "space": text += "Space"
        case "return": text += "↩"
        case "escape": text += "⎋"
        case "delete": text += "⌫"
        case "tab": text += "⇥"
        default: text += key.uppercased()
        }
        return text
    }

    public var description: String { displayString }

    /// Reasons a shortcut may not be registered globally (plan §13.5).
    public enum Rejection: String, Codable, Sendable {
        case noModifier
        case systemReserved
        case optionOnlyOnEarlySequoia
    }

    public func rejection(on os: OSVersion = .current) -> Rejection? {
        if modifiers.isEmpty || modifiers == .shift { return .noModifier }
        if KeyShortcut.systemReserved.contains(self) { return .systemReserved }
        let optionOnly = modifiers == .option || modifiers == [.option, .shift]
        if optionOnly && os.major == 15 && os.minor < 2 { return .optionOnlyOnEarlySequoia }
        return nil
    }

    /// Known system-wide defaults that must not be offered as defaults or silently taken.
    public static let systemReserved: Set<KeyShortcut> = [
        KeyShortcut(key: "space", modifiers: [.command]),               // Spotlight
        KeyShortcut(key: "space", modifiers: [.command, .option]),      // Finder search window
        KeyShortcut(key: "space", modifiers: [.control]),               // Previous input source
        KeyShortcut(key: "space", modifiers: [.control, .option]),      // Next input source
        KeyShortcut(key: "space", modifiers: [.control, .command]),     // Emoji & Symbols
        KeyShortcut(key: "tab", modifiers: [.command]),
        KeyShortcut(key: "q", modifiers: [.command]),
        KeyShortcut(key: "w", modifiers: [.command]),
        KeyShortcut(key: "h", modifiers: [.command]),
        KeyShortcut(key: "m", modifiers: [.command]),
        KeyShortcut(key: "c", modifiers: [.command]),
        KeyShortcut(key: "v", modifiers: [.command]),
        KeyShortcut(key: "x", modifiers: [.command]),
        KeyShortcut(key: "z", modifiers: [.command]),
        KeyShortcut(key: "a", modifiers: [.command]),
        KeyShortcut(key: "3", modifiers: [.command, .shift]),
        KeyShortcut(key: "4", modifiers: [.command, .shift]),
        KeyShortcut(key: "5", modifiers: [.command, .shift]),
        KeyShortcut(key: "q", modifiers: [.control, .command]),
    ]

    public static let knownKeys: Set<String> = {
        var keys = Set("abcdefghijklmnopqrstuvwxyz0123456789".map(String.init))
        keys.formUnion(["space", "return", "escape", "delete", "tab", "comma", "period", "slash", "semicolon",
                        "quote", "leftbracket", "rightbracket", "backslash", "minus", "equal", "grave",
                        "up", "down", "left", "right"])
        for n in 1...20 { keys.insert("f\(n)") }
        return keys
    }()
}
