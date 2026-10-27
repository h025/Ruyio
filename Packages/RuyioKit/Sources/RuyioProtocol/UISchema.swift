import Foundation
import RuyioCore

/// Versioned, host-rendered UI description (PRD §10.4, plan §9). Plugins never ship view code.
public struct ViewDocument: Codable, Sendable, Hashable {
    public var viewID: String
    /// Monotonic per view; stale responses with a lower revision are dropped by the host.
    public var revision: Int
    public var title: String?
    public var root: UINode

    public init(viewID: String, revision: Int, title: String? = nil, root: UINode) {
        self.viewID = viewID
        self.revision = revision
        self.title = title
        self.root = root
    }
}

public indirect enum UINode: Sendable, Hashable {
    case stack(StackSpec)
    case text(TextSpec)
    case markdown(String)
    case code(String)
    case image(ImageSpec)
    case keyValue([KeyValueRow])
    case form(FormSpec)
    case list(ListSpec)
    case collection(CollectionSpec)
    case empty(EmptySpec)
    case error(ErrorSpec)
    case progress(ProgressSpec)
    case loading
}

extension UINode: Codable {
    private enum CodingKeys: String, CodingKey { case type, spec }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "stack": self = .stack(try c.decode(StackSpec.self, forKey: .spec))
        case "text": self = .text(try c.decode(TextSpec.self, forKey: .spec))
        case "markdown": self = .markdown(try c.decode(String.self, forKey: .spec))
        case "code": self = .code(try c.decode(String.self, forKey: .spec))
        case "image": self = .image(try c.decode(ImageSpec.self, forKey: .spec))
        case "keyValue": self = .keyValue(try c.decode([KeyValueRow].self, forKey: .spec))
        case "form": self = .form(try c.decode(FormSpec.self, forKey: .spec))
        case "list": self = .list(try c.decode(ListSpec.self, forKey: .spec))
        case "collection": self = .collection(try c.decode(CollectionSpec.self, forKey: .spec))
        case "empty": self = .empty(try c.decode(EmptySpec.self, forKey: .spec))
        case "error": self = .error(try c.decode(ErrorSpec.self, forKey: .spec))
        case "progress": self = .progress(try c.decode(ProgressSpec.self, forKey: .spec))
        case "loading": self = .loading
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown UI node type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stack(let s): try c.encode("stack", forKey: .type); try c.encode(s, forKey: .spec)
        case .text(let s): try c.encode("text", forKey: .type); try c.encode(s, forKey: .spec)
        case .markdown(let s): try c.encode("markdown", forKey: .type); try c.encode(s, forKey: .spec)
        case .code(let s): try c.encode("code", forKey: .type); try c.encode(s, forKey: .spec)
        case .image(let s): try c.encode("image", forKey: .type); try c.encode(s, forKey: .spec)
        case .keyValue(let s): try c.encode("keyValue", forKey: .type); try c.encode(s, forKey: .spec)
        case .form(let s): try c.encode("form", forKey: .type); try c.encode(s, forKey: .spec)
        case .list(let s): try c.encode("list", forKey: .type); try c.encode(s, forKey: .spec)
        case .collection(let s): try c.encode("collection", forKey: .type); try c.encode(s, forKey: .spec)
        case .empty(let s): try c.encode("empty", forKey: .type); try c.encode(s, forKey: .spec)
        case .error(let s): try c.encode("error", forKey: .type); try c.encode(s, forKey: .spec)
        case .progress(let s): try c.encode("progress", forKey: .type); try c.encode(s, forKey: .spec)
        case .loading: try c.encode("loading", forKey: .type)
        }
    }
}

public struct StackSpec: Codable, Sendable, Hashable {
    public enum Axis: String, Codable, Sendable { case vertical, horizontal }
    public var axis: Axis
    public var children: [UINode]
    public init(axis: Axis = .vertical, children: [UINode]) {
        self.axis = axis
        self.children = children
    }
}

public struct TextSpec: Codable, Sendable, Hashable {
    public enum Style: String, Codable, Sendable { case title, headline, body, secondary, caption, monospaced }
    public var text: String
    public var style: Style
    public init(_ text: String, style: Style = .body) {
        self.text = text
        self.style = style
    }
}

public struct ImageSpec: Codable, Sendable, Hashable {
    /// Host blob reference. Remote URLs are never fetched (plan §9).
    public var blobID: String
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var accessibilityLabel: String
    public init(blobID: String, pixelWidth: Int? = nil, pixelHeight: Int? = nil, accessibilityLabel: String) {
        self.blobID = blobID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.accessibilityLabel = accessibilityLabel
    }
}

public struct KeyValueRow: Codable, Sendable, Hashable {
    public var key: String
    public var value: String
    public var monospaced: Bool
    public init(key: String, value: String, monospaced: Bool = false) {
        self.key = key
        self.value = value
        self.monospaced = monospaced
    }
}

// MARK: - Forms

public struct FormSpec: Codable, Sendable, Hashable {
    public var fields: [FieldSpec]
    public var submitTitle: String?
    public var footnote: String?
    public init(fields: [FieldSpec], submitTitle: String? = nil, footnote: String? = nil) {
        self.fields = fields
        self.submitTitle = submitTitle
        self.footnote = footnote
    }
}

public struct FieldSpec: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case textField, textEditor, toggle, picker, slider, stepper, fileChooser, directoryChooser, applicationChooser
    }
    public struct Option: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public var id: String
    public var label: String
    public var kind: Kind
    public var value: JSONValue
    public var placeholder: String?
    public var help: String?
    public var options: [Option]?
    public var minimum: Double?
    public var maximum: Double?
    public var step: Double?
    public var isRequired: Bool
    /// Inline validation error to show next to the field.
    public var error: String?
    /// For text fields: select only the base name, not the extension (PRD §19.18).
    public var selectsBaseName: Bool

    public init(
        id: String, label: String, kind: Kind, value: JSONValue = .null, placeholder: String? = nil,
        help: String? = nil, options: [Option]? = nil, minimum: Double? = nil, maximum: Double? = nil,
        step: Double? = nil, isRequired: Bool = false, error: String? = nil, selectsBaseName: Bool = false
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.value = value
        self.placeholder = placeholder
        self.help = help
        self.options = options
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.isRequired = isRequired
        self.error = error
        self.selectsBaseName = selectsBaseName
    }
}

// MARK: - Lists and collections

public struct ItemAction: Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var shortcut: String?
    public var symbol: String?
    public var isDestructive: Bool
    public var isDefault: Bool
    public init(id: String, title: String, shortcut: String? = nil, symbol: String? = nil, isDestructive: Bool = false, isDefault: Bool = false) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.symbol = symbol
        self.isDestructive = isDestructive
        self.isDefault = isDefault
    }
}

public struct ListItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var detail: String?
    public var symbol: String?
    public var thumbnailBlobID: String?
    public var badges: [String]
    public var isDisabled: Bool
    public var isFavorite: Bool
    public var accessibilityLabel: String?
    public var actions: [ItemAction]

    public init(
        id: String, title: String, subtitle: String? = nil, detail: String? = nil, symbol: String? = nil,
        thumbnailBlobID: String? = nil, badges: [String] = [], isDisabled: Bool = false, isFavorite: Bool = false,
        accessibilityLabel: String? = nil, actions: [ItemAction] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.symbol = symbol
        self.thumbnailBlobID = thumbnailBlobID
        self.badges = badges
        self.isDisabled = isDisabled
        self.isFavorite = isFavorite
        self.accessibilityLabel = accessibilityLabel
        self.actions = actions
    }
}

public struct ListSpec: Codable, Sendable, Hashable {
    public var items: [ListItem]
    public var selection: String?
    public var nextCursor: String?
    public var total: Int?
    public var empty: EmptySpec?
    public init(items: [ListItem], selection: String? = nil, nextCursor: String? = nil, total: Int? = nil, empty: EmptySpec? = nil) {
        self.items = items
        self.selection = selection
        self.nextCursor = nextCursor
        self.total = total
        self.empty = empty
    }
}

public struct FilterOption: Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct BannerSpec: Codable, Sendable, Hashable {
    public enum Tone: String, Codable, Sendable { case info, warning, critical }
    public var text: String
    public var tone: Tone
    public var actions: [ItemAction]
    public init(text: String, tone: Tone = .info, actions: [ItemAction] = []) {
        self.text = text
        self.tone = tone
        self.actions = actions
    }
}

public struct UndoSpec: Codable, Sendable, Hashable {
    public var text: String
    public var token: String
    public var expiresAt: Date
    public init(text: String, token: String, expiresAt: Date) {
        self.text = text
        self.token = token
        self.expiresAt = expiresAt
    }
}

/// Semantic component for search + list + preview panels (plan §9 `collectionWithPreview`). Open to all plugins.
public struct CollectionSpec: Codable, Sendable, Hashable {
    public var searchText: String
    public var searchPlaceholder: String
    public var filters: [FilterOption]
    public var selectedFilter: String?
    public var list: ListSpec
    public var preview: UINode?
    public var footerActions: [ItemAction]
    public var banner: BannerSpec?
    public var undo: UndoSpec?

    public init(
        searchText: String = "", searchPlaceholder: String, filters: [FilterOption] = [], selectedFilter: String? = nil,
        list: ListSpec, preview: UINode? = nil, footerActions: [ItemAction] = [], banner: BannerSpec? = nil, undo: UndoSpec? = nil
    ) {
        self.searchText = searchText
        self.searchPlaceholder = searchPlaceholder
        self.filters = filters
        self.selectedFilter = selectedFilter
        self.list = list
        self.preview = preview
        self.footerActions = footerActions
        self.banner = banner
        self.undo = undo
    }
}

public struct EmptySpec: Codable, Sendable, Hashable {
    public var title: String
    public var message: String?
    public var action: ItemAction?
    public init(title: String, message: String? = nil, action: ItemAction? = nil) {
        self.title = title
        self.message = message
        self.action = action
    }
}

public struct ErrorSpec: Codable, Sendable, Hashable {
    public var title: String
    public var message: String?
    public var code: String?
    public var actions: [ItemAction]
    public init(title: String, message: String? = nil, code: String? = nil, actions: [ItemAction] = []) {
        self.title = title
        self.message = message
        self.code = code
        self.actions = actions
    }
}

public struct ProgressSpec: Codable, Sendable, Hashable {
    public var label: String
    /// Nil means indeterminate; never fabricate a percentage (interaction §16.3).
    public var fraction: Double?
    public var cancellable: Bool
    public init(label: String, fraction: Double? = nil, cancellable: Bool = false) {
        self.label = label
        self.fraction = fraction
        self.cancellable = cancellable
    }
}

// MARK: - Events

public enum ViewEvent: Sendable, Hashable {
    case searchChanged(String)
    case filterChanged(String)
    case selectionChanged(String?)
    case invoke(actionID: String, itemID: String?)
    case submit([String: JSONValue])
    case fieldChanged(fieldID: String, value: JSONValue)
    case loadNextPage(cursor: String)
    case undo(token: String)
    case cancel
}

extension ViewEvent: Codable {
    private enum CodingKeys: String, CodingKey { case type, text, id, actionID, itemID, values, fieldID, value, cursor, token }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "searchChanged": self = .searchChanged(try c.decode(String.self, forKey: .text))
        case "filterChanged": self = .filterChanged(try c.decode(String.self, forKey: .id))
        case "selectionChanged": self = .selectionChanged(try c.decodeIfPresent(String.self, forKey: .itemID))
        case "invoke": self = .invoke(actionID: try c.decode(String.self, forKey: .actionID), itemID: try c.decodeIfPresent(String.self, forKey: .itemID))
        case "submit": self = .submit(try c.decode([String: JSONValue].self, forKey: .values))
        case "fieldChanged": self = .fieldChanged(fieldID: try c.decode(String.self, forKey: .fieldID), value: try c.decode(JSONValue.self, forKey: .value))
        case "loadNextPage": self = .loadNextPage(cursor: try c.decode(String.self, forKey: .cursor))
        case "undo": self = .undo(token: try c.decode(String.self, forKey: .token))
        case "cancel": self = .cancel
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown event \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .searchChanged(let text): try c.encode("searchChanged", forKey: .type); try c.encode(text, forKey: .text)
        case .filterChanged(let id): try c.encode("filterChanged", forKey: .type); try c.encode(id, forKey: .id)
        case .selectionChanged(let id): try c.encode("selectionChanged", forKey: .type); try c.encodeIfPresent(id, forKey: .itemID)
        case .invoke(let actionID, let itemID):
            try c.encode("invoke", forKey: .type); try c.encode(actionID, forKey: .actionID); try c.encodeIfPresent(itemID, forKey: .itemID)
        case .submit(let values): try c.encode("submit", forKey: .type); try c.encode(values, forKey: .values)
        case .fieldChanged(let fieldID, let value):
            try c.encode("fieldChanged", forKey: .type); try c.encode(fieldID, forKey: .fieldID); try c.encode(value, forKey: .value)
        case .loadNextPage(let cursor): try c.encode("loadNextPage", forKey: .type); try c.encode(cursor, forKey: .cursor)
        case .undo(let token): try c.encode("undo", forKey: .type); try c.encode(token, forKey: .token)
        case .cancel: try c.encode("cancel", forKey: .type)
        }
    }
}

// MARK: - Limits

public enum UISchemaLimits {
    public static let maxNodes = 500
    public static let maxDepth = 12
    public static let firstPageSize = 50

    public static func validate(_ document: ViewDocument) throws {
        var count = 0
        func walk(_ node: UINode, depth: Int) throws {
            count += 1
            if count > maxNodes { throw RuyioError(.invalidRequest, diagnostic: "view exceeds \(maxNodes) nodes") }
            if depth > maxDepth { throw RuyioError(.invalidRequest, diagnostic: "view exceeds depth \(maxDepth)") }
            switch node {
            case .stack(let s): for child in s.children { try walk(child, depth: depth + 1) }
            case .collection(let s):
                count += s.list.items.count
                if let preview = s.preview { try walk(preview, depth: depth + 1) }
            case .list(let s): count += s.items.count
            case .form(let s): count += s.fields.count
            case .keyValue(let rows): count += rows.count
            default: break
            }
            if count > maxNodes { throw RuyioError(.invalidRequest, diagnostic: "view exceeds \(maxNodes) nodes") }
        }
        try walk(document.root, depth: 1)
    }
}
