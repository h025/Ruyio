import Foundation
import RuyioCore

/// Wire envelope. One per frame (plan §8.2).
public struct Envelope: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case request, response, event }

    public var protocolVersion: Int
    public var messageID: String
    public var kind: Kind
    public var method: String
    public var replyTo: String?
    public var executionID: ExecutionID?
    public var operationID: OperationID?
    public var registryGeneration: Int?
    public var payload: JSONValue
    public var error: RuyioError?

    public init(
        protocolVersion: Int = 1, messageID: String = UUID().uuidString.lowercased(), kind: Kind, method: String,
        replyTo: String? = nil, executionID: ExecutionID? = nil, operationID: OperationID? = nil,
        registryGeneration: Int? = nil, payload: JSONValue = .null, error: RuyioError? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.messageID = messageID
        self.kind = kind
        self.method = method
        self.replyTo = replyTo
        self.executionID = executionID
        self.operationID = operationID
        self.registryGeneration = registryGeneration
        self.payload = payload
        self.error = error
    }
}

/// Method names. Plugins may only send the plugin→host set; the host rejects anything else.
public enum Method {
    // host → plugin
    public static let hello = "hello"
    public static let actionInvoke = "action.invoke"
    public static let actionCancel = "action.cancel"
    public static let viewOpen = "view.open"
    public static let viewEvent = "view.event"
    public static let viewClose = "view.close"
    public static let dynamicItems = "finder.dynamicItems"
    public static let localeChanged = "locale.changed"
    public static let lifecycleShutdown = "lifecycle.shutdown"
    public static let lifecyclePing = "lifecycle.ping"
    public static let lifecycleMigrate = "lifecycle.migrate"
    public static let lifecycleHealth = "lifecycle.health"
    public static let settingsChanged = "settings.changed"

    // plugin → host
    public static let actionProgress = "action.progress"
    public static let viewUpdate = "view.update"
    public static let snapshotPublish = "snapshot.publish"
    public static let statusPublish = "status.publish"
    public static let storagePrefix = "storage."
    public static let capabilityPrefix = "capability."

    public static let pluginToHostEvents: Set<String> = [actionProgress, viewUpdate, snapshotPublish, statusPublish]
}

public enum RuntimeMode: String, Codable, Sendable {
    /// Normal operation on the committed active data generation.
    case normal
    /// Update migration: candidate partition only, no side-effect capabilities (plan §8.3).
    case migration
    /// Read-only health check on the candidate partition.
    case health
}

/// Explicit data preparation contract. Zero denotes a fresh, empty candidate partition.
public struct DataPreparationRequest: Codable, Sendable, Hashable {
    public var sourceSchemaVersion: Int
    public var targetSchemaVersion: Int

    public init(sourceSchemaVersion: Int, targetSchemaVersion: Int) {
        self.sourceSchemaVersion = sourceSchemaVersion
        self.targetSchemaVersion = targetSchemaVersion
    }
}

public struct HelloRequest: Codable, Sendable, Hashable {
    public var nonce: String
    public var hostVersion: SemanticVersion
    public var ipcVersions: [Int]
    public var uiSchemaVersions: [Int]
    public var expectedPluginID: PluginID
    public var locale: String
    public var runtimeMode: RuntimeMode

    public init(nonce: String, hostVersion: SemanticVersion, ipcVersions: [Int], uiSchemaVersions: [Int],
                expectedPluginID: PluginID, locale: String, runtimeMode: RuntimeMode) {
        self.nonce = nonce
        self.hostVersion = hostVersion
        self.ipcVersions = ipcVersions
        self.uiSchemaVersions = uiSchemaVersions
        self.expectedPluginID = expectedPluginID
        self.locale = locale
        self.runtimeMode = runtimeMode
    }
}

public struct HelloReply: Codable, Sendable, Hashable {
    public var nonce: String
    public var pluginID: PluginID
    public var version: SemanticVersion
    public var ipcVersion: Int
    public var uiSchemaVersion: Int
    public var sdkVersion: String

    public init(nonce: String, pluginID: PluginID, version: SemanticVersion, ipcVersion: Int, uiSchemaVersion: Int, sdkVersion: String) {
        self.nonce = nonce
        self.pluginID = pluginID
        self.version = version
        self.ipcVersion = ipcVersion
        self.uiSchemaVersion = uiSchemaVersion
        self.sdkVersion = sdkVersion
    }
}

// MARK: - Actions

/// A file the user pointed at. The path is information, not an access grant (plan §13.2).
public struct FileRef: Codable, Sendable, Hashable {
    /// Opaque, host-issued reference valid for one operation.
    public var ref: String
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var isPackage: Bool

    public init(ref: String, path: String, name: String, isDirectory: Bool, isPackage: Bool = false) {
        self.ref = ref
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
    }
}

public struct FinderInvocationContext: Codable, Sendable, Hashable {
    public var targetDirectory: FileRef?
    public var selection: [FileRef]
    public var dynamicItemID: String?
    public init(targetDirectory: FileRef?, selection: [FileRef], dynamicItemID: String? = nil) {
        self.targetDirectory = targetDirectory
        self.selection = selection
        self.dynamicItemID = dynamicItemID
    }
}

public struct ActionInvocation: Codable, Sendable, Hashable {
    public var actionID: ActionID
    public var entry: PresentationKind?
    public var parameters: [String: JSONValue]
    public var finder: FinderInvocationContext?
    public var viewID: String?
    public var itemID: String?
    public var contextRef: String?
    public var locale: String

    public init(actionID: ActionID, entry: PresentationKind?, parameters: [String: JSONValue] = [:],
                finder: FinderInvocationContext? = nil, viewID: String? = nil, itemID: String? = nil,
                contextRef: String? = nil, locale: String) {
        self.actionID = actionID
        self.entry = entry
        self.parameters = parameters
        self.finder = finder
        self.viewID = viewID
        self.itemID = itemID
        self.contextRef = contextRef
        self.locale = locale
    }
}

public enum ActionOutput: Sendable, Hashable {
    case none
    /// Short confirmation such as "Copied 3 paths" (PRD §18.2).
    case notice(String)
    case openView(String)
    case revealFiles([String])
    /// Ask the host to collect input and re-invoke with the values (state awaitingInput).
    case requestInput(FormSpec)
}

extension ActionOutput: Codable {
    private enum CodingKeys: String, CodingKey { case type, text, viewID, paths, form }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "none": self = .none
        case "notice": self = .notice(try c.decode(String.self, forKey: .text))
        case "openView": self = .openView(try c.decode(String.self, forKey: .viewID))
        case "revealFiles": self = .revealFiles(try c.decode([String].self, forKey: .paths))
        case "requestInput": self = .requestInput(try c.decode(FormSpec.self, forKey: .form))
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown output \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: try c.encode("none", forKey: .type)
        case .notice(let text): try c.encode("notice", forKey: .type); try c.encode(text, forKey: .text)
        case .openView(let id): try c.encode("openView", forKey: .type); try c.encode(id, forKey: .viewID)
        case .revealFiles(let paths): try c.encode("revealFiles", forKey: .type); try c.encode(paths, forKey: .paths)
        case .requestInput(let form): try c.encode("requestInput", forKey: .type); try c.encode(form, forKey: .form)
        }
    }
}

public struct ActionResult: Codable, Sendable, Hashable {
    public var state: ExecutionState
    public var output: ActionOutput
    public var error: RuyioError?

    public init(state: ExecutionState, output: ActionOutput = .none, error: RuyioError? = nil) {
        self.state = state
        self.output = output
        self.error = error
    }

    public static func succeeded(_ output: ActionOutput = .none) -> ActionResult { .init(state: .succeeded, output: output) }
    public static func failed(_ error: RuyioError) -> ActionResult { .init(state: .failed, error: error) }
}

public struct ActionProgress: Codable, Sendable, Hashable {
    public var fraction: Double?
    public var label: String?
    public init(fraction: Double? = nil, label: String? = nil) {
        self.fraction = fraction
        self.label = label
    }
}

// MARK: - Views

public struct ViewOpenRequest: Codable, Sendable, Hashable {
    public var viewID: String
    public var parameters: [String: JSONValue]
    public var locale: String
    public init(viewID: String, parameters: [String: JSONValue] = [:], locale: String) {
        self.viewID = viewID
        self.parameters = parameters
        self.locale = locale
    }
}

public struct ViewEventRequest: Codable, Sendable, Hashable {
    public var viewID: String
    public var revision: Int
    public var event: ViewEvent
    public init(viewID: String, revision: Int, event: ViewEvent) {
        self.viewID = viewID
        self.revision = revision
        self.event = event
    }
}

/// What the host should do after a view event, in addition to an optional new document.
public enum ViewEffect: Sendable, Hashable {
    case none
    case close
    /// Close the overlay, restore the previous app, then paste (or only copy) — host-mediated (PRD §19.15).
    case closeAndPaste(plainText: Bool, autoPaste: Bool)
    case notice(String)
    case confirm(ConfirmSpec)
}

extension ViewEffect: Codable {
    private enum CodingKeys: String, CodingKey { case type, plainText, autoPaste, text, confirm }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "none": self = .none
        case "close": self = .close
        case "closeAndPaste":
            self = .closeAndPaste(plainText: try c.decode(Bool.self, forKey: .plainText), autoPaste: try c.decode(Bool.self, forKey: .autoPaste))
        case "notice": self = .notice(try c.decode(String.self, forKey: .text))
        case "confirm": self = .confirm(try c.decode(ConfirmSpec.self, forKey: .confirm))
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown effect \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: try c.encode("none", forKey: .type)
        case .close: try c.encode("close", forKey: .type)
        case .closeAndPaste(let plain, let auto):
            try c.encode("closeAndPaste", forKey: .type); try c.encode(plain, forKey: .plainText); try c.encode(auto, forKey: .autoPaste)
        case .notice(let text): try c.encode("notice", forKey: .type); try c.encode(text, forKey: .text)
        case .confirm(let spec): try c.encode("confirm", forKey: .type); try c.encode(spec, forKey: .confirm)
        }
    }
}

/// Host-rendered confirmation for destructive operations; focus defaults to the safe action (PRD §18.3).
public struct ConfirmSpec: Codable, Sendable, Hashable {
    public var title: String
    public var message: String
    public var confirmTitle: String
    public var confirmActionID: String
    public var isDestructive: Bool
    public init(title: String, message: String, confirmTitle: String, confirmActionID: String, isDestructive: Bool) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.confirmActionID = confirmActionID
        self.isDestructive = isDestructive
    }
}

public struct ViewEventReply: Codable, Sendable, Hashable {
    public var document: ViewDocument?
    public var effect: ViewEffect
    public init(document: ViewDocument?, effect: ViewEffect = .none) {
        self.document = document
        self.effect = effect
    }
}

// MARK: - Status and snapshots

/// Menu bar / overlay status published by a plugin (e.g. clipboard capture state).
public struct PluginStatusReport: Codable, Sendable, Hashable {
    public var captureState: CaptureState?
    public var statusText: String?
    public var detail: String?
    public init(captureState: CaptureState? = nil, statusText: String? = nil, detail: String? = nil) {
        self.captureState = captureState
        self.statusText = statusText
        self.detail = detail
    }
}

/// Dynamic Finder children published ahead of time; titles carry metadata only (PRD §19.17).
public struct DynamicItemsReport: Codable, Sendable, Hashable {
    public struct Item: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var kind: String
        public init(id: String, title: String, kind: String) {
            self.id = id
            self.title = String(title.prefix(60))
            self.kind = kind
        }
    }
    public var provider: String
    public var items: [Item]
    public var clipboardKinds: [String]
    public init(provider: String, items: [Item], clipboardKinds: [String] = []) {
        self.provider = provider
        self.items = Array(items.prefix(5))
        self.clipboardKinds = clipboardKinds
    }
}
