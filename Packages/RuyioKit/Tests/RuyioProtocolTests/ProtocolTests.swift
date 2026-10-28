import Foundation
import Testing
@testable import RuyioProtocol
import RuyioCore

struct FramingTests {
    @Test func roundTripsAcrossArbitraryChunks() throws {
        let envelopes = (0..<5).map { Envelope(kind: .request, method: "m\($0)", payload: ["n": .number(Double($0)), "s": "中文"]) }
        var bytes = Data()
        for envelope in envelopes { bytes.append(try Framing.encode(envelope)) }
        var decoder = FrameDecoder()
        var decoded: [Envelope] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let end = min(index + 7, bytes.endIndex)
            decoder.append(bytes[index..<end])
            while let next = try decoder.next() { decoded.append(next) }
            index = end
        }
        #expect(decoded == envelopes)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func rejectsOversizedDeclaredLength() {
        var decoder = FrameDecoder()
        var length = UInt32(Framing.maxFrameBytes + 1).bigEndian
        decoder.append(Data(bytes: &length, count: 4))
        #expect(throws: RuyioError.self) { _ = try decoder.next() }
    }

    @Test func deeplyNestedJSONIsRejectedWithoutExhaustingTheStack() throws {
        // ~2 KB of nesting used to overflow the reader thread's stack and crash the host.
        let deep = String(repeating: "{\"a\":", count: 2_000) + "1" + String(repeating: "}", count: 2_000)
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(JSONValue.self, from: Data(deep.utf8)) }
        let ok = String(repeating: "[", count: 20) + "1" + String(repeating: "]", count: 20)
        #expect((try? JSONDecoder().decode(JSONValue.self, from: Data(ok.utf8))) != nil)
    }

    @Test func rejectsGarbage() {
        var decoder = FrameDecoder()
        var length = UInt32(3).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(contentsOf: [0x7b, 0x7b, 0x7b])
        decoder.append(data)
        #expect(throws: RuyioError.self) { _ = try decoder.next() }
    }
}

struct ManifestTests {
    static let prdExample = """
    {
      "schemaVersion": 1,
      "id": "app.ruyio.clipboard-history",
      "name": "Clipboard History",
      "version": "1.0.0",
      "minimumHostVersion": "1.0.0",
      "minimumMacOSVersion": "15.0",
      "architectures": ["arm64"],
      "runtime": "native-isolated",
      "bundlePath": "Plugin.app",
      "executable": "Plugin.app/Contents/MacOS/PluginExecutable",
      "permissions": ["clipboard.read", "clipboard.write", "background"],
      "actions": [
        { "id": "show-history", "handler": "showHistory", "title": "Show Clipboard History",
          "presentations": [ { "type": "commandPalette", "title": "Show Clipboard History" },
                             { "type": "globalHotkey", "defaultShortcut": "command+shift+v" } ] },
        { "id": "paste-recent", "handler": "pasteRecent", "title": "Paste Recent",
          "presentations": [ { "type": "finderContextMenu", "title": "Paste Recent", "group": "clipboard",
                               "presentation": "groupItems", "childrenProvider": "recentItems",
                               "contexts": { "targets": ["directory"], "selection": ["none", "files"] } } ] }
      ],
      "localizations": { "zh-Hans": { "name": "历史剪贴板", "action.show-history.title": "显示历史剪贴板" } }
    }
    """

    @Test func decodesAndValidatesPRDExample() throws {
        let manifest = try ManifestValidator.decode(Data(Self.prdExample.utf8))
        #expect(ManifestValidator.issues(in: manifest).isEmpty)
        #expect(manifest.permissions == [.clipboardRead, .clipboardWrite, .background])
        #expect(manifest.displayName(locale: "zh-Hans").text == "历史剪贴板")
        #expect(manifest.displayName(locale: "zh-CN").text == "历史剪贴板")
        let fallback = manifest.displayName(locale: "fr")
        #expect(fallback.text == "Clipboard History")
        #expect(fallback.isFallback)
        let action = try #require(manifest.action(ActionID("show-history")))
        #expect(manifest.actionTitle(action, locale: "zh-Hans").text == "显示历史剪贴板")
    }

    @Test func rejectsUnknownPermission() {
        let json = Self.prdExample.replacingOccurrences(of: "\"background\"]", with: "\"background\", \"storage.private\"]")
        #expect(throws: RuyioError.self) { _ = try ManifestValidator.decode(Data(json.utf8)) }
    }

    @Test func rejectsPathTraversalAndForeignExecutable() throws {
        var manifest = try ManifestValidator.decode(Data(Self.prdExample.utf8))
        manifest.bundlePath = "../Evil.app"
        manifest.executable = "/bin/sh"
        let fields = Set(ManifestValidator.issues(in: manifest).map(\.field))
        #expect(fields.contains("bundlePath"))
        #expect(fields.contains("executable"))
    }

    @Test func rejectsDuplicateActions() throws {
        var manifest = try ManifestValidator.decode(Data(Self.prdExample.utf8))
        manifest.actions.append(manifest.actions[0])
        #expect(ManifestValidator.issues(in: manifest).contains { $0.reason == "duplicate action id" })
    }

    @Test func hostLanguageResolution() {
        #expect(Localization.hostLanguage(for: ["zh-Hant-TW"]) == "zh-Hans")
        #expect(Localization.hostLanguage(for: ["en-GB"]) == "en")
        #expect(Localization.hostLanguage(for: ["fr-FR", "de"]) == "en")
    }
}

struct UISchemaTests {
    @Test func codableRoundTrip() throws {
        let doc = ViewDocument(viewID: "history", revision: 3, root: .collection(CollectionSpec(
            searchPlaceholder: "Search", filters: [FilterOption(id: "all", title: "All")],
            list: ListSpec(items: [ListItem(id: "1", title: "Hello", badges: ["pinned"])]),
            preview: .stack(StackSpec(children: [.text(TextSpec("Hello")), .keyValue([KeyValueRow(key: "App", value: "Notes")])])),
            footerActions: [ItemAction(id: "paste", title: "Paste", shortcut: "return", isDefault: true)]
        )))
        let data = try JSONCoding.encoder().encode(doc)
        #expect(try JSONCoding.decoder().decode(ViewDocument.self, from: data) == doc)
        try UISchemaLimits.validate(doc)
    }

    @Test func enforcesDepthLimit() {
        var node = UINode.text(TextSpec("leaf"))
        for _ in 0..<20 { node = .stack(StackSpec(children: [node])) }
        #expect(throws: RuyioError.self) { try UISchemaLimits.validate(ViewDocument(viewID: "v", revision: 1, root: node)) }
    }

    @Test func eventsRoundTrip() throws {
        let events: [ViewEvent] = [.searchChanged("x"), .invoke(actionID: "paste", itemID: "1"), .submit(["a": 1]), .undo(token: "t"), .cancel]
        for event in events {
            let data = try JSONCoding.encoder().encode(event)
            #expect(try JSONCoding.decoder().decode(ViewEvent.self, from: data) == event)
        }
    }
}
