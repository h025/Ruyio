#if DEBUG
import AppKit
import RuyioCore
import RuyioHostKit
import RuyioPersistence
import RuyioProtocol
import RuyioUI
import SwiftUI

/// Development-only visual check: `Ruyio --ui-gallery <dir>` renders every surface against a throwaway
/// data directory and writes window captures. The overlay uses sample records, never the real clipboard.
@MainActor
final class UIGallery {
    private let out: URL
    private let root: URL
    private let model: AppModel
    private let overlay: OverlayController
    private let palette: CommandPaletteController
    private static let frameKeys = ["NSWindow Frame RuyioMainWindow", "NSWindow Frame RuyioOverlay.history"]
    private let savedFrames: [String: Any]

    private init(out: URL) throws {
        self.out = out
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ruyio-gallery-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(applicationSupport: root.appendingPathComponent("Support"), caches: root.appendingPathComponent("Caches"))
        try paths.ensureDirectories()
        model = AppModel(engine: try HostEngine(paths: paths, locale: "zh-Hans"))
        overlay = OverlayController(model: model)
        palette = CommandPaletteController(model: model)
        savedFrames = Self.frameKeys.reduce(into: [:]) { $0[$1] = UserDefaults.standard.object(forKey: $1) }
    }

    static func run(out: URL) {
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let gallery = try UIGallery(out: out)
            Task { await gallery.capture() }
        } catch {
            print("GALLERY failed: \(error)")
            exit(1)
        }
    }

    private func capture() async {
        let bridge = SystemBridgeImpl()
        bridge.model = model
        model.engine.setBridge(bridge)
        model.startObserving()
        try? await model.engine.start(bundledPackages: AppDelegate.bundledPackages())
        for _ in 0..<100 where model.snapshot.plugins.count < 2 { await settle(0.1) }

        let only = ProcessInfo.processInfo.environment["RUYIO_GALLERY_ONLY"]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            if only == nil || only == "main" { await mainWindow(name) }
            if only == nil || only == "overlay" { await overlayPanel(name) }
            if only == nil || only == "palette" { await commandPalette(name) }
            if only == nil || only == "onboarding" { await onboarding(name) }
            if only == nil || only == "hud" {
                HUD.shared.show("已复制 1 条路径", duration: 3)
                await settle(0.6)
                if let window = HUD.shared.galleryWindow { shoot(window, "hud-\(name)") }
            }
        }
        for (key, value) in savedFrames { UserDefaults.standard.set(value, forKey: key) }
        for key in Self.frameKeys where savedFrames[key] == nil { UserDefaults.standard.removeObject(forKey: key) }
        await model.engine.shutdown()
        try? FileManager.default.removeItem(at: root)
        print("GALLERY done \(out.path)")
        exit(0)
    }

    private func mainWindow(_ name: String) async {
        let main = MainWindowController(model: model)
        main.window?.setFrameAutosaveName("")
        main.window?.setContentSize(NSSize(width: 980, height: 680))
        main.window?.center()
        main.show()
        for page in Page.allCases {
            model.selectedPlugin = nil
            model.page = page
            await settle(0.8)
            if let window = main.window { shoot(window, "main-\(page.rawValue)-\(name)") }
        }
        model.page = .plugins
        for (id, label) in [("app.ruyio.clipboard-history", "clipboard"), ("app.ruyio.finder-essentials", "finder")] {
            model.selectedPlugin = PluginID(id)
            await settle(1.0)
            if let window = main.window { shoot(window, "detail-\(label)-\(name)") }
        }
        model.selectedPlugin = nil
        main.window?.orderOut(nil)
    }

    private func overlayPanel(_ name: String) async {
        overlay.presentForGallery(document: Self.sampleHistory(), pluginID: PluginID("app.ruyio.clipboard-history"))
        await settle(0.8)
        if let window = overlay.galleryWindow { shoot(window, "overlay-\(name)") }
        overlay.close()
    }

    private func commandPalette(_ name: String) async {
        palette.open()
        await settle(0.6)
        if let window = palette.galleryWindow { shoot(window, "palette-\(name)") }
        palette.query = "剪贴"
        await settle(0.5)
        if let window = palette.galleryWindow { shoot(window, "palette-query-\(name)") }
        palette.close()
    }

    private func onboarding(_ name: String) async {
        let controller = OnboardingController(model: model)
        controller.show()
        for step in 0...3 {
            controller.state.step = step
            await settle(0.6)
            if let window = controller.window { shoot(window, "onboarding-\(step)-\(name)") }
        }
        controller.window?.orderOut(nil)
    }

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Own-window capture; needs no Screen Recording permission. The symbol is obsolete in the SDK headers
    /// but still exported, so it is looked up at runtime for this debug tool only.
    private func shoot(_ window: NSWindow, _ name: String) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // optionIncludingWindow, boundsIgnoreFraming | bestResolution
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: out.appendingPathComponent("\(name).png"))
    }

    /// Mirrors the Clipboard History plugin's view with invented content.
    static func sampleHistory() -> ViewDocument {
        let actions = [
            ItemAction(id: "paste", title: "粘贴", shortcut: "return", isDefault: true),
            ItemAction(id: "paste-plain", title: "粘贴为纯文本", shortcut: "option+return"),
            ItemAction(id: "copy-only", title: "仅复制", shortcut: "command+return"),
            ItemAction(id: "favorite", title: "收藏", shortcut: "command+d", symbol: "star"),
            ItemAction(id: "delete", title: "删除", shortcut: "command+delete", symbol: "trash", isDestructive: true),
        ]
        let samples: [(String, String, String, Bool)] = [
            ("周会纪要：下周三前完成 Finder 扩展验收，并整理发布清单", "备忘录 · 刚刚", "doc.plaintext", true),
            ("https://developer.apple.com/design/human-interface-guidelines/materials", "Safari 浏览器 · 2 分钟前", "link", false),
            ("let panel = FloatingPanel(size: NSSize(width: 780, height: 520))", "Xcode · 5 分钟前", "doc.plaintext", false),
            ("截屏 2026-10-28 09.41.12", "截屏 · 18 分钟前", "photo", false),
            ("项目预算.xlsx", "访达 · 32 分钟前", "doc", false),
            ("杭州市西湖区文三路 398 号", "地图 · 1 小时前", "doc.plaintext", false),
            ("Ruyio 是一个插件化的 macOS 工具箱", "备忘录 · 昨天", "doc.richtext", true),
            ("brew install xcodegen", "终端 · 昨天", "doc.plaintext", false),
        ]
        let rows = samples.enumerated().map { index, sample in
            ListItem(id: "s\(index)", title: sample.0, subtitle: sample.1, symbol: sample.2, isFavorite: sample.3, actions: actions)
        }
        let preview = UINode.stack(StackSpec(children: [
            .text(TextSpec(samples[0].0, style: .body)),
            .keyValue([KeyValueRow(key: "来源", value: "备忘录"), KeyValueRow(key: "复制时间", value: "09:46"),
                       KeyValueRow(key: "次数", value: "3"), KeyValueRow(key: "大小", value: "96 字节")]),
        ]))
        let spec = CollectionSpec(
            searchPlaceholder: "搜索复制内容",
            filters: [FilterOption(id: "all", title: "全部"), FilterOption(id: "text", title: "文本"), FilterOption(id: "image", title: "图片"),
                      FilterOption(id: "url", title: "链接"), FilterOption(id: "file", title: "文件"), FilterOption(id: "favorite", title: "收藏")],
            selectedFilter: "all",
            list: ListSpec(items: rows, selection: "s0"),
            preview: preview,
            footerActions: actions + [ItemAction(id: "clear-unfavorited", title: "清空未收藏…", isDestructive: true)])
        return ViewDocument(viewID: "history", revision: 1, title: "历史剪贴板", root: .collection(spec))
    }
}
#endif
