import Darwin
import Foundation
import Testing
@testable import RuyioHostKit
import RuyioProtocol
import RuyioCore

/// In-memory service handler standing in for the real host brokers.
final class FakeServices: PluginServiceHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [String: StoredDocument] = [:]
    private(set) var events: [String] = []

    func handleRequest(_ envelope: Envelope, session: SessionInfo) async throws -> JSONValue {
        if envelope.method.hasPrefix(Method.capabilityPrefix) {
            guard let permission = CapabilityMethod.permission(for: envelope.method), session.declares(permission) else {
                throw RuyioError(.permissionNotDeclared, objectID: envelope.method)
            }
            return .bool(true)
        }
        switch envelope.method {
        case StorageMethod.put:
            let doc = try JSONCoding.decode(StoredDocument.self, from: envelope.payload)
            lock.withLock { documents["\(doc.collection)/\(doc.id)"] = doc }
            return .null
        case StorageMethod.get:
            let key = try JSONCoding.decode(StorageKey.self, from: envelope.payload)
            guard let doc = lock.withLock({ documents["\(key.collection)/\(key.id)"] }) else { return .null }
            return try JSONCoding.value(doc)
        default:
            throw RuyioError(.invalidRequest)
        }
    }

    func handleEvent(_ envelope: Envelope, session: SessionInfo) {
        lock.withLock { events.append(envelope.method) }
    }
}

enum Fixture {
    static var testPluginExecutable: URL {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return packageRoot.appendingPathComponent(".build/debug/RuyioTestPlugin")
    }

    static let pluginID = PluginID("org.ruyio.test-plugin")

    static func manifest() -> PluginManifest {
        PluginManifest(
            id: pluginID, name: "Test Plugin", version: SemanticVersion("1.0.0")!,
            bundlePath: "Test.app", executable: "Test.app/Contents/MacOS/RuyioTestPlugin", permissions: [.clipboardWrite]
        )
    }

    static func session(_ services: FakeServices, manifest: PluginManifest = manifest()) -> PluginSession {
        let info = SessionInfo(pluginID: manifest.id, manifest: manifest, runtimeMode: .normal, dataGeneration: 1, isDevelopment: true)
        return PluginSession(info: info, executable: testPluginExecutable, services: services)
    }

    static func invocation(_ action: String, _ params: [String: JSONValue] = [:]) -> ActionInvocation {
        ActionInvocation(actionID: ActionID(action), entry: .commandPalette, parameters: params, locale: "zh-Hans")
    }

    static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }
}

@Suite(.serialized)
struct PluginProcessTests {
    @Test func handshakeAndInvoke() async throws {
        let services = FakeServices()
        let session = Fixture.session(services)
        try await session.start(locale: "zh-Hans", firstLaunch: true)
        let result = try await session.invoke(Fixture.invocation("echo", ["text": "hi"]), execution: ExecutionID(), operation: nil, registryGeneration: 1)
        #expect(result.state == .succeeded)
        #expect(result.output == .notice("echo:hi:zh-Hans"))
        await session.stop()
        #expect(!session.isAlive)
    }

    @Test func handshakeRejectsMismatchedIdentity() async throws {
        let services = FakeServices()
        var manifest = Fixture.manifest()
        manifest.id = PluginID("org.ruyio.someone-else")
        let session = Fixture.session(services, manifest: manifest)
        await #expect(throws: RuyioError.self) { try await session.start(locale: "en", firstLaunch: true) }
        #expect(!session.isAlive)
    }

    @Test func handshakeRejectsVersionMismatch() async throws {
        let services = FakeServices()
        var manifest = Fixture.manifest()
        manifest.version = SemanticVersion("2.0.0")!
        let session = Fixture.session(services, manifest: manifest)
        await #expect(throws: RuyioError.self) { try await session.start(locale: "en", firstLaunch: true) }
    }

    @Test func crashIsIsolatedAndReported() async throws {
        let services = FakeServices()
        let session = Fixture.session(services)
        let reported = LockedBox<RuyioError?>(nil)
        session.onTermination { reported.value = $0 }
        try await session.start(locale: "en", firstLaunch: true)
        await #expect(throws: RuyioError.self) {
            _ = try await session.invoke(Fixture.invocation("crash"), execution: ExecutionID(), operation: nil, registryGeneration: 1)
        }
        #expect(await Fixture.waitUntil { reported.value != nil })
        #expect(reported.value?.code == .pluginCrashed)
        #expect(!session.isAlive)
    }

    @Test func pluginExitsWhenHostClosesChannelEvenIfMainThreadBlocked() async throws {
        let services = FakeServices()
        let session = Fixture.session(services)
        try await session.start(locale: "en", firstLaunch: true)
        _ = try await session.invoke(Fixture.invocation("block-main"), execution: ExecutionID(), operation: nil, registryGeneration: 1)
        let pid = try #require(session.pid)
        #expect(Fixture.isAlive(pid))
        // Simulate host death: close only the pipes, do not signal the process.
        await session.closeChannelForTesting()
        #expect(await Fixture.waitUntil { !Fixture.isAlive(pid) })
    }

    @Test func storageRoundTripThroughHost() async throws {
        let services = FakeServices()
        let session = Fixture.session(services)
        try await session.start(locale: "en", firstLaunch: true)
        let result = try await session.invoke(Fixture.invocation("storage"), execution: ExecutionID(), operation: nil, registryGeneration: 1)
        #expect(result.output == .notice("中文内容"))
        await session.stop()
    }

    @Test func undeclaredCapabilityIsRejected() async throws {
        let services = FakeServices()
        let session = Fixture.session(services)
        try await session.start(locale: "en", firstLaunch: true)
        let result = try await session.invoke(Fixture.invocation("undeclared-capability"), execution: ExecutionID(), operation: nil, registryGeneration: 1)
        #expect(result.state == .failed)
        #expect(result.error?.code == .permissionNotDeclared)
        await session.stop()
    }

    @Test func cancelStopsLongAction() async throws {
        let services = FakeServices()
        let session = Fixture.session(services)
        try await session.start(locale: "en", firstLaunch: true)
        let execution = ExecutionID()
        async let result = session.invoke(Fixture.invocation("slow"), execution: execution, operation: nil, registryGeneration: 1, timeout: .seconds(20))
        try await Task.sleep(for: .milliseconds(200))
        session.cancel(execution)
        let value = try await result
        #expect(value.state == .cancelled)
        await session.stop()
    }

    @Test func supervisorStartsOnDemandAndStops() async throws {
        let services = FakeServices()
        let supervisor = PluginSupervisor(services: services, locale: "en")
        await supervisor.register(PluginLaunchSpec(manifest: Fixture.manifest(), executable: Fixture.testPluginExecutable, isDevelopment: true, isBackground: false))
        #expect(await supervisor.isRunning(Fixture.pluginID) == false)
        let session = try await supervisor.ensureRunning(Fixture.pluginID)
        let again = try await supervisor.ensureRunning(Fixture.pluginID)
        #expect(session === again)
        await supervisor.stop(Fixture.pluginID)
        #expect(await supervisor.isRunning(Fixture.pluginID) == false)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
