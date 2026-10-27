import AppKit
import RuyioCore
import RuyioHostKit
import RuyioProtocol
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    init(model: AppModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 760, height: 560)
        window.title = "Ruyio"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("RuyioMainWindow")
        if !window.setFrameUsingName("RuyioMainWindow") { window.center() }
        window.contentView = NSHostingView(rootView: MainView(model: model))
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
            VStack(alignment: .leading, spacing: 0) {
                BrandWordmark().frame(height: 34).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
                List(Page.allCases, selection: Binding(get: { model.page }, set: { if let page = $0 { model.page = page } })) { page in
                    Label(page.title(l), systemImage: page.symbol).tag(page)
                }
                .listStyle(.sidebar)
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    Text(l.tagline)
                    Text(verbatim: "Ruyio \(HostInfo.version)")
                }
                .font(.caption).foregroundStyle(.secondary).padding(16)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 180, max: 230)
        } detail: {
            Group {
                switch model.page {
                case .plugins: PluginsPage(model: model)
                case .market: MarketPage(model: model)
                case .shortcuts: ShortcutsPage(model: model)
                case .privacy: PrivacyPage(model: model)
                case .general: GeneralPage(model: model)
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .environment(\.locale, Locale(identifier: model.language))
        .preferredColorScheme(model.settings.theme == "light" ? .light : (model.settings.theme == "dark" ? .dark : nil))
    }
}

struct BrandWordmark: View {
    var body: some View {
        if let image = Bundle.main.image(forResource: "Wordmark") {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).accessibilityLabel("Ruyio")
        } else {
            Text("Ruyio").font(.system(size: 22, weight: .semibold, design: .rounded))
        }
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            Text(title).font(.system(size: 20, weight: .semibold))
            Spacer()
            trailing
        }
        .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 8)
    }
}

struct StatusChip: View {
    let text: String
    var tone: Color = .secondary
    var body: some View {
        Text(text).font(.caption).padding(.horizontal, 7).padding(.vertical, 2)
            .background(tone.opacity(0.14), in: Capsule()).foregroundStyle(tone == .secondary ? Color.secondary : tone)
    }
}

// MARK: - Plugins page (PRD §19.3)

struct PluginsPage: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var filter = "all"
    var l: L10n { model.l }

    var body: some View {
        if let id = model.selectedPlugin, let summary = model.summary(id) {
            PluginDetailView(model: model, summary: summary)
        } else {
            list
        }
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

    var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: l.plugins) {
                Button(l.addSource) { model.page = .market }.buttonStyle(.borderedProminent)
            }
            HStack {
                TextField(l.searchPlugins, text: $search).textFieldStyle(.roundedBorder)
                Picker("", selection: $filter) {
                    Text(l.filterAll).tag("all")
                    Text(l.filterEnabled).tag("enabled")
                    Text(l.filterDisabled).tag("disabled")
                    Text(l.filterAttention).tag("attention")
                }
                .labelsHidden().fixedSize()
            }
            .padding(.horizontal, 28).padding(.bottom, 8)
            if model.snapshot.plugins.isEmpty && model.snapshot.restorableDefaults.isEmpty {
                VStack(spacing: 8) {
                    Text(l.noPlugins).font(.headline)
                    Text(l.noPluginsHint).foregroundStyle(.secondary)
                    Button(l.addSource) { model.page = .market }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    let enabled = filtered.filter { $0.status.listGroup == .enabled }
                    let disabled = filtered.filter { $0.status.listGroup == .disabled }
                    if !enabled.isEmpty { Section("\(l.groupEnabled) · \(enabled.count)") { ForEach(enabled) { row($0) } } }
                    if !disabled.isEmpty { Section("\(l.groupDisabled) · \(disabled.count)") { ForEach(disabled) { row($0) } } }
                    if !model.snapshot.restorableDefaults.isEmpty && (filter == "all" || filter == "disabled") {
                        Section(l.groupRestorable) {
                            ForEach(model.snapshot.restorableDefaults) { item in
                                HStack {
                                    PluginIcon(id: item.id)
                                    VStack(alignment: .leading) {
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
                .listStyle(.inset)
            }
        }
    }

    func row(_ summary: PluginSummary) -> some View {
        HStack(spacing: 12) {
            PluginIcon(id: summary.id)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.displayName).font(.body.weight(.medium))
                    if let badge = summary.status.primaryBadge, badge != .noUpdateSource {
                        StatusChip(text: l.badge(badge), tone: summary.status.needsAttention ? .orange : .secondary)
                    }
                }
                Text([summary.displayDescription, summary.version.description, summary.isDefault ? l.official : (summary.status.isDevelopment ? l.developer : nil)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            // The switch only enables or disables; it never uninstalls (PRD §19.3).
            Toggle("", isOn: Binding(get: { summary.status.activation == .enabled || summary.status.activation == .needsPermission || summary.status.activation == .enabling },
                                     set: { model.setEnabled(summary.id, $0) }))
                .toggleStyle(.switch).labelsHidden()
                .accessibilityLabel("\(summary.displayName), \(l.activation(summary.status.activation))")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedPlugin = summary.id }
        .contextMenu {
            Button(summary.status.isInvocable ? l.disablePlugin : l.enablePlugin) { model.setEnabled(summary.id, !summary.status.isInvocable) }
            Button(l.uninstall) { model.selectedPlugin = summary.id }
        }
    }
}

struct PluginIcon: View {
    let id: PluginID
    var size: CGFloat = 36
    var body: some View {
        let symbol = id.rawValue.contains("clipboard") ? "doc.on.clipboard" : (id.rawValue.contains("finder") ? "folder" : "puzzlepiece.extension")
        RoundedRectangle(cornerRadius: size * 0.24).fill(Color.accentColor.opacity(0.14)).frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.45)).foregroundStyle(Color.accentColor))
            .accessibilityHidden(true)
    }
}
