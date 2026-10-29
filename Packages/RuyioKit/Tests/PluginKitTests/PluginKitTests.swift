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

    /// A bundled plugin that needs a newer macOS than Ruyio itself would be refused on the oldest supported one.
    @Test(arguments: ["ClipboardHistory", "FinderEssentials"])
    func manifestsRunOnTheOldestSupportedMacOS(_ plugin: String) throws {
        #expect(try Repo.manifest(plugin).minimumMacOSVersion <= HostInfo.minimumOS)
    }

    /// Every other place that states the oldest supported macOS says the same as HostInfo.minimumOS.
    @Test func minimumSystemIsTheSameEverywhere() throws {
        let minimum = "\(HostInfo.minimumOS.major).\(HostInfo.minimumOS.minor)"
        func lines(_ path: String) throws -> [Substring] {
            try String(contentsOf: Repo.root.appendingPathComponent(path), encoding: .utf8).split(separator: "\n")
        }
        // `key: "14.0"` in project.yml.
        let project = try lines("project.yml")
        for key in ["macOS:", "MACOSX_DEPLOYMENT_TARGET:", "LSMinimumSystemVersion:"] {
            let values = project.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key) }
                .map { $0.split(separator: "\"").dropFirst().first.map(String.init) ?? "" }
            #expect(!values.isEmpty && values.allSatisfy { $0 == minimum }, "project.yml \(key) \(values)")
        }
        for plist in ["Apps/Ruyio/Info.plist", "Helpers/CaptureHelper/Info.plist"] {
            let text = try lines(plist)
            let key = try #require(text.firstIndex { $0.contains("<key>LSMinimumSystemVersion</key>") }, "\(plist)")
            #expect(text[key + 1].contains("<string>\(minimum)</string>"), "\(plist)")
        }
        #expect(try lines("Packages/RuyioKit/Package.swift").contains { $0.contains(".macOS(.v\(HostInfo.minimumOS.major))") })
        #expect(try lines("Scripts/release.sh").contains { $0.contains("<sparkle:minimumSystemVersion>\(minimum)</sparkle:minimumSystemVersion>") })
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

    @Test func savedFileNamesFollowUILanguage() {
        let stamp = "2026-10-27 22.30.43"
        let zh = Strings(locale: "zh-Hans"), en = Strings(locale: "en")
        #expect(ClipboardHistoryPlugin.savedFileName(.richText, stamp: stamp, ext: "txt", strings: zh) == "文本 2026-10-27 22.30.43.txt")
        #expect(ClipboardHistoryPlugin.savedFileName(.image, stamp: stamp, ext: "png", strings: zh) == "图片 2026-10-27 22.30.43.png")
        #expect(ClipboardHistoryPlugin.savedFileName(.url, stamp: stamp, ext: "webloc", strings: en) == "Link 2026-10-27 22.30.43.webloc")
    }
}
