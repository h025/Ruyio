import AppKit
import RuyioCore
import RuyioHostKit
import RuyioProtocol
import SwiftUI

// MARK: - Shortcuts (PRD §19.12)

struct ShortcutsPage: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var recording: String?
    @State private var message: String?
    var l: L10n { model.l }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: l.shortcuts) { EmptyView() }
            TextField(l.searchActions, text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 28).padding(.bottom, 8)
            if let message { Text(message).foregroundStyle(.orange).font(.callout).padding(.horizontal, 28) }
            List {
                Section("Ruyio") {
                    HStack {
                        Text(l.openCommandPalette)
                        Spacer()
                        recorderButton(key: "host.palette", current: model.settings.commandPaletteShortcut.flatMap(KeyShortcut.init(manifestString:)), state: nil) { shortcut in
                            model.update { $0.commandPaletteShortcut = shortcut?.manifestString }
                        }
                    }
                }
                let grouped = Dictionary(grouping: model.snapshot.entries.hotkeys.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.pluginName.localizedCaseInsensitiveContains(search) }, by: \.pluginName)
                ForEach(grouped.keys.sorted(), id: \.self) { plugin in
                    Section(plugin) {
                        ForEach(grouped[plugin] ?? []) { entry in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(entry.title)
                                    if !entry.isPluginEnabled { Text(l.pluginDisabledNote).font(.caption).foregroundStyle(.secondary) }
                                    else if entry.state == .unavailable { Text(l.unavailable).font(.caption).foregroundStyle(.orange) }
                                }
                                Spacer()
                                recorderButton(key: entry.id, current: entry.shortcut, state: entry.state) { shortcut in
                                    Task { try? await model.engine.registry.setHotkey(entry.ref, shortcut: shortcut) }
                                }
                                .disabled(!entry.isPluginEnabled)
                                if entry.isCustom {
                                    Button(l.restoreDefault) { Task { try? await model.engine.registry.setHotkey(entry.ref, shortcut: nil, resetToDefault: true) } }
                                        .buttonStyle(.borderless)
                                }
                            }
                            .opacity(entry.isPluginEnabled ? 1 : 0.55)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    func recorderButton(key: String, current: KeyShortcut?, state: HotkeyRegistrationState?, apply: @escaping (KeyShortcut?) -> Void) -> some View {
        Button {
            recording = key
            message = nil
            ShortcutRecorder.shared.record { result in
                recording = nil
                switch result {
                case .cancel: break
                case .clear: apply(nil)
                case .shortcut(let shortcut):
                    if let reason = shortcut.rejection() { message = l.shortcutRejected(reason); return }
                    // Internal conflicts need an explicit replacement decision (PRD §19.12).
                    if let other = model.snapshot.entries.hotkeys.first(where: { $0.shortcut == shortcut && $0.id != key }) {
                        let alert = NSAlert()
                        alert.messageText = shortcut.displayString
                        alert.informativeText = l.conflictMessage(other.title)
                        alert.addButton(withTitle: l.cancel)
                        alert.addButton(withTitle: l.replace)
                        guard alert.runModal() == .alertSecondButtonReturn else { return }
                        Task { try? await model.engine.registry.setHotkey(other.ref, shortcut: nil) }
                    }
                    apply(shortcut)
                }
            }
        } label: {
            Text(recording == key ? l.recordShortcut : (current?.displayString ?? l.notSet))
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 90)
        }
        .accessibilityLabel(current?.displayString ?? l.notSet)
    }
}

/// Captures the next key combination; Escape cancels and Delete clears (PRD §19.12).
@MainActor
final class ShortcutRecorder {
    static let shared = ShortcutRecorder()
    enum Result { case shortcut(KeyShortcut), clear, cancel }
    private var monitor: Any?

    func record(_ completion: @escaping (Result) -> Void) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if let monitor = self.monitor { NSEvent.removeMonitor(monitor) }
            self.monitor = nil
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 && flags.isEmpty { completion(.cancel) }
            else if (event.keyCode == 51 || event.keyCode == 117) && flags.isEmpty { completion(.clear) }
            else if let shortcut = HotkeyManager.shortcut(from: event) { completion(.shortcut(shortcut)) }
            else { completion(.cancel) }
            return nil
        }
    }
}

// MARK: - Permissions & privacy (PRD §19.13)

struct PrivacyPage: View {
    @ObservedObject var model: AppModel
    var l: L10n { model.l }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: l.privacy) { Button(l.recheck) { model.refreshSystemState() } }
            List {
                Section(l.systemPermissions) {
                    permissionRow(l.accessibility, l.accessibilityUse, model.accessibilityTrusted ? l.authorized : l.notAuthorized,
                                  ok: model.accessibilityTrusted) { SystemSettings.openAccessibility() }
                    permissionRow(l.finderExtension, l.finderExtensionUse, model.finderExtensionEnabled ? l.enabledState : l.notEnabled,
                                  ok: model.finderExtensionEnabled) { FinderExtensionStatus.showManagementInterface() }
                    permissionRow(l.filesAndFolders, l.filesAndFoldersUse, l.asNeeded, ok: true) { SystemSettings.openFilesAndFolders() }
                    permissionRow(l.clipboardAccess, l.clipboardAccessUse, clipboardState.0, ok: clipboardState.1) { SystemSettings.openPasteboardPrivacy() }
                }
                ForEach(model.snapshot.plugins) { plugin in
                    Section {
                        ForEach(plugin.manifest.permissions, id: \.self) { permission in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(l.permissionName(permission))
                                    Spacer()
                                    StatusChip(text: l.enforcement(permission.enforcement))
                                }
                                if permission.enforcement == .declaredAudited { Text(l.auditedNote).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    } header: {
                        Button(plugin.displayName) { model.selectedPlugin = plugin.id; model.page = .plugins }.buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.inset)
        }
        .onAppear { model.refreshSystemState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshSystemState() }
    }

    var clipboardState: (String, Bool) {
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow, .default: return (l.authorized, true)
            case .ask: return (l.t("每次询问", "Ask each time"), false)
            case .alwaysDeny: return (l.notAuthorized, false)
            @unknown default: return (l.unknownState, false)
            }
        }
        return (l.unknownState, true)
    }

    func permissionRow(_ title: String, _ use: String, _ state: String, ok: Bool, open: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(use).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusChip(text: state, tone: ok ? .green : .orange)
            Button(l.openSystemSettings, action: open).controlSize(.small)
        }
    }
}

// MARK: - General settings (PRD §19.14)

struct GeneralPage: View {
    @ObservedObject var model: AppModel
    var l: L10n { model.l }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: l.general) { EmptyView() }
            if let error = model.settingsError { Text(error).foregroundStyle(.red).padding(.horizontal, 28) }
            Form {
                Section(l.startup) {
                    Toggle(l.launchAtLogin, isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    Toggle(l.showInMenuBar, isOn: Binding(get: { model.settings.showInMenuBar }, set: { v in model.update { $0.showInMenuBar = v } }))
                }
                Section(l.appearance) {
                    Picker(l.theme, selection: Binding(get: { model.settings.theme }, set: { v in model.update { $0.theme = v } })) {
                        Text(l.followSystem).tag("system")
                        Text(l.light).tag("light")
                        Text(l.dark).tag("dark")
                    }
                    Picker(l.language, selection: Binding(get: { model.settings.language }, set: { v in model.update { $0.language = v } })) {
                        ForEach(AppLanguage.allCases) { Text($0.title(l)).tag($0) }
                    }
                }
                Section(l.updates) {
                    Toggle(l.autoRefreshMarkets, isOn: Binding(get: { model.settings.autoRefreshMarkets }, set: { v in model.update { $0.autoRefreshMarkets = v } }))
                    Toggle(l.autoCheckPlugins, isOn: Binding(get: { model.settings.autoCheckPluginUpdates }, set: { v in model.update { $0.autoCheckPluginUpdates = v } }))
                    Toggle(l.autoCheckApp, isOn: Binding(get: { model.settings.autoCheckAppUpdates }, set: { v in model.update { $0.autoCheckAppUpdates = v } }))
                }
                Section(l.dataSection) {
                    Toggle(l.includeInBackup, isOn: Binding(get: { model.settings.includeInBackup }, set: { v in model.update { $0.includeInBackup = v } }))
                }
                Section(l.advanced) {
                    Toggle(l.developerMode, isOn: Binding(get: { model.settings.developerMode }, set: { enable in
                        if enable {
                            let alert = NSAlert()
                            alert.messageText = l.developerMode
                            alert.informativeText = l.developerModeWarning
                            alert.addButton(withTitle: l.cancel)
                            alert.addButton(withTitle: l.continueAction)
                            guard alert.runModal() == .alertSecondButtonReturn else { return }
                        }
                        model.update { $0.developerMode = enable }
                    }))
                    if model.settings.developerMode {
                        Button(l.loadDevelopmentPlugin) { loadDevelopmentPlugin() }
                    }
                }
                Section(l.help) {
                    HStack {
                        Button(l.rerunOnboarding) { NSApp.sendAction(#selector(AppDelegate.showOnboarding), to: nil, from: nil) }
                        Button(l.openLogs) { NSWorkspace.shared.open(model.engine.paths.logs) }
                        Button(l.clearLogs) { model.engine.log.clear() }
                        Button(l.licenses) { if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") { NSWorkspace.shared.open(url) } }
                    }
                    Text("Ruyio \(HostInfo.version) · macOS \(OSVersion.current) · arm64").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    func loadDevelopmentPlugin() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let preview = try await model.engine.installDevelopmentPackage(at: url)
                guard preview.isInstallable else { model.show(model.l.errorText(RuyioError(.sourceInvalid, diagnostic: preview.failureSummary))); return }
                _ = try await model.engine.commitInstall(preview, updateChannel: .development, source: url.path)
            } catch let error as RuyioError {
                model.show(model.l.errorText(error))
            } catch {
                model.show(error.localizedDescription)
            }
        }
    }
}
