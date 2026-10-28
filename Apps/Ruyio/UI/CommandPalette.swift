import AppKit
import RuyioCore
import RuyioHostKit
import RuyioProtocol
import RuyioUI
import SwiftUI

/// Command palette (PRD §19.2, interaction §9). Aggregates enabled plugins' command entries.
@MainActor
final class CommandPaletteController: ObservableObject {
    enum Phase: Equatable {
        case browsing
        case form(ActionRef, FormSpec, [String: JSONValue])
        case running(ActionRef)
        case failed(ActionRef, String)
        case outcomePending(ActionRef, String)
    }

    private let model: AppModel
    weak var overlay: OverlayController?
    var openPluginDetail: ((PluginID) -> Void)?
    fileprivate var panel: FloatingPanel?
    @Published var query = ""
    @Published var selection: String?
    @Published var phase: Phase = .browsing
    private var usage: [String: (Int, Date)] = [:]

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? close() : open() }

    func open() {
        overlay?.close()
        PasteService.shared.rememberFrontmostApp()
        query = ""
        phase = .browsing
        usage = Dictionary(uniqueKeysWithValues: ((try? model.engine.database.usage()) ?? []).map { ("\($0.pluginID)/\($0.actionID)", ($0.count, $0.lastUsedAt)) })
        selection = results.first?.id
        let panel = panel ?? FloatingPanel(size: NSSize(width: 680, height: 460), minSize: NSSize(width: 680, height: 300), resizable: false)
        panel.contentView = NSHostingView(rootView: CommandPaletteView(controller: self, model: model).environment(\.locale, Locale(identifier: model.language)))
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        panel.onResignKey = { [weak self] in
            Task { @MainActor in
                guard let self, NSApp.modalWindow == nil else { return }
                // Clicking outside closes, except while an action that cannot be interrupted runs (PRD §19.2).
                if case .running = self.phase { return }
                if NSApp.keyWindow !== self.panel { self.close() }
            }
        }
        panel.centerOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Empty query: suggestions by recent use. Otherwise local fuzzy match on title, keywords and plugin name.
    var results: [CommandEntry] {
        let commands = model.snapshot.entries.commands
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty {
            return commands.sorted { lhs, rhs in
                let a = usage[lhs.id]?.1 ?? .distantPast
                let b = usage[rhs.id]?.1 ?? .distantPast
                return a != b ? a > b : lhs.title < rhs.title
            }
        }
        return commands.compactMap { entry -> (CommandEntry, Int)? in
            let haystacks = [entry.title, entry.pluginName] + entry.keywords
            let best = haystacks.compactMap { Self.fuzzyScore(trimmed, in: $0.lowercased()) }.max()
            return best.map { (entry, $0 + (usage[entry.id]?.0 ?? 0)) }
        }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func fuzzyScore(_ needle: String, in haystack: String) -> Int? {
        if haystack.contains(needle) { return 1000 - haystack.count + (haystack.hasPrefix(needle) ? 200 : 0) }
        var index = haystack.startIndex
        var score = 0
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return nil }
            score += found == index ? 10 : 1
            index = haystack.index(after: found)
        }
        return score
    }

    func handleKey(_ event: NSEvent) -> Bool {
        switch KeyCommand(event) {
        case .escape:
            if case .form = phase { phase = .browsing; return true }
            close()
            return true
        case .up, .down:
            guard case .browsing = phase else { return false }
            let list = results
            guard !list.isEmpty else { return true }
            let index = list.firstIndex { $0.id == selection } ?? -1
            let delta = KeyCommand(event) == .up ? -1 : 1
            selection = list[max(0, min(list.count - 1, index + delta))].id
            return true
        case .enter:
            guard case .browsing = phase, let entry = results.first(where: { $0.id == selection }) ?? results.first else { return false }
            run(entry)
            return true
        default:
            return false
        }
    }

    func run(_ entry: CommandEntry, parameters: [String: JSONValue] = [:]) {
        if (model.summary(entry.ref.pluginID)?.status.pendingOutcomeCount ?? 0) > 0,
           model.summary(entry.ref.pluginID)?.manifest.action(entry.ref.actionID)?.hasSideEffects == true {
            phase = .outcomePending(entry.ref, model.l.errorText(RuyioError(.outcomeUnknown)))
            return
        }
        if let view = entry.opensView {
            try? model.engine.database.recordUsage(entry.ref)
            close()
            overlay?.open(pluginID: entry.ref.pluginID, viewID: view)
            return
        }
        phase = .running(entry.ref)
        Task {
            let report = await model.engine.invoke(InvocationRequest(ref: entry.ref, entry: .commandPalette, parameters: parameters))
            handle(report, entry: entry, parameters: parameters)
        }
    }

    private func handle(_ report: ExecutionReport, entry: CommandEntry, parameters: [String: JSONValue]) {
        switch report.state {
        case .succeeded:
            switch report.output {
            case .requestInput(let form):
                phase = .form(entry.ref, form, parameters)
            case .openView(let view):
                close()
                overlay?.open(pluginID: entry.ref.pluginID, viewID: view)
            case .notice(let text):
                phase = .browsing
                if entry.completion != .keepPanel { close() }
                model.show(text)
            default:
                phase = .browsing
                if entry.completion == .closePanel { close() }
            }
        case .cancelled:
            phase = .browsing
        case .outcomeUnknown:
            phase = .outcomePending(entry.ref, model.l.errorText(report.error ?? RuyioError(.outcomeUnknown)))
        default:
            // Failures keep the panel and the query, offering retry and plugin details (PRD §19.2).
            phase = .failed(entry.ref, report.error.map(model.l.errorText) ?? model.l.t("执行失败", "Failed"))
        }
    }
}

/// Spotlight-style: a glass search capsule with a results card under it (interaction §9).
struct CommandPaletteView: View {
    @ObservedObject var controller: CommandPaletteController
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    var l: L10n { model.l }

    var body: some View {
        GlassGroup(spacing: 12) {
            VStack(spacing: 10) {
                searchBar
                switch controller.phase {
                case .form(let ref, let form, _):
                    formCard(ref: ref, form: form)
                default:
                    resultsCard
                }
            }
        }
        .padding(12)
        .frame(width: 680, height: 460, alignment: .top)
        .keyWindowControls()
        .onAppear { focused = true }
    }

    var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
            TextField(l.commandPlaceholder, text: $controller.query)
                .textFieldStyle(.plain).font(.system(size: 22)).focused($focused)
                .onChange(of: controller.query) { _, _ in controller.selection = controller.results.first?.id }
            if case .running = controller.phase { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 20).frame(height: 56)
        .ruyioGlass(in: Capsule())
    }

    @ViewBuilder
    var resultsCard: some View {
        let results = controller.results
        let failure: (ActionRef, String, Bool)? = switch controller.phase {
        case .failed(let ref, let message): (ref, message, true)
        case .outcomePending(let ref, let message): (ref, message, false)
        default: nil
        }
        if !results.isEmpty || failure != nil || !controller.query.isEmpty {
            VStack(spacing: 0) {
                if results.isEmpty {
                    VStack(spacing: 10) {
                        Text(l.noCommands).font(.headline)
                        Button(l.openMarket) {
                            controller.close()
                            model.page = .market
                            NSApp.sendAction(#selector(AppDelegate.showMainWindow), to: nil, from: nil)
                        }
                        .ruyioGlassButton()
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
                } else {
                    ScrollViewReader { proxy in
                        List(selection: $controller.selection) {
                            ForEach(results) { entry in
                                row(entry).tag(entry.id).id(entry.id)
                            }
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                        .alternatingRowBackgrounds(.disabled)
                        .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                            if let id = ids.first, let entry = controller.results.first(where: { $0.id == id }) { controller.run(entry) }
                        }
                        .frame(height: min(CGFloat(results.count) * 44 + 16, 300))
                        .onChange(of: controller.selection) { _, id in if let id { proxy.scrollTo(id) } }
                    }
                }
                if let failure {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(failure.1).font(.callout).lineLimit(2)
                        Spacer()
                        if failure.2 {
                            Button(l.retry) { if let entry = controller.results.first(where: { $0.ref == failure.0 }) { controller.run(entry) } }
                                .ruyioGlassButton().controlSize(.small)
                        }
                        Button(l.openPluginDetail) { controller.close(); controller.openPluginDetail?(failure.0.pluginID) }
                            .ruyioGlassButton().controlSize(.small)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.orange.opacity(0.1))
                }
                Divider().opacity(0.5)
                HStack(spacing: 14) {
                    Text(l.paletteHelp)
                    Spacer()
                    if let entry = controller.results.first(where: { $0.id == controller.selection }) { Text(entry.pluginName) }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 9)
            }
            .ruyioGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    func row(_ entry: CommandEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.symbol ?? "bolt.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                if let subtitle = entry.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(entry.pluginName).font(.caption).foregroundStyle(.secondary)
            if let shortcut = entry.shortcut { Text(shortcut.displayString).font(.caption.monospaced()).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    func formCard(ref: ActionRef, form: FormSpec) -> some View {
        let context = SchemaContext(pluginID: ref.pluginID, document: ViewDocument(viewID: "form", revision: 0, root: .form(form)),
                                    strings: SchemaStrings(submit: l.done, cancel: l.cancel, undo: "", loading: "", choose: "…"),
                                    sendEvent: { _, _ in }, loadBlob: { _ in nil })
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { controller.phase = .browsing } label: { Image(systemName: "chevron.left") }
                    .ruyioGlassButton()
                    .buttonBorderShape(.circle)
                    .help(l.back)
                    .accessibilityLabel(l.back)
                Text(model.snapshot.entries.commands.first { $0.ref == ref }?.title ?? "").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 12)
            SchemaFormView(spec: form, context: context) { values in
                if let entry = model.snapshot.entries.commands.first(where: { $0.ref == ref }) {
                    var parameters: [String: JSONValue] = [:]
                    if case .form(_, _, let previous) = controller.phase { parameters = previous }
                    parameters.merge(values) { $1 }
                    controller.run(entry, parameters: parameters)
                }
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: 340)
        }
        .ruyioGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

#if DEBUG
extension CommandPaletteController {
    var galleryWindow: NSWindow? { panel }
}
#endif
