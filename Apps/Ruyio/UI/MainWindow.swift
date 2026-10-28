import AppKit
import RuyioCore
import RuyioHostKit
import RuyioProtocol
import RuyioUI
import SwiftUI

/// Main window: a native split view whose titles, search fields and buttons live in the window toolbar
/// (SwiftUI toolbar bridging), with System Settings-style grouped content.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    init(model: AppModel) {
        let hosting = NSHostingController(rootView: MainView(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 820, height: 560)
        window.title = "Ruyio"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 980, height: 680))
        window.setFrameAutosaveName("RuyioMainWindow")
        if !window.setFrameUsingName("RuyioMainWindow") { window.center() }
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    var l: L10n { model.l }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.page }, set: { page in
                guard let page else { return }
                // Choosing a sidebar item always lands on that page's root (PRD §18.1).
                model.selectedPlugin = nil
                model.page = page
            })) {
                Section {
                    sidebarRow(.plugins).badge(model.snapshot.plugins.filter { $0.status.needsAttention }.count)
                    sidebarRow(.market)
                }
                Section(l.settings) {
                    sidebarRow(.shortcuts)
                    sidebarRow(.privacy)
                    sidebarRow(.general)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            NavigationStack {
                page
                    .navigationDestination(item: $model.selectedPlugin) { id in
                        PluginDetailHost(model: model, id: id)
                    }
            }
        }
        .environment(\.locale, Locale(identifier: model.language))
        .preferredColorScheme(model.settings.theme == "light" ? .light : (model.settings.theme == "dark" ? .dark : nil))
    }

    func sidebarRow(_ page: Page) -> some View {
        Label(page.title(l), systemImage: page.symbol).tag(page)
    }

    @ViewBuilder
    var page: some View {
        switch model.page {
        case .plugins: PluginsPage(model: model)
        case .market: MarketPage(model: model)
        case .shortcuts: ShortcutsPage(model: model)
        case .privacy: PrivacyPage(model: model)
        case .general: GeneralPage(model: model)
        }
    }
}

struct StatusChip: View {
    let text: String
    var tone: Color = .secondary
    var body: some View {
        Text(text).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 2)
            .background(tone.opacity(0.14), in: Capsule())
            .foregroundStyle(tone == .secondary ? Color.secondary : tone)
    }
}

/// System Settings-style app tile: white symbol on a coloured rounded square.
struct PluginIcon: View {
    let id: PluginID
    var size: CGFloat = 32

    var body: some View {
        let (symbol, color) = Self.style(for: id)
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.white))
            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
            .accessibilityHidden(true)
    }

    static func style(for id: PluginID) -> (String, Color) {
        if id.rawValue.contains("clipboard") { return ("list.clipboard.fill", .orange) }
        if id.rawValue.contains("finder") { return ("folder.fill", .blue) }
        let palette: [Color] = [.indigo, .teal, .pink, .green, .purple, .mint]
        let index = id.rawValue.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count
        return ("puzzlepiece.extension.fill", palette[index])
    }
}

// MARK: - Plugins page (PRD §19.3)

struct PluginsPage: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var filter = "all"
    @State private var showAdd = false
    var l: L10n { model.l }

    var body: some View {
        content
            .navigationTitle(l.plugins)
            .searchable(text: $search, placement: .toolbar, prompt: l.searchPlugins)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker(l.t("显示", "Show"), selection: $filter) {
                            Text(l.filterAll).tag("all")
                            Text(l.filterEnabled).tag("enabled")
                            Text(l.filterDisabled).tag("disabled")
                            Text(l.filterAttention).tag("attention")
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(l.t("筛选", "Filter"), systemImage: filter == "all" ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .help(l.t("筛选", "Filter"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Label(l.addSource, systemImage: "plus") }
                        .help(l.addSource)
                }
            }
            .sheet(isPresented: $showAdd) { AddSourceSheet(model: model, isPresented: $showAdd) }
    }

    var filtered: [PluginSummary] {
        model.snapshot.plugins.filter { summary in
            let matchesSearch = search.isEmpty || [summary.displayName, summary.manifest.author ?? "", summary.manifest.source ?? "", summary.id.rawValue]
                .contains { $0.localizedCaseInsensitiveContains(search) }
            let matchesFilter: Bool
            switch filter {
            case "enabled": matchesFilter = summary.status.listGroup == .enabled
            case "disabled": matchesFilter = summary.status.listGroup == .disabled
            case "attention": matchesFilter = summary.status.needsAttention
            default: matchesFilter = true
            }
            return matchesSearch && matchesFilter
        }
    }

    @ViewBuilder
    var content: some View {
        let restorable = (filter == "all" || filter == "disabled") && search.isEmpty ? model.snapshot.restorableDefaults : []
        if model.snapshot.plugins.isEmpty && model.snapshot.restorableDefaults.isEmpty {
            ContentUnavailableView {
                Label(l.noPlugins, systemImage: "puzzlepiece.extension")
            } description: {
                Text(l.noPluginsHint)
            } actions: {
                Button(l.addSource) { showAdd = true }.buttonStyle(.borderedProminent)
            }
        } else if filtered.isEmpty && restorable.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            let enabled = filtered.filter { $0.status.listGroup == .enabled }
            let disabled = filtered.filter { $0.status.listGroup == .disabled }
            Form {
                if !enabled.isEmpty { Section(l.groupEnabled) { ForEach(enabled) { PluginRow(model: model, summary: $0) } } }
                if !disabled.isEmpty { Section(l.groupDisabled) { ForEach(disabled) { PluginRow(model: model, summary: $0) } } }
                if !restorable.isEmpty {
                    Section(l.groupRestorable) {
                        ForEach(restorable) { item in
                            HStack(spacing: 12) {
                                PluginIcon(id: item.id).saturation(0.2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayName)
                                    Text(verbatim: "\(item.version) · \(l.official)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(l.restore) { model.restoreDefault(item.id) }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

struct PluginRow: View {
    @ObservedObject var model: AppModel
    let summary: PluginSummary
    var l: L10n { model.l }

    var body: some View {
        HStack(spacing: 12) {
            PluginIcon(id: summary.id)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.displayName)
                    if summary.status.isDevelopment { StatusChip(text: l.developer, tone: .purple) }
                    if let badge = summary.status.primaryBadge, badge != .noUpdateSource {
                        StatusChip(text: l.badge(badge), tone: summary.status.needsAttention ? .orange : .secondary)
                    }
                }
                if let description = summary.displayDescription {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            // The switch only enables or disables; it never uninstalls (PRD §19.3).
            Toggle("", isOn: Binding(get: { summary.status.activation == .enabled || summary.status.activation == .needsPermission || summary.status.activation == .enabling },
                                     set: { model.setEnabled(summary.id, $0) }))
                .toggleStyle(.switch).labelsHidden()
                .accessibilityLabel("\(summary.displayName), \(l.activation(summary.status.activation))")
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedPlugin = summary.id }
        .accessibilityAction(named: l.openPluginDetail) { model.selectedPlugin = summary.id }
        .contextMenu {
            Button(l.openPluginDetail) { model.selectedPlugin = summary.id }
            Button(summary.status.isInvocable ? l.disablePlugin : l.enablePlugin) { model.setEnabled(summary.id, !summary.status.isInvocable) }
        }
    }
}

/// Resolves the current summary on every update so details never show stale state.
struct PluginDetailHost: View {
    @ObservedObject var model: AppModel
    let id: PluginID

    var body: some View {
        if let summary = model.summary(id) {
            PluginDetailView(model: model, summary: summary)
        } else {
            ContentUnavailableView(model.l.t("插件已卸载", "Plugin Uninstalled"), systemImage: "puzzlepiece.extension")
        }
    }
}
