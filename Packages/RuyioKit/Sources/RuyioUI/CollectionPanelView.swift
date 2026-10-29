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
            let showingCompactPreview = !wide && context.compactPreviewVisible && spec.preview != nil
            VStack(alignment: .leading, spacing: 12) {
                header(wide: wide)
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
            .disabled(showingCompactPreview)
            .accessibilityHidden(showingCompactPreview)
            .overlay(alignment: .bottom) { undoToast.padding(.bottom, 64) }
            // Narrow windows show the preview as a temporary overlay (interaction §10.1).
            .overlay {
                if showingCompactPreview, let preview = spec.preview {
                    VStack(spacing: 12) {
                        HStack {
                            Text(context.strings.preview).font(.headline)
                            Spacer()
                            Button { context.compactPreviewVisible = false } label: { Image(systemName: "xmark") }
                                .ruyioGlassButton().buttonBorderShape(.circle)
                                .help(context.strings.cancel).accessibilityLabel(context.strings.cancel)
                        }
                        ScrollView { SchemaNodeView(node: preview, context: context).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                        .padding(16)
                        .ruyioGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(28)
                }
            }
            .onChange(of: wide) { _, _ in context.compactPreviewVisible = false }
            .onChange(of: spec.preview == nil) { _, missing in
                if missing { context.compactPreviewVisible = false }
            }
        }
        .keyWindowControls()
        .onAppear { query = spec.searchText }
        .onDisappear { debounce?.cancel(); debounce = nil }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("app.ruyio.clearSearch"))) { _ in query = "" }
    }

    // MARK: Header and search

    func header(wide: Bool) -> some View {
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
            if spec.preview != nil {
                Button {
                    if wide { context.previewVisible.toggle() } else { context.compactPreviewVisible.toggle() }
                } label: { Image(systemName: "sidebar.right") }
                    .ruyioGlassButton().buttonBorderShape(.circle).controlSize(.large)
                    .help(context.strings.preview + "  ⌘Y").accessibilityLabel(context.strings.preview)
            }
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { searchField.frame(minWidth: 220); filters }
            VStack(alignment: .leading, spacing: 10) { searchField; filters }
        }
    }

    var searchField: some View {
            NativeSearchField(text: $query, placeholder: spec.searchPlaceholder)
                .onChange(of: query) { _, newValue in
                    debounce?.cancel()
                    debounce = Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        context.send(.searchChanged(newValue))
                    }
                }
    }

    @ViewBuilder
    var filters: some View {
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

    func bannerView(_ banner: BannerSpec) -> some View {
        let tone: Color = banner.tone == .critical ? .red : (banner.tone == .warning ? .orange : .secondary)
        let message = Label {
            Text(banner.text).font(.callout).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: banner.tone == .critical ? "exclamationmark.octagon.fill" : (banner.tone == .warning ? "exclamationmark.triangle.fill" : "pause.circle.fill"))
                .foregroundStyle(tone)
        }
        let actions = HStack {
            ForEach(banner.actions, id: \.id) { action in
                Button(action.title) { context.send(.invoke(actionID: action.id, itemID: nil)) }
                    .ruyioGlassButton()
            }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { message; Spacer(minLength: 8); actions.fixedSize() }
            VStack(alignment: .leading, spacing: 10) { message; actions }
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
                    // Selection is drawn here, not by the list: keyboard focus stays in the search field, so the
                    // list's own highlight would be its unfocused grey block, and its separators read as heavy
                    // lines on glass. Arrow keys move the selection from the panel (moveSelection).
                    List {
                        ForEach(spec.list.items) { item in
                            let isSelected = item.id == context.localSelection
                            ItemRow(item: item, context: context)
                                .contentShape(Rectangle())
                                .simultaneousGesture(TapGesture().onEnded { context.select(item.id) })
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    if let event = context.invocation(itemID: item.id) { context.send(event) }
                                })
                                .listRowSeparator(.hidden)
                                .listRowBackground(ListSelectionBackground(isSelected: isSelected))
                                .accessibilityAddTraits(isSelected ? .isSelected : [])
                                .id(item.id)
                                .onAppear {
                                    if item.id == spec.list.items.last?.id, let cursor = spec.list.nextCursor { context.send(.loadNextPage(cursor: cursor)) }
                                }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .alternatingRowBackgrounds(.disabled)
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
        let primary = spec.footerActions.filter { $0.isDefault }
        let secondary = spec.footerActions.filter { !$0.isDefault && $0.shortcut != nil && !$0.isDestructive }
        let visible = Array((primary + secondary).prefix(2))
        return GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(visible, id: \.id) { action in
                    let button = Button(role: action.isDestructive ? .destructive : nil) {
                        if let event = context.footerInvocation(action) { context.send(event) }
                    } label: {
                        Text(action.title)
                    }
                    .disabled(context.footerInvocation(action) == nil)
                    .help("\(action.title)  \(Self.symbol(for: action.shortcut ?? ""))")
                    if action.isDefault { button.ruyioGlassButton(prominent: true) } else { button.ruyioGlassButton() }
                }
                Spacer(minLength: 0)
                if !spec.footerActions.isEmpty { Menu {
                    ForEach(spec.footerActions, id: \.id) { action in
                        Button(role: action.isDestructive ? .destructive : nil) {
                            if let event = context.footerInvocation(action) { context.send(event) }
                        } label: {
                            Text(action.title)
                            if let shortcut = action.shortcut { Text(Self.symbol(for: shortcut)) }
                        }
                        .disabled(context.footerInvocation(action) == nil)
                    }
                } label: {
                    Label(context.strings.moreActions, systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .ruyioGlassButton()
                .fixedSize()
                }
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

/// The selected row on glass: a soft vibrant fill with continuous corners, as Spotlight draws it.
/// The selected row of a list in a floating panel: a soft rounded fill, no separators around it. Keyboard
/// focus stays in the search field, so the list's own highlight would be its unfocused grey block, and its
/// separators read as heavy lines on glass. Shared by plugin lists and the command palette.
public struct ListSelectionBackground: View {
    let isSelected: Bool

    public init(isSelected: Bool) { self.isSelected = isSelected }

    public var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isSelected ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear))
            .padding(.horizontal, 6)
    }
}
