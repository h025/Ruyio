import AppKit
import Combine
import RuyioCore
import RuyioHostKit
import RuyioPersistence
import RuyioProtocol
import RuyioUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var bridge = SystemBridgeImpl()
    private let conflicts = ConflictResolver()
    private var mainWindow: MainWindowController?
    private var onboarding: OnboardingController?
    private var palette: CommandPaletteController!
    private var overlay: OverlayController!
    private var menuBar: MenuBarController!
    private var finderBridge: FinderBridge?
    private var inputSheet: InputSheetController?
    private var hotkeySignature = ""
    private var automaticUpdates: AutomaticUpdateCoordinator?
    private var appUpdateObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--selftest-media") { runMediaSelfTest(); return }
        if let index = CommandLine.arguments.firstIndex(of: "--ui-gallery"), CommandLine.arguments.count > index + 1 {
            NSApp.setActivationPolicy(.accessory)
            UIGallery.run(out: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        #endif
        do {
            // The engine opens Host.sqlite first so a pending migration always gets its pre-migration backup
            // (plan §19.1); the saved language is applied right after, before any plugin starts.
            let paths = try AppPaths.standard()
            let engine = try HostEngine(paths: paths, locale: Localization.hostLanguage(for: Locale.preferredLanguages))
            model = AppModel(engine: engine)
        } catch {
            // Host database recovery window: no plugin and no Finder request runs (plan §19.1, R09).
            let l = L10n(Localization.hostLanguage(for: Locale.preferredLanguages))
            let alert = NSAlert()
            alert.messageText = l.recoveryTitle
            var detail = l.recoveryBody
            if case HostDatabaseError.migrationFailed(let backup, let underlying) = error {
                detail += "\n\n" + (backup.map { l.t("迁移前备份：", "Backup before migration: ") + $0.path } ?? "") + "\n" + underlying
            } else {
                detail += "\n\n" + error.localizedDescription
            }
            alert.informativeText = detail
            alert.addButton(withTitle: l.t("退出", "Quit"))
            alert.addButton(withTitle: l.t("打开数据位置", "Show Data Folder"))
            if alert.runModal() == .alertSecondButtonReturn, let paths = try? AppPaths.standard() {
                NSWorkspace.shared.activateFileViewerSelecting([paths.applicationSupport])
            }
            NSApp.terminate(nil)
            return
        }
        bridge.model = model
        conflicts.model = model
        installMainMenu()
        model.engine.setBridge(bridge)
        model.engine.setFileConflictDelegate(conflicts)

        overlay = OverlayController(model: model)
        palette = CommandPaletteController(model: model)
        palette.overlay = overlay
        overlay.palette = palette
        palette.openPluginDetail = { [weak self] id in self?.showPlugin(id) }
        menuBar = MenuBarController(model: model)
        menuBar.openPalette = { [weak self] in self?.palette.toggle() }
        menuBar.openPage = { [weak self] page in self?.model.page = page; self?.showMainWindow() }
        menuBar.runAction = { [weak self] item in self?.run(menuItem: item) }
        menuBar.setVisible(model.settings.showInMenuBar)

        setUpFinderBridge()
        model.startObserving()
        model.refreshSystemState()

        NotificationCenter.default.addObserver(forName: .ruyioSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // The network usually returns a little after wake; checking at once would only record failures.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                await self?.automaticUpdates?.checkIfDue()
            }
        }
        Task { await observeRegistry() }

        // Ruyio's own updater comes first and does not depend on the engine starting: a release whose
        // startup fails must still be able to fetch the release that fixes it.
        let appUpdates = AppUpdateService.Configuration.mainBundle().map {
            AppUpdateService(configuration: $0, staging: model.engine.paths.downloads)
        }
        if let appUpdates {
            AppUpdateService.removeLeftovers(beside: appUpdates.configuration.installedApp)
            model.appUpdates = appUpdates
            appUpdateObservation = model.$appUpdatePhase.map(\.menuKey).removeDuplicates().sink { [weak self] _ in
                DispatchQueue.main.async { self?.menuBar.rebuild() }
            }
            Task { [weak self] in
                await appUpdates.observe { item in Task { @MainActor in self?.model.appUpdateFound(item) } }
                // One small request per launch, so an update found before a restart is not forgotten until
                // the next scheduled check.
                if self?.model.settings.autoCheckAppUpdates == true { _ = try? await appUpdates.check() }
            }
        }

        Task {
            do {
                await model.engine.setLocale(model.language)
                try await model.engine.start(bundledPackages: Self.bundledPackages())
                let updates = AutomaticUpdateCoordinator(engine: model.engine, appUpdates: appUpdates)
                automaticUpdates = updates
                await updates.configure(refreshMarkets: model.settings.autoRefreshMarkets, checkPluginUpdates: model.settings.autoCheckPluginUpdates,
                                        checkAppUpdates: model.settings.autoCheckAppUpdates)
            } catch {
                model.startupError = error.localizedDescription
                model.show(error.localizedDescription)
            }
            // Judge waiting Finder clicks against the fully started registry, not a partial one.
            let started = await model.engine.registry.snapshot()
            finderBridge?.update(projection: started.entries, locale: model.language, strings: ["openRuyio": model.l.openRuyioToLoad])
            finderBridge?.markReady()
            if !model.settings.onboardingCompleted { showOnboarding() }
        }
    }

    #if DEBUG
    /// Development check that untrusted image decoding really goes through the sandboxed XPC service.
    private func runMediaSelfTest() {
        let image = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill(); return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("SELFTEST png failed"); exit(1) }
        Task {
            let decoded = await MediaDecoderClient.shared.image(from: png, maxPixel: 256)
            let garbage = await MediaDecoderClient.shared.image(from: Data(repeating: 0x41, count: 4096), maxPixel: 256)
            print("SELFTEST decoded=\(decoded.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil") garbageRejected=\(garbage == nil)")
            exit(decoded != nil && garbage == nil ? 0 : 1)
        }
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon restores the last page (PRD §18.1).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        finderBridge?.stopListening()
        let engine = model?.engine
        let updates = automaticUpdates
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await updates?.stop()
            await engine?.shutdown()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
    }

    static func bundledPackages() -> [URL] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("DefaultPlugins") else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasSuffix(".ruyioplugin.zip") }.sorted { $0.path < $1.path }
    }

    // MARK: Windows

    @objc func showMainWindow() {
        if mainWindow == nil { mainWindow = MainWindowController(model: model) }
        mainWindow?.show()
    }

    @objc func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingController(model: model)
            onboarding?.onFinish = { [weak self] openPalette in if openPalette { self?.palette.open() } }
        }
        onboarding?.show()
    }

    func showPlugin(_ id: PluginID) {
        model.page = .plugins
        model.selectedPlugin = id
        showMainWindow()
    }

    // MARK: Registry-driven updates

    private func observeRegistry() async {
        await model.engine.registry.observe { [weak self] snapshot in
            Task { @MainActor in self?.registryChanged(snapshot) }
        }
    }

    private func registryChanged(_ snapshot: RegistrySnapshot) {
        menuBar.rebuild()
        applyHotkeys(snapshot)
        finderBridge?.update(projection: snapshot.entries, locale: model.language,
                             strings: ["openRuyio": model.l.openRuyioToLoad])
    }

    /// Rebuilt when the language changes.
    private func installMainMenu() {
        NSApp.mainMenu = MainMenu.make(model.l, settings: #selector(showSettings), help: #selector(showHelp))
    }

    @objc func showSettings() {
        model.page = .general
        showMainWindow()
    }

    @objc func showHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/h025/Ruyio/wiki")!)
    }

    private func settingsChanged() {
        installMainMenu()
        let refreshMarkets = model.settings.autoRefreshMarkets
        let checkPlugins = model.settings.autoCheckPluginUpdates
        let checkApp = model.settings.autoCheckAppUpdates
        Task { await automaticUpdates?.configure(refreshMarkets: refreshMarkets, checkPluginUpdates: checkPlugins, checkAppUpdates: checkApp) }
        menuBar.setVisible(model.settings.showInMenuBar)
        menuBar.rebuild()
        hotkeySignature = ""
        applyHotkeys(model.snapshot)
        finderBridge?.update(projection: model.snapshot.entries, locale: model.language, strings: ["openRuyio": model.l.openRuyioToLoad])
    }

    /// Registers only what changed; real registration state is fed back to the registry (plan §13.5).
    private func applyHotkeys(_ snapshot: RegistrySnapshot) {
        var bindings: [(key: String, shortcut: KeyShortcut, handler: () -> Void)] = []
        if let raw = model.settings.commandPaletteShortcut, let shortcut = KeyShortcut(manifestString: raw) {
            bindings.append(("host.palette", shortcut, { [weak self] in self?.palette.toggle() }))
        }
        for entry in snapshot.entries.hotkeys where entry.isPluginEnabled {
            guard let shortcut = entry.shortcut else { continue }
            let ref = entry.ref
            bindings.append((entry.id, shortcut, { [weak self] in self?.runHotkey(ref) }))
        }
        let signature = bindings.map { "\($0.key)=\($0.shortcut.manifestString)" }.sorted().joined(separator: ";")
        guard signature != hotkeySignature else { return }
        hotkeySignature = signature
        let states = HotkeyManager.shared.apply(bindings)
        Task { await model.engine.registry.setHotkeyStates(states.filter { $0.key != "host.palette" }) }
    }

    private func runHotkey(_ ref: ActionRef) {
        guard let manifest = model.summary(ref.pluginID)?.manifest, let action = manifest.action(ref.actionID) else { return }
        if let view = action.opensView {
            // Pressing the same shortcut again closes the overlay (PRD §19.2 / §19.15).
            overlay.toggle(pluginID: ref.pluginID, viewID: view)
            return
        }
        let request = InvocationRequest(ref: ref, entry: .globalHotkey)
        Task { handle(await model.engine.invoke(request), request: request) }
    }

    private func run(menuItem: MenuBarItem) {
        guard let manifest = model.summary(menuItem.ref.pluginID)?.manifest, let action = manifest.action(menuItem.ref.actionID) else { return }
        if let view = action.opensView { overlay.open(pluginID: menuItem.ref.pluginID, viewID: view); return }
        let request = InvocationRequest(ref: menuItem.ref, entry: .menuBar)
        Task { handle(await model.engine.invoke(request), request: request) }
    }

    /// Shared handling for background entries: HUD feedback, overlays and the naming sheet.
    func handle(_ report: ExecutionReport, request: InvocationRequest?) {
        switch report.state {
        case .succeeded:
            switch report.output {
            case .notice(let text): model.show(text)
            case .openView(let view): overlay.open(pluginID: report.ref.pluginID, viewID: view)
            case .requestInput(let form):
                guard let request else { return }
                showInput(form: form, request: request)
            case .revealFiles(let paths):
                // Same rule as the reveal capability: only files this plugin wrote through the broker.
                let allowed = model.engine.services.fileBroker.revealablePaths(for: report.ref.pluginID)
                let urls = paths.prefix(64).filter { allowed.contains($0) }.map { URL(fileURLWithPath: $0) }
                FileReveal.reveal(urls)
            case .none: break
            }
        case .cancelled:
            break
        default:
            if let error = report.error, error.code != .cancelled { model.show(model.l.errorText(error)) }
        }
    }

    private func showInput(form: FormSpec, request: InvocationRequest) {
        let summary = model.summary(request.ref.pluginID)
        let action = summary?.manifest.action(request.ref.actionID).map { summary!.manifest.actionTitle($0, locale: model.language).text } ?? ""
        // The window title names the plugin, so a form asking for input can never pass as Ruyio or macOS.
        let title = "\(summary?.displayName ?? request.ref.pluginID.rawValue) — \(action)"
        if inputSheet == nil { inputSheet = InputSheetController(model: model) }
        inputSheet?.show(title: title, form: form) { [weak self] values in
            guard let self else { return }
            var next = request
            next.parameters.merge(values) { $1 }
            Task { self.handle(await self.model.engine.invoke(next), request: next) }
        }
    }

    // MARK: Finder

    private func setUpFinderBridge() {
        guard let container = FinderWire.channelDirectory(infoDictionary: Bundle.main.infoDictionary) else { return }
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bridge = FinderBridge(containerURL: container)
        bridge.onRequest({ [weak self] _, invocation in
            await MainActor.run {
                guard let self else { return }
                if let manifest = self.model.summary(invocation.ref.pluginID)?.manifest,
                   let view = manifest.action(invocation.ref.actionID)?.opensView {
                    PasteService.shared.rememberFrontmostApp()
                    self.overlay.open(pluginID: invocation.ref.pluginID, viewID: view)
                    return
                }
                Task { self.handle(await self.model.engine.invoke(invocation), request: invocation) }
            }
        }, rejected: { [weak self] request, error in
            Task { @MainActor in
                guard let self else { return }
                // Identifiers and the result code only; never the selection or target paths (PRD §21).
                self.model.engine.log.record(.finderRequest, ["plugin": request.pluginID, "action": request.actionID, "result": error.code.rawValue,
                                                              "detail": error.diagnostic ?? "-"])
                self.model.show(error.code == .contextExpired ? self.model.l.requestExpired : self.model.l.errorText(error))
            }
        })
        model.engine.onDynamicItems { [weak bridge] pluginID, report in bridge?.update(dynamicItems: report, pluginID: pluginID) }
        bridge.holdUntilReady()
        bridge.startListening()
        finderBridge = bridge
    }
}

/// Lightweight naming sheet for Finder actions that need input (PRD §19.18 step 1).
@MainActor
final class InputSheetController {
    private let model: AppModel
    private var window: NSPanel?

    init(model: AppModel) { self.model = model }

    func show(title: String, form: FormSpec, submit: @escaping ([String: JSONValue]) -> Void) {
        let l = model.l
        let context = SchemaContext(pluginID: PluginID("app.ruyio.host"), document: ViewDocument(viewID: "input", revision: 0, root: .form(form)),
                                    strings: SchemaStrings(submit: l.done, cancel: l.cancel, undo: "", loading: "", choose: "…"),
                                    sendEvent: { _, _ in }, loadBlob: { _ in nil })
        let panel = window ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.titled, .closable],
                                      backing: .buffered, defer: true)
        panel.title = title.replacingOccurrences(of: "…", with: "")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        let root = VStack(alignment: .leading) {
            SchemaFormView(spec: form, context: context) { [weak panel] values in
                panel?.orderOut(nil)
                submit(values)
            }
            HStack { Spacer(); Button(l.cancel) { [weak panel] in panel?.orderOut(nil) }.keyboardShortcut(.cancelAction) }.padding([.horizontal, .bottom])
        }
        .frame(width: 460)
        panel.contentView = NSHostingView(rootView: root)
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }
}
