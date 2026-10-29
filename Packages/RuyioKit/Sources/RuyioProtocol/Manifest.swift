import Foundation
import RuyioCore

/// Plugin manifest (PRD §10.2 + plan §7.1). The copy inside the signed bundle is authoritative.
public struct PluginManifest: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var id: PluginID
    public var name: String
    public var description: String?
    public var version: SemanticVersion
    public var minimumHostVersion: SemanticVersion
    public var minimumMacOSVersion: OSVersion
    public var architectures: [String]
    public var runtime: String
    public var bundlePath: String
    public var executable: String
    public var permissions: [Permission]
    public var actions: [ActionDeclaration]
    public var views: [ViewDeclaration]
    public var supportedIPC: [Int]
    public var supportedUISchema: [Int]
    public var storageSchemaVersion: Int
    public var defaultLocale: String
    /// locale → key → string. Keys: "name", "description", "action.<id>.title", "view.<id>.title", free keys.
    public var localizations: [String: [String: String]]
    public var author: String?
    public var source: String?
    public var homepage: String?
    public var license: String?

    public init(
        schemaVersion: Int = 1, id: PluginID, name: String, description: String? = nil,
        version: SemanticVersion, minimumHostVersion: SemanticVersion = SemanticVersion(major: 0, minor: 0, patch: 1),
        minimumMacOSVersion: OSVersion = OSVersion(major: 15), architectures: [String] = ["arm64"],
        runtime: String = "native-isolated", bundlePath: String, executable: String,
        permissions: [Permission] = [], actions: [ActionDeclaration] = [], views: [ViewDeclaration] = [],
        supportedIPC: [Int] = [1], supportedUISchema: [Int] = [1], storageSchemaVersion: Int = 1,
        defaultLocale: String = "en", localizations: [String: [String: String]] = [:],
        author: String? = nil, source: String? = nil, homepage: String? = nil, license: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.minimumHostVersion = minimumHostVersion
        self.minimumMacOSVersion = minimumMacOSVersion
        self.architectures = architectures
        self.runtime = runtime
        self.bundlePath = bundlePath
        self.executable = executable
        self.permissions = permissions
        self.actions = actions
        self.views = views
        self.supportedIPC = supportedIPC
        self.supportedUISchema = supportedUISchema
        self.storageSchemaVersion = storageSchemaVersion
        self.defaultLocale = defaultLocale
        self.localizations = localizations
        self.author = author
        self.source = source
        self.homepage = homepage
        self.license = license
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, description, version, minimumHostVersion, minimumMacOSVersion, architectures
        case runtime, bundlePath, executable, permissions, actions, views, supportedIPC, supportedUISchema
        case storageSchemaVersion, defaultLocale, localizations, author, source, homepage, license
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(PluginID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        version = try c.decode(SemanticVersion.self, forKey: .version)
        minimumHostVersion = try c.decode(SemanticVersion.self, forKey: .minimumHostVersion)
        minimumMacOSVersion = try c.decode(OSVersion.self, forKey: .minimumMacOSVersion)
        architectures = try c.decode([String].self, forKey: .architectures)
        runtime = try c.decode(String.self, forKey: .runtime)
        bundlePath = try c.decode(String.self, forKey: .bundlePath)
        executable = try c.decode(String.self, forKey: .executable)
        // Unknown permission identifiers are a hard failure (PRD §10.2).
        permissions = try c.decodeIfPresent([Permission].self, forKey: .permissions) ?? []
        actions = try c.decodeIfPresent([ActionDeclaration].self, forKey: .actions) ?? []
        views = try c.decodeIfPresent([ViewDeclaration].self, forKey: .views) ?? []
        supportedIPC = try c.decodeIfPresent([Int].self, forKey: .supportedIPC) ?? [1]
        supportedUISchema = try c.decodeIfPresent([Int].self, forKey: .supportedUISchema) ?? [1]
        storageSchemaVersion = try c.decodeIfPresent(Int.self, forKey: .storageSchemaVersion) ?? 1
        defaultLocale = try c.decodeIfPresent(String.self, forKey: .defaultLocale) ?? "en"
        localizations = try c.decodeIfPresent([String: [String: String]].self, forKey: .localizations) ?? [:]
        author = try c.decodeIfPresent(String.self, forKey: .author)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        license = try c.decodeIfPresent(String.self, forKey: .license)
    }

    public func action(_ id: ActionID) -> ActionDeclaration? { actions.first { $0.id == id } }
    public func view(_ id: String) -> ViewDeclaration? { views.first { $0.id == id } }
}

public struct ActionDeclaration: Codable, Sendable, Hashable {
    public var id: ActionID
    public var handler: String
    /// Default title (in `defaultLocale`); localized via "action.<id>.title".
    public var title: String
    public var subtitle: String?
    public var keywords: [String]
    public var symbol: String?
    public var presentations: [Presentation]
    public var parameters: FormSpec?
    public var completion: CompletionBehavior
    /// Opens this view instead of running a handler, e.g. "show-history" → "history".
    public var opensView: String?
    /// Actions in the same group never run concurrently in one plugin.
    public var concurrencyGroup: String?
    /// Whether the action has external side effects that need an operation receipt.
    public var hasSideEffects: Bool

    public init(
        id: ActionID, handler: String? = nil, title: String, subtitle: String? = nil, keywords: [String] = [],
        symbol: String? = nil, presentations: [Presentation], parameters: FormSpec? = nil,
        completion: CompletionBehavior = .closePanel, opensView: String? = nil, concurrencyGroup: String? = nil,
        hasSideEffects: Bool = false
    ) {
        self.id = id
        self.handler = handler ?? id.rawValue
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.symbol = symbol
        self.presentations = presentations
        self.parameters = parameters
        self.completion = completion
        self.opensView = opensView
        self.concurrencyGroup = concurrencyGroup
        self.hasSideEffects = hasSideEffects
    }

    enum CodingKeys: String, CodingKey {
        case id, handler, title, subtitle, keywords, symbol, presentations, parameters, completion, opensView
        case concurrencyGroup, hasSideEffects
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ActionID.self, forKey: .id)
        handler = try c.decodeIfPresent(String.self, forKey: .handler) ?? id.rawValue
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        presentations = try c.decode([Presentation].self, forKey: .presentations)
        parameters = try c.decodeIfPresent(FormSpec.self, forKey: .parameters)
        completion = try c.decodeIfPresent(CompletionBehavior.self, forKey: .completion) ?? .closePanel
        opensView = try c.decodeIfPresent(String.self, forKey: .opensView)
        concurrencyGroup = try c.decodeIfPresent(String.self, forKey: .concurrencyGroup)
        hasSideEffects = try c.decodeIfPresent(Bool.self, forKey: .hasSideEffects) ?? false
    }

    public func presentation(_ kind: PresentationKind) -> Presentation? {
        presentations.first { $0.kind == kind }
    }
}

public struct ViewDeclaration: Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    /// overlay = independent floating panel (e.g. clipboard history); page = plugin detail page; settings.
    public var placement: ViewPlacement

    public init(id: String, title: String, placement: ViewPlacement) {
        self.id = id
        self.title = title
        self.placement = placement
    }
}

public enum ViewPlacement: String, Codable, Sendable {
    case overlay, page, settings
}

public enum PresentationKind: String, Codable, Sendable, CaseIterable {
    case commandPalette, globalHotkey, finderContextMenu, menuBar
}

/// Where an action may appear. Presentations describe entries only, never behavior (PRD §10.3).
public struct Presentation: Codable, Sendable, Hashable {
    public var type: PresentationKind
    public var title: String?
    public var defaultShortcut: String?
    public var group: String?
    /// For Finder: "item" (single action) or "groupItems" (dynamic children expand inline).
    public var presentation: String?
    public var childrenProvider: String?
    public var contexts: FinderContexts?
    /// For menu bar: "action" or "status".
    public var menuRole: String?
    public var order: Int?

    public init(
        type: PresentationKind, title: String? = nil, defaultShortcut: String? = nil, group: String? = nil,
        presentation: String? = nil, childrenProvider: String? = nil, contexts: FinderContexts? = nil,
        menuRole: String? = nil, order: Int? = nil
    ) {
        self.type = type
        self.title = title
        self.defaultShortcut = defaultShortcut
        self.group = group
        self.presentation = presentation
        self.childrenProvider = childrenProvider
        self.contexts = contexts
        self.menuRole = menuRole
        self.order = order
    }

    public var kind: PresentationKind { type }
}

public struct FinderContexts: Codable, Sendable, Hashable {
    /// "directory", "file"
    public var targets: [String]
    /// "none", "single", "files", "directories", "multiple"
    public var selection: [String]
    public var requiresWritableTarget: Bool?
    public var requiresClipboardKind: [String]?

    public init(targets: [String], selection: [String], requiresWritableTarget: Bool? = nil, requiresClipboardKind: [String]? = nil) {
        self.targets = targets
        self.selection = selection
        self.requiresWritableTarget = requiresWritableTarget
        self.requiresClipboardKind = requiresClipboardKind
    }
}

// MARK: - Localization

public extension PluginManifest {
    /// Fallback chain (plan §17.1): exact → language-compatible → plugin default → literal fallback.
    func localized(_ key: String, locale: String, fallback: String) -> LocalizedText {
        for candidate in Localization.candidates(for: locale) {
            if let table = localizations[candidate], let value = table[key] {
                return LocalizedText(text: value, locale: candidate, isFallback: false)
            }
        }
        if let value = localizations[defaultLocale]?[key] {
            return LocalizedText(text: value, locale: defaultLocale, isFallback: !Localization.matches(locale, defaultLocale))
        }
        return LocalizedText(text: fallback, locale: defaultLocale, isFallback: !Localization.matches(locale, defaultLocale))
    }

    func displayName(locale: String) -> LocalizedText { localized("name", locale: locale, fallback: name) }

    func actionTitle(_ action: ActionDeclaration, locale: String) -> LocalizedText {
        localized("action.\(action.id).title", locale: locale, fallback: action.title)
    }
}

public struct LocalizedText: Sendable, Hashable {
    public var text: String
    public var locale: String
    public var isFallback: Bool
}

public enum Localization {
    /// Host languages shipped in V1.
    public static let hostLanguages = ["zh-Hans", "en"]

    /// Resolves a BCP 47 preference to a host language (plan §17.1): Chinese → zh-Hans, else en.
    public static func hostLanguage(for preferred: [String]) -> String {
        for identifier in preferred {
            let lower = identifier.lowercased()
            if lower.hasPrefix("zh") { return "zh-Hans" }
            if lower.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    static func candidates(for locale: String) -> [String] {
        var result = [locale]
        if locale.lowercased().hasPrefix("zh") { result.append(contentsOf: ["zh-Hans", "zh"]) }
        if let language = locale.split(separator: "-").first.map(String.init), language != locale { result.append(language) }
        return result
    }

    static func matches(_ a: String, _ b: String) -> Bool {
        a.split(separator: "-").first?.lowercased() == b.split(separator: "-").first?.lowercased()
    }
}
