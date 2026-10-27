import Foundation
import RuyioCore
import RuyioProtocol

/// Read-only summary of one plugin for every page and menu (single source of truth, PRD §20.1).
public struct PluginSummary: Sendable, Hashable, Identifiable {
    public var id: PluginID
    public var manifest: PluginManifest
    public var displayName: String
    public var displayDescription: String?
    public var status: PluginStatus
    public var processState: ProcessState
    public var report: PluginStatusReport?
    public var isDefault: Bool
    public var teamID: String?
    public var installPath: String
    public var dataGeneration: Int
    public var lastError: RuyioError?

    public var version: SemanticVersion { manifest.version }
}

public struct CommandEntry: Sendable, Hashable, Identifiable {
    public var ref: ActionRef
    public var title: String
    public var subtitle: String?
    public var pluginName: String
    public var keywords: [String]
    public var symbol: String?
    public var shortcut: KeyShortcut?
    public var opensView: String?
    public var completion: CompletionBehavior
    public var needsFinderContext: Bool
    public var hasParameters: Bool
    public var id: String { ref.description }
}

public enum HotkeyRegistrationState: String, Sendable, Hashable {
    case registered, unavailable, conflict, pluginDisabled, unset, pending
}

public struct HotkeyEntry: Sendable, Hashable, Identifiable {
    public var ref: ActionRef
    public var title: String
    public var pluginName: String
    public var defaultShortcut: KeyShortcut?
    public var shortcut: KeyShortcut?
    public var isCustom: Bool
    public var isPluginEnabled: Bool
    public var state: HotkeyRegistrationState
    public var id: String { ref.description }
}

public struct MenuBarItem: Sendable, Hashable, Identifiable {
    public var ref: ActionRef
    public var title: String
    public var shortcut: KeyShortcut?
    public var id: String { ref.description }
}

public struct MenuBarGroup: Sendable, Hashable, Identifiable {
    public var pluginID: PluginID
    public var title: String
    public var status: PluginStatusReport?
    public var items: [MenuBarItem]
    public var id: String { pluginID.rawValue }
}

public struct FinderItemEntry: Sendable, Hashable, Identifiable {
    public var ref: ActionRef
    public var title: String
    public var contexts: FinderContexts
    public var childrenProvider: String?
    public var visible: Bool
    public var order: Int
    public var id: String { ref.description }
}

public struct FinderGroupEntry: Sendable, Hashable, Identifiable {
    public var pluginID: PluginID
    public var title: String
    public var items: [FinderItemEntry]
    public var order: Int
    public var id: String { pluginID.rawValue }
}

/// All entry presentations derived from one registry generation (plan §6.1).
public struct EntryProjection: Sendable, Hashable {
    public var generation: Int
    public var commands: [CommandEntry]
    public var hotkeys: [HotkeyEntry]
    public var menuBar: [MenuBarGroup]
    public var finder: [FinderGroupEntry]

    public static let empty = EntryProjection(generation: 0, commands: [], hotkeys: [], menuBar: [], finder: [])
}

public struct RegistrySnapshot: Sendable, Hashable {
    public var generation: Int
    public var plugins: [PluginSummary]
    public var restorableDefaults: [RestorableDefault]
    public var entries: EntryProjection

    public init(generation: Int, plugins: [PluginSummary], restorableDefaults: [RestorableDefault], entries: EntryProjection) {
        self.generation = generation
        self.plugins = plugins
        self.restorableDefaults = restorableDefaults
        self.entries = entries
    }
}

public struct RestorableDefault: Sendable, Hashable, Identifiable {
    public var id: PluginID
    public var displayName: String
    public var version: SemanticVersion
    public var keptData: Bool
}
