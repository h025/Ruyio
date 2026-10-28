#if DEBUG
import AppKit
import RuyioCore
import RuyioHostKit
import RuyioPersistence
import RuyioProtocol
import RuyioSourceTransport
import RuyioUI
import SwiftUI

/// Reproducible native UI fixtures. No plugin process, real clipboard or remote service is used.
/// Run the Debug executable with `--ui-gallery <output-directory>`.
@MainActor
final class UIGallery {
    private let out: URL
    private let root: URL
    private let model: AppModel
    private let overlay: OverlayController
    private let palette: CommandPaletteController
    private static let frameKeys = ["NSWindow Frame RuyioMainWindow", "NSWindow Frame RuyioOverlay.history"]
    private let savedFrames: [String: Any]
    private var captures: [Capture] = []
    private var failures: [String] = []
    private var imageBlobID: String?
    private var theme = "light"
    private var locale = "zh-Hans"

    private struct Capture: Codable {
        var file: String
        var title: String
        var theme: String
        var language: String
        var pointWidth: Double
        var pointHeight: Double
        var pixelWidth: Int
        var pixelHeight: Int
    }

    private init(out: URL) throws {
        self.out = out
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ruyio-gallery-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(applicationSupport: root.appendingPathComponent("Support"), caches: root.appendingPathComponent("Caches"))
        try paths.ensureDirectories()
        model = AppModel(engine: try HostEngine(paths: paths, locale: "zh-Hans", fetcher: GalleryFetcher()))
        model.isGallery = true
        model.settings.language = .zhHans
        model.settings.theme = "light"
        model.accessibilityTrusted = false
        model.finderExtensionEnabled = true
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
        defer {
            for (key, value) in savedFrames { UserDefaults.standard.set(value, forKey: key) }
            for key in Self.frameKeys where savedFrames[key] == nil { UserDefaults.standard.removeObject(forKey: key) }
            PasteService.shared.inAppPasteTarget = nil
            try? FileManager.default.removeItem(at: root)
        }
        do {
            // A directly launched fixture process needs an active application for native key-window styling.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            await settle()
            model.startObserving()
            try await prepareRegistry()
            let only = ProcessInfo.processInfo.environment["RUYIO_GALLERY_ONLY"]
            for name in ["light", "dark"] {
                theme = name
                model.settings.theme = name
                NSApp.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
                if only == nil || only == "main" { try await mainWindow(name) }
                if only == nil || only == "overlay" { await overlayPanels(name) }
                if only == nil || only == "palette" { await commandPalette(name) }
                if only == nil || only == "onboarding" { await onboarding(name) }
                if only == nil || only == "sheets" { await sheets(name) }
                if only == nil || only == "hud" {
                    HUD.shared.show(model.l.t("已复制 1 条路径", "Copied 1 path"), duration: 1)
                    await settle()
                    if let window = HUD.shared.galleryWindow { await shoot(window, "hud-\(name)", title: "HUD") }
                    HUD.shared.galleryWindow?.orderOut(nil)
                }
            }
            if only == nil || only == "english" {
                locale = "en"
                theme = "light"
                model.settings.language = .en
                model.settings.theme = "light"
                NSApp.appearance = NSAppearance(named: .aqua)
                await model.engine.registry.setLocale("en")
                await model.engine.registry.setReport(PluginID("app.ruyio.clipboard-history"), PluginStatusReport(captureState: .recording, statusText: "Recording"))
                await settle()
                try await mainWindow("en-light", compact: true)
                await overlayPanels("en-light", variants: ["narrow", "narrow-paused", "compact-preview"])
                await commandPalette("en-light")
                await onboarding("en-light", steps: [0, 3])
                await pluginSettings("en-light")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(captures).write(to: out.appendingPathComponent("manifest.json"), options: .atomic)
            try "Native Ruyio views rendered with synthetic registry, storage and market data. No plugin process was started and no clipboard contents or network services were accessed.\n".write(to: out.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        } catch {
            failures.append(String(describing: error))
        }
        await model.engine.shutdown()
        print("GALLERY \(failures.isEmpty ? "done" : "failed") \(captures.count) captures at \(out.path)")
        for failure in failures { print("GALLERY error: \(failure)") }
        // Schedule exit after this scope so temporary storage and saved frame preferences are restored.
        let result: Int32 = failures.isEmpty ? 0 : 1
        DispatchQueue.main.async { exit(result) }
    }

    private func prepareRegistry() async throws {
        // Read manifests as data. Deliberately never call engine.start, install, enable or openView.
        var manifests: [PluginManifest] = []
        for url in AppDelegate.bundledPackages() {
            let archive = try ZipArchive(url: url)
            guard let entry = archive.entries.first(where: { $0.path == "manifest.json" || ($0.path.hasSuffix("/manifest.json") && $0.path.split(separator: "/").count == 2) }) else { continue }
            let manifest = try ManifestValidator.decode(archive.contents(of: entry))
            manifests.append(manifest)
            let nonexistent = root.appendingPathComponent("Fixtures/\(manifest.id)/not-an-executable")
            var record = try InstalledPluginRecord(manifest: manifest, installPath: nonexistent.deletingLastPathComponent(), executablePath: nonexistent,
                                                   teamID: nil, signingIdentifier: manifest.id.rawValue, isDevelopment: false, isDefault: true, updateChannel: .bundledWithHost)
            record.activationState = .enabled
            try await model.engine.registry.insert(record)
        }
        guard manifests.count == 2 else { throw RuyioError(.pluginNotFound, diagnostic: "gallery requires the two bundled manifests") }
        await model.engine.registry.setBundledDefaults(manifests)
        let keys = await model.engine.registry.snapshot().entries.hotkeys
        await model.engine.registry.setHotkeyStates(Dictionary(uniqueKeysWithValues: keys.map { ($0.id, .registered) }))
        await model.engine.registry.setReport(PluginID("app.ruyio.clipboard-history"), PluginStatusReport(captureState: .recording, statusText: "正在记录"))
        await settle()
        imageBlobID = try makeImageFixture()
    }

    private func mainWindow(_ name: String, compact: Bool = false) async throws {
        for market in await model.engine.markets.markets() { try await model.engine.markets.remove(market.marketID) }
        let main = MainWindowController(model: model)
        main.window?.setFrameAutosaveName("")
        main.window?.setContentSize(NSSize(width: 980, height: 680))
        main.window?.center()
        main.show()
        for page in Page.allCases {
            model.selectedPlugin = nil
            model.page = page
            await settle(0.65)
            if let window = main.window { await shoot(window, "main-\(page.rawValue)-\(name)", title: page.title(model.l)) }
        }
        model.page = .plugins
        for (id, label) in [("app.ruyio.clipboard-history", "clipboard"), ("app.ruyio.finder-essentials", "finder")] {
            model.selectedPlugin = PluginID(id)
            await settle(0.7)
            if let window = main.window {
                await shoot(window, "detail-\(label)-\(name)", title: "\(label) · overview and entries")
                if !compact {
                    scrollToEnd(window.contentView)
                    await settle()
                    await shoot(window, "detail-\(label)-bottom-\(name)", title: "\(label) · permissions, settings and versions")
                }
            }
            model.selectedPlugin = nil
            await settle(0.2)
        }
        model.page = .general
        main.window?.setFrame(NSRect(x: 100, y: 100, width: 820, height: 560), display: true)
        await settle()
        if let window = main.window { await shoot(window, "main-minimum-\(name)", title: "Minimum window · General") }
        main.window?.orderOut(nil)
        if !compact {
            try await seedMarket()
            await marketWindow(name, tab: 0)
            await marketWindow(name, tab: 1)
        }
    }

    private func seedMarket() async throws {
        for address in ["https://gallery.example.org/ruyio-market.json", "https://archive.example.org/ruyio-market.json"] {
            let resolved = try await model.engine.markets.resolve(address)
            _ = try await model.engine.markets.addMarket(resolved)
        }
        try await model.engine.markets.setEnabled("org.example.archive", false)
    }

    private func marketWindow(_ name: String, tab: Int) async {
        model.galleryMarketTab = tab
        model.selectedPlugin = nil
        model.page = .market
        await host(MainView(model: model), name: "market-\(tab == 0 ? "discover" : "sources")-\(name)", title: "Market · \(tab == 0 ? "Discover" : "Sources")", size: NSSize(width: 980, height: 680), fullSizeContentView: true)
        model.galleryMarketTab = 0
    }

    private func overlayPanels(_ name: String, variants: [String] = ["text", "image", "file-unavailable", "paused", "empty", "no-results", "narrow", "compact-preview"]) async {
        for variant in variants {
            let document = history(variant: variant)
            overlay.presentForGallery(document: document, pluginID: PluginID("app.ruyio.clipboard-history"))
            let compact = variant == "narrow" || variant == "narrow-paused" || variant == "compact-preview"
            // Ignore the preceding fixture's saved window size when switching from narrow to wide.
            overlay.galleryWindow?.setContentSize(compact ? NSSize(width: 640, height: 420) : NSSize(width: 780, height: 520))
            await settle(0.2)
            if variant == "compact-preview" { overlay.setCompactPreviewForGallery(true) }
            await settle(0.7)
            if let window = overlay.galleryWindow { await shoot(window, "clipboard-\(variant)-\(name)", title: "Clipboard · \(variant)") }
            overlay.close()
            await settle(0.1)
        }
    }

    private func commandPalette(_ name: String) async {
        palette.open()
        await settle()
        if let window = palette.galleryWindow { await shoot(window, "palette-\(name)", title: "Command palette") }
        palette.query = locale == "en" ? "clipboard" : "剪贴"
        await settle()
        if let window = palette.galleryWindow { await shoot(window, "palette-query-\(name)", title: "Command palette · results") }
        palette.query = "no-matching-command"
        await settle()
        if let window = palette.galleryWindow { await shoot(window, "palette-empty-\(name)", title: "Command palette · no results") }
        if let command = model.snapshot.entries.commands.first {
            palette.query = ""
            palette.phase = .form(command.ref, sampleForm(), [:])
            await settle()
            if let window = palette.galleryWindow {
                await shoot(window, "palette-form-\(name)", title: "Command palette · synthetic parameter form")
                scrollToEnd(window.contentView)
                await settle()
                await shoot(window, "palette-form-bottom-\(name)", title: "Command palette · parameter form bottom")
            }
        }
        palette.close()
    }

    private func onboarding(_ name: String, steps: [Int] = [0, 1, 2, 3]) async {
        let controller = OnboardingController(model: model)
        controller.show()
        for step in steps {
            controller.state.step = step
            controller.state.clipboardDone = step == 3
            if step == 3 { controller.state.practiceText = model.l.t("第一条复制记录", "My first clipboard item") }
            await settle()
            if let window = controller.window { await shoot(window, "onboarding-\(step)-\(name)", title: "Onboarding · \(step + 1)") }
        }
        controller.window?.orderOut(nil)
        PasteService.shared.inAppPasteTarget = nil
    }

    private func sheets(_ name: String) async {
        await host(AddSourceSheet(model: model, isPresented: .constant(true)), name: "add-source-\(name)", title: "Add plugin or market", size: NSSize(width: 560, height: 230))
        await host(FinderMenuSheet(model: model, isPresented: .constant(true)), name: "finder-menu-settings-\(name)", title: "Finder menu settings", size: NSSize(width: 520, height: 460))
        if let summary = model.summary(PluginID("app.ruyio.clipboard-history")) {
            await host(UninstallSheet(model: model, summary: summary, isPresented: .constant(true)), name: "uninstall-\(name)", title: "Uninstall plugin", size: NSSize(width: 460, height: 240))
        }
        await pluginSettings(name)
    }

    private func pluginSettings(_ name: String) async {
        guard let summary = model.summary(PluginID("app.ruyio.clipboard-history")) else { return }
        let document = ViewDocument(viewID: "gallery-settings", revision: 1, root: .form(sampleForm()))
        for showError in [false, true] {
            let error = showError ? model.l.t("暂时无法保存设置。所选文件夹当前不可访问，请重新选择有访问权限的位置，再次保存。现有设置和未提交的修改均已保留。", "Settings could not be saved. The selected folder is currently unavailable. Choose a location you can access and try saving again. Your existing settings and unsaved changes have been preserved.") : nil
            await host(PluginSettingsSheet(model: model, summary: summary, isPresented: .constant(true), galleryDocument: document, galleryError: error),
                       name: "plugin-settings-\(showError ? "error" : "form")-\(name)", title: "Plugin settings · synthetic form\(showError ? " and error" : "")", size: NSSize(width: 560, height: 560), captureBottom: true)
        }
    }

    private func sampleForm() -> FormSpec {
        let l = model.l
        return FormSpec(fields: [
            FieldSpec(id: "label", label: l.t("配置名称", "Configuration Name"), kind: .textField, value: .string(l.t("我的工作记录", "My Work History")), isRequired: true),
            FieldSpec(id: "retention", label: l.t("保留天数", "Retention Days"), kind: .stepper, value: .number(30), minimum: 1, maximum: 365, step: 1),
            FieldSpec(id: "images", label: l.t("保存图片", "Save Images"), kind: .toggle, value: .bool(true)),
            FieldSpec(id: "files", label: l.t("保存文件引用", "Save File References"), kind: .toggle, value: .bool(true)),
            FieldSpec(id: "format", label: l.t("默认格式", "Default Format"), kind: .picker, value: .string("original"), options: [FieldSpec.Option(id: "original", title: l.t("保留原格式", "Keep Original Formatting")), FieldSpec.Option(id: "plain", title: l.t("纯文本", "Plain Text"))]),
            FieldSpec(id: "limit", label: l.t("最大记录条数", "Maximum History Items"), kind: .stepper, value: .number(500), minimum: 100, maximum: 10000, step: 100),
            FieldSpec(id: "passwords", label: l.t("跳过密码管理器", "Skip Password Managers"), kind: .toggle, value: .bool(true)),
            FieldSpec(id: "note", label: l.t("备注", "Notes"), kind: .textField, value: .string(l.t("仅保存在这台 Mac 上", "Stored only on this Mac")))
        ], submitTitle: l.t("保存", "Save"), footnote: l.t("此表单仅用于验证原生控件、滚动及错误布局。", "This fixture verifies native controls, scrolling, and error layout."))
    }

    private func host<V: View>(_ content: V, name: String, title: String, size: NSSize, captureBottom: Bool = false, fullSizeContentView: Bool = false) async {
        let hosting = NSHostingController(rootView: content.environment(\.locale, Locale(identifier: locale)))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = []
        var style: NSWindow.StyleMask = [.titled, .closable]
        // Fixed-size sheet contents need their complete content height below the temporary title bar.
        if fullSizeContentView { style.insert(.fullSizeContentView) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.title = title
        // Assigning the hosting controller may reset the window to its initial zero fitting size.
        // Apply the intended content size afterwards, as MainWindowController does.
        window.setContentSize(size)
        let controller = NSWindowController(window: window)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        await settle(0.7)
        window.contentView?.layoutSubtreeIfNeeded()
        await shoot(window, name, title: title)
        if captureBottom {
            scrollToEnd(window.contentView)
            await settle()
            await shoot(window, "\(name)-bottom", title: "\(title) · bottom")
        }
        window.orderOut(nil)
        withExtendedLifetime(controller) {}
    }

    private func settle(_ seconds: Double = 0.45) async { try? await Task.sleep(for: .seconds(seconds)) }

    private func scrollToEnd(_ view: NSView?) {
        guard let view else { return }
        if let scroll = view as? NSScrollView, let document = scroll.documentView,
           document.bounds.height > scroll.contentView.bounds.height {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            return
        }
        for child in view.subviews { scrollToEnd(child) }
    }

    private func shoot(_ window: NSWindow, _ name: String, title: String) async {
        if window.styleMask.contains(.titled) {
            // Focus can move while an async fixture is settling. Activate the exact window at capture
            // time and let AppKit redraw its native active appearance before asking WindowServer.
            for _ in 0..<4 {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeMain()
                await settle(0.2)
                if NSApp.isActive && window.isKeyWindow { break }
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard NSApp.isActive && window.isKeyWindow else {
                failures.append("inactive capture skipped: \(name); active=\(NSApp.isActive), key=\(window.isKeyWindow), keyWindow=\(NSApp.keyWindow?.windowNumber ?? -1)")
                return
            }
        }
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { failures.append("capture API missing: \(name)"); return }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            failures.append("capture failed: \(name); frame=\(window.frame), visible=\(window.isVisible), key=\(window.isKeyWindow), number=\(window.windowNumber)")
            return
        }
        do {
            try data.write(to: out.appendingPathComponent("\(name).png"))
            captures.append(Capture(file: "\(name).png", title: title, theme: theme, language: locale,
                                    pointWidth: window.frame.width, pointHeight: window.frame.height, pixelWidth: image.width, pixelHeight: image.height))
            print("GALLERY captured \(name)")
        } catch { failures.append("\(name): \(error)") }
    }

    private func makeImageFixture() throws -> String? {
        let image = NSImage(size: NSSize(width: 800, height: 500), flipped: false) { rect in
            NSColor(calibratedRed: 0.89, green: 0.94, blue: 0.98, alpha: 1).setFill()
            rect.fill()
            NSColor(calibratedRed: 0.22, green: 0.49, blue: 0.63, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 60, y: 70, width: 680, height: 360), xRadius: 24, yRadius: 24).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 54, weight: .semibold), .foregroundColor: NSColor.white]
            ("Ruyio" as NSString).draw(at: NSPoint(x: 115, y: 275), withAttributes: attributes)
            ("Sample image" as NSString).draw(at: NSPoint(x: 115, y: 195), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.white.withAlphaComponent(0.8)])
            return true
        }
        guard let data = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]) else { return nil }
        let store = try model.engine.services.stores.store(pluginID: PluginID("app.ruyio.clipboard-history"), generation: 1, development: false)
        var uploadID: String?
        var result: String?
        for offset in stride(from: 0, to: data.count, by: 60 * 1024) {
            let end = min(offset + 60 * 1024, data.count)
            let reply = try store.appendUpload(BlobPutRequest(uploadID: uploadID, chunk: data.subdata(in: offset..<end), isFinal: end == data.count))
            uploadID = reply.uploadID
            result = reply.blobID
        }
        return result
    }

    private func history(variant: String) -> ViewDocument {
        var document = Self.sampleHistory(language: locale)
        guard case .collection(var spec) = document.root else { return document }
        switch variant {
        case "image":
            spec.list.selection = "s3"
            if let blob = imageBlobID { spec.preview = .stack(StackSpec(children: [.image(ImageSpec(blobID: blob, pixelWidth: 800, pixelHeight: 500, accessibilityLabel: "Ruyio sample image")), .keyValue([KeyValueRow(key: "尺寸", value: "800 × 500"), KeyValueRow(key: "来源", value: "截屏")])])) }
        case "file-unavailable":
            spec.list.selection = "s4"
            spec.preview = .stack(StackSpec(children: [.text(TextSpec("文件已移动、删除或无法访问，请使用“复制路径”。")), .code("/Users/example/Documents/项目预算.xlsx")]))
            spec.footerActions = [ItemAction(id: "copy-paths", title: "复制路径", isDefault: true), ItemAction(id: "delete", title: "删除", shortcut: "command+delete", isDestructive: true)]
        case "paused", "narrow-paused":
            spec.banner = BannerSpec(text: model.l.t("已暂停记录，新复制内容不会保存。", "Recording is paused. Newly copied content will not be saved."), actions: [ItemAction(id: "resume", title: model.l.t("恢复记录", "Resume Recording"))])
        case "empty", "no-results":
            spec.list.items = []
            spec.list.selection = nil
            spec.preview = nil
            spec.footerActions = []
            spec.searchText = variant == "no-results" ? "没有匹配的内容" : ""
            spec.list.empty = EmptySpec(title: variant == "empty" ? "还没有复制记录" : "没有匹配的记录", message: variant == "empty" ? "复制文字、图片或文件后，记录会出现在这里。" : nil,
                                       action: variant == "no-results" ? ItemAction(id: "clear-filters", title: "清除筛选") : nil)
        default: break
        }
        document.root = .collection(spec)
        return document
    }

    /// Mirrors the Clipboard History plugin's view with invented content.
    static func sampleHistory(language: String = "zh-Hans") -> ViewDocument {
        let l = L10n(language)
        let actions = [
            ItemAction(id: "paste", title: l.t("粘贴", "Paste"), shortcut: "return", isDefault: true),
            ItemAction(id: "paste-plain", title: l.t("粘贴为纯文本", "Paste as Plain Text"), shortcut: "option+return"),
            ItemAction(id: "copy-only", title: l.t("仅复制", "Copy Only"), shortcut: "command+return"),
            ItemAction(id: "favorite", title: l.t("收藏", "Favorite"), shortcut: "command+d", symbol: "star"),
            ItemAction(id: "delete", title: l.t("删除", "Delete"), shortcut: "command+delete", symbol: "trash", isDestructive: true),
        ]
        let samples: [(String, String, String, Bool)] = l.zh ? [
            ("周会纪要：下周三前完成 Finder 扩展验收，并整理发布清单", "备忘录 · 刚刚", "doc.plaintext", true),
            ("https://developer.apple.com/design/human-interface-guidelines/materials", "Safari 浏览器 · 2 分钟前", "link", false),
            ("let panel = FloatingPanel(size: NSSize(width: 780, height: 520))", "Xcode · 5 分钟前", "doc.plaintext", false),
            ("截屏 2026-10-28 09.41.12", "截屏 · 18 分钟前", "photo", false),
            ("项目预算.xlsx", "访达 · 32 分钟前", "doc", false),
            ("杭州市西湖区文三路 398 号", "地图 · 1 小时前", "doc.plaintext", false),
            ("Ruyio 是一个插件化的 macOS 工具箱", "备忘录 · 昨天", "doc.richtext", true),
            ("brew install xcodegen", "终端 · 昨天", "doc.plaintext", false),
        ] : [
            ("Weekly notes: finish Finder extension acceptance by Wednesday and prepare the release checklist", "Notes · Just now", "doc.plaintext", true),
            ("https://developer.apple.com/design/human-interface-guidelines/materials", "Safari · 2 minutes ago", "link", false),
            ("let panel = FloatingPanel(size: NSSize(width: 780, height: 520))", "Xcode · 5 minutes ago", "doc.plaintext", false),
            ("Screenshot 2026-10-28 at 09.41.12", "Screenshot · 18 minutes ago", "photo", false),
            ("Project Budget.xlsx", "Finder · 32 minutes ago", "doc", false),
            ("398 Wensan Road, Xihu District, Hangzhou", "Maps · 1 hour ago", "doc.plaintext", false),
            ("Ruyio is a plugin-based macOS toolbox", "Notes · Yesterday", "doc.richtext", true),
            ("brew install xcodegen", "Terminal · Yesterday", "doc.plaintext", false),
        ]
        let rows = samples.enumerated().map { index, sample in
            ListItem(id: "s\(index)", title: sample.0, subtitle: sample.1, symbol: sample.2, isFavorite: sample.3, actions: actions)
        }
        let preview = UINode.stack(StackSpec(children: [
            .text(TextSpec(samples[0].0, style: .body)),
            .keyValue([KeyValueRow(key: l.t("来源", "Source"), value: l.t("备忘录", "Notes")), KeyValueRow(key: l.t("复制时间", "Copied"), value: "09:46"),
                       KeyValueRow(key: l.t("次数", "Count"), value: "3"), KeyValueRow(key: l.t("大小", "Size"), value: l.t("96 字节", "96 bytes"))]),
        ]))
        let spec = CollectionSpec(
            searchPlaceholder: l.t("搜索复制内容", "Search clipboard"),
            filters: [FilterOption(id: "all", title: l.t("全部", "All")), FilterOption(id: "text", title: l.t("文本", "Text")), FilterOption(id: "image", title: l.t("图片", "Images")),
                      FilterOption(id: "url", title: l.t("链接", "Links")), FilterOption(id: "file", title: l.t("文件", "Files")), FilterOption(id: "favorite", title: l.t("收藏", "Favorites"))],
            selectedFilter: "all",
            list: ListSpec(items: rows, selection: "s0"),
            preview: preview,
            footerActions: actions + [ItemAction(id: "clear-unfavorited", title: l.t("清空未收藏…", "Clear Unfavorited…"), isDestructive: true)])
        return ViewDocument(viewID: "history", revision: 1, title: l.t("历史剪贴板", "Clipboard History"), root: .collection(spec))
    }
}

/// Deliberately cannot reach the network. All addresses in gallery fixtures are reserved examples.
private struct GalleryFetcher: RemoteFetching {
    func fetch(_ url: URL, maxBytes: Int, accept: String?, timeout: TimeInterval) async throws -> FetchResult {
        let archive = url.host == "archive.example.org"
        let payload: [String: Any]
        if url.lastPathComponent == "ruyio-market.json" {
            let entries: [[String: Any]] = [
                ["id": "app.ruyio.clipboard-history", "manifest": "clipboard/ruyio-plugin.json", "name": "历史剪贴板", "summary": "文字、图片与文件的本地复制记录"],
                ["id": "org.example.image-converter", "manifest": "image/ruyio-plugin.json", "name": "Image Converter", "summary": "Convert images with native formats"],
                ["id": "org.example.quick-notes", "manifest": "notes/ruyio-plugin.json", "name": "Quick Notes", "summary": "Save a thought without leaving your work"]
            ]
            payload = ["schemaVersion": 1, "kind": "market", "id": archive ? "org.example.archive" : "org.example.community",
                       "name": archive ? "Archive Market" : "Community Market", "plugins": archive ? [] : entries]
        } else {
            let component = url.deletingLastPathComponent().lastPathComponent
            let details: (String, String, String) = switch component {
            case "clipboard": ("app.ruyio.clipboard-history", "历史剪贴板", "文字、图片与文件的本地复制记录")
            case "image": ("org.example.image-converter", "Image Converter", "Convert images with native formats")
            default: ("org.example.quick-notes", "Quick Notes", "Save a thought without leaving your work")
            }
            payload = ["schemaVersion": 1, "kind": "plugin", "id": details.0, "name": details.1, "description": details.2,
                       "releases": [["version": "1.0.0", "minimumHostVersion": "1.0.0", "minimumMacOSVersion": "15.0", "architectures": ["arm64"],
                                     "artifact": "sample.ruyioplugin.zip", "sha256": String(repeating: "a", count: 64)]]]
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard data.count <= maxBytes else { throw RuyioError(.frameTooLarge) }
        return FetchResult(data: data, finalURL: url, statusCode: 200)
    }

    func download(_ url: URL, to destination: URL, maxBytes: Int, progress: (@Sendable (Int64, Int64?) -> Void)?) async throws {
        throw RuyioError(.permissionDenied, diagnostic: "gallery fixtures do not install plugins")
    }
}
#endif
