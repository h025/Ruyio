import Foundation

/// Machine-readable error codes. UI copy is localized by the host from the code, never from plugin text.
public struct ErrorCode: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    public static let pluginNotFound: ErrorCode = "plugin.notFound"
    public static let pluginAlreadyInstalled: ErrorCode = "plugin.alreadyInstalled"
    public static let pluginNotInvocable: ErrorCode = "plugin.notInvocable"
    public static let pluginLaunchFailed: ErrorCode = "plugin.launchFailed"
    public static let handshakeFailed: ErrorCode = "plugin.handshakeFailed"
    public static let handshakeTimeout: ErrorCode = "plugin.handshakeTimeout"
    public static let incompatibleProtocol: ErrorCode = "plugin.incompatibleProtocol"
    public static let pluginCrashed: ErrorCode = "plugin.crashed"
    public static let requestTimeout: ErrorCode = "plugin.requestTimeout"
    public static let actionNotFound: ErrorCode = "action.notFound"
    public static let actionFailed: ErrorCode = "action.failed"
    public static let contextExpired: ErrorCode = "action.contextExpired"
    public static let cancelled: ErrorCode = "action.cancelled"
    public static let permissionDenied: ErrorCode = "permission.denied"
    public static let permissionNotDeclared: ErrorCode = "permission.notDeclared"
    public static let invalidRequest: ErrorCode = "protocol.invalidRequest"
    public static let frameTooLarge: ErrorCode = "protocol.frameTooLarge"
    public static let storageQuotaExceeded: ErrorCode = "storage.quotaExceeded"
    public static let storageFailure: ErrorCode = "storage.failure"
    public static let retainedDataIncompatible: ErrorCode = "storage.retainedDataIncompatible"
    public static let fileConflict: ErrorCode = "file.conflict"
    public static let fileWriteFailed: ErrorCode = "file.writeFailed"
    public static let fileNameInvalid: ErrorCode = "file.nameInvalid"
    public static let fileAccessDenied: ErrorCode = "file.accessDenied"
    public static let outcomeUnknown: ErrorCode = "operation.outcomeUnknown"
    public static let manifestInvalid: ErrorCode = "manifest.invalid"
    public static let sourceInvalid: ErrorCode = "source.invalid"
    public static let networkPolicy: ErrorCode = "source.networkPolicy"
    public static let networkFailure: ErrorCode = "source.networkFailure"
    public static let rateLimited: ErrorCode = "source.rateLimited"
    public static let hotkeyConflict: ErrorCode = "hotkey.conflict"
    public static let hotkeyUnavailable: ErrorCode = "hotkey.unavailable"
    public static let internalError: ErrorCode = "internal"
}

/// Suggested next step the host can offer (PRD §18.2: errors carry object, cause, data effect, next step).
public enum RecoveryAction: String, Codable, Sendable {
    case retry
    case openPluginDetail
    case openSystemSettings
    case openPermissions
    case chooseApplication
    case rename
    case revealInFinder
    case reenable
    case none
}

public struct RuyioError: Error, Codable, Sendable, Hashable, CustomStringConvertible {
    public var code: ErrorCode
    public var objectID: String?
    public var executionID: ExecutionID?
    public var retryable: Bool
    public var dataEffect: DataEffect
    public var recovery: RecoveryAction
    /// Diagnostic only. Never shown as primary UI copy; never contains clipboard or file content.
    public var diagnostic: String?

    public init(
        _ code: ErrorCode,
        objectID: String? = nil,
        executionID: ExecutionID? = nil,
        retryable: Bool = false,
        dataEffect: DataEffect = .unmodified,
        recovery: RecoveryAction = .none,
        diagnostic: String? = nil
    ) {
        self.code = code
        self.objectID = objectID
        self.executionID = executionID
        self.retryable = retryable
        self.dataEffect = dataEffect
        self.recovery = recovery
        self.diagnostic = diagnostic.map { String($0.prefix(512)) }
    }

    public var description: String {
        var parts = [code.rawValue]
        if let objectID { parts.append("object=\(objectID)") }
        if let diagnostic { parts.append(diagnostic) }
        return parts.joined(separator: " ")
    }
}
