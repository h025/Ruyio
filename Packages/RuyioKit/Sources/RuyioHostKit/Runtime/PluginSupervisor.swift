import Foundation
import RuyioCore
import RuyioProtocol

/// Where an installed plugin's code lives and how to run it.
public struct PluginLaunchSpec: Sendable, Hashable {
    public var manifest: PluginManifest
    public var executable: URL
    public var isDevelopment: Bool
    public var dataGeneration: Int
    public var isBackground: Bool

    public init(manifest: PluginManifest, executable: URL, isDevelopment: Bool, dataGeneration: Int = 1, isBackground: Bool) {
        self.manifest = manifest
        self.executable = executable
        self.isDevelopment = isDevelopment
        self.dataGeneration = dataGeneration
        self.isBackground = isBackground
    }
}

/// Owns plugin processes: on-demand start, leases, idle exit, crash reporting (plan §6.2, §8.1).
/// Never restarts a crashed plugin in a loop.
public actor PluginSupervisor {
    public typealias CrashHandler = @Sendable (PluginID, RuyioError) -> Void
    public typealias ProcessStateHandler = @Sendable (PluginID, ProcessState) -> Void

    public static let idleTimeout: Duration = .seconds(30)

    private let services: PluginServiceHandler
    private var sessions: [PluginID: PluginSession] = [:]
    private var starting: [PluginID: Task<PluginSession, Error>] = [:]
    private var specs: [PluginID: PluginLaunchSpec] = [:]
    private var leases: [PluginID: Int] = [:]
    private var crashHandler: CrashHandler?
    private var stateHandler: ProcessStateHandler?
    private var locale: String
    private var idleTask: Task<Void, Never>?

    public init(services: PluginServiceHandler, locale: String) {
        self.services = services
        self.locale = locale
    }

    public func setHandlers(crash: @escaping CrashHandler, state: @escaping ProcessStateHandler) {
        crashHandler = crash
        stateHandler = state
    }

    public func register(_ spec: PluginLaunchSpec) {
        specs[spec.manifest.id] = spec
    }

    public func unregister(_ id: PluginID) async {
        specs[id] = nil
        await stop(id)
    }

    public func isRunning(_ id: PluginID) -> Bool { sessions[id]?.isAlive == true }

    public func runningPluginIDs() -> [PluginID] { sessions.filter { $0.value.isAlive }.map(\.key) }

    public func session(for id: PluginID) -> PluginSession? { sessions[id] }

    /// Returns a live session, starting the process if needed. Concurrent callers share one start.
    public func ensureRunning(_ id: PluginID, mode: RuntimeMode = .normal) async throws -> PluginSession {
        if let session = sessions[id], session.isAlive { return session }
        if let task = starting[id] { return try await task.value }
        guard let spec = specs[id] else { throw RuyioError(.pluginNotFound, objectID: id.rawValue) }

        stateHandler?(id, .starting)
        let info = SessionInfo(pluginID: id, manifest: spec.manifest, runtimeMode: mode,
                               dataGeneration: spec.dataGeneration, isDevelopment: spec.isDevelopment)
        let session = PluginSession(info: info, executable: spec.executable, services: services)
        let locale = self.locale
        let task = Task { try await session.start(locale: locale); return session }
        starting[id] = task
        do {
            let started = try await task.value
            starting[id] = nil
            sessions[id] = started
            started.onTermination { [weak self] error in
                Task { await self?.sessionEnded(id, session: started, error: error) }
            }
            stateHandler?(id, .running)
            scheduleIdleCheck()
            return started
        } catch {
            starting[id] = nil
            stateHandler?(id, .failed)
            throw error
        }
    }

    /// Keeps the plugin alive while `body` runs (an open panel or a running action holds a lease).
    public func withLease<T: Sendable>(_ id: PluginID, _ body: @Sendable (PluginSession) async throws -> T) async throws -> T {
        let session = try await ensureRunning(id)
        leases[id, default: 0] += 1
        defer { Task { await self.release(id) } }
        return try await body(session)
    }

    public func acquireLease(_ id: PluginID) async throws -> PluginSession {
        let session = try await ensureRunning(id)
        leases[id, default: 0] += 1
        return session
    }

    public func release(_ id: PluginID) {
        leases[id] = max(0, (leases[id] ?? 0) - 1)
        scheduleIdleCheck()
    }

    public func stop(_ id: PluginID) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        leases[id] = nil
        stateHandler?(id, .stopping)
        await session.stop()
        stateHandler?(id, .stopped)
    }

    public func stopAll() async {
        for id in Array(sessions.keys) { await stop(id) }
    }

    public func updateLocale(_ locale: String) {
        self.locale = locale
        for session in sessions.values where session.isAlive { session.sendLocale(locale) }
    }

    // MARK: Internals

    private func sessionEnded(_ id: PluginID, session: PluginSession, error: RuyioError?) {
        guard sessions[id] === session else { return }
        sessions[id] = nil
        leases[id] = nil
        if let error {
            stateHandler?(id, .failed)
            crashHandler?(id, error)
        } else {
            stateHandler?(id, .stopped)
        }
    }

    private func scheduleIdleCheck() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.reapIdle()
        }
    }

    private func reapIdle() async {
        let now = ContinuousClock.now
        var anyAlive = false
        for (id, session) in sessions {
            guard let spec = specs[id] else { continue }
            if spec.isBackground || (leases[id] ?? 0) > 0 { anyAlive = true; continue }
            if now - session.lastActivity >= Self.idleTimeout {
                await stop(id)
            } else {
                anyAlive = true
            }
        }
        if anyAlive { scheduleIdleCheck() }
    }
}
