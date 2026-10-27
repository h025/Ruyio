import Foundation
import RuyioCore

/// Typed host capabilities (plan §10). No arbitrary executable, arguments, scripts or schemes.
public enum CapabilityMethod {
    public static let clipboardWrite = "capability.clipboard.write"
    public static let openWebLink = "capability.open.webLink"
    public static let openTerminalDirectory = "capability.open.terminalDirectory"
    public static let openInConfiguredApplication = "capability.open.configuredApplication"
    public static let fileWrite = "capability.file.write"
    public static let fileReveal = "capability.file.reveal"
    public static let finderToggleHiddenFiles = "capability.finder.toggleHiddenFiles"
    public static let operationReceipt = "capability.operation.receipt"

    /// Permission required for each method.
    public static func permission(for method: String) -> Permission? {
        switch method {
        case clipboardWrite: return .clipboardWrite
        case openWebLink, openTerminalDirectory, openInConfiguredApplication, fileReveal, finderToggleHiddenFiles: return .appsOpen
        case fileWrite: return .filesWrite
        case operationReceipt: return nil
        default: return nil
        }
    }
}

/// One pasteboard representation. Large data is referenced by blob, never Base64'd into UI messages.
public struct PasteboardRepresentation: Codable, Sendable, Hashable {
    public var type: String
    public var text: String?
    public var blobID: String?
    public init(type: String, text: String? = nil, blobID: String? = nil) {
        self.type = type
        self.text = text
        self.blobID = blobID
    }
}

public struct PasteboardItemPayload: Codable, Sendable, Hashable {
    public var representations: [PasteboardRepresentation]
    public init(representations: [PasteboardRepresentation]) { self.representations = representations }
}

public struct ClipboardWriteRequest: Codable, Sendable, Hashable {
    public var items: [PasteboardItemPayload]
    /// Marker the plugin uses to ignore its own write when capturing.
    public var originToken: String
    public init(items: [PasteboardItemPayload], originToken: String) {
        self.items = items
        self.originToken = originToken
    }
}

public struct ClipboardWriteReply: Codable, Sendable, Hashable {
    public var changeCount: Int
    public init(changeCount: Int) { self.changeCount = changeCount }
}

public struct WebLinkRequest: Codable, Sendable, Hashable {
    public var url: String
    public init(url: String) { self.url = url }
}

public struct DirectoryRequest: Codable, Sendable, Hashable {
    public var directories: [FileRef]
    public init(directories: [FileRef]) { self.directories = directories }
}

public struct ConfiguredApplicationRequest: Codable, Sendable, Hashable {
    /// Setting key holding the user's chosen application, e.g. "editor".
    public var role: String
    public var targets: [FileRef]
    public init(role: String, targets: [FileRef]) {
        self.role = role
        self.targets = targets
    }
}

/// What to do when the destination name already exists (PRD §19.19).
public enum ConflictPolicy: String, Codable, Sendable {
    case ask, keepBoth, replace, skip, fail
}

public struct FileWriteItem: Codable, Sendable, Hashable {
    public enum Source: Codable, Sendable, Hashable {
        case text(String)
        case blob(String)
        case copyOf(FileRef)
        case empty

        private enum CodingKeys: String, CodingKey { case type, text, blobID, file }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "text": self = .text(try c.decode(String.self, forKey: .text))
            case "blob": self = .blob(try c.decode(String.self, forKey: .blobID))
            case "copyOf": self = .copyOf(try c.decode(FileRef.self, forKey: .file))
            case "empty": self = .empty
            case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown source \(other)")
            }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let t): try c.encode("text", forKey: .type); try c.encode(t, forKey: .text)
            case .blob(let b): try c.encode("blob", forKey: .type); try c.encode(b, forKey: .blobID)
            case .copyOf(let f): try c.encode("copyOf", forKey: .type); try c.encode(f, forKey: .file)
            case .empty: try c.encode("empty", forKey: .type)
            }
        }
    }

    public var fileName: String
    public var source: Source
    public init(fileName: String, source: Source) {
        self.fileName = fileName
        self.source = source
    }
}

public struct FileWriteRequest: Codable, Sendable, Hashable {
    public var directory: FileRef
    public var items: [FileWriteItem]
    public var conflictPolicy: ConflictPolicy
    public var revealAfterWrite: Bool
    public init(directory: FileRef, items: [FileWriteItem], conflictPolicy: ConflictPolicy = .ask, revealAfterWrite: Bool = true) {
        self.directory = directory
        self.items = items
        self.conflictPolicy = conflictPolicy
        self.revealAfterWrite = revealAfterWrite
    }
}

public struct FileWriteOutcome: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case written, skipped, failed, conflict, cancelled }
    public var requestedName: String
    public var finalPath: String?
    public var status: Status
    public var errorCode: String?
    public init(requestedName: String, finalPath: String?, status: Status, errorCode: String? = nil) {
        self.requestedName = requestedName
        self.finalPath = finalPath
        self.status = status
        self.errorCode = errorCode
    }
}

public struct FileWriteReply: Codable, Sendable, Hashable {
    public var outcomes: [FileWriteOutcome]
    public var dataEffect: DataEffect
    public init(outcomes: [FileWriteOutcome], dataEffect: DataEffect) {
        self.outcomes = outcomes
        self.dataEffect = dataEffect
    }
}

public struct RevealRequest: Codable, Sendable, Hashable {
    public var paths: [String]
    public init(paths: [String]) { self.paths = paths }
}
