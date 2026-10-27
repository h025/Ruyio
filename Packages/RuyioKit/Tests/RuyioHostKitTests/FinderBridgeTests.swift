import Foundation
import Testing
@testable import RuyioHostKit
import RuyioProtocol
import RuyioCore

struct FinderBridgeTests {
    func bridge() -> FinderBridge {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return FinderBridge(containerURL: dir)
    }

    func write(_ request: FinderRequest, to bridge: FinderBridge) throws {
        try FinderWire.encoder().encode(request).write(to: bridge.requestsURL.appendingPathComponent("\(request.requestID).json"))
    }

    @Test func consumesValidRequestOnceAndRejectsExpiredOrForeignVersion() async throws {
        let bridge = bridge()
        let received = LockedBox<[InvocationRequest]>([])
        let rejected = LockedBox<[ErrorCode]>([])
        bridge.onRequest({ _, invocation in received.value.append(invocation) }, rejected: { _, error in rejected.value.append(error.code) })

        let good = FinderRequest(pluginID: "app.ruyio.finder-essentials", actionID: "copy-path", dynamicItemID: nil,
                                 targetDirectory: "/Users/x/Documents", selection: ["/Users/x/Documents/a.txt"], snapshotGeneration: 3)
        try write(good, to: bridge)
        bridge.drainQueue()
        // Same request delivered twice (duplicate wake-up) must not run twice.
        try write(good, to: bridge)
        bridge.drainQueue()

        let expired = FinderRequest(createdAt: Date().addingTimeInterval(-60), pluginID: "app.ruyio.finder-essentials", actionID: "copy-path",
                                    dynamicItemID: nil, targetDirectory: "/tmp", selection: [], snapshotGeneration: 3)
        try write(expired, to: bridge)
        var future = FinderRequest(pluginID: "app.ruyio.finder-essentials", actionID: "copy-path", dynamicItemID: nil, targetDirectory: "/tmp", selection: [], snapshotGeneration: 3)
        future.wireSchemaVersion = 99
        try write(future, to: bridge)
        bridge.drainQueue()

        #expect(await Fixture.waitUntil(timeout: .seconds(2)) { received.value.count == 1 })
        #expect(received.value.first?.finder?.selection.map(\.path) == ["/Users/x/Documents/a.txt"])
        #expect(received.value.first?.entry == .finderContextMenu)
        #expect(Set(rejected.value) == [.contextExpired, .incompatibleProtocol])
        #expect(try FileManager.default.contentsOfDirectory(atPath: bridge.requestsURL.path).isEmpty)
    }

    @Test func snapshotCarriesOnlyMetadataAndHidesEmptyDynamicGroups() throws {
        let bridge = bridge()
        let plugin = PluginID("app.ruyio.clipboard-history")
        let contexts = FinderContexts(targets: ["directory"], selection: ["none", "files"], requiresWritableTarget: true)
        let projection = EntryProjection(generation: 7, commands: [], hotkeys: [], menuBar: [], finder: [
            FinderGroupEntry(pluginID: plugin, title: "历史剪贴板", items: [
                FinderItemEntry(ref: ActionRef(pluginID: plugin, actionID: ActionID("paste-recent")), title: "存为文件", contexts: contexts,
                                childrenProvider: "recentItems", visible: true, order: 0),
            ], order: 0),
        ])
        bridge.update(projection: projection, locale: "zh-Hans", strings: [:])
        var snapshot = bridge.buildSnapshot()
        #expect(snapshot.groups.first?.items.first?.children == [])
        let ctx = FinderContextMatcher.Context(targetIsDirectory: true, selectionCount: 0, selectionHasDirectories: false, selectionHasFiles: false, clipboardKinds: [])
        #expect(!FinderContextMatcher.applies(snapshot.groups[0].items[0], to: ctx))

        bridge.update(dynamicItems: DynamicItemsReport(provider: "recentItems", items: [.init(id: "r1", title: "文本 · 10:32", kind: "text")], clipboardKinds: ["text"]), pluginID: plugin)
        snapshot = bridge.buildSnapshot()
        #expect(snapshot.groups[0].items[0].children?.map(\.title) == ["文本 · 10:32"])
        #expect(FinderContextMatcher.applies(snapshot.groups[0].items[0], to: ctx))
        bridge.invalidateDynamicItems(pluginID: plugin)
        #expect(bridge.buildSnapshot().groups[0].items[0].children == [])
    }

    @Test func contextMatcherHidesInapplicableActions() {
        let copyPath = FinderMenuSnapshot.Item(actionID: "copy-path", title: "复制完整路径", targets: ["file", "directory"], selection: ["single", "multiple"], requiresWritableTarget: false)
        let newFile = FinderMenuSnapshot.Item(actionID: "new-text", title: "新建文本文件…", targets: ["directory"], selection: ["none"], requiresWritableTarget: true)
        let none = FinderContextMatcher.Context(targetIsDirectory: true, selectionCount: 0, selectionHasDirectories: false, selectionHasFiles: false, clipboardKinds: [])
        let two = FinderContextMatcher.Context(targetIsDirectory: true, selectionCount: 2, selectionHasDirectories: false, selectionHasFiles: true, clipboardKinds: [])
        #expect(!FinderContextMatcher.applies(copyPath, to: none))
        #expect(FinderContextMatcher.applies(copyPath, to: two))
        #expect(FinderContextMatcher.applies(newFile, to: none))
        #expect(!FinderContextMatcher.applies(newFile, to: two))
    }
}
