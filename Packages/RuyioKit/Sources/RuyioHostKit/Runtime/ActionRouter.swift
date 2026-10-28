import Foundation
import RuyioCore
import RuyioPersistence
import RuyioProtocol

/// Files the user pointed at in Finder, frozen at click time (PRD §19.17).
public struct FinderTargets: Sendable, Hashable {
    public var targetDirectory: URL?
    public var selection: [URL]
    public var dynamicItemID: String?
    /// Right-click location on the folder's background, screen coordinates.
    public var clickLocation: CGPoint?
    public init(targetDirectory: URL?, selection: [URL], dynamicItemID: String? = nil, clickLocation: CGPoint? = nil) {
        self.targetDirectory = targetDirectory
        self.selection = selection
        self.dynamicItemID = dynamicItemID
        self.clickLocation = clickLocation
    }
}

public struct InvocationRequest: Sendable {
    public var ref: ActionRef
    public var entry: PresentationKind?
    public var parameters: [String: JSONValue]
    public var finder: FinderTargets?
    public var viewID: String?
    public var itemID: String?
    public init(ref: ActionRef, entry: PresentationKind?, parameters: [String: JSONValue] = [:], finder: FinderTargets? = nil,
                viewID: String? = nil, itemID: String? = nil) {
        self.ref = ref
        self.entry = entry
        self.parameters = parameters
        self.finder = finder
        self.viewID = viewID
        self.itemID = itemID
    }
}

public struct ExecutionReport: Sendable, Hashable {
    public var executionID: ExecutionID
    public var operationID: OperationID?
    public var ref: ActionRef
    public var state: ExecutionState
    public var output: ActionOutput
    public var error: RuyioError?
}

/// Every entry (palette, hotkey, menu bar, Finder) goes through here: same validation, same state and
/// error model, unique execution IDs, stable operation IDs for side effects (PRD §20.3, plan §6.2).
public actor ActionRouter {
    private let registry: PluginRegistry
    private let supervisor: PluginSupervisor
    private let database: HostDatabase
    private let contexts: InvocationContexts
    private var locale: String
    private var running: [ExecutionID: (ActionRef, PluginSession?)] = [:]
    private var gates: [String: Int] = [:]
    private var gateWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var progressHandler: (@Sendable (ExecutionID, ActionProgress) -> Void)?

    public static let defaultTimeout: Duration = .seconds(10)
    public static let sideEffectTimeout: Duration = .seconds(120)

    public init(registry: PluginRegistry, supervisor: PluginSupervisor, database: HostDatabase, contexts: InvocationContexts, locale: String) {
        self.registry = registry
        self.supervisor = supervisor
        self.database = database
        self.contexts = contexts
        self.locale = locale
    }

    public func setLocale(_ locale: String) { self.locale = locale }

    public func setProgressHandler(_ handler: @escaping @Sendable (ExecutionID, ActionProgress) -> Void) {
        progressHandler = handler
    }

    public func reportProgress(_ execution: ExecutionID, _ progress: ActionProgress) {
        progressHandler?(execution, progress)
    }

    public func invoke(_ request: InvocationRequest, execution: ExecutionID = ExecutionID()) async -> ExecutionReport {
        let ref = request.ref
        func report(_ state: ExecutionState, _ output: ActionOutput = .none, _ error: RuyioError? = nil, op: OperationID? = nil) -> ExecutionReport {
            ExecutionReport(executionID: execution, operationID: op, ref: ref, state: state, output: output, error: error)
        }

        // validating: plugin state, entry visibility, action existence. No user data is touched.
        guard await registry.isInvocable(ref), let manifest = await registry.manifest(ref.pluginID),
              let action = manifest.action(ref.actionID) else {
            return report(.failed, .none, RuyioError(.pluginNotInvocable, objectID: ref.description, recovery: .openPluginDetail))
        }
        if let entry = request.entry, !(await registry.isEntryVisible(ref, kind: entry)) {
            return report(.failed, .none, RuyioError(.actionNotFound, objectID: ref.description))
        }

        let operation: OperationID? = action.hasSideEffects ? OperationID() : nil
        var finderContext: FinderInvocationContext?
        if let finder = request.finder {
            finderContext = FinderInvocationContext(
                targetDirectory: finder.targetDirectory.map {
                    contexts.issue($0, for: ref.pluginID, execution: execution, placement: finder.clickLocation)
                },
                selection: finder.selection.prefix(10_000).map { contexts.issue($0, for: ref.pluginID, execution: execution) },
                dynamicItemID: finder.dynamicItemID)
        }
        let invocation = ActionInvocation(actionID: ref.actionID, entry: request.entry, parameters: request.parameters, finder: finderContext,
                                          viewID: request.viewID, itemID: request.itemID, contextRef: execution.rawValue, locale: locale)
        let gateKey = "\(ref.pluginID)/\(action.concurrencyGroup ?? (action.hasSideEffects ? "mutating" : execution.rawValue))"
        await acquireGate(gateKey)
        defer { releaseGate(gateKey) }

        let generation = await registry.generation
        // A queued action may outlive a disable. An unresolved earlier outcome does not block it: the UI offers
        // no one-click retry, and a new operation the user starts explicitly is allowed (PRD §19.15, §20).
        guard await registry.isInvocable(ref) else {
            contexts.revokeAll(for: execution)
            return report(.failed, .none, RuyioError(.pluginNotInvocable, objectID: ref.description))
        }
        let timeout = action.hasSideEffects ? Self.sideEffectTimeout : Self.defaultTimeout
        running[execution] = (ref, nil)
        contexts.begin(execution, for: ref.pluginID)
        defer {
            running[execution] = nil
            contexts.revokeAll(for: execution)
        }
        do {
            let session = try await supervisor.acquireLease(ref.pluginID)
            running[execution] = (ref, session)
            defer { Task { await supervisor.release(session) } }
            let result = try await session.invoke(invocation, execution: execution, operation: operation, registryGeneration: generation, timeout: timeout)
            if result.state == .succeeded { try? database.recordUsage(ref) }
            return report(result.state, result.output, result.error, op: operation)
        } catch let error as RuyioError {
            if error.code == .requestTimeout { running[execution]?.1?.cancel(execution) }
            // A side effect may have happened if an operation was recorded but never completed.
            if let operation, let record = try? database.operation(operation), record.phase != .completed {
                var unknown = record
                unknown.phase = .unknown
                try? database.saveOperation(unknown)
                let pending = (try? database.unresolvedOperations(pluginID: ref.pluginID).count) ?? 1
                await registry.setPendingOutcomes(ref.pluginID, count: pending)
                return report(.outcomeUnknown, .none, RuyioError(.outcomeUnknown, objectID: ref.description, executionID: execution,
                                                               dataEffect: .unknown, recovery: .revealInFinder), op: operation)
            }
            var failure = error
            failure.executionID = execution
            return report(.failed, .none, failure, op: operation)
        } catch {
            return report(.failed, .none, RuyioError(.internalError, executionID: execution, diagnostic: String(describing: error)), op: operation)
        }
    }

    public func cancel(_ execution: ExecutionID) {
        running[execution]?.1?.cancel(execution)
    }

    // MARK: Concurrency groups

    private func acquireGate(_ key: String) async {
        if gates[key, default: 0] == 0 {
            gates[key] = 1
            return
        }
        await withCheckedContinuation { continuation in
            gateWaiters[key, default: []].append(continuation)
        }
    }

    private func releaseGate(_ key: String) {
        if var waiters = gateWaiters[key], !waiters.isEmpty {
            let next = waiters.removeFirst()
            gateWaiters[key] = waiters.isEmpty ? nil : waiters
            next.resume()
        } else {
            gates[key] = nil
            gateWaiters[key] = nil
        }
    }
}
