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
        Form {
            if let message {
                Section { Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            Section("Ruyio") {
                LabeledContent(l.openCommandPalette) {
                    recorderButton(key: "host.palette", current: model.settings.commandPaletteShortcut.flatMap(KeyShortcut.init(manifestString:)), state: nil) { shortcut in
                        model.update { $0.commandPaletteShortcut = shortcut?.manifestString }
                    }
                }
            }
            let grouped = Dictionary(grouping: model.snapshot.entries.hotkeys.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.pluginName.localizedCaseInsensitiveContains(search) }, by: \.pluginName)
            ForEach(grouped.keys.sorted(), id: \.self) { plugin in
                Section(plugin) {
                    ForEach(grouped[plugin] ?? []) { entry in
                        LabeledContent {
                            HStack(spacing: 8) {
                                if entry.isCustom {
                                    Button(l.restoreDefault) { Task { try? await model.engine.registry.setHotkey(entry.ref, shortcut: nil, resetToDefault: true) } }
                                        .buttonStyle(.link)
                                }
                                recorderButton(key: entry.id, current: entry.shortcut, state: entry.state) { shortcut in
                                    Task { try? await model.engine.registry.setHotkey(entry.ref, shortcut: shortcut) }
                                }
                                .disabled(!entry.isPluginEnabled)
                            }
                        } label: {
                            Text(entry.title)
                            if !entry.isPluginEnabled { Text(l.pluginDisabledNote) }
                            else if entry.state == .unavailable { Text(l.unavailable).foregroundStyle(.orange) }
                            else if entry.state == .conflict { Text(l.t("与其他快捷键冲突，未生效", "Conflicts with another shortcut; not active")).foregroundStyle(.orange) }
                        }
                        .opacity(entry.isPluginEnabled ? 1 : 0.55)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(l.shortcuts)
        .searchable(text: $search, placement: .toolbar, prompt: l.searchActions)
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
                    // Internal conflicts need an explicit replacement decision (PRD §19.12), including the
                    // command palette's own shortcut.
                    let palette = model.settings.commandPaletteShortcut.flatMap(KeyShortcut.init(manifestString:))
                    let other = model.snapshot.entries.hotkeys.first(where: { $0.shortcut == shortcut && $0.id != key })
                    if other != nil || (key != "host.palette" && palette == shortcut) {
                        let alert = NSAlert()
                        alert.messageText = shortcut.displayString
                        alert.informativeText = l.conflictMessage(other?.title ?? l.openCommandPalette)
                        alert.addButton(withTitle: l.cancel)
                        alert.addButton(withTitle: l.replace)
                        guard alert.runModal() == .alertSecondButtonReturn else { return }
                        if let other {
                            Task { try? await model.engine.registry.setHotkey(other.ref, shortcut: nil) }
                        } else {
                            model.update { $0.commandPaletteShortcut = nil }
                        }
                    }
                    apply(shortcut)
                }
            }
        } label: {
            Text(recording == key ? l.recordShortcut : (current?.displayString ?? l.notSet))
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(current == nil && recording != key ? .secondary : .primary)
                .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 7))
        .tint(recording == key ? .accentColor : nil)
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
        Form {
            Section(l.systemPermissions) {
                permissionRow("accessibility", .blue, l.accessibility, l.accessibilityUse, model.accessibilityTrusted ? l.authorized : l.notAuthorized,
                              ok: model.accessibilityTrusted) { SystemSettings.openAccessibility() }
                permissionRow("puzzlepiece.extension.fill", .gray, l.finderExtension, l.finderExtensionUse, model.finderExtensionEnabled ? l.enabledState : l.notEnabled,
                              ok: model.finderExtensionEnabled) { FinderExtensionStatus.showManagementInterface() }
                permissionRow("folder.fill", .cyan, l.filesAndFolders, l.filesAndFoldersUse, l.asNeeded, ok: true) { SystemSettings.openFilesAndFolders() }
                permissionRow("list.clipboard.fill", .orange, l.clipboardAccess, l.clipboardAccessUse, clipboardState.0, ok: clipboardState.1) { SystemSettings.openPasteboardPrivacy() }
            }
            ForEach(model.snapshot.plugins) { plugin in
                Section {
                    ForEach(plugin.manifest.permissions, id: \.self) { permission in
                        LabeledContent {
                            StatusChip(text: l.enforcement(permission.enforcement))
                        } label: {
                            Text(l.permissionName(permission))
                            if permission.enforcement == .declaredAudited { Text(l.auditedNote) }
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        PluginIcon(id: plugin.id, size: 18)
                        Text(plugin.displayName)
                        Spacer()
                        Button(l.openPluginDetail) { model.page = .plugins; model.selectedPlugin = plugin.id }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(l.privacy)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.refreshSystemState() } label: { Label(l.recheck, systemImage: "arrow.clockwise") }.help(l.recheck)
            }
        }
        .onAppear { model.refreshSystemState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshSystemState() }
    }

    var clipboardState: (String, Bool) {
        #if DEBUG
        if model.isGallery { return (l.authorized, true) }
        #endif
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

    func permissionRow(_ symbol: String, _ color: Color, _ title: String, _ use: String, _ state: String, ok: Bool, open: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient).frame(width: 30, height: 30)
                .overlay(Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.white))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(use).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label(state, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.callout).foregroundStyle(ok ? Color.green : Color.orange)
            Button(l.t("打开", "Open"), action: open).help(l.openSystemSettings)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - General settings (PRD §19.14)

/// Ruyio's own update: check, then download, verify and install on request (A41).
struct AppUpdateStatus: View {
    @ObservedObject var model: AppModel
    var l: L10n { model.l }

    var body: some View {
        HStack {
            switch model.appUpdatePhase {
            case .idle:
                Button(l.checkNow) { model.checkForAppUpdate() }
            case .checking:
                ProgressView().controlSize(.small)
            case .upToDate:
                Text(l.upToDate).foregroundStyle(.secondary)
                Button(l.checkNow) { model.checkForAppUpdate() }
            case .available(let item):
                Text(l.updateAvailable(item.version.description))
                if let notes = item.releaseNotesURL { Link(l.releaseNotes, destination: notes) }
                Button(l.downloadAndInstall) { model.installAppUpdate(item) }
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 140)
            case .failed(let message):
                Text(message).foregroundStyle(.orange).lineLimit(2).multilineTextAlignment(.trailing)
                Button(l.checkNow) { model.checkForAppUpdate() }
            }
        }
    }
}

struct GeneralPage: View {
    @ObservedObject var model: AppModel
    var l: L10n { model.l }

    var body: some View {
        Form {
            if let error = model.settingsError {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
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
                Toggle(l.autoCheckApp, isOn: Binding(get: { model.appUpdates != nil && model.settings.autoCheckAppUpdates },
                                                     set: { v in model.update { $0.autoCheckAppUpdates = v } }))
                    .disabled(model.appUpdates == nil)
                if model.appUpdates == nil {
                    Text(l.localBuildNoUpdates).font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent(l.appVersionRow) { AppUpdateStatus(model: model) }
                }
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
                    LabeledContent(l.t("开发插件", "Development Plugin")) {
                        Button(l.loadDevelopmentPlugin) { loadDevelopmentPlugin() }
                    }
                }
            }
            Section(l.help) {
                LabeledContent(l.t("首次引导", "Onboarding")) {
                    Button(l.rerunOnboarding) { NSApp.sendAction(#selector(AppDelegate.showOnboarding), to: nil, from: nil) }
                }
                LabeledContent(l.t("诊断日志", "Diagnostic Logs")) {
                    HStack {
                        Button(l.openLogs) { NSWorkspace.shared.open(model.engine.paths.logs) }
                        Button(l.t("导出…", "Export…")) { exportLogs() }
                        Button(l.clearLogs) { model.engine.log.clear() }
                    }
                }
                LabeledContent(l.licenses) {
                    Button(l.t("查看", "View")) { if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") { NSWorkspace.shared.open(url) } }
                }
            }
            Section {
                LabeledContent(l.version) { Text(verbatim: "\(HostInfo.version)").monospacedDigit() }
                LabeledContent(l.t("系统", "System")) { Text(verbatim: "macOS \(OSVersion.current) · arm64") }
            } footer: {
                Text(l.tagline).frame(maxWidth: .infinity, alignment: .center).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(l.general)
    }

    /// Shows the included fields first, then lets the user choose where to save (PRD §21).
    func exportLogs() {
        let alert = NSAlert()
        alert.messageText = l.t("导出诊断日志", "Export Diagnostic Logs")
        alert.informativeText = l.t("日志只包含以下字段，不含剪贴板内容、文件内容、路径或完整网址：\n", "Logs contain only these fields — no clipboard or file content, paths or full URLs:\n")
            + DiagnosticLog.exportedFields.joined(separator: ", ")
        alert.addButton(withTitle: l.continueAction)
        alert.addButton(withTitle: l.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Ruyio-diagnostics.log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.engine.log.export(to: url) } catch { model.show(error.localizedDescription) }
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
                defer { model.engine.installer.discard(preview) }
                guard preview.isInstallable else { model.show(model.l.errorText(RuyioError(.sourceInvalid, diagnostic: preview.failureSummary))); return }
                var dataChoice = HostEngine.RestoreDataChoice.keepCompatible
                if try model.engine.requiresFreshData(for: preview) {
                    guard confirmFreshDataInstallation(using: l) else { return }
                    dataChoice = .fresh
                }
                _ = try await model.engine.commitInstall(preview, updateChannel: .development, source: url.path, dataChoice: dataChoice)
            } catch let error as RuyioError {
                model.show(model.l.errorText(error))
            } catch {
                model.show(error.localizedDescription)
            }
        }
    }
}
