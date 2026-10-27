import AppKit
import RuyioCore
import RuyioHostKit
import RuyioProtocol
import RuyioUI
import SwiftUI

/// Plugin details (PRD §19.4): overview, actions & entries, permissions, settings, version.
struct PluginDetailView: View {
    @ObservedObject var model: AppModel
    let summary: PluginSummary
    @State private var tab = 0
    @State private var showUninstall = false
    @State private var showFinderMenu = false
    var l: L10n { model.l }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { model.selectedPlugin = nil } label: { Label(l.plugins, systemImage: "chevron.left") }.buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 14)
            HStack(spacing: 14) {
                PluginIcon(id: summary.id, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.displayName).font(.title2.weight(.semibold))
                    Text([summary.version.description, summary.isDefault ? l.official : nil, l.activation(summary.status.activation)].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { summary.status.isInvocable }, set: { model.setEnabled(summary.id, $0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 28).padding(.vertical, 12)
            Picker("", selection: $tab) {
                Text(l.overview).tag(0)
                Text(l.actionsAndEntries).tag(1)
                Text(l.permissions).tag(2)
                Text(l.settings).tag(3)
                Text(l.version).tag(4)
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 28)
            Divider().padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case 0: overview
                    case 1: actions
                    case 2: permissions
                    case 3: PluginSettingsTab(model: model, summary: summary)
                    default: versionTab
                    }
                    Divider().padding(.top, 20)
                    HStack {
                        Button(summary.status.isInvocable ? l.disablePlugin : l.enablePlugin) { model.setEnabled(summary.id, !summary.status.isInvocable) }
                        Spacer()
                        Button(l.uninstall, role: .destructive) { showUninstall = true }
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .sheet(isPresented: $showUninstall) { UninstallSheet(model: model, summary: summary, isPresented: $showUninstall) }
        .sheet(isPresented: $showFinderMenu) { FinderMenuSheet(model: model, isPresented: $showFinderMenu) }
    }

    var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let description = summary.displayDescription { Text(description) }
            if summary.status.pendingOutcomeCount > 0 {
                HStack {
                    Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                    Text(l.pendingOutcomes)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow { Text(l.status).foregroundStyle(.secondary); Text(l.activation(summary.status.activation)) }
                if let author = summary.manifest.author { GridRow { Text(l.author).foregroundStyle(.secondary); Text(author) } }
                if let source = summary.manifest.source { GridRow { Text(l.source).foregroundStyle(.secondary); Text(source + " " + l.sourceUnverified).textSelection(.enabled) } }
                GridRow { Text(l.signature).foregroundStyle(.secondary); Text(summary.teamID.map { "Team \($0)" } ?? l.t("ad-hoc（开发构建）", "ad-hoc (development build)")) }
                if let error = summary.lastError { GridRow { Text(l.lastError).foregroundStyle(.secondary); Text(l.errorText(error)).foregroundStyle(.orange) } }
            }
        }
    }

    var actions: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(summary.manifest.actions, id: \.id) { action in
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.manifest.actionTitle(action, locale: model.language).text).font(.body.weight(.medium))
                    HStack(spacing: 8) {
                        ForEach(action.presentations, id: \.type) { presentation in
                            EntryToggle(model: model, ref: ActionRef(pluginID: summary.id, actionID: action.id), kind: presentation.kind)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            if summary.manifest.actions.contains(where: { $0.presentation(.finderContextMenu) != nil }) {
                Button(l.manageFinderMenu) { showFinderMenu = true }
            }
        }
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(summary.manifest.permissions, id: \.self) { permission in
                HStack {
                    Text(l.permissionName(permission))
                    Spacer()
                    StatusChip(text: l.enforcement(permission.enforcement))
                }
                if permission.enforcement == .declaredAudited { Text(l.auditedNote).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    var versionTab: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow { Text(l.version).foregroundStyle(.secondary); Text(summary.version.description).font(.system(.body, design: .monospaced)) }
            GridRow {
                Text(l.updateChannel).foregroundStyle(.secondary)
                Text(summary.status.updateChannel == .bundledWithHost ? l.updatesWithHost : (summary.status.updateChannel == .none ? l.noUpdateSource : summary.status.updateChannel.rawValue))
            }
            GridRow { Text("ID").foregroundStyle(.secondary); Text(summary.id.rawValue).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
        }
    }
}

struct EntryToggle: View {
    @ObservedObject var model: AppModel
    let ref: ActionRef
    let kind: PresentationKind
    @State private var visible = true

    var body: some View {
        let l = model.l
        let label: String = switch kind {
        case .commandPalette: l.commandPalette
        case .globalHotkey: l.hotkey + " " + (model.snapshot.entries.hotkeys.first { $0.ref == ref }?.shortcut?.displayString ?? l.notSet)
        case .finderContextMenu: l.finder
        case .menuBar: l.menuBar
        }
        Button {
            if kind == .globalHotkey { model.page = .shortcuts; return }
            visible.toggle()
            Task { try? await model.engine.registry.setEntryVisible(ref, kind: kind, visible: visible) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: visible ? "checkmark.circle.fill" : "circle")
                Text(label)
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("\(label), \(visible ? l.enabledState : l.notEnabled)")
        .task { visible = await model.engine.registry.isEntryVisible(ref, kind: kind) }
    }
}

struct UninstallSheet: View {
    @ObservedObject var model: AppModel
    let summary: PluginSummary
    @Binding var isPresented: Bool
    @State private var deleteData = false
    @State private var plan: HostEngine.UninstallPlan?
    var l: L10n { model.l }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l.uninstallTitle(summary.displayName)).font(.headline)
            Text(l.uninstallMessage(plan?.entryCount ?? 0, running: plan?.isRunning ?? false)).fixedSize(horizontal: false, vertical: true)
            if let plan { Text(l.dataSummary(plan.documentCount, plan.dataBytes)).foregroundStyle(.secondary) }
            Toggle(l.deleteData, isOn: $deleteData)
            Text(l.containerNote).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                // Focus stays on the safe action (PRD §18.3).
                Button(l.cancel) { isPresented = false }.keyboardShortcut(.cancelAction)
                Button(l.uninstall, role: .destructive) {
                    isPresented = false
                    model.uninstall(summary.id, deleteData: deleteData)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .task { plan = await model.engine.uninstallPlan(summary.id) }
    }
}

/// Reorder within a plugin group and reorder groups; never move an action into another plugin (PRD §19.4).
struct FinderMenuSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    var l: L10n { model.l }

    var body: some View {
        let groups = model.snapshot.entries.finder
        VStack(alignment: .leading, spacing: 12) {
            Text(l.manageFinderMenu.replacingOccurrences(of: "…", with: "")).font(.headline)
            List {
                Text("Ruyio ›").foregroundStyle(.secondary)
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    Section {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { itemIndex, item in
                            HStack {
                                Text(item.title)
                                Spacer()
                                Toggle("", isOn: Binding(get: { item.visible }, set: { value in
                                    Task { try? await model.engine.registry.setEntryVisible(item.ref, kind: .finderContextMenu, visible: value) }
                                })).labelsHidden()
                                Button { move(group, itemIndex, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(itemIndex == 0)
                                    .help(l.moveUp).accessibilityLabel(l.moveUp)
                                Button { move(group, itemIndex, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(itemIndex == group.items.count - 1)
                                    .help(l.moveDown).accessibilityLabel(l.moveDown)
                            }
                        }
                    } header: {
                        HStack {
                            Text(group.title)
                            Spacer()
                            Button { moveGroup(index, -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(index == 0).accessibilityLabel(l.moveUp)
                            Button { moveGroup(index, 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).disabled(index == groups.count - 1).accessibilityLabel(l.moveDown)
                        }
                    }
                }
            }
            .frame(minHeight: 300)
            HStack {
                Button(l.restoreDefaultLayout) { Task { try? await model.engine.registry.resetFinderLayout() } }
                Spacer()
                Button(l.done) { isPresented = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }

    func move(_ group: FinderGroupEntry, _ index: Int, _ delta: Int) {
        var ids = group.items.map(\.ref.actionID)
        let target = index + delta
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        Task { try? await model.engine.registry.setFinderOrder(pluginID: group.pluginID, actionIDs: ids) }
    }

    func moveGroup(_ index: Int, _ delta: Int) {
        var ids = model.snapshot.entries.finder.map(\.pluginID)
        let target = index + delta
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        Task { try? await model.engine.registry.setFinderGroupOrder(ids) }
    }
}

/// Settings tab: host-rendered plugin settings view; disabled plugins are read-only and never started (R13).
struct PluginSettingsTab: View {
    @ObservedObject var model: AppModel
    let summary: PluginSummary
    @StateObject private var holder = SettingsHolder()
    var l: L10n { model.l }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if summary.id.rawValue == "app.ruyio.finder-essentials" {
                let editor = model.engine.pluginSettings(summary.id)["app.editor"]?.stringValue
                HStack {
                    Text(l.t("编辑器", "Editor"))
                    Spacer()
                    Text(editor ?? l.notSet).foregroundStyle(.secondary)
                    Button("…") {
                        Task {
                            if let id = await SystemBridgeImpl().chooseApplication(role: "editor") {
                                try? await model.engine.setPluginSetting(summary.id, key: "app.editor", value: .string(id))
                                model.objectWillChange.send()
                            }
                        }
                    }
                }
                HStack { Text(l.t("终端", "Terminal")); Spacer(); Text("Terminal").foregroundStyle(.secondary) }
            }
            if summary.manifest.views.contains(where: { $0.placement == .settings }) {
                if !summary.status.isInvocable {
                    Text(l.settingsNeedEnable).foregroundStyle(.secondary)
                } else if let context = holder.context {
                    SchemaNodeView(node: context.document.root, context: context).frame(minHeight: 360)
                } else {
                    ProgressView()
                }
            } else if summary.id.rawValue != "app.ruyio.finder-essentials" {
                Text(l.noSettings).foregroundStyle(.secondary)
            }
        }
        .task(id: summary.status.isInvocable) {
            guard summary.status.isInvocable, let view = summary.manifest.views.first(where: { $0.placement == .settings }) else { return }
            await holder.open(model: model, pluginID: summary.id, viewID: view.id)
        }
        .onDisappear { holder.close(model: model) }
    }
}

@MainActor
final class SettingsHolder: ObservableObject {
    @Published var context: SchemaContext?
    private var opened: (PluginID, String)?

    func open(model: AppModel, pluginID: PluginID, viewID: String) async {
        guard opened == nil else { return }
        do {
            let document = try await model.engine.openView(pluginID: pluginID, viewID: viewID)
            opened = (pluginID, viewID)
            let l = model.l
            let engine = model.engine
            context = SchemaContext(pluginID: pluginID, document: document,
                                    strings: SchemaStrings(submit: l.done, cancel: l.cancel, undo: "", loading: "", choose: "…"),
                                    sendEvent: { [weak self] event, revision in
                                        guard let reply = try? await engine.viewEvent(pluginID: pluginID, viewID: viewID, revision: revision, event: event) else { return }
                                        await MainActor.run {
                                            if let document = reply.document { self?.context?.apply(document) }
                                            switch reply.effect {
                                            case .notice(let text): model.show(text)
                                            case .confirm(let spec):
                                                let alert = NSAlert()
                                                alert.messageText = spec.title
                                                alert.informativeText = spec.message
                                                alert.addButton(withTitle: l.cancel)
                                                alert.addButton(withTitle: spec.confirmTitle).hasDestructiveAction = spec.isDestructive
                                                if alert.runModal() == .alertSecondButtonReturn {
                                                    self?.context?.send(.invoke(actionID: spec.confirmActionID, itemID: nil))
                                                }
                                            default: break
                                            }
                                        }
                                    },
                                    loadBlob: { _ in nil })
        } catch {
            context = nil
        }
    }

    func close(model: AppModel) {
        guard let (pluginID, viewID) = opened else { return }
        opened = nil
        Task { await model.engine.closeView(pluginID: pluginID, viewID: viewID) }
    }
}
