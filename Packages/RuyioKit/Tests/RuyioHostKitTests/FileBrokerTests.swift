import Foundation
import Testing
@testable import RuyioHostKit
import RuyioPersistence
import RuyioProtocol
import RuyioCore

final class ScriptedConflicts: FileBrokerDelegate, @unchecked Sendable {
    var answers: [ConflictResolution]
    var asked: [String] = []
    init(_ answers: [ConflictResolution]) { self.answers = answers }
    func resolveConflict(_ info: ConflictInfo) async -> ConflictResolution {
        asked.append(info.fileName)
        return answers.isEmpty ? ConflictResolution(.cancel) : answers.removeFirst()
    }
}

struct FileBrokerTests {
    let plugin = PluginID("app.ruyio.finder-essentials")

    func setup() throws -> (FileBroker, InvocationContexts, URL, HostDatabase) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try HostDatabase()
        let contexts = InvocationContexts()
        let broker = FileBroker(database: db, contexts: contexts) { _, _ in Data("blob".utf8) }
        return (broker, contexts, dir, db)
    }

    @Test func createsFileAtomicallyAndNeverOverwritesByDefault() async throws {
        let (broker, contexts, dir, _) = try setup()
        let ref = contexts.issue(dir, for: plugin, execution: ExecutionID())
        let reply = try await broker.write(FileWriteRequest(directory: ref, items: [FileWriteItem(fileName: "Untitled.txt", source: .text("hi"))], conflictPolicy: .fail),
                                           pluginID: plugin, operationID: OperationID(), executionID: nil)
        #expect(reply.outcomes.first?.status == .written)
        #expect(try String(contentsOf: dir.appendingPathComponent("Untitled.txt"), encoding: .utf8) == "hi")
        let again = try await broker.write(FileWriteRequest(directory: ref, items: [FileWriteItem(fileName: "Untitled.txt", source: .text("other"))], conflictPolicy: .fail),
                                           pluginID: plugin, operationID: OperationID(), executionID: nil)
        #expect(again.outcomes.first?.status == .conflict)
        #expect(try String(contentsOf: dir.appendingPathComponent("Untitled.txt"), encoding: .utf8) == "hi")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func emptyTextFileIsLegal() async throws {
        let (broker, contexts, dir, _) = try setup()
        let ref = contexts.issue(dir, for: plugin, execution: ExecutionID())
        let reply = try await broker.write(FileWriteRequest(directory: ref, items: [FileWriteItem(fileName: "Empty.md", source: .empty)]),
                                           pluginID: plugin, operationID: OperationID(), executionID: nil)
        #expect(reply.outcomes.first?.status == .written)
        #expect((try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("Empty.md").path)[.size] as? NSNumber)?.intValue == 0)
    }

    @Test func conflictChoicesKeepBothReplaceSkipApplyToAll() async throws {
        let (broker, contexts, dir, _) = try setup()
        for name in ["a.txt", "b.txt", "c.txt"] { try "old".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let delegate = ScriptedConflicts([ConflictResolution(.keepBoth), ConflictResolution(.replace, applyToAll: true)])
        broker.delegate = delegate
        let ref = contexts.issue(dir, for: plugin, execution: ExecutionID())
        let items = ["a.txt", "b.txt", "c.txt"].map { FileWriteItem(fileName: $0, source: .text("new")) }
        let reply = try await broker.write(FileWriteRequest(directory: ref, items: items), pluginID: plugin, operationID: OperationID(), executionID: nil)
        #expect(reply.outcomes.map(\.status) == [.written, .written, .written])
        #expect(delegate.asked == ["a.txt", "b.txt"])
        #expect(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: dir.appendingPathComponent("a 2.txt"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: dir.appendingPathComponent("b.txt"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: dir.appendingPathComponent("c.txt"), encoding: .utf8) == "new")
    }

    @Test func cancelStopsRemainingItemsAndReportsPartial() async throws {
        let (broker, contexts, dir, _) = try setup()
        try "old".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let delegate = ScriptedConflicts([ConflictResolution(.cancel)])
        broker.delegate = delegate
        let ref = contexts.issue(dir, for: plugin, execution: ExecutionID())
        let items = ["a.txt", "b.txt", "c.txt"].map { FileWriteItem(fileName: $0, source: .text("new")) }
        let reply = try await broker.write(FileWriteRequest(directory: ref, items: items), pluginID: plugin, operationID: OperationID(), executionID: nil)
        #expect(reply.outcomes.map(\.status) == [.written, .cancelled, .cancelled])
        #expect(reply.dataEffect == .partial)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("c.txt").path))
        withExtendedLifetime(delegate) {}
    }

    @Test func retryWithSameOperationReturnsReceiptWithoutRewriting() async throws {
        let (broker, contexts, dir, _) = try setup()
        let ref = contexts.issue(dir, for: plugin, execution: ExecutionID())
        let op = OperationID()
        let request = FileWriteRequest(directory: ref, items: [FileWriteItem(fileName: "x.txt", source: .text("1"))], conflictPolicy: .keepBoth)
        let first = try await broker.write(request, pluginID: plugin, operationID: op, executionID: nil)
        let second = try await broker.write(request, pluginID: plugin, operationID: op, executionID: nil)
        #expect(first == second)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("x 2.txt").path))
    }

    @Test func interruptedOperationBecomesUnknownAndIsNotReplayed() async throws {
        let (broker, contexts, dir, db) = try setup()
        let op = OperationID()
        try db.saveOperation(OperationRecord(operationID: op.rawValue, pluginID: plugin.rawValue, actionID: nil, executionID: nil, phase: .staged, intent: "{}"))
        let recovered = try broker.recoverInterruptedOperations()
        #expect(recovered.map(\.operationID) == [op.rawValue])
        let ref = contexts.issue(dir, for: plugin, execution: ExecutionID())
        await #expect(throws: RuyioError.self) {
            _ = try await broker.write(FileWriteRequest(directory: ref, items: [FileWriteItem(fileName: "y.txt", source: .text("1"))]),
                                       pluginID: plugin, operationID: op, executionID: nil)
        }
    }

    @Test func rejectsForeignReferencesBadNamesAndSwappedTargets() async throws {
        let (broker, contexts, dir, _) = try setup()
        let ref = contexts.issue(dir, for: PluginID("org.other.plugin"), execution: ExecutionID())
        await #expect(throws: RuyioError.self) {
            _ = try await broker.write(FileWriteRequest(directory: ref, items: [FileWriteItem(fileName: "a.txt", source: .text("1"))]),
                                       pluginID: plugin, operationID: nil, executionID: nil)
        }
        let mine = contexts.issue(dir, for: plugin, execution: ExecutionID())
        for bad in ["", "..", "a/b.txt", "x:y", String(repeating: "长", count: 100)] {
            await #expect(throws: RuyioError.self) {
                _ = try await broker.write(FileWriteRequest(directory: mine, items: [FileWriteItem(fileName: bad, source: .text("1"))]),
                                           pluginID: plugin, operationID: nil, executionID: nil)
            }
        }
        // Directory replaced after the grant was issued: refuse instead of writing into the new target.
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let swapRef = contexts.issue(other, for: plugin, execution: ExecutionID())
        try FileManager.default.removeItem(at: other)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        await #expect(throws: RuyioError.self) {
            _ = try await broker.write(FileWriteRequest(directory: swapRef, items: [FileWriteItem(fileName: "a.txt", source: .text("1"))]),
                                       pluginID: plugin, operationID: nil, executionID: nil)
        }
    }

    @Test func copiesFilesWithoutTouchingSource() async throws {
        let (broker, contexts, dir, _) = try setup()
        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let source = sourceDir.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: source)
        let execution = ExecutionID()
        let dirRef = contexts.issue(dir, for: plugin, execution: execution)
        let fileRef = contexts.issue(source, for: plugin, execution: execution)
        let reply = try await broker.write(FileWriteRequest(directory: dirRef, items: [FileWriteItem(fileName: "photo.png", source: .copyOf(fileRef))]),
                                           pluginID: plugin, operationID: nil, executionID: nil)
        #expect(reply.outcomes.first?.status == .written)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: dir.appendingPathComponent("photo.png")) == Data([1, 2, 3]))
    }

    @Test func sanitizesNames() {
        #expect(FileBroker.sanitizeFileName("a/b:c\n") == "a-b-c")
        #expect(FileBroker.sanitizeFileName("...hidden") == "hidden")
        #expect(FileBroker.sanitizeFileName("   ") == "Untitled")
        #expect(FileBroker.numberedName("Report.md", 2) == "Report 2.md")
    }
}
