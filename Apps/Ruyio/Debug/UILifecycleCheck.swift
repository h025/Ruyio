#if DEBUG
import AppKit
import RuyioCore
import RuyioHostKit
import RuyioPersistence
import RuyioProtocol
import SwiftUI

/// Exercises the real window controllers with temporary storage and invented content. No plugins,
/// clipboard access or network requests are started. The same journey also supplies memory measurements.
@MainActor
enum UILifecycleCheck {
    static func run(out: URL) {
        Task {
            do { try await check(out: out) }
            catch { print("LIFECYCLE failed: \(error)"); exit(1) }
        }
    }

    private static func check(out: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ruyio-lifecycle-\(UUID())")
        let paths = AppPaths(applicationSupport: root.appendingPathComponent("Support"), caches: root.appendingPathComponent("Caches"))
        let model = AppModel(engine: try HostEngine(paths: paths, locale: "en"))
        model.isGallery = true
        model.settings.language = .en
        model.settings.onboardingCompleted = true
        let frameKey = "NSWindow Frame RuyioMainWindow"
        let savedFrame = UserDefaults.standard.object(forKey: frameKey)
        defer {
            UserDefaults.standard.set(savedFrame, forKey: frameKey)
            PasteService.shared.inAppPasteTarget = nil
            try? FileManager.default.removeItem(at: root)
        }
        // Populate the real registry without installing or starting executable plugins.
        for url in AppDelegate.bundledPackages() {
            let zip = try ZipArchive(url: url)
            guard let entry = zip.entries.first(where: { $0.path.hasSuffix("/manifest.json") && $0.path.split(separator: "/").count == 2 }) else { continue }
            let manifest = try ManifestValidator.decode(zip.contents(of: entry))
            let nonexistent = root.appendingPathComponent("Fixtures/\(manifest.id)/missing")
            var record = try InstalledPluginRecord(manifest: manifest, installPath: nonexistent.deletingLastPathComponent(), executablePath: nonexistent,
                                                   publisherID: nil, signingIdentifier: manifest.id.rawValue, isDevelopment: false, isDefault: true, updateChannel: .bundledWithHost)
            record.activationState = .enabled
            try await model.engine.registry.insert(record)
        }
        model.startObserving()
        await settle()
        var failures: [String] = []
        var assertions = 0
        func expect(_ value: Bool, _ message: String) {
            assertions += 1
            if !value { failures.append(message) }
        }
        var measurements: [[String: Any]] = []
        func measure(_ stage: String) {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            if result == KERN_SUCCESS { measurements.append(["stage": stage, "physicalFootprintBytes": info.phys_footprint]) }
        }
        let palette = CommandPaletteController(model: model)
        let overlay = OverlayController(model: model)
        palette.overlay = overlay
        overlay.palette = palette
        let input = InputSheetController(model: model)
        let form = FormSpec(fields: [FieldSpec(id: "name", label: "Name", kind: .textField, value: .string("Synthetic input"))], submitTitle: "Continue")
        var main: MainWindowController?
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        let offsets = WindowScrollOffsets.capture(in: scroll)
        scroll.contentView.scroll(to: .zero)
        WindowScrollOffsets.restore(offsets, in: scroll)
        expect(abs(scroll.contentView.bounds.origin.y - 400) < 0.5, "lightweight scroll offsets must restore the document position")
        scroll.documentView?.setFrameSize(NSSize(width: 200, height: 250))
        WindowScrollOffsets.restore(offsets, in: scroll)
        expect(scroll.contentView.bounds.maxY <= 250, "restored offsets must fit a smaller document")
        measure("before-UI")
        for cycle in 0..<4 {
            if main == nil {
                let controller = MainWindowController(model: model)
                controller.onClose = { [weak controller] in if main === controller { main = nil } }
                main = controller
            }
            main?.window?.setFrameAutosaveName("")
            main?.show()
            await settle()
            if cycle == 0 {
                main?.window?.miniaturize(nil)
                await settle()
                expect(main?.window?.contentView != nil, "minimizing must preserve the live main view")
                main?.show()
                model.showRoot(.general)
                measure("main-visible")
            }
            let oldMain = main?.window
            expect(oldMain?.isVisible == true && oldMain?.contentView != nil, "main window must be rendered before closing")
            oldMain?.close()
            await settle()
            expect(main == nil, "closing must release the main controller owner")
            expect(oldMain?.contentView == nil, "closed main window retained its view (cycle \(cycle))")
            expect(model.page == .general, "closing must preserve the selected settings page")

            palette.open()
            await settle()
            palette.query = "synthetic"
            let oldPalette = palette.galleryWindow
            expect(oldPalette?.isVisible == true && oldPalette?.contentView != nil, "palette must be rendered before closing")
            palette.close()
            await settle()
            expect(palette.galleryWindow == nil && oldPalette?.contentView == nil, "closed palette retained its window or view")
            expect(palette.query.isEmpty && palette.selection == nil, "closed palette retained temporary search state")

            HUD.shared.show("Synthetic notice", duration: 0.02)
            let oldHUD = HUD.shared.galleryWindow
            expect(oldHUD?.contentView != nil, "HUD must have content before its deadline")
            await settle()
            expect(HUD.shared.galleryWindow == nil && oldHUD?.contentView == nil, "expired HUD retained its view")

            input.show(title: "Synthetic input", form: form) { _ in }
            await settle()
            let oldInput = input.lifecycleWindow
            expect(oldInput?.isVisible == true && oldInput?.contentView != nil, "input window must be rendered before closing")
            oldInput?.performClose(nil)
            await settle()
            expect(oldInput?.contentView == nil, "closed input window retained its form")

            let onboarding = OnboardingController(model: model)
            onboarding.show()
            await settle()
            let oldOnboarding = onboarding.window
            expect(oldOnboarding?.isVisible == true && oldOnboarding?.contentView != nil, "onboarding must be rendered before closing")
            oldOnboarding?.close()
            await settle()
            expect(oldOnboarding?.contentView == nil, "closed onboarding retained its view")
            expect(PasteService.shared.inAppPasteTarget == nil, "closed onboarding retained its paste target")

            overlay.presentForGallery(document: UIGallery.sampleHistory(language: "en"), pluginID: PluginID("app.ruyio.clipboard-history"))
            await settle()
            overlay.expandPreviewForGallery(.json("{\"synthetic\":true}"))
            await settle()
            let oldOverlay = overlay.galleryWindow
            let oldPreview = overlay.galleryExpandedWindow
            expect(oldOverlay?.contentView != nil && oldPreview?.contentView != nil, "overlay and preview must be rendered before closing")
            overlay.close()
            await settle()
            expect(oldOverlay?.contentView == nil && oldPreview?.contentView == nil, "closed overlay or expanded preview retained content")
            expect(overlay.galleryWindow == nil && overlay.galleryExpandedWindow == nil, "closed overlay retained a window")
        }
        await settle(3)
        measure("closed-idle")
        expect(NSApp.activationPolicy() == .accessory, "closed document windows must hide the Dock")

        if let entry = model.snapshot.entries.commands.first(where: { $0.opensView == nil }) {
            palette.open()
            let oldInvocation = palette.run(entry)
            palette.close()
            palette.open()
            palette.query = "new presentation"
            await oldInvocation?.value
            expect(palette.phase == .browsing && palette.query == "new presentation", "late action result overwrote a reopened palette")
            palette.close()
        } else { expect(false, "fixture must supply a command without an overlay") }

        HUD.shared.show("Old notice", duration: 0.03)
        HUD.shared.show("New notice", duration: 10)
        await settle()
        expect(HUD.shared.galleryWindow?.isVisible == true, "an old HUD deadline dismissed a newer notice")
        HUD.shared.hide()

        let image = NSImage(size: NSSize(width: 240, height: 160), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
        PinnedImages.shared.pin(image, scale: 1, pluginName: "Synthetic pin", l: model.l)
        let pin = PinnedImages.shared.galleryLastPanel
        IdleMemoryReclaimer.schedule()
        await settle(3)
        expect(pin?.isVisible == true && pin?.contentView != nil, "idle cleanup discarded a visible pin")
        PinnedImages.shared.closeAll()

        let passes = IdleMemoryReclaimer.completedPasses
        for _ in 0..<20 { IdleMemoryReclaimer.schedule() }
        for _ in 0..<100 {
            if IdleMemoryReclaimer.completedPasses > passes { break }
            await settle(0.1)
        }
        expect(IdleMemoryReclaimer.completedPasses == passes + 1, "close bursts must produce one coalesced allocator pass")
        await settle(2.5)
        expect(IdleMemoryReclaimer.completedPasses == passes + 1, "idle cleanup must not repeat without another close")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let report: [String: Any] = ["assertions": assertions, "failures": failures, "measurements": measurements]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("lifecycle.json"))
        await model.engine.shutdown()
        print("LIFECYCLE \(failures.isEmpty ? "passed" : "failed"): \(assertions) checks, \(failures.count) failures")
        for failure in failures { print("LIFECYCLE error: \(failure)") }
        let status: Int32 = failures.isEmpty ? 0 : 1
        DispatchQueue.main.async { exit(status) }
    }

    private static func settle(_ seconds: Double = 0.15) async { try? await Task.sleep(for: .seconds(seconds)) }
}
#endif
