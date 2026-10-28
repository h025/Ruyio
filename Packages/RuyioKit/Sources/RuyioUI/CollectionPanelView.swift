import AppKit
import RuyioProtocol
import SwiftUI

/// Search + filters + list + preview + action bar (interaction §10), as a floating glass panel built from
/// native controls: AppKit search field, large segmented control, a List with system selection, and glass
/// buttons. Keyboard commands are dispatched by the hosting panel so typing, Space and ⌫ always edit the
/// search field (PRD §19.15).
public struct CollectionPanelView: View {
    let spec: CollectionSpec
    @ObservedObject var context: SchemaContext
    @State private var query = ""
    @State private var debounce: Task<Void, Never>?

    public init(spec: CollectionSpec, context: SchemaContext) {
        self.spec = spec
        self.context = context
    }

    public var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700
            VStack(alignment: .leading, spacing: 12) {
                header
                searchRow
                if let banner = spec.banner { bannerView(banner) }
                HStack(alignment: .top, spacing: 12) {
                    listCard
                    if wide && context.previewVisible && spec.preview != nil {
                        previewCard.frame(width: geometry.size.width * 0.4)
                    }
                }
                .frame(maxHeight: .infinity)
                actionBar
            }
            .padding(16)
            .overlay(alignment: .bottom) { undoToast.padding(.bottom, 64) }
            // Narrow windows show the preview as a temporary overlay (interaction §10.1).
            .overlay {
                if !wide && !context.previewVisible, let preview = spec.preview {
                    ScrollView { SchemaNodeView(node: preview, context: context).padding(16) }
                        .ruyioGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(28)
                }
            }
        }
        .keyWindowControls()
        .onAppear { query = spec.searchText }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("app.ruyio.clearSearch"))) { _ in query = "" }
    }

    // MARK: Header and search

    var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                if let title = context.document.title {
                    Text(title).font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                }
                if let source = context.source {
                    Label(source, systemImage: "puzzlepiece.extension").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let dismiss = context.dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .ruyioGlassButton()
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help(context.strings.cancel)
                    .accessibilityLabel(context.strings.cancel)
            }
        }
        .padding(.leading, 4)
    }

    var searchRow: some View {
        HStack(spacing: 10) {
            NativeSearchField(text: $query, placeholder: spec.searchPlaceholder)
                .onChange(of: query) { _, newValue in
                    debounce?.cancel()
                    debounce = Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        context.send(.searchChanged(newValue))
                    }
                }
            if !spec.filters.isEmpty {
                Picker("", selection: Binding(get: { spec.selectedFilter ?? spec.filters.first?.id ?? "" }, set: { context.send(.filterChanged($0)) })) {
                    ForEach(spec.filters, id: \.id) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.large)
            }
        }
    }

    func bannerView(_ banner: BannerSpec) -> some View {
        let tone: Color = banner.tone == .critical ? .red : (banner.tone == .warning ? .orange : .secondary)
        return HStack(spacing: 10) {
            Image(systemName: banner.tone == .critical ? "exclamationmark.octagon.fill" : (banner.tone == .warning ? "exclamationmark.triangle.fill" : "pause.circle.fill"))
                .foregroundStyle(tone)
            Text(banner.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            ForEach(banner.actions, id: \.id) { action in
                Button(action.title) { context.send(.invoke(actionID: action.id, itemID: nil)) }
                    .ruyioGlassButton()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tone.opacity(banner.tone == .info ? 0.08 : 0.14)))
    }

    // MARK: List and preview

    var listCard: some View {
        Group {
            if spec.list.items.isEmpty, let empty = spec.list.empty {
                EmptyStateView(spec: empty, context: context)
            } else {
                ScrollViewReader { proxy in
                    List(selection: Binding(get: { context.localSelection }, set: { id in if let id { context.select(id) } })) {
                        ForEach(spec.list.items) { item in
                            ItemRow(item: item, context: context)
                                .tag(item.id)
                                .id(item.id)
                                .onAppear {
                                    if item.id == spec.list.items.last?.id, let cursor = spec.list.nextCursor { context.send(.loadNextPage(cursor: cursor)) }
                                }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .alternatingRowBackgrounds(.disabled)
                    // Native double-click / Return-on-row handling; item menus come from the row.
                    .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                        if let id = ids.first { context.send(.invoke(actionID: "paste", itemID: id)) }
                    }
                    .onChange(of: context.localSelection) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ruyioCard(radius: 18)
    }

    var previewCard: some View {
        ScrollView {
            if let preview = spec.preview {
                SchemaNodeView(node: preview, context: context).padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ruyioCard(radius: 18)
    }

    // MARK: Action bar

    /// Native glass buttons; the default action is prominent, shortcuts appear in tooltips and in the
    /// overflow menu, which lists every action with its key equivalent.
    var actionBar: some View {
        let selection = context.localSelection
        let keyed = spec.footerActions.filter { $0.shortcut != nil }
        return GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(keyed, id: \.id) { action in
                    let button = Button(role: action.isDestructive ? .destructive : nil) {
                        context.send(.invoke(actionID: action.id, itemID: selection))
                    } label: {
                        Text(action.title)
                    }
                    .help("\(action.title)  \(Self.symbol(for: action.shortcut ?? ""))")
                    .disabled(selection == nil)
                    if action.isDefault { button.ruyioGlassButton(prominent: true) } else { button.ruyioGlassButton() }
                }
                Spacer(minLength: 0)
                Menu {
                    ForEach(spec.footerActions, id: \.id) { action in
                        Button(role: action.isDestructive ? .destructive : nil) {
                            context.send(.invoke(actionID: action.id, itemID: action.shortcut == nil ? nil : selection))
                        } label: {
                            Text(action.title)
                            if let shortcut = action.shortcut { Text(Self.symbol(for: shortcut)) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .ruyioGlassButton()
                .buttonBorderShape(.circle)
                .fixedSize()
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder
    var undoToast: some View {
        if let undo = spec.undo, undo.expiresAt > Date() {
            HStack(spacing: 10) {
                Text(undo.text).font(.callout)
                Button(context.strings.undo) { context.send(.undo(token: undo.token)) }
                    .keyboardShortcut("z", modifiers: .command)
                    .ruyioGlassButton()
            }
            .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
            .ruyioGlass(in: Capsule())
            .accessibilityElement(children: .contain)
        }
    }

    /// Shortcut symbols are never translated (plan §17.1).
    public static func symbol(for shortcut: String) -> String {
        var text = ""
        let parts = shortcut.split(separator: "+").map(String.init)
        for part in parts.dropLast() {
            switch part {
            case "control": text += "⌃"
            case "option": text += "⌥"
            case "shift": text += "⇧"
            case "command": text += "⌘"
            default: break
            }
        }
        switch parts.last ?? "" {
        case "return": text += "↩"
        case "delete": text += "⌫"
        case "escape": text += "esc"
        case "space": text += "Space"
        case let key: text += key.uppercased()
        }
        return text
    }
}
