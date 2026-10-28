import AppKit
import RuyioCore
import RuyioHostKit
import RuyioProtocol
import RuyioSourceTransport
import RuyioUI
import SwiftUI

/// Plugin details (PRD §19.4) as System Settings-style grouped sections; pushed onto the main
/// window's navigation stack, so the toolbar shows the native back button.
struct PluginDetailView: View {
    @ObservedObject var model: AppModel
    let summary: PluginSummary
    @State private var showUninstall = false
    @State private var showFinderMenu = false
    @State private var showSettings = false
    var l: L10n { model.l }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    PluginIcon(id: summary.id, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.displayName).font(.title2.weight(.semibold))
                        Text([summary.version.description, summary.isDefault ? l.official : nil, l.activation(summary.status.activation)].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { summary.status.isInvocable }, set: { model.setEnabled(summary.id, $0) }))
                        .toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(summary.status.isInvocable ? l.disablePlugin : l.enablePlugin)
                }
                .padding(.vertical, 4)
                if let description = summary.displayDescription { Text(description).foregroundStyle(.secondary) }
            }
            if summary.status.pendingOutcomeCount > 0 {
                Section {
                    Label(l.pendingOutcomes, systemImage: "questionmark.circle.fill").foregroundStyle(.orange)
                    HStack {
                        Button(l.t("在 Finder 中查看", "Show in Finder")) {
                            let urls = model.engine.pendingOutcomeLocations(summary.id)
                            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                        }
                        Button(l.markResolved) { Task { await model.engine.markOutcomesResolved(summary.id) } }
                    }
                }
            }
            Section(l.overview) {
                LabeledContent(l.status, value: l.activation(summary.status.activation))
                if let author = summary.manifest.author { LabeledContent(l.author, value: author) }
                if let source = summary.manifest.source {
                    LabeledContent(l.source) {
                        Text(source + " " + l.sourceUnverified).textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent(l.signature, value: summary.teamID.map { "Team \($0)" } ?? l.t("ad-hoc（开发构建）", "ad-hoc (development build)"))
                if let error = summary.lastError {
                    LabeledContent(l.lastError) { Text(l.errorText(error)).foregroundStyle(.orange).multilineTextAlignment(.trailing) }
                }
            }
            Section(l.actionsAndEntries) {
                ForEach(summary.manifest.actions, id: \.id) { action in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary.manifest.actionTitle(action, locale: model.language).text)
                            .fixedSize(horizontal: false, vertical: true)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(action.presentations, id: \.type) { presentation in
                                EntryToggle(model: model, ref: ActionRef(pluginID: summary.id, actionID: action.id), kind: presentation.kind)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
                if summary.manifest.actions.contains(where: { $0.presentation(.finderContextMenu) != nil }) {
                    Button(l.manageFinderMenu) { showFinderMenu = true }
                }
            }
            if !summary.manifest.permissions.isEmpty {
                Section(l.permissions) {
                    ForEach(summary.manifest.permissions, id: \.self) { permission in
                        LabeledContent {
                            StatusChip(text: l.enforcement(permission.enforcement))
                        } label: {
                            Text(l.permissionName(permission))
                            if permission.enforcement == .declaredAudited { Text(l.auditedNote) }
                        }
                    }
                }
            }
            Section(l.settings) {
                PluginSettingsRows(model: model, summary: summary, showSettings: $showSettings)
            }
            Section(l.version) {
                UpdateSection(model: model, summary: summary)
            }
            Section {
                HStack {
                    Button(summary.status.isInvocable ? l.disablePlugin : l.enablePlugin) { model.setEnabled(summary.id, !summary.status.isInvocable) }
                    Spacer()
                    Button(l.uninstall, role: .destructive) { showUninstall = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(summary.displayName)
        .sheet(isPresented: $showUninstall) { UninstallSheet(model: model, summary: summary, isPresented: $showUninstall) }
        .sheet(isPresented: $showFinderMenu) { FinderMenuSheet(model: model, isPresented: $showFinderMenu) }
        .sheet(isPresented: $showSettings) { PluginSettingsSheet(model: model, summary: summary, isPresented: $showSettings) }
    }
}

/// Version section with check / update (PRD §19.11): differences are shown before the user confirms.
struct UpdateSection: View {
    @ObservedObject var model: AppModel
    let summary: PluginSummary
    @State private var checking = false
    @State private var available: HostEngine.AvailableUpdate?
    @State private var checked = false
    @State private var working = false
    @State private var result: String?
    @State private var olderReleases: [PluginDescriptor.Release] = []
    @State private var source: (PluginDescriptor, URL)?
    var l: L10n { model.l }

    var body: some View {
        Group {
            LabeledContent(l.version) { Text(summary.version.description).monospacedDigit() }
            LabeledContent(l.updateChannel, value: summary.status.updateChannel == .bundledWithHost ? l.updatesWithHost
                           : (summary.status.updateChannel == .none ? l.noUpdateSource : summary.status.updateChannel.rawValue))
            LabeledContent("ID") { Text(summary.id.rawValue).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            HStack(spacing: 8) {
                Button(l.t("检查更新", "Check for Update")) { check() }.disabled(checking || working || summary.status.updateChannel == .none)
                if checking || working { ProgressView().controlSize(.small) }
                Spacer()
                if let available {
                    Button(l.t("更新…", "Update…")) { update(available) }.buttonStyle(.borderedProminent).disabled(working)
                }
            }
            if let available {
                Text(l.t("发现新版本 \(available.version)", "Version \(available.version) is available"))
                    .fixedSize(horizontal: false, vertical: true)
            } else if checked {
                Text(l.t("已是最新版本", "Up to date")).foregroundStyle(.secondary)
            }
            if canChangeSource || !olderReleases.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { sourceActions }
                    VStack(alignment: .leading, spacing: 10) { sourceActions }
                }
            }
            if let result { Text(result).font(.callout).foregroundStyle(.secondary) }
        }
        .task(id: summary.version) {
            available = model.engine.availableUpdate(summary.id)
            if let (descriptor, url) = await model.engine.sourceDescriptor(summary.id) {
                olderReleases = descriptor.releases.filter { $0.version < summary.version }.sorted { $0.version > $1.version }
                source = (descriptor, url)
            }
        }
        .onChange(of: summary.status.update) { _, state in
            if state == .available { available = model.engine.availableUpdate(summary.id) }
        }
    }

    private var canChangeSource: Bool {
        summary.status.updateChannel == .descriptor || summary.status.updateChannel == .market
    }

    @ViewBuilder
    private var sourceActions: some View {
        if canChangeSource {
            Button(l.t("更换来源…", "Change Source…")) { changeSource() }
                .fixedSize().disabled(working)
        }
        if !olderReleases.isEmpty {
            Menu(l.t("安装其他版本…", "Install Another Version…")) {
                ForEach(olderReleases, id: \.version) { release in
                    Button(release.version.description) { downgrade(release) }
                }
            }
            .fixedSize().disabled(working)
        }
    }

    /// Same-identity source switch (R08): verified first, then only the binding changes.
    func changeSource() {
        let alert = NSAlert()
        alert.messageText = l.t("更换来源", "Change Source")
        alert.informativeText = l.t("输入同一插件的另一个描述文件地址。只有发布者签名一致时才会更换，代码、数据和权限保持不变。",
                                    "Enter another descriptor address for the same plugin. The source changes only if the publisher signature matches; code, data and permissions stay as they are.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://"
        alert.accessoryView = field
        alert.addButton(withTitle: l.resolve)
        alert.addButton(withTitle: l.cancel)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let resolved = try await model.engine.markets.resolve(field.stringValue)
                try await model.engine.switchSource(summary.id, to: resolved)
                available = nil
                checked = false
                olderReleases = []
                source = nil
                result = l.t("来源已更换。", "Source changed.")
            } catch let error as RuyioError {
                result = l.errorText(error) + (error.diagnostic.map { " (\($0))" } ?? "")
            } catch {
                result = error.localizedDescription
            }
        }
    }

    /// Publisher changed (R08 / DIST-07): two confirmed steps, new data partition, nothing carried over.
    func reinstallAcrossIdentity(_ preview: InstallPreview) {
        let first = NSAlert()
        first.messageText = l.t("发布者身份已变化", "The publisher identity changed")
        first.informativeText = l.t("这不是普通更新。第 1 步：卸载当前插件，其数据保留并仍归原发布者；第 2 步：按新身份安装，使用全新的数据和权限确认。旧数据不会交给新发布者。",
                                    "This is not a normal update. Step 1 uninstalls the current plugin and keeps its data under the original publisher. Step 2 installs the new identity with fresh data and permission confirmation. Old data is never handed to the new publisher.")
        first.addButton(withTitle: l.cancel)
        first.addButton(withTitle: l.t("第 1 步：卸载旧身份", "Step 1: Uninstall Current"))
        guard first.runModal() == .alertSecondButtonReturn else { model.engine.installer.discard(preview); return }
        Task {
            // Freeze the verified source before uninstall removes its registry record.
            guard let previous = await model.engine.registry.record(summary.id) else {
                model.engine.installer.discard(preview)
                result = l.errorText(RuyioError(.pluginNotFound))
                return
            }
            do {
                try await model.engine.validateInstallSource(updateChannel: previous.updateChannel, source: previous.source)
                try await model.engine.uninstall(summary.id, deleteData: false)
            } catch let error as RuyioError {
                result = l.errorText(error)
                model.engine.installer.discard(preview)
                return
            } catch {
                result = error.localizedDescription
                model.engine.installer.discard(preview)
                return
            }
            let second = NSAlert()
            second.messageText = l.t("第 2 步：按新身份安装？", "Step 2: Install the new identity?")
            second.informativeText = l.t("权限：", "Permissions: ") + preview.manifest.permissions.map { l.permissionName($0) }.joined(separator: "、")
                + "\nTeam: " + (preview.signing.teamID ?? "—")
            second.addButton(withTitle: l.cancel)
            second.addButton(withTitle: l.t("安装", "Install"))
            guard second.runModal() == .alertSecondButtonReturn else {
                model.engine.installer.discard(preview)
                model.show(l.t("旧版本已卸载，数据保留。可以从插件页或原来源重新安装。", "The old version was uninstalled and its data kept. Reinstall it from Plugins or its original source."))
                return
            }
            do {
                let id = try await model.engine.commitInstall(preview, updateChannel: previous.updateChannel, source: previous.source, dataChoice: .fresh)
                model.selectedPlugin = id
            } catch let error as RuyioError {
                // A failed second step leaves the plugin uninstalled; it never claims to be restored.
                model.engine.installer.discard(preview)
                model.show(l.t("新身份安装失败，旧版本保持已卸载、数据保留：", "Installing the new identity failed; the old version stays uninstalled with its data kept: ") + l.errorText(error))
            } catch {
                model.engine.installer.discard(preview)
                model.show(l.t("新身份安装失败，旧版本保持已卸载、数据保留：", "Installing the new identity failed; the old version stays uninstalled with its data kept: ") + error.localizedDescription)
            }
        }
    }

    /// Older versions need a data decision; only choices compatible with the target are offered (R16).
    func downgrade(_ release: PluginDescriptor.Release) {
        guard let (descriptor, url) = source else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await model.engine.validateUpdateSource(summary.id)
                let binding = await model.engine.registry.record(summary.id)?.source
                let marketID = binding?.hasPrefix("market:") == true ? binding.map { String($0.dropFirst(7)) } : nil
                let preview = try await model.engine.markets.prepareInstall(descriptor: descriptor, descriptorURL: url, release: release, marketID: marketID)
                guard preview.isInstallable else {
                    result = l.errorText(RuyioError(.sourceInvalid, diagnostic: preview.failureSummary))
                    model.engine.installer.discard(preview)
                    return
                }
                let choices = await model.engine.updater.downgradeChoices(for: preview)
                let alert = NSAlert()
                alert.messageText = l.t("安装旧版本 \(release.version)？", "Install older version \(release.version)?")
                alert.informativeText = l.t("当前数据会保留在磁盘上，可随时恢复。旧版本之后的记录不会出现在快照中。", "Current data stays on disk for recovery. Records created after a snapshot will not appear in it.")
                for choice in choices {
                    switch choice {
                    case .keepCurrent: alert.addButton(withTitle: l.t("保留当前数据", "Keep Current Data"))
                    case .snapshot(_, let date): alert.addButton(withTitle: l.t("使用 \(date.formatted(date: .abbreviated, time: .shortened)) 的快照", "Use Snapshot from \(date.formatted(date: .abbreviated, time: .shortened))"))
                    case .fresh: alert.addButton(withTitle: l.t("新建空数据", "Start with Empty Data"))
                    }
                }
                alert.addButton(withTitle: l.cancel)
                let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                guard index >= 0, index < choices.count else { model.engine.installer.discard(preview); return }
                switch await model.engine.updater.downgrade(with: preview, data: choices[index]) {
                case .completed(let version): result = l.t("已切换到 \(version)", "Switched to \(version)")
                case .rolledBack(let still, let error): result = l.t("未完成，仍在使用 \(still)。", "Not completed; still using \(still). ") + l.errorText(error)
                case .committedWithRuntimeError(let version, let error): result = l.t("已切换到 \(version)，但运行异常。", "Switched to \(version) but it failed to run. ") + l.errorText(error)
                }
            } catch let error as RuyioError {
                result = l.errorText(error)
            } catch {
                result = error.localizedDescription
            }
        }
    }

    func check() {
        checking = true
        Task {
            switch await model.engine.checkForUpdateResult(summary.id) {
            case .available(let update):
                available = update
                checked = true
                result = nil
            case .upToDate:
                available = nil
                checked = true
                result = nil
            case .unavailable(let error):
                checked = false
                result = l.t("检查更新失败：", "Could not check for updates: ") + l.errorText(error)
            }
            checking = false
        }
    }

    func update(_ update: HostEngine.AvailableUpdate) {
        working = true
        result = nil
        Task {
            defer { working = false }
            do {
                let preview = try await model.engine.prepareUpdate(update)
                guard preview.isInstallable else {
                    result = l.errorText(RuyioError(.sourceInvalid, diagnostic: preview.failureSummary))
                    model.engine.installer.discard(preview)
                    return
                }
                let diff = await model.engine.updater.diff(for: preview)
                let alert = NSAlert()
                alert.messageText = l.t("更新到 \(preview.manifest.version)？", "Update to \(preview.manifest.version)?")
                var lines = [l.t("当前版本 \(summary.version)", "Current version \(summary.version)")]
                if let diff, !diff.addedPermissions.isEmpty {
                    lines.append(l.t("新增权限：", "New permissions: ") + diff.addedPermissions.map { l.permissionName($0) }.joined(separator: "、"))
                }
                if diff?.signerChanged == true {
                    reinstallAcrossIdentity(preview)
                    return
                }
                alert.informativeText = lines.joined(separator: "\n")
                alert.addButton(withTitle: l.cancel)
                alert.addButton(withTitle: l.t("更新", "Update"))
                guard alert.runModal() == .alertSecondButtonReturn else { model.engine.installer.discard(preview); return }
                switch await model.engine.updater.update(with: preview) {
                case .completed(let version):
                    result = l.t("已更新到 \(version)", "Updated to \(version)")
                    available = nil
                case .rolledBack(let still, let error):
                    result = l.t("更新失败，已恢复，仍在使用 \(still)。", "Update failed and was rolled back; still using \(still). ") + l.errorText(error)
                case .committedWithRuntimeError(let version, let error):
                    result = l.t("更新已提交（\(version)），但运行异常；新数据已保留。", "Update to \(version) was committed but the plugin failed to run; new data was kept. ") + l.errorText(error)
                }
            } catch let error as RuyioError {
                result = l.errorText(error)
            } catch {
                result = error.localizedDescription
            }
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
            if kind == .globalHotkey { model.selectedPlugin = nil; model.page = .shortcuts; return }
            visible.toggle()
            Task { try? await model.engine.registry.setEntryVisible(ref, kind: kind, visible: visible) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: visible ? "checkmark" : "plus").font(.caption2.weight(.bold))
                Text(label).fixedSize(horizontal: true, vertical: false)
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(visible ? .accentColor : nil)
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

/// Settings rows inside the detail page. Plugin-rendered settings open in a sheet so their form is
/// never nested inside the host form; disabled plugins are read-only and never started (R13).
struct PluginSettingsRows: View {
    @ObservedObject var model: AppModel
    let summary: PluginSummary
    @Binding var showSettings: Bool
    var l: L10n { model.l }

    var body: some View {
        if summary.id.rawValue == "app.ruyio.finder-essentials" {
            let editor = model.engine.pluginSettings(summary.id)["app.editor"]?.stringValue
            LabeledContent(l.t("编辑器", "Editor")) {
                HStack {
                    Text(editor ?? l.notSet).foregroundStyle(.secondary)
                    Button(l.t("选择…", "Choose…")) {
                        Task {
                            if let id = await SystemBridgeImpl().chooseApplication(role: "editor") {
                                do { try await model.engine.setPluginSetting(summary.id, key: "app.editor", value: .string(id)) }
                                catch let error as RuyioError { model.show(l.errorText(error)) }
                                catch { model.show(error.localizedDescription) }
                                model.objectWillChange.send()
                            }
                        }
                    }
                }
            }
            LabeledContent(l.t("终端", "Terminal"), value: "Terminal")
        }
        if summary.manifest.views.contains(where: { $0.placement == .settings }) {
            if summary.status.isInvocable {
                Button(l.t("插件设置…", "Plugin Settings…")) { showSettings = true }
            } else {
                Text(l.settingsNeedEnable).foregroundStyle(.secondary)
            }
        } else if summary.id.rawValue != "app.ruyio.finder-essentials" {
            Text(l.noSettings).foregroundStyle(.secondary)
        }
    }
}

struct PluginSettingsSheet: View {
    @ObservedObject var model: AppModel
    let summary: PluginSummary
    @Binding var isPresented: Bool
    #if DEBUG
    var galleryDocument: ViewDocument? = nil
    var galleryError: String? = nil
    #endif
    @StateObject private var holder = SettingsHolder()
    var l: L10n { model.l }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PluginIcon(id: summary.id, size: 24)
                Text(summary.displayName).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 18)
            if let error = holder.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if holder.canRetry {
                        Button(l.retry) { Task { await holder.retry(model: model, pluginID: summary.id, viewID: settingsViewID) } }
                    }
                }
                .font(.callout).padding()
            }
            Group {
                if let context = holder.context {
                    SchemaNodeView(node: context.document.root, context: context)
                        .disabled(context.isBusy)
                } else if holder.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            HStack {
                Spacer()
                Button(l.t("关闭", "Close")) { isPresented = false }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 560)
        .task {
            #if DEBUG
            if model.isGallery {
                if let galleryDocument {
                    holder.context = SchemaContext(pluginID: summary.id, document: galleryDocument,
                                                   strings: SchemaStrings(submit: l.done, cancel: l.cancel, undo: "", loading: "", choose: "…"),
                                                   sendEvent: { _, _ in }, loadBlob: { _ in nil })
                }
                holder.error = galleryError
                return
            }
            #endif
            guard summary.status.isInvocable, let viewID = settingsViewID else { return }
            await holder.open(model: model, pluginID: summary.id, viewID: viewID)
        }
        .onChange(of: holder.wantsClose) { _, close in if close { isPresented = false } }
        .onDisappear { holder.close(model: model) }
    }

    private var settingsViewID: String? { summary.manifest.views.first { $0.placement == .settings }?.id }
}

@MainActor
final class SettingsHolder: ObservableObject {
    @Published var context: SchemaContext?
    @Published var error: String?
    @Published var isLoading = false
    @Published var wantsClose = false
    private var opened: (PluginID, String)?
    private var subscription: UUID?
    private var pendingDocument: ViewDocument?
    private var generation = UUID()
    private var lifecycleTask: Task<Void, Never>?
    private var pendingSubmission: [String: JSONValue]?

    var canRetry: Bool { !isLoading && context == nil }

    func open(model: AppModel, pluginID: PluginID, viewID: String) async {
        close(model: model)
        let ticket = generation
        let previous = lifecycleTask
        error = nil
        wantsClose = false
        isLoading = true
        let task = Task {
            await previous?.value
            guard generation == ticket else { return }
            await load(model: model, pluginID: pluginID, viewID: viewID, ticket: ticket)
        }
        lifecycleTask = task
        await task.value
    }

    private func load(model: AppModel, pluginID: PluginID, viewID: String, ticket: UUID) async {
        defer { if generation == ticket { isLoading = false } }
        subscription = model.viewUpdates.observe(pluginID: pluginID, viewID: viewID) { [weak self] document in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                if let context = self.context { context.apply(document) }
                else if document.revision >= (self.pendingDocument?.revision ?? Int.min) { self.pendingDocument = document }
            }
        }
        do {
            let document = try await model.engine.openView(pluginID: pluginID, viewID: viewID)
            guard generation == ticket else {
                await model.engine.closeView(pluginID: pluginID, viewID: viewID)
                return
            }
            opened = (pluginID, viewID)
            let l = model.l
            let engine = model.engine
            context = SchemaContext(pluginID: pluginID, document: document,
                                    strings: SchemaStrings(submit: l.done, cancel: l.cancel, undo: "", loading: "", choose: "…"),
                                    sendEvent: { [weak self] event, revision in
                                        await self?.send(event, revision: revision, model: model, ticket: ticket)
                                    },
                                    loadBlob: { blob in await OverlayController.loadBlob(engine: engine, pluginID: pluginID, blobID: blob) })
            if let pendingDocument { context?.apply(pendingDocument); self.pendingDocument = nil }
        } catch {
            guard generation == ticket else { return }
            if let subscription { model.viewUpdates.remove(subscription) }
            subscription = nil
            pendingDocument = nil
            context = nil
            self.error = (error as? RuyioError).map(model.l.errorText) ?? error.localizedDescription
        }
    }

    private func send(_ event: ViewEvent, revision: Int, model: AppModel, ticket: UUID) async {
        guard generation == ticket, let (pluginID, viewID) = opened, context?.isBusy != true else { return }
        context?.isBusy = true
        error = nil
        if case .submit(let values) = event { pendingSubmission = values }
        defer { if generation == ticket { context?.isBusy = false } }
        do {
            let reply = try await model.engine.viewEvent(pluginID: pluginID, viewID: viewID, revision: revision, event: event)
            guard generation == ticket else { return }
            if let document = reply.document { context?.apply(document) }
            switch reply.effect {
            case .none, .notice, .close:
                if let values = pendingSubmission {
                    context?.acknowledgeSubmission(values, document: reply.document)
                    pendingSubmission = nil
                }
            default: break
            }
            switch reply.effect {
            case .notice(let text): model.show(text)
            case .close: wantsClose = true
            case .confirm(let spec):
                switch event { case .submit, .invoke: break; default: return }
                let alert = NSAlert()
                alert.messageText = spec.title
                alert.informativeText = model.l.fromPlugin(model.summary(pluginID)?.displayName ?? pluginID.rawValue) + "\n\n" + spec.message
                alert.addButton(withTitle: model.l.cancel)
                alert.addButton(withTitle: spec.confirmTitle).hasDestructiveAction = spec.isDestructive
                if alert.runModal() == .alertSecondButtonReturn {
                    context?.isBusy = false
                    await send(.invoke(actionID: spec.confirmActionID, itemID: nil), revision: context?.document.revision ?? revision, model: model, ticket: ticket)
                } else { pendingSubmission = nil }
            default: break
            }
        } catch {
            guard generation == ticket else { return }
            self.error = (error as? RuyioError).map(model.l.errorText) ?? error.localizedDescription
            pendingSubmission = nil
        }
    }

    func retry(model: AppModel, pluginID: PluginID, viewID: String?) async {
        if context == nil, let viewID {
            await open(model: model, pluginID: pluginID, viewID: viewID)
        }
    }

    func close(model: AppModel) {
        generation = UUID()
        if let subscription { model.viewUpdates.remove(subscription) }
        subscription = nil
        pendingDocument = nil
        let opened = opened
        self.opened = nil
        context = nil
        isLoading = false
        pendingSubmission = nil
        if let (pluginID, viewID) = opened {
            let previous = lifecycleTask
            lifecycleTask = Task {
                await previous?.value
                await model.engine.closeView(pluginID: pluginID, viewID: viewID)
            }
        }
    }
}
