import Foundation
import Testing
@testable import ClipboardHistoryKit
@testable import FinderEssentialsKit
import RuyioPluginSDK

enum Repo {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func manifest(_ plugin: String) throws -> PluginManifest {
        try ManifestValidator.decode(Data(contentsOf: root.appendingPathComponent("Plugins/\(plugin)/manifest.json")))
    }
}

struct OfficialManifestTests {
    @Test(arguments: ["ClipboardHistory", "FinderEssentials"])
    func manifestsValidateAndAreFullyLocalized(_ plugin: String) throws {
        let manifest = try Repo.manifest(plugin)
        #expect(ManifestValidator.issues(in: manifest).isEmpty, "\(ManifestValidator.issues(in: manifest))")
        #expect(manifest.id.isOfficialNamespace)
        let zh = try #require(manifest.localizations["zh-Hans"])
        #expect(zh["name"] != nil)
        for action in manifest.actions {
            #expect(zh["action.\(action.id).title"] != nil, "missing zh title for \(action.id)")
            for presentation in action.presentations where presentation.title != nil {
                let suffix = switch presentation.kind { case .commandPalette: "palette"; case .menuBar: "menu"; case .finderContextMenu: "finder"; case .globalHotkey: "" }
                if !suffix.isEmpty { #expect(zh["action.\(action.id).\(suffix)"] != nil, "missing zh \(suffix) for \(action.id)") }
            }
        }
    }

    @Test func clipboardHistoryDeclaresBackgroundAndHotkey() throws {
        let manifest = try Repo.manifest("ClipboardHistory")
        #expect(manifest.permissions.contains(.background))
        #expect(manifest.action(ActionID("show-history"))?.presentation(.globalHotkey)?.defaultShortcut == "command+shift+v")
    }
}

struct PasteboardRulesTests {
    let text = PasteboardRules.text

    @Test func sensitiveAndOwnWritesAreSkipped() {
        #expect(PasteboardRules.isSensitive(types: [text, "org.nspasteboard.ConcealedType"]))
        #expect(PasteboardRules.isSensitive(types: ["com.agilebits.onepassword", text]))
        #expect(!PasteboardRules.isSensitive(types: [text]))
        #expect(PasteboardRules.isOwnWrite(types: [text, PasteboardRules.originMarker]))
    }

    @Test func persistableFiltersHugeAndPrivateTypes() {
        #expect(PasteboardRules.isPersistable(text))
        #expect(!PasteboardRules.isPersistable("com.apple.webarchive"))
        #expect(!PasteboardRules.isPersistable("dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu"))
        #expect(!PasteboardRules.isPersistable("com.microsoft.ole.source.foo"))
    }

    @Test func fingerprintIgnoresVolatileMetadataButNotContent() {
        let a: [[String: Data]] = [[text: Data("hello".utf8), "org.chromium.source-url": Data("x".utf8)]]
        let b: [[String: Data]] = [[text: Data("hello".utf8), "org.chromium.source-url": Data("y".utf8)]]
        let c: [[String: Data]] = [[text: Data("hello".utf8), PasteboardRules.rtf: Data("{\\rtf1 hello}".utf8)]]
        #expect(PasteboardRules.fingerprint(items: a) == PasteboardRules.fingerprint(items: b))
        #expect(PasteboardRules.fingerprint(items: a) != PasteboardRules.fingerprint(items: c))
        let twoFiles: [[String: Data]] = [[PasteboardRules.fileURL: Data("file:///a".utf8)], [PasteboardRules.fileURL: Data("file:///b".utf8)]]
        let swapped: [[String: Data]] = [twoFiles[1], twoFiles[0]]
        #expect(PasteboardRules.fingerprint(items: twoFiles) != PasteboardRules.fingerprint(items: swapped))
    }

    @Test func kindDetection() {
        #expect(PasteboardRules.kind(of: [[text: Data("plain".utf8)]]) == .text)
        #expect(PasteboardRules.kind(of: [[text: Data("https://example.com/a".utf8)]]) == .url)
        #expect(PasteboardRules.kind(of: [[text: Data("see https://example.com".utf8)]]) == .text)
        #expect(PasteboardRules.kind(of: [[PasteboardRules.png: Data([0])]]) == .image)
        #expect(PasteboardRules.kind(of: [[PasteboardRules.fileURL: Data("file:///a".utf8)]]) == .file)
        #expect(PasteboardRules.kind(of: [[text: Data("x".utf8), PasteboardRules.html: Data("<b>x</b>".utf8)]]) == .richText)
    }

    @Test func emptyTextIsNotARecord() {
        #expect(PasteboardRules.isEffectivelyEmpty([text: Data("  \n ".utf8)]))
        #expect(!PasteboardRules.isEffectivelyEmpty([text: Data(" ".utf8), PasteboardRules.rtf: Data("{}".utf8)]))
    }

    @Test func titles() {
        #expect(ClipText.title(for: "\n\n  项目会议纪要\n第二行") == "项目会议纪要")
        #expect(ClipText.title(for: String(repeating: "a", count: 300)).count == 201)
    }
}
