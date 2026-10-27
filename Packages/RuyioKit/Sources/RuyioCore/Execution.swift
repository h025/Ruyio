import Foundation

/// PRD §20.3 Action execution state machine.
public enum ExecutionState: String, Codable, Sendable, CaseIterable {
    case requested, validating, awaitingInput, running, succeeded, failed, cancelled, outcomeUnknown

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .outcomeUnknown: return true
        default: return false
        }
    }

    public func canTransition(to next: ExecutionState) -> Bool {
        switch (self, next) {
        case (.requested, .validating), (.requested, .cancelled): return true
        case (.validating, .awaitingInput), (.validating, .running), (.validating, .failed), (.validating, .cancelled): return true
        case (.awaitingInput, .running), (.awaitingInput, .cancelled), (.awaitingInput, .failed): return true
        case (.running, .succeeded), (.running, .failed), (.running, .cancelled), (.running, .outcomeUnknown): return true
        default: return false
        }
    }
}

/// What happened to user data when an execution did not succeed (plan §6.2).
public enum DataEffect: String, Codable, Sendable {
    case unmodified
    case partial
    case rolledBack
    case unknown
}

/// How the command palette behaves after an action completes (PRD §19.2).
public enum CompletionBehavior: String, Codable, Sendable {
    case closePanel
    case keepPanel
    case showResult
}
