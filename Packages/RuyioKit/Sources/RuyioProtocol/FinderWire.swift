import Foundation

/// Host ⇄ Finder Sync Extension wire format (plan §13.1–13.3.1). Versioned independently of the
/// plugin IPC so an old extension process can keep running after a host update.
public enum FinderWire {
    public static let wireSchemaVersion = 1
    public static let snapshotFileName = "menu-snapshot-v1.json"
    public static let requestsDirectoryName = "requests-v1"
    public static let requestNotification = "app.ruyio.finder.request"
    public static let snapshotNotification = "app.ruyio.finder.snapshot"
    /// Time the host has to accept a click before it must be repeated (plan §13.2).
    public static let requestTTL: TimeInterval = 15
    /// Dynamic (clipboard) children older than this are treated as stale.
    public static let dynamicTTL: TimeInterval = 6 * 3600
    public static let maxRequestBytes = 64 * 1024
    public static let maxTitleCharacters = 60

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

public struct FinderMenuSnapshot: Codable, Sendable, Hashable {
    public struct Child: Codable, Sendable, Hashable {
        public var id: String
        /// Metadata only ("Text · 10:32"); never clipboard content (PRD §19.17).
        public var title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = String(title.prefix(FinderWire.maxTitleCharacters))
        }
    }

    public struct Item: Codable, Sendable, Hashable {
        public var actionID: String
        public var title: String
        /// "directory", "file"
        public var targets: [String]
        /// "none", "single", "files", "directories", "multiple"
        public var selection: [String]
        public var requiresWritableTarget: Bool
        public var requiresClipboardKind: [String]?
        /// When present, the item expands inline into these children (no fourth level).
        public var children: [Child]?
        public var needsInput: Bool

        public init(actionID: String, title: String, targets: [String], selection: [String], requiresWritableTarget: Bool,
                    requiresClipboardKind: [String]? = nil, children: [Child]? = nil, needsInput: Bool = false) {
            self.actionID = actionID
            self.title = title
            self.targets = targets
            self.selection = selection
            self.requiresWritableTarget = requiresWritableTarget
            self.requiresClipboardKind = requiresClipboardKind
            self.children = children
            self.needsInput = needsInput
        }
    }

    public struct Group: Codable, Sendable, Hashable {
        public var pluginID: String
        public var title: String
        public var items: [Item]
        public init(pluginID: String, title: String, items: [Item]) {
            self.pluginID = pluginID
            self.title = title
            self.items = items
        }
    }

    public var wireSchemaVersion: Int
    public var generation: Int
    public var generatedAt: Date
    public var dynamicGeneratedAt: Date?
    public var locale: String
    public var rootTitle: String
    public var groups: [Group]
    /// Kinds currently on the pasteboard ("text", "image", "url", "file"), for context filtering.
    public var clipboardKinds: [String]
    /// Localized fallback titles the extension may need without the host.
    public var strings: [String: String]

    public init(generation: Int, generatedAt: Date = Date(), dynamicGeneratedAt: Date?, locale: String, rootTitle: String = "Ruyio",
                groups: [Group], clipboardKinds: [String], strings: [String: String]) {
        wireSchemaVersion = FinderWire.wireSchemaVersion
        self.generation = generation
        self.generatedAt = generatedAt
        self.dynamicGeneratedAt = dynamicGeneratedAt
        self.locale = locale
        self.rootTitle = rootTitle
        self.groups = groups
        self.clipboardKinds = clipboardKinds
        self.strings = strings
    }
}

/// A frozen Finder click (PRD §19.17): target, selection, action and snapshot generation.
public struct FinderRequest: Codable, Sendable, Hashable {
    public var wireSchemaVersion: Int
    public var requestID: String
    public var createdAt: Date
    public var pluginID: String
    public var actionID: String
    public var dynamicItemID: String?
    public var targetDirectory: String?
    public var selection: [String]
    public var snapshotGeneration: Int

    public init(requestID: String = UUID().uuidString.lowercased(), createdAt: Date = Date(), pluginID: String, actionID: String,
                dynamicItemID: String?, targetDirectory: String?, selection: [String], snapshotGeneration: Int) {
        wireSchemaVersion = FinderWire.wireSchemaVersion
        self.requestID = requestID
        self.createdAt = createdAt
        self.pluginID = pluginID
        self.actionID = actionID
        self.dynamicItemID = dynamicItemID
        self.targetDirectory = targetDirectory
        self.selection = Array(selection.prefix(1_000))
        self.snapshotGeneration = snapshotGeneration
    }
}

/// Context matching shared by the extension (menu building) and the host (re-validation on receipt).
public enum FinderContextMatcher {
    public struct Context: Sendable {
        public var targetIsDirectory: Bool
        public var selectionCount: Int
        public var selectionHasDirectories: Bool
        public var selectionHasFiles: Bool
        public var clipboardKinds: [String]
        public init(targetIsDirectory: Bool, selectionCount: Int, selectionHasDirectories: Bool, selectionHasFiles: Bool, clipboardKinds: [String]) {
            self.targetIsDirectory = targetIsDirectory
            self.selectionCount = selectionCount
            self.selectionHasDirectories = selectionHasDirectories
            self.selectionHasFiles = selectionHasFiles
            self.clipboardKinds = clipboardKinds
        }
    }

    /// Inapplicable actions are hidden, never shown disabled (PRD §9.2).
    public static func applies(_ item: FinderMenuSnapshot.Item, to context: Context) -> Bool {
        if item.targets.contains("directory") && !item.targets.contains("file") && !context.targetIsDirectory && context.selectionCount == 0 {
            return false
        }
        let selectionOK: Bool
        switch context.selectionCount {
        case 0: selectionOK = item.selection.contains("none")
        case 1: selectionOK = item.selection.contains("single") || item.selection.contains("files")
            || (item.selection.contains("directories") && context.selectionHasDirectories && !context.selectionHasFiles)
        default: selectionOK = item.selection.contains("multiple") || item.selection.contains("files")
            || (item.selection.contains("directories") && !context.selectionHasFiles)
        }
        guard selectionOK else { return false }
        if let kinds = item.requiresClipboardKind, !kinds.isEmpty, Set(kinds).isDisjoint(with: context.clipboardKinds) { return false }
        if let children = item.children, children.isEmpty { return false }
        return true
    }
}
