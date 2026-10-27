import AppKit
import RuyioProtocol
import SwiftUI

/// Search + filters + list + preview + footer (interaction §10). Keyboard commands are dispatched by
/// the hosting panel so that typing, Space and ⌫ always edit the search field (PRD §19.15).
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
            VStack(spacing: 0) {
                header
                if let banner = spec.banner { bannerView(banner) }
                Divider()
                HStack(spacing: 0) {
                    listPane.frame(width: geometry.size.width >= 700 && context.previewVisible ? geometry.size.width * 0.58 : geometry.size.width)
                    if geometry.size.width >= 700 && context.previewVisible {
                        Divider()
                        previewPane
                    }
                }
                Divider()
                footer
            }
            .overlay(alignment: .bottom) { undoToast.padding(.bottom, 44) }
            // Narrow windows show the preview as a temporary overlay (interaction §10.1).
            .overlay {
                if geometry.size.width < 700 && !context.previewVisible, let preview = spec.preview {
                    ScrollView { SchemaNodeView(node: preview, context: context).padding(16) }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(24)
                }
            }
        }
        .onAppear {
            query = spec.searchText
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("app.ruyio.clearSearch"))) { _ in query = "" }
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(spec.searchPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
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
            if !spec.filters.isEmpty {
                Picker("", selection: Binding(get: { spec.selectedFilter ?? spec.filters.first?.id ?? "" }, set: { context.send(.filterChanged($0)) })) {
                    ForEach(spec.filters, id: \.id) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(12)
    }

    func bannerView(_ banner: BannerSpec) -> some View {
        HStack(spacing: 8) {
            Image(systemName: banner.tone == .critical ? "exclamationmark.octagon" : (banner.tone == .warning ? "exclamationmark.triangle" : "pause.circle"))
                .foregroundStyle(banner.tone == .critical ? .red : (banner.tone == .warning ? .orange : .secondary))
            Text(banner.text).font(.callout)
            Spacer()
            ForEach(banner.actions, id: \.id) { action in
                Button(action.title) { context.send(.invoke(actionID: action.id, itemID: nil)) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(banner.tone == .info ? Color.secondary.opacity(0.08) : Color.orange.opacity(0.12))
    }

    var listPane: some View {
        Group {
            if spec.list.items.isEmpty, let empty = spec.list.empty {
                EmptyStateView(spec: empty, context: context)
            } else {
                ScrollViewReader { proxy in
                    List(spec.list.items, selection: Binding(get: { context.localSelection }, set: { id in
                        context.localSelection = id
                        context.send(.selectionChanged(id))
                    })) { item in
                        ItemRow(item: item, context: context).tag(item.id).id(item.id)
                            .onTapGesture(count: 2) { context.send(.invoke(actionID: "paste", itemID: item.id)) }
                            .onAppear {
                                if item.id == spec.list.items.last?.id, let cursor = spec.list.nextCursor { context.send(.loadNextPage(cursor: cursor)) }
                            }
                    }
                    .listStyle(.plain)
                    .onChange(of: context.localSelection) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
        }
    }

    var previewPane: some View {
        ScrollView {
            if let preview = spec.preview {
                SchemaNodeView(node: preview, context: context).padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var footer: some View {
        HStack(spacing: 14) {
            ForEach(spec.footerActions.filter { $0.shortcut != nil }, id: \.id) { action in
                HStack(spacing: 4) {
                    Text(Self.symbol(for: action.shortcut ?? "")).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Text(action.title).font(.caption).foregroundStyle(action.isDestructive ? .red : .secondary)
                }
            }
            Spacer()
            ForEach(spec.footerActions.filter { $0.shortcut == nil }, id: \.id) { action in
                Button(action.title, role: action.isDestructive ? .destructive : nil) { context.send(.invoke(actionID: action.id, itemID: nil)) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    var undoToast: some View {
        if let undo = spec.undo, undo.expiresAt > Date() {
            HStack(spacing: 10) {
                Text(undo.text)
                Button(context.strings.undo) { context.send(.undo(token: undo.token)) }.keyboardShortcut("z", modifiers: .command)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
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
