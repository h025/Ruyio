import AppKit
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let paths = try AppPaths.standard()
            let language = Self.initialLanguage(paths: paths)
            let engine = try HostEngine(paths: paths, locale: language)
            model = AppModel(engine: engine)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Ruyio"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        bridge.model = model
        conflicts.model = model
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
        Task { await observeRegistry() }

        Task {
            do {
                try await model.engine.start(bundledPackages: Self.bundledPackages())
            } catch {
                model.startupError = error.localizedDescription
                model.show(error.localizedDescription)
            }
            if !model.settings.onboardingCompleted { showOnboarding() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon restores the last page (PRD §18.1).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        finderBridge?.stopListening()
        let engine = model?.engine
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await engine?.shutdown()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
    }

    static func initialLanguage(paths: AppPaths) -> String {
        let database = try? HostDatabase(url: paths.hostDatabase)
        let settings = ((try? database?.setting("host.settings", as: HostSettings.self)) ?? nil) ?? HostSettings()
        return settings.language.resolved
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

    private func settingsChanged() {
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
        Task { handle(await model.engine.invoke(InvocationRequest(ref: ref, entry: .globalHotkey)), request: nil) }
    }

    private func run(menuItem: MenuBarItem) {
        guard let manifest = model.summary(menuItem.ref.pluginID)?.manifest, let action = manifest.action(menuItem.ref.actionID) else { return }
        if let view = action.opensView { overlay.open(pluginID: menuItem.ref.pluginID, viewID: view); return }
        Task { handle(await model.engine.invoke(InvocationRequest(ref: menuItem.ref, entry: .menuBar)), request: nil) }
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
            case .revealFiles(let paths): NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
            case .none: break
            }
        case .cancelled:
            break
        default:
            if let error = report.error, error.code != .cancelled { model.show(model.l.errorText(error)) }
        }
    }

    private func showInput(form: FormSpec, request: InvocationRequest) {
        let title = model.summary(request.ref.pluginID)?.manifest.action(request.ref.actionID)
            .map { model.summary(request.ref.pluginID)!.manifest.actionTitle($0, locale: model.language).text } ?? ""
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
        }, rejected: { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                self.model.show(error.code == .contextExpired ? self.model.l.requestExpired : self.model.l.errorText(error))
            }
        })
        model.engine.onDynamicItems { [weak bridge] pluginID, report in bridge?.update(dynamicItems: report, pluginID: pluginID) }
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
