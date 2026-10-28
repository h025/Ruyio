import AppKit
import RuyioProtocol
import SwiftUI

/// Search + filters + list + preview + hint bar (interaction §10), laid out as a floating glass panel:
/// large title, capsule search, grouped list and preview cards, and a floating hint capsule.
/// Keyboard commands are dispatched by the hosting panel so typing, Space and ⌫ always edit the search
/// field (PRD §19.15).
public struct CollectionPanelView: View {
    let spec: CollectionSpec
    @ObservedObject var context: SchemaContext
    @State private var query = ""
    @State private var debounce: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

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
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 62)
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    undoToast
                    footer
                }
                .padding(.bottom, 12)
            }
            // Narrow windows show the preview as a temporary overlay (interaction §10.1).
            .overlay {
                if !wide && !context.previewVisible, let preview = spec.preview {
                    ScrollView { SchemaNodeView(node: preview, context: context).padding(16) }
                        .ruyioGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(28)
                }
            }
        }
        .onAppear {
            query = spec.searchText
            searchFocused = true
        }
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
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .ruyioGlass(in: Circle(), interactive: true)
                .accessibilityLabel(context.strings.cancel)
            }
        }
        .padding(.leading, 4)
    }

    var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(spec.searchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel(spec.searchPlaceholder)
                    .onChange(of: query) { _, newValue in
                        debounce?.cancel()
                        debounce = Task {
                            try? await Task.sleep(for: .milliseconds(150))
                            guard !Task.isCancelled else { return }
                            context.send(.searchChanged(newValue))
                        }
                    }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            if !spec.filters.isEmpty {
                Picker("", selection: Binding(get: { spec.selectedFilter ?? spec.filters.first?.id ?? "" }, set: { context.send(.filterChanged($0)) })) {
                    ForEach(spec.filters, id: \.id) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
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
                    .controlSize(.small)
                    .ruyioGlassButton()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tone.opacity(banner.tone == .info ? 0.08 : 0.14)))
    }

    // MARK: List

    var listCard: some View {
        Group {
            if spec.list.items.isEmpty, let empty = spec.list.empty {
                EmptyStateView(spec: empty, context: context)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            let items = spec.list.items
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                let selected = item.id == context.localSelection
                                ItemRow(item: item, context: context, isSelected: selected)
                                    .id(item.id)
                                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .onTapGesture {
                                        // Double-click pastes; single-click selects without waiting for a second tap.
                                        if NSApp.currentEvent?.clickCount == 2 {
                                            context.send(.invoke(actionID: "paste", itemID: item.id))
                                        } else {
                                            context.select(item.id)
                                        }
                                    }
                                    .onAppear {
                                        if item.id == items.last?.id, let cursor = spec.list.nextCursor { context.send(.loadNextPage(cursor: cursor)) }
                                    }
                                if index < items.count - 1 && !selected && items[index + 1].id != context.localSelection {
                                    Divider().padding(.leading, 52).padding(.trailing, 10)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .scrollIndicators(.automatic)
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

    // MARK: Hint bar

    var footer: some View {
        let selection = context.localSelection
        let keyed = spec.footerActions.filter { $0.shortcut != nil }
        let others = spec.footerActions.filter { $0.shortcut == nil }
        return HStack(spacing: 14) {
            ForEach(keyed, id: \.id) { action in
                Button { context.send(.invoke(actionID: action.id, itemID: selection)) } label: {
                    HStack(spacing: 5) {
                        KeyCap(Self.symbol(for: action.shortcut ?? ""))
                        Text(action.title).font(.callout)
                    }
                    .foregroundStyle(action.isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .disabled(selection == nil)
            }
            if !others.isEmpty {
                Menu {
                    ForEach(others, id: \.id) { action in
                        Button(action.title, role: action.isDestructive ? .destructive : nil) { context.send(.invoke(actionID: action.id, itemID: nil)) }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .ruyioGlass(in: Capsule())
    }

    @ViewBuilder
    var undoToast: some View {
        if let undo = spec.undo, undo.expiresAt > Date() {
            HStack(spacing: 10) {
                Text(undo.text).font(.callout)
                Button(context.strings.undo) { context.send(.undo(token: undo.token)) }
                    .keyboardShortcut("z", modifiers: .command)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
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
