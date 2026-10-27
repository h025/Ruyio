import Foundation

/// PRD §20.1 — four orthogonal dimensions. Never collapse them into one enum.
public enum InstallationState: String, Codable, Sendable, CaseIterable {
    case notInstalled, installing, installed, uninstalling, installFailed, incompatible
}

public enum ActivationState: String, Codable, Sendable, CaseIterable {
    case disabled, enabling, needsPermission, enabled, disabling, runtimeFailed
}

public enum UpdateState: String, Codable, Sendable, CaseIterable {
    case none, checking, available, updating, updateFailed
}

public enum SourceState: String, Codable, Sendable, CaseIterable {
    case linked, disabled, orphaned, conflicted
}

/// Process lifecycle is kept separately; "enabled" does not mean a resident process (plan §6.1).
public enum ProcessState: String, Codable, Sendable, CaseIterable {
    case stopped, starting, running, stopping, failed
}

/// What kind of update channel a plugin has (PRD §19.7).
public enum UpdateChannel: String, Codable, Sendable {
    case market
    case descriptor
    case none
    case bundledWithHost
    case development
}

public enum PluginListGroup: String, Codable, Sendable {
    case enabled, disabled, restorableDefault
}

/// Badges a row can show; at most one primary badge per row (interaction §16.4).
public enum PluginBadge: String, Codable, Sendable, CaseIterable {
    case runtimeFailed, identityConflict, incompatible, needsPermission, outcomePending
    case updateAvailable, sourceRemoved, noUpdateSource, developer
}

public struct PluginStatus: Codable, Sendable, Hashable {
    public var installation: InstallationState
    public var activation: ActivationState
    public var update: UpdateState
    public var source: SourceState
    public var updateChannel: UpdateChannel
    public var isDevelopment: Bool
    public var isRestorableDefault: Bool
    public var lastErrorCode: String?
    public var pendingOutcomeCount: Int

    public init(
        installation: InstallationState = .installed,
        activation: ActivationState = .disabled,
        update: UpdateState = .none,
        source: SourceState = .linked,
        updateChannel: UpdateChannel = .none,
        isDevelopment: Bool = false,
        isRestorableDefault: Bool = false,
        lastErrorCode: String? = nil,
        pendingOutcomeCount: Int = 0
    ) {
        self.installation = installation
        self.activation = activation
        self.update = update
        self.source = source
        self.updateChannel = updateChannel
        self.isDevelopment = isDevelopment
        self.isRestorableDefault = isRestorableDefault
        self.lastErrorCode = lastErrorCode
        self.pendingOutcomeCount = pendingOutcomeCount
    }

    /// PRD §20.1: derived flag, not a new enum value.
    public var needsAttention: Bool {
        activation == .needsPermission
            || activation == .runtimeFailed
            || installation == .incompatible
            || source == .conflicted
            || (activation == .disabled && lastErrorCode != nil)
            || pendingOutcomeCount > 0
    }

    public var listGroup: PluginListGroup {
        if isRestorableDefault && installation == .notInstalled { return .restorableDefault }
        switch activation {
        case .enabled, .needsPermission, .runtimeFailed, .enabling: return .enabled
        case .disabled, .disabling: return .disabled
        }
    }

    /// Priority order from PRD §20.1.
    public var badges: [PluginBadge] {
        var result: [PluginBadge] = []
        if activation == .runtimeFailed { result.append(.runtimeFailed) }
        if source == .conflicted { result.append(.identityConflict) }
        if installation == .incompatible { result.append(.incompatible) }
        if activation == .needsPermission { result.append(.needsPermission) }
        if pendingOutcomeCount > 0 { result.append(.outcomePending) }
        if update == .available { result.append(.updateAvailable) }
        if source == .orphaned { result.append(.sourceRemoved) }
        if updateChannel == .none && !isDevelopment { result.append(.noUpdateSource) }
        if isDevelopment { result.append(.developer) }
        return result
    }

    public var primaryBadge: PluginBadge? { badges.first }

    /// Whether entries may be registered and actions invoked.
    public var isInvocable: Bool {
        installation == .installed && (activation == .enabled || activation == .needsPermission)
    }
}
