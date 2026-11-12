import Darwin
import Foundation
import Testing
@testable import RuyioHostKit

@Suite(.serialized)
struct ProcessTerminationTests {
    /// Each fixture is a native executable reached through a symlink; it never opens a real plugin store.
    static func withProcess<T: Sendable>(_ mode: String,
                                        _ body: @Sendable (PluginProcess, pid_t) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ruyio-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("RuyioProcessFixture-\(mode)")
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: Fixture.testPluginExecutable)
        let process = try PluginProcess.spawn(executable: executable)
        defer {
            process.signal(SIGKILL)
            close(process.readFD)
            close(process.writeFD)
        }
        var child: pid_t = 0
        if mode != "exit" {
            let flags = fcntl(process.readFD, F_GETFL)
            _ = fcntl(process.readFD, F_SETFL, flags | O_NONBLOCK)
            var response = Data()
            let ready = await Fixture.waitUntil {
                var bytes = [UInt8](repeating: 0, count: 128)
                let count = read(process.readFD, &bytes, bytes.count)
                if count > 0 { response.append(contentsOf: bytes.prefix(count)) }
                return response.contains(10) || process.hasExited
            }
            let line = String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(ready && line.hasPrefix("ready:"), "fixture did not become ready: \(line)")
            child = try #require(pid_t(line.dropFirst("ready:".count)))
        }
        return try await body(process, child)
    }

    static func exitStatus(_ process: PluginProcess) async -> Int32 {
        await withCheckedContinuation { continuation in
            process.onExit { continuation.resume(returning: $0) }
        }
    }

    @Test func cooperativeExitReturnsBeforeTheGraceDeadline() async throws {
        try await Self.withProcess("graceful") { process, _ in
            let start = ContinuousClock.now
            await process.terminate(grace: .seconds(30))
            #expect(start.duration(to: .now) < .seconds(5))
            #expect(process.hasExited)
            #expect(await Self.exitStatus(process) & 0x7f == SIGTERM)
        }
    }

    @Test func anUncooperativeProcessAndItsDescendantAreKilledAndReaped() async throws {
        try await Self.withProcess("ignore-term-child") { process, child in
            try #require(child > 0 && Fixture.isAlive(child))
            await process.terminate(grace: .milliseconds(100))
            #expect(process.hasExited)
            #expect(await Self.exitStatus(process) & 0x7f == SIGKILL)
            #expect(await Fixture.waitUntil { !Fixture.isAlive(child) })
        }
    }

    @Test func cancellationBeforeOrDuringTerminationStillWaitsForCleanup() async throws {
        for cancelledBefore in [true, false] {
            try await Self.withProcess("ignore-term") { process, _ in
                let began = LockedBox(false)
                let task = Task {
                    if cancelledBefore { withUnsafeCurrentTask { $0?.cancel() } }
                    began.value = true
                    await process.terminate(grace: .milliseconds(150))
                    return process.hasExited
                }
                #expect(await Fixture.waitUntil { began.value })
                task.cancel()
                #expect(await task.value)
                #expect(await Self.exitStatus(process) & 0x7f == SIGKILL)
            }
        }
    }

    @Test func concurrentCancelledTerminatorsAllObserveTheSameExit() async throws {
        try await Self.withProcess("ignore-term") { process, _ in
            let completed = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        await process.terminate(grace: .milliseconds(100))
                        return process.hasExited
                    }
                }
                group.cancelAll()
                var completed = 0
                for await exited in group where exited { completed += 1 }
                return completed
            }
            #expect(completed == 4)
            #expect(await Self.exitStatus(process) & 0x7f == SIGKILL)
        }
    }

    @Test func zeroOrNegativeGraceStillWaitsUntilTheProcessIsReaped() async throws {
        for grace in [Duration.zero, .milliseconds(-10)] {
            try await Self.withProcess("ignore-term") { process, _ in
                await process.terminate(grace: grace)
                #expect(process.hasExited)
                #expect(await Self.exitStatus(process) & 0x7f == SIGKILL)
            }
        }
    }

    @Test func anAlreadyExitedProcessKeepsItsStatusAndNotifiesLateObservers() async throws {
        try await Self.withProcess("exit") { process, _ in
            let status = await Self.exitStatus(process)
            #expect(status == 23 << 8)
            await process.terminate(grace: .seconds(30))
            #expect(await Self.exitStatus(process) == status)
            #expect(await Self.exitStatus(process) == status)
        }
    }

    @Test func earlyExitDoesNotRetainTheProcessUntilItsEscalationDeadline() async throws {
        let reference = WeakProcessReference()
        try await Self.withProcess("graceful") { process, _ in
            reference.value = process
            await process.terminate(grace: .seconds(30))
        }
        #expect(await Fixture.waitUntil { reference.value == nil })
    }
}

private final class WeakProcessReference: @unchecked Sendable {
    weak var value: PluginProcess?
}
