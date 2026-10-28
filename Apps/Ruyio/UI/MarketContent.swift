import AppKit
import RuyioCore
import RuyioHostKit
import RuyioPersistence
import RuyioSourceTransport
import SwiftUI

/// Discover (aggregated enabled markets) and Sources (per-market management) — interaction §8.
struct MarketContent: View {
    @ObservedObject var model: AppModel
    @Binding var showAdd: Bool
    @Binding var tab: Int
    @State private var markets: [MarketRecord] = []
    @State private var entries: [MarketEntryState] = []
    @State private var search = ""
    @State private var openMarket: String?
    @State private var refreshingID: String?
    @State private var detail: MarketEntryState?
    var l: L10n { model.l }

    var body: some View {
        Group {
            if markets.isEmpty {
                ContentUnavailableView {
                    Label(l.marketEmpty, systemImage: "square.grid.2x2")
                } description: {
                    Text(l.marketEmptyHint)
                } actions: {
                    Button(l.addMarket) { showAdd = true }.buttonStyle(.borderedProminent)
                }
            } else if tab == 0 {
                discover
                    .searchable(text: $search, placement: .toolbar, prompt: l.t("搜索所有已启用市场", "Search enabled markets"))
            } else {
                sources
            }
        }
        .task(id: showAdd) { await reload() }
        .sheet(item: $detail) { entry in MarketPluginSheet(model: model, entry: entry) { detail = nil } }
    }

    func reload() async {
        markets = await model.engine.markets.markets()
        var all: [MarketEntryState] = []
        for market in markets where (openMarket == market.marketID || (openMarket == nil && market.enabled)) {
            all += await model.engine.markets.entries(market.marketID, load: 30)
        }
        entries = all
    }

    @ViewBuilder
    var discover: some View {
        // Same plugin from several markets is grouped, but publisher identity is only known after
        // the signed package is verified (plan §14.3), so sources are listed, not merged.
        let grouped = Dictionary(grouping: entries.filter { matches($0) }, by: \.id)
        if grouped.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            Form {
                if markets.contains(where: { $0.state == "stale" }) || openMarket != nil {
                    Section {
                        if markets.contains(where: { $0.state == "stale" }) {
                            Label(l.t("部分市场刷新失败，正在显示上次成功的缓存。", "Some markets failed to refresh; showing the last good cache."),
                                  systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        if let openMarket {
                            LabeledContent(l.t("只看此市场", "Showing one market"), value: openMarket)
                            Button(l.t("显示全部市场", "Show All Markets")) { self.openMarket = nil; Task { await reload() } }
                        }
                    }
                }
                Section {
                    ForEach(grouped.keys.sorted(), id: \.self) { id in
                        let variants = grouped[id] ?? []
                        let entry = variants[0]
                        HStack(spacing: 12) {
                            PluginIcon(id: id)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.descriptor?.name ?? entry.hintName ?? id.rawValue)
                                Text(entry.descriptor?.description ?? entry.hintSummary ?? id.rawValue).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(variants.map(\.marketID).joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            StatusChip(text: status(entry), tone: entry.hasUpdate ? .accentColor : .secondary)
                            Button(l.t("查看", "View")) { detail = entry }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    func matches(_ entry: MarketEntryState) -> Bool {
        search.isEmpty || [entry.id.rawValue, entry.descriptor?.name ?? "", entry.hintName ?? "", entry.descriptor?.description ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(search) }
    }

    func status(_ entry: MarketEntryState) -> String {
        if entry.rollbackWarning { return l.t("来源版本回退", "Rolled back") }
        if entry.load == .pending { return l.t("待加载", "Not loaded") }
        if entry.load == .failed { return l.t("加载失败", "Failed") }
        if entry.hasUpdate { return l.t("可更新", "Update") }
        if entry.isInstalled { return l.t("已安装", "Installed") }
        return l.t("未安装", "Not installed")
    }

    var sources: some View {
        Form {
            Section {
                ForEach(markets, id: \.marketID) { market in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.gray.gradient).frame(width: 32, height: 32)
                            .overlay(Image(systemName: "square.grid.2x2.fill").font(.system(size: 15)).foregroundStyle(.white))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(market.name)
                            Text(URL(string: market.canonicalURL)?.host.map { $0 + (URL(string: market.canonicalURL)?.path ?? "") } ?? market.canonicalURL)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(sourceStatus(market)).font(.caption).foregroundStyle(market.state == "active" ? Color.secondary : .orange)
                        }
                        Spacer()
                        if refreshingID == market.marketID { ProgressView().controlSize(.small) }
                        Menu {
                            Button(l.t("刷新", "Refresh")) { refresh(market.marketID) }
                            Button(market.enabled ? l.t("停用", "Disable") : l.t("启用", "Enable")) {
                                Task { try? await model.engine.markets.setEnabled(market.marketID, !market.enabled); await reload() }
                            }
                            Button(l.t("只看此市场", "Browse This Market")) { openMarket = market.marketID; tab = 0; Task { await reload() } }
                            Button(l.t("复制来源地址", "Copy Source Address")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(market.inputURL, forType: .string)
                            }
                            Divider()
                            Button(l.t("移除…", "Remove…"), role: .destructive) { remove(market) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
    }

    func sourceStatus(_ market: MarketRecord) -> String {
        let count = (market.index.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["market"] as? [String: Any])?["plugins"] as? [Any]
        let time = market.lastRefreshAt.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "—"
        var parts = [l.t("\(count?.count ?? 0) 个插件", "\(count?.count ?? 0) plugins"), time]
        if !market.enabled { parts.append(l.t("已停用", "Disabled")) }
        switch market.state {
        case "stale": parts.append(l.t("刷新失败，显示缓存", "Refresh failed; showing cache"))
        case "conflicted": parts.append(l.t("身份冲突，已冻结", "Identity conflict; frozen"))
        case "disabled": parts.append(l.t("已停用", "Disabled"))
        case "unavailable": parts.append(l.t("不可用", "Unavailable"))
        default: break
        }
        return parts.joined(separator: " · ")
    }

    func refresh(_ id: String) {
        refreshingID = id
        Task {
            _ = await model.engine.markets.refresh(id)
            refreshingID = nil
            await reload()
        }
    }

    /// Removing a market keeps installed plugins and marks them "source removed" (PRD §7.6.7).
    func remove(_ market: MarketRecord) {
        let alert = NSAlert()
        alert.messageText = l.t("移除“\(market.name)”？", "Remove “\(market.name)”?")
        alert.informativeText = l.t("已从该市场安装的插件不会被卸载，将标记为“来源已移除”。", "Plugins installed from this market stay installed and are marked “Source removed”.")
        alert.addButton(withTitle: l.cancel)
        alert.addButton(withTitle: l.t("移除", "Remove"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task { try? await model.engine.markets.remove(market.marketID); await reload() }
    }
}

/// Add plugin or market (PRD §19.6): the address is accessed only after "Resolve".
struct AddSourceSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var address = ""
    @State private var task: Task<Void, Never>?
    @State private var resolving = false
    @State private var error: String?
    @State private var resolved: ResolvedSource?
    @State private var conflict: (MarketRecord, String)?
    var l: L10n { model.l }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l.addMarket.replacingOccurrences(of: "…", with: "")).font(.headline)
            Text(l.addressPrompt)
            TextField("https://", text: $address).textFieldStyle(.roundedBorder).disabled(resolving)
            Text(l.t("地址只会在点击“解析”后访问。私有仓库暂不支持。", "The address is accessed only after Resolve. Private repositories are not supported.")).font(.caption).foregroundStyle(.secondary)
            if resolving { ProgressView().controlSize(.small) }
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if let resolved { resultView(resolved) }
            HStack {
                Spacer()
                Button(l.cancel) {
                    task?.cancel()
                    if resolving { resolving = false } else { isPresented = false }
                }
                .keyboardShortcut(.cancelAction)
                if resolved == nil {
                    Button(l.resolve) { resolve() }.keyboardShortcut(.defaultAction).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || resolving)
                }
            }
        }
        .padding(24).frame(width: 560)
    }

    func resolve() {
        error = nil
        resolved = nil
        resolving = true
        task = Task {
            do {
                let result = try await model.engine.markets.resolve(address)
                guard !Task.isCancelled else { return }
                resolved = result
            } catch let failure as RuyioError {
                error = model.l.errorText(failure) + (failure.diagnostic.map { " (\($0))" } ?? "")
            } catch {
                self.error = error.localizedDescription
            }
            resolving = false
        }
    }

    @ViewBuilder
    func resultView(_ resolved: ResolvedSource) -> some View {
        switch resolved.kind {
        case .market(let market, let url):
            VStack(alignment: .leading, spacing: 6) {
                Label(l.t("识别到插件市场", "Plugin market found"), systemImage: "square.grid.2x2").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text(l.t("名称", "Name")).foregroundStyle(.secondary); Text(market.name) }
                    GridRow { Text("ID").foregroundStyle(.secondary); Text(market.id).font(.system(.body, design: .monospaced)) }
                    GridRow { Text(l.t("插件数量", "Plugins")).foregroundStyle(.secondary); Text("\(market.plugins.count)") }
                    GridRow { Text(l.source).foregroundStyle(.secondary); Text(resolved.canonicalURL).lineLimit(2) }
                    if url.absoluteString != resolved.inputURL { GridRow { Text(l.t("实际地址", "Fetched from")).foregroundStyle(.secondary); Text(url.host ?? "").lineLimit(1) } }
                    if let github = resolved.github { GridRow { Text("Commit").foregroundStyle(.secondary); Text(String(github.commitSHA.prefix(12))).font(.system(.body, design: .monospaced)) } }
                }
                Text(l.t("元数据未验证（V1 市场索引没有签名）。添加市场不会安装任何插件。", "Metadata is unverified (V1 market indexes are unsigned). Adding a market installs nothing."))
                    .font(.caption).foregroundStyle(.secondary)
                if let (existing, incoming) = conflict {
                    Text(l.t("已有同 ID 市场：\(existing.canonicalURL)\n新地址：\(incoming)", "A market with this ID exists: \(existing.canonicalURL)\nNew address: \(incoming)"))
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    if conflict != nil {
                        Button(l.t("替换已有市场", "Replace Existing"), role: .destructive) { add(resolved, replace: true) }
                    } else {
                        Button(l.t("添加市场", "Add Market")) { add(resolved, replace: false) }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        case .plugin(let descriptor, let url):
            PluginInstallPreviewView(model: model, descriptor: descriptor, descriptorURL: url, packageURL: nil, source: resolved.canonicalURL,
                                     sourceBinding: PluginSourceBinding(resolved)) { isPresented = false }
        case .package(let url):
            PluginInstallPreviewView(model: model, descriptor: nil, descriptorURL: nil, packageURL: url, source: url.absoluteString) { isPresented = false }
        }
    }

    func add(_ resolved: ResolvedSource, replace: Bool) {
        Task {
            do {
                switch try await model.engine.markets.addMarket(resolved, replaceExisting: replace) {
                case .added, .alreadyAdded: isPresented = false
                case .conflict(let existing, let incoming): conflict = (existing, incoming)
                }
            } catch let failure as RuyioError {
                error = model.l.errorText(failure)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Install preview (PRD §19.7): metadata shows "pending verification" until the real package is checked.
struct PluginInstallPreviewView: View {
    @ObservedObject var model: AppModel
    let descriptor: PluginDescriptor?
    let descriptorURL: URL?
    let packageURL: URL?
    let source: String
    var sourceBinding: PluginSourceBinding? = nil
    let done: () -> Void
    @State private var preview: InstallPreview?
    @State private var checking = false
    @State private var installing = false
    @State private var progress: Double?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    var l: L10n { model.l }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(descriptor?.name ?? packageURL?.lastPathComponent ?? "", systemImage: "puzzlepiece.extension").font(.headline)
            if let descriptor {
                if let description = descriptor.description { Text(description) }
                Text(verbatim: "\(descriptor.id) · \(descriptor.bestRelease()?.version.description ?? l.t("无兼容版本", "No compatible release"))").font(.caption).foregroundStyle(.secondary)
                if let src = descriptor.source { Text(l.source + ": " + src + " " + l.sourceUnverified).font(.caption).foregroundStyle(.secondary) }
            }
            Text(l.t("来源：", "Source: ") + source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let preview {
                verification(preview)
            } else {
                Text(l.t("签名、权限与哈希：待验证", "Signature, permissions and hash: pending verification")).foregroundStyle(.secondary)
                if checking { ProgressView(value: progress).progressViewStyle(.linear) }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                if installing { ProgressView().controlSize(.small) }
                if checking { Button(l.cancel) { task?.cancel(); checking = false } }
                if let preview {
                    Button(l.t("安装", "Install")) { install(preview) }.keyboardShortcut(.defaultAction).disabled(!preview.isInstallable || installing)
                } else {
                    Button(l.t("下载并验证", "Download and Verify")) { verify() }.disabled(checking || (descriptor != nil && descriptor?.bestRelease() == nil))
                }
            }
        }
        // Closing the preview without installing drops the verified staging copy.
        .onDisappear { task?.cancel(); discardStaging() }
    }

    func discardStaging() {
        if let preview { model.engine.installer.discard(preview) }
    }

    func verification(_ preview: InstallPreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(preview.checks, id: \.name) { check in
                HStack {
                    Image(systemName: check.outcome == .passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(check.outcome == .passed ? .green : .red)
                    Text(check.name)
                    if let detail = check.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
            // No expected digest for direct packages: never claim a "match" (R21).
            Text(preview.expectedSHA256 == nil
                 ? l.t("摘要已计算（无外部预期值）：", "Digest computed (no expected value): ") + String(preview.sha256.prefix(16))
                 : l.t("SHA-256 匹配：", "SHA-256 matches: ") + String(preview.sha256.prefix(16)))
                .font(.system(.caption, design: .monospaced))
            Text(l.t("权限：", "Permissions: ") + preview.manifest.permissions.map { l.permissionName($0) }.joined(separator: "、")).font(.caption)
            if preview.manifest.permissions.contains(.networkClient) {
                Text(l.t("网络访问范围包括互联网、本机及局域网。", "Network access covers the internet, this Mac and the local network.")).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    func verify() {
        checking = true
        error = nil
        task = Task {
            do {
                let report: @Sendable (Int64, Int64?) -> Void = { done, total in
                    Task { @MainActor in progress = total.map { Double(done) / Double(max($0, 1)) } }
                }
                if let descriptor, let descriptorURL, let release = descriptor.bestRelease() {
                    let marketID = source.hasPrefix("market:") ? String(source.dropFirst(7)) : nil
                    preview = try await model.engine.markets.prepareInstall(descriptor: descriptor, descriptorURL: descriptorURL, release: release, marketID: marketID, progress: report)
                } else if let packageURL {
                    preview = try await model.engine.markets.prepareInstall(packageURL: packageURL, progress: report)
                }
            } catch let failure as RuyioError {
                error = model.l.errorText(failure) + (failure.diagnostic.map { " (\($0))" } ?? "")
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            checking = false
        }
    }

    func install(_ preview: InstallPreview) {
        guard !installing else { return }
        installing = true
        error = nil
        Task {
            defer { installing = false }
            var commitStarted = false
            do {
                // Installs from a market follow that market (removal marks them orphaned, updates come from it).
                let fromMarket = source.hasPrefix("market:")
                let channel: UpdateChannel = fromMarket ? .market : (descriptor != nil ? .descriptor : .none)
                let persistedSource = try sourceBinding?.encoded() ?? source
                var dataChoice = HostEngine.RestoreDataChoice.keepCompatible
                if try model.engine.requiresFreshData(for: preview) {
                    guard confirmFreshDataInstallation(using: l) else { return }
                    dataChoice = .fresh
                }
                commitStarted = true
                let id = try await model.engine.commitInstall(preview, updateChannel: channel, source: persistedSource, dataChoice: dataChoice)
                model.selectedPlugin = id
                model.page = .plugins
                done()
            } catch let failure as RuyioError {
                if commitStarted { model.engine.installer.discard(preview); self.preview = nil }
                error = model.l.errorText(failure)
            } catch {
                if commitStarted { model.engine.installer.discard(preview); self.preview = nil }
                self.error = error.localizedDescription
            }
        }
    }
}

@MainActor
func confirmFreshDataInstallation(using l: L10n) -> Bool {
    let alert = NSAlert()
    alert.messageText = l.t("保留的数据与此版本不兼容", "Retained data is incompatible with this version")
    alert.informativeText = l.t("可以保留旧数据，使用新的空数据安装插件。旧数据不会被覆盖或删除。取消后不会安装插件，也不会更改旧数据。",
                               "You can install the plugin with new, empty data. Existing data will be kept without being overwritten or deleted. Cancelling leaves the plugin uninstalled and the old data unchanged.")
    alert.addButton(withTitle: l.cancel)
    alert.addButton(withTitle: l.t("保留旧数据，使用新数据安装", "Keep Old Data and Install with New Data"))
    return alert.runModal() == .alertSecondButtonReturn
}

struct MarketPluginSheet: View {
    @ObservedObject var model: AppModel
    let entry: MarketEntryState
    let close: () -> Void
    @State private var loaded: (PluginDescriptor, URL)?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let (descriptor, url) = loaded {
                PluginInstallPreviewView(model: model, descriptor: descriptor, descriptorURL: url, packageURL: nil, source: "market:\(entry.marketID)", done: close)
            } else {
                Text(entry.hintName ?? entry.id.rawValue).font(.headline)
                if loading { ProgressView().controlSize(.small) }
                if let error {
                    Text(error).foregroundStyle(.orange)
                    Button(model.l.t("重试", "Retry")) { Task { await load() } }.disabled(loading)
                }
            }
            HStack { Spacer(); Button(model.l.done) { close() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 560)
        .task { await load() }
    }

    func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            loaded = try await model.engine.markets.descriptor(marketID: entry.marketID, pluginID: entry.id, refresh: false)
        } catch let failure as RuyioError {
            error = model.l.errorText(failure) + (failure.diagnostic.map { " (\($0))" } ?? "")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
