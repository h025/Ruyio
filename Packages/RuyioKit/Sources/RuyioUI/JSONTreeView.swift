import AppKit
import SwiftUI

/// Host copy for the JSON viewer.
public struct JSONViewerStrings: Sendable {
    public var find: String
    public var noMatches: String
    public var clear: String
    public var previous: String
    public var next: String
    public var expand: String
    public var collapse: String
    public var expandAll: String
    public var collapseAll: String
    public var copyValue: String
    public var copyPath: String
    public var truncated: String
    public var keys: @Sendable (Int) -> String
    public var items: @Sendable (Int) -> String

    public init(find: String = "Find in JSON", noMatches: String = "No matches", clear: String = "Clear", previous: String = "Previous Match",
                next: String = "Next Match", expand: String = "Expand", collapse: String = "Collapse",
                expandAll: String = "Expand All", collapseAll: String = "Collapse All",
                copyValue: String = "Copy Value", copyPath: String = "Copy Path",
                truncated: String = "The preview shows the beginning of this JSON only.",
                keys: @escaping @Sendable (Int) -> String = { $0 == 1 ? "1 key" : "\($0) keys" },
                items: @escaping @Sendable (Int) -> String = { $0 == 1 ? "1 item" : "\($0) items" }) {
        self.find = find
        self.noMatches = noMatches
        self.clear = clear
        self.previous = previous
        self.next = next
        self.expand = expand
        self.collapse = collapse
        self.expandAll = expandAll
        self.collapseAll = collapseAll
        self.copyValue = copyValue
        self.copyPath = copyPath
        self.truncated = truncated
        self.keys = keys
        self.items = items
    }
}

/// The `json` schema node: a collapsible, searchable tree. Text that is not JSON (or a lone scalar) keeps
/// the indented, coloured text view. Lives inside the preview's scroll view, so it stacks lazily rather
/// than scrolling itself, with its search bar pinned on top.
struct JSONTreeView: View {
    let text: String
    let strings: JSONViewerStrings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tree: JSONTree?
    @State private var parsed = false
    @State private var collapsed: Set<Int> = []
    @State private var lines: [JSONTree.Line] = []
    @State private var query = ""
    @State private var hits: [Int] = []
    @State private var current = 0

    var body: some View {
        Group {
            if let tree {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(lines) { line in
                                JSONLineView(tree: tree, line: line, collapsed: collapsed, query: query, hit: hit(for: line),
                                             strings: strings, toggle: { toggle($0) }, setAll: { setAll(collapsed: $0) })
                                    .id(line.id)
                                    .transition(.opacity)
                            }
                            if tree.isTruncated {
                                Text(strings.truncated).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                            }
                        } header: {
                            toolbar(proxy: proxy)
                        }
                    }
                    .onChange(of: query) { _, _ in search(proxy: proxy) }
                }
            } else if parsed {
                Text(JSONFormatting.highlighted(JSONFormatting.indented(text)))
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .task(id: text) {
            let source = text
            let built = await Task.detached(priority: .userInitiated) { JSONTree(source) }.value
            tree = built
            collapsed = built?.defaultCollapsed() ?? []
            lines = built?.lines(collapsed: collapsed) ?? []
            query = ""
            hits = []
            current = 0
            parsed = true
        }
    }

    private var hitSet: Set<Int> { Set(hits) }

    private func hit(for line: JSONTree.Line) -> JSONLineView.Hit? {
        guard !hits.isEmpty, line.role != .close else { return nil }
        if hits[current] == line.node { return .current }
        return hitSet.contains(line.node) ? .other : nil
    }

    private func toolbar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            NativeSearchField(text: $query, placeholder: strings.find, controlSize: .regular,
                              identifier: NativeSearchField.previewIdentifier, focusOnAppear: false, bordered: false) { command in
                switch command {
                case .next: step(1, proxy: proxy)
                case .previous: step(-1, proxy: proxy)
                }
            }
            .frame(minWidth: 100, maxWidth: 240)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.tertiary).help(strings.clear).accessibilityLabel(strings.clear)
            }
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(hits.isEmpty ? strings.noMatches : "\(current + 1)/\(hits.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Button { step(-1, proxy: proxy) } label: { Image(systemName: "chevron.up") }
                    .help(strings.previous).accessibilityLabel(strings.previous).disabled(hits.isEmpty)
                Button { step(1, proxy: proxy) } label: { Image(systemName: "chevron.down") }
                    .help(strings.next).accessibilityLabel(strings.next).disabled(hits.isEmpty)
            }
            Spacer(minLength: 0)
            Menu {
                Button(strings.expandAll) { setAll(collapsed: false) }
                Button(strings.collapseAll) { setAll(collapsed: true) }
            } label: { Image(systemName: "list.bullet.indent") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(strings.expandAll + " / " + strings.collapseAll)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // One floating glass capsule holds the field and its controls: it blurs the lines scrolling under it
        // and sits on the card in both appearances, where a solid bar read as a dark slab.
        .ruyioGlass(in: Capsule())
        .padding(.bottom, 6)
    }

    private var animation: Animation? { reduceMotion ? nil : .snappy(duration: 0.22) }

    private func apply(_ change: () -> Void) {
        withAnimation(animation) {
            change()
            if let tree { lines = tree.lines(collapsed: collapsed) }
        }
    }

    private func toggle(_ id: Int) {
        apply { if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) } }
    }

    private func setAll(collapsed fold: Bool) {
        guard let tree else { return }
        // The root stays open: collapsing everything shows the top level, not a single line.
        var folded: Set<Int> = []
        if fold {
            for node in tree.nodes where node.depth >= 1 && !node.children.isEmpty { folded.insert(node.id) }
        }
        apply { collapsed = folded }
    }

    /// Finds as you type; every match's parents open so each one can be reached.
    private func search(proxy: ScrollViewProxy) {
        guard let tree else { return }
        hits = tree.matches(query)
        current = 0
        guard !hits.isEmpty else { return }
        apply { collapsed.subtract(tree.ancestors(of: hits)) }
        reveal(proxy: proxy)
    }

    private func step(_ delta: Int, proxy: ScrollViewProxy) {
        guard !hits.isEmpty else { return }
        current = (current + delta + hits.count) % hits.count
        reveal(proxy: proxy)
    }

    private func reveal(proxy: ScrollViewProxy) {
        guard let line = lines.first(where: { $0.node == hits[current] && $0.role != .close }) else { return }
        withAnimation(animation) { proxy.scrollTo(line.id, anchor: .center) }
    }
}

/// One line of the tree: indentation, a disclosure chevron for containers, coloured text.
struct JSONLineView: View {
    enum Hit { case current, other }

    let tree: JSONTree
    let line: JSONTree.Line
    let collapsed: Set<Int>
    let query: String
    let hit: Hit?
    let strings: JSONViewerStrings
    let toggle: (Int) -> Void
    let setAll: (Bool) -> Void

    private var node: JSONTree.Node { tree.node(line.node) }
    private var isContainer: Bool { node.kind == .object || node.kind == .array }
    private var isOpen: Bool { !collapsed.contains(line.node) }
    private var folded: Bool { isContainer && line.role == .open && !isOpen && !node.children.isEmpty }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Color.clear.frame(width: CGFloat(line.depth) * 14, height: 1)
            if isContainer, line.role == .open, !node.children.isEmpty {
                Button { toggle(line.node) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isOpen ? strings.collapse : strings.expand)
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            Text(content).textSelection(.enabled)
            if folded {
                // "{ … } 3 keys," : the count belongs to the folded value, the comma comes after it.
                Text("  " + (node.kind == .object ? strings.keys(node.children.count) : strings.items(node.children.count)))
                    .foregroundStyle(.tertiary)
                if tree.hasComma(after: line.node) { Text(",").foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.vertical, 1)
        .background {
            if let hit {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.yellow.opacity(hit == .current ? 0.35 : 0.14))
                    .padding(.horizontal, -3)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if line.role != .close {
                Button(strings.copyValue) { copy(tree.sourceText(of: line.node)) }
                Button(strings.copyPath) { copy(tree.path(of: line.node)) }
                Divider()
            }
            if isContainer, line.role == .open, !node.children.isEmpty {
                Button(isOpen ? strings.collapse : strings.expand) { toggle(line.node) }
            }
            Button(strings.expandAll) { setAll(false) }
            Button(strings.collapseAll) { setAll(true) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var content: AttributedString {
        var result = AttributedString()
        let comma = tree.hasComma(after: line.node) ? "," : ""
        if line.role == .close {
            result += piece(node.kind == .object ? "}" : "]", .secondaryLabelColor)
            result += piece(comma, .secondaryLabelColor)
            return result
        }
        if let key = node.key {
            result += piece("\"" + key + "\"", .systemBlue, highlight: true)
            result += piece(": ", .secondaryLabelColor)
        }
        switch node.kind {
        case .object, .array:
            let (open, close) = node.kind == .object ? ("{", "}") : ("[", "]")
            if node.children.isEmpty {
                result += piece(open + close + comma, .secondaryLabelColor)
            } else if isOpen {
                result += piece(open, .secondaryLabelColor)
            } else {
                result += piece(open + " … " + close, .secondaryLabelColor)
            }
        case .string: result += piece(node.text, .systemRed, highlight: true) + piece(comma, .secondaryLabelColor)
        case .number: result += piece(node.text, .systemOrange, highlight: true) + piece(comma, .secondaryLabelColor)
        case .literal: result += piece(node.text, .systemPink, highlight: true) + piece(comma, .secondaryLabelColor)
        }
        return result
    }

    /// Coloured text; with `highlight`, the parts matching the search are marked as well.
    private func piece(_ text: String, _ color: NSColor, highlight: Bool = false) -> AttributedString {
        var result = AttributedString()
        let needle = query.trimmingCharacters(in: .whitespaces)
        var rest = Substring(text)
        while highlight, !needle.isEmpty,
              let found = rest.range(of: needle, options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]) {
            var before = AttributedString(String(rest[..<found.lowerBound]))
            before.foregroundColor = Color(nsColor: color)
            var match = AttributedString(String(rest[found]))
            match.foregroundColor = Color(nsColor: color)
            match.backgroundColor = Color.yellow.opacity(0.55)
            result += before + match
            rest = rest[found.upperBound...]
        }
        var tail = AttributedString(String(rest))
        tail.foregroundColor = Color(nsColor: color)
        return result + tail
    }
}
