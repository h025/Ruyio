import Foundation

/// Stable, cross-version plugin identity (PRD §7.6.5). Reverse-DNS, lowercase.
public struct PluginID: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard PluginID.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// For literals in code and tests; traps on invalid input.
    public init(_ literal: String) {
        guard let value = PluginID(rawValue: literal) else {
            preconditionFailure("Invalid plugin ID: \(literal)")
        }
        self = value
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = PluginID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid plugin ID"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// Identifiers starting with this prefix are reserved for the official signing team (PRD §7.6.5).
    public static let officialPrefix = "app.ruyio."

    public var isOfficialNamespace: Bool { rawValue.hasPrefix(Self.officialPrefix) }

    public static func < (lhs: PluginID, rhs: PluginID) -> Bool { lhs.rawValue < rhs.rawValue }

    static func isValid(_ value: String) -> Bool {
        guard (3...128).contains(value.count) else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard !label.isEmpty, label.first != "-", label.last != "-" else { return false }
            for scalar in label.unicodeScalars {
                switch scalar {
                case "a"..."z", "0"..."9", "-": continue
                default: return false
                }
            }
        }
        return true
    }
}

/// Action identifier, unique within one plugin (PRD §10.3).
public struct ActionID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard (1...64).contains(rawValue.count),
              rawValue.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }),
              rawValue.first != "-"
        else { return nil }
        self.rawValue = rawValue
    }

    public init(_ literal: String) {
        guard let value = ActionID(rawValue: literal) else { preconditionFailure("Invalid action ID: \(literal)") }
        self = value
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = ActionID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid action ID"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Fully qualified action reference across plugins.
public struct ActionRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public var pluginID: PluginID
    public var actionID: ActionID

    public init(pluginID: PluginID, actionID: ActionID) {
        self.pluginID = pluginID
        self.actionID = actionID
    }

    public var description: String { "\(pluginID)/\(actionID)" }
}

/// One invocation of an Action (PRD §20.3). Retries get a new execution ID.
public struct ExecutionID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { rawValue = UUID().uuidString.lowercased() }
    public var description: String { rawValue }
}

/// Stable identity of one side effect; IPC re-sends and receipt queries reuse it (plan §13.3).
public struct OperationID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { rawValue = UUID().uuidString.lowercased() }
    public var description: String { rawValue }
}
