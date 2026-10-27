import Foundation

/// Manifest permission identifiers (PRD §10.2 table). Unknown identifiers are rejected.
public enum Permission: String, Codable, Sendable, CaseIterable, Comparable {
    case clipboardRead = "clipboard.read"
    case clipboardWrite = "clipboard.write"
    case filesReadSelected = "files.read.selected"
    case filesWrite = "files.write"
    case appsOpen = "apps.open"
    case pasteAutomatic = "paste.automatic"
    case background = "background"
    case networkClient = "network.client"

    public var enforcement: EnforcementLevel {
        switch self {
        case .clipboardRead: return .declaredAudited
        case .clipboardWrite, .filesReadSelected, .filesWrite, .appsOpen, .pasteAutomatic: return .hostMediated
        case .background: return .hostLifecycle
        case .networkClient: return .systemEnforced
        }
    }

    /// Entitlement that must be present in the plugin signature when declared.
    public var requiredEntitlement: String? {
        switch self {
        case .networkClient: return "com.apple.security.network.client"
        default: return nil
        }
    }

    public static func < (lhs: Permission, rhs: Permission) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// PRD §3.5 enforcement levels.
public enum EnforcementLevel: String, Codable, Sendable {
    case systemEnforced
    case hostMediated
    case declaredAudited
    case hostLifecycle
}

/// Real capture state, kept apart from the user's recording preference (plan §12.1.1).
public enum CaptureState: String, Codable, Sendable, CaseIterable {
    case recording
    case userPaused
    case blockedBySystem
    case suspended
    case failed
    /// Only on systems without NSPasteboard.accessBehavior.
    case unknown
}
