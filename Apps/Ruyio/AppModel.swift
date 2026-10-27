import AppKit
import Combine
import RuyioCore
import RuyioHostKit
import RuyioPersistence
import RuyioProtocol
import ServiceManagement
import SwiftUI

/// Host-level settings (PRD §19.14). Saved immediately; failures restore the old value.
struct HostSettings: Codable, Equatable {
    var language: AppLanguage = .system
    var theme: String = "system"
    var showInMenuBar = true
    var autoRefreshMarkets = false
    var autoCheckPluginUpdates = true
    var autoCheckAppUpdates = true
    var includeInBackup = false
    var developerMode = false
    var onboardingCompleted = false
    var neverAskAutoPaste = false
    /// Temporary default (decision A06): ⌃⌥Space conflicts with input-source switching.
    var commandPaletteShortcut: String? = "shift+command+space"
}

enum Page: String, CaseIterable, Identifiable, Hashable {
    case plugins, market, shortcuts, privacy, general
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .plugins: return "puzzlepiece.extension"
        case .market: return "square.grid.2x2"
        case .shortcuts: return "command"
        case .privacy: return "hand.raised"
        case .general: return "gearshape"
        }
    }
    func title(_ l: L10n) -> String {
        switch self {
        case .plugins: return l.plugins
        case .market: return l.market
        case .shortcuts: return l.shortcuts
        case .privacy: return l.privacy
        case .general: return l.general
        }
    }
}

/// Single observable source for every window, menu and panel (PRD §20.1: one state source).
@MainActor
final class AppModel: ObservableObject {
    let engine: HostEngine
    @Published private(set) var snapshot = RegistrySnapshot(generation: 0, plugins: [], restorableDefaults: [], entries: .empty)
    @Published var settings: HostSettings
    @Published var page: Page = .plugins
    @Published var selectedPlugin: PluginID?
    @Published var notice: String?
    @Published var accessibilityTrusted = AXIsProcessTrusted()
    @Published var finderExtensionEnabled = false
    @Published var settingsError: String?
    @Published var startupError: String?

    var l: L10n { L10n(settings.language.resolved) }
    var language: String { settings.language.resolved }

    init(engine: HostEngine) {
        self.engine = engine
        settings = ((try? engine.database.setting("host.settings", as: HostSettings.self)) ?? nil) ?? HostSettings()
        engine.developerMode = settings.developerMode
    }

    func startObserving() {
        Task {
            await engine.registry.observe { [weak self] snapshot in
                Task { @MainActor in self?.snapshot = snapshot }
            }
        }
    }

    func summary(_ id: PluginID) -> PluginSummary? { snapshot.plugins.first { $0.id == id } }

    // MARK: Settings

    func update(_ change: (inout HostSettings) -> Void) {
        let previous = settings
        var next = settings
        change(&next)
        do {
            try engine.database.setSetting("host.settings", next)
            if next.includeInBackup != previous.includeInBackup {
                try engine.database.setSetting("data.includeInBackup", next.includeInBackup)
                try? BackupPolicy.setExcludedFromBackup(!next.includeInBackup, at: engine.paths.dataRoot)
            }
            settings = next
            settingsError = nil
            if next.language != previous.language { Task { await engine.setLocale(next.language.resolved) } }
            if next.developerMode != previous.developerMode { engine.developerMode = next.developerMode }
            NotificationCenter.default.post(name: .ruyioSettingsChanged, object: nil)
        } catch {
            settings = previous
            settingsError = l.saveFailed + error.localizedDescription
        }
    }

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Toggle saves immediately; on failure the switch returns to its old state with the system reason (PRD §19.1).
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settingsError = nil
        } catch {
            settingsError = l.saveFailed + error.localizedDescription
        }
        objectWillChange.send()
    }

    // MARK: Plugin operations

    func setEnabled(_ id: PluginID, _ enabled: Bool) {
        Task {
            if enabled {
                if let error = await engine.enable(id) { show(l.errorText(error)) }
            } else {
                await engine.disable(id)
            }
        }
    }

    func uninstall(_ id: PluginID, deleteData: Bool) {
        Task {
            do {
                try await engine.uninstall(id, deleteData: deleteData)
                if selectedPlugin == id { selectedPlugin = nil }
            } catch let error as RuyioError {
                show(l.errorText(error))
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func restoreDefault(_ id: PluginID) {
        Task {
            do { try await engine.restoreDefault(id) } catch let error as RuyioError { show(l.errorText(error)) } catch { show(error.localizedDescription) }
        }
    }

    func show(_ text: String) {
        notice = text
        HUD.shared.show(text)
    }

    func refreshSystemState() {
        accessibilityTrusted = AXIsProcessTrusted()
        finderExtensionEnabled = FinderExtensionStatus.isEnabled
    }
}

extension Notification.Name {
    static let ruyioSettingsChanged = Notification.Name("app.ruyio.settingsChanged")
}
