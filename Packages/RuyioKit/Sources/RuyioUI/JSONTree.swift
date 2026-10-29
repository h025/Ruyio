import Foundation

/// A JSON document as a tree for the collapsible preview. Parsed from the text itself, like
/// `JSONFormatting`: key order and the spelling of numbers and strings stay exactly as copied. Text cut
/// short (previews carry a prefix of large documents) still parses: open containers close at the end and
/// `isTruncated` says so.
public struct JSONTree: Sendable {
    public enum Kind: Sendable, Equatable { case object, array, string, number, literal }

    public struct Node: Sendable, Equatable {
        public var id: Int
        public var parent: Int?
        /// Object member name as written, quotes removed but escapes kept.
        public var key: String?
        /// Position in a parent array.
        public var index: Int?
        public var kind: Kind
        /// Scalars: the value as written (strings with their quotes).
        public var text: String
        public var children: [Int]
        public var depth: Int
        /// The node's span in the source, for copying it exactly.
        public var range: Range<Int>
    }

    public private(set) var nodes: [Node] = []
    public private(set) var isTruncated = false
    let source: [Character]

    public var root: Node? { nodes.first }

    /// Nil when the text is not JSON at all (a scalar alone is not worth a tree).
    public init?(_ text: String) {
        source = Array(text)
        var parser = Parser(chars: source)
        parser.skipSpace()
        guard parser.peek == "{" || parser.peek == "[" else { return nil }
        parser.value(parent: nil, key: nil, index: nil, depth: 0)
        guard parser.failed == false, !parser.nodes.isEmpty else { return nil }
        nodes = parser.nodes
        isTruncated = parser.truncated
    }

    public func node(_ id: Int) -> Node { nodes[id] }

    /// The value's own text, as copied.
    public func sourceText(of id: Int) -> String {
        let range = nodes[id].range
        return String(source[range.clamped(to: 0..<source.count)])
    }

    /// A path such as `$.data.items[3]["first name"]`.
    public func path(of id: Int) -> String {
        var parts: [String] = []
        var current: Int? = id
        while let node = current.map({ nodes[$0] }), node.parent != nil {
            if let index = node.index {
                parts.append("[\(index)]")
            } else if let key = node.key {
                let plain = !key.isEmpty && key.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber } && !(key.first?.isNumber ?? false)
                parts.append(plain ? "." + key : "[\"" + key + "\"]")
            }
            current = node.parent
        }
        return "$" + parts.reversed().joined()
    }

    /// Containers to start collapsed: none for small documents, deeper levels for large ones, so the
    /// first screen shows the outline rather than thousands of lines.
    public func defaultCollapsed() -> Set<Int> {
        guard nodes.count > 400 else { return [] }
        return Set(nodes.filter { ($0.kind == .object || $0.kind == .array) && $0.depth >= 2 && !$0.children.isEmpty }.map(\.id))
    }

    // MARK: Lines

    public struct Line: Sendable, Identifiable, Equatable {
        public enum Role: Sendable, Equatable { case open, close, scalar }
        public var node: Int
        public var role: Role
        public var depth: Int
        public var id: String { "\(node)\(role == .close ? "c" : "")" }
    }

    /// The lines to show with `collapsed` containers folded to one line each.
    public func lines(collapsed: Set<Int>) -> [Line] {
        var lines: [Line] = []
        func visit(_ id: Int) {
            let node = nodes[id]
            switch node.kind {
            case .object, .array:
                lines.append(Line(node: id, role: .open, depth: node.depth))
                guard !collapsed.contains(id), !node.children.isEmpty else { return }
                node.children.forEach(visit)
                lines.append(Line(node: id, role: .close, depth: node.depth))
            default:
                lines.append(Line(node: id, role: .scalar, depth: node.depth))
            }
        }
        if !nodes.isEmpty { visit(0) }
        return lines
    }

    /// Whether a line needs a trailing comma: it is not its parent's last child.
    public func hasComma(after id: Int) -> Bool {
        guard let parent = nodes[id].parent else { return false }
        return nodes[parent].children.last != id
    }

    // MARK: Search

    /// Nodes whose key or scalar value contains `query`, ignoring case and width, in document order.
    public func matches(_ query: String) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return nodes.filter { node in
            if let key = node.key, Self.contains(key, needle) { return true }
            switch node.kind {
            case .string: return Self.contains(String(node.text.dropFirst().dropLast()), needle)
            case .number, .literal: return Self.contains(node.text, needle)
            case .object, .array: return false
            }
        }.map(\.id)
    }

    /// Containers to open so that every node in `ids` is on screen.
    public func ancestors(of ids: [Int]) -> Set<Int> {
        var open: Set<Int> = []
        for id in ids {
            var current = nodes[id].parent
            while let parent = current, open.insert(parent).inserted { current = nodes[parent].parent }
        }
        return open
    }

    static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]) != nil
    }

    // MARK: Parser

    private struct Parser {
        let chars: [Character]
        var position = 0
        var nodes: [Node] = []
        var truncated = false
        var failed = false

        init(chars: [Character]) { self.chars = chars }

        var peek: Character? { position < chars.count ? chars[position] : nil }

        mutating func skipSpace() {
            while let c = peek, c == " " || c == "\n" || c == "\r" || c == "\t" { position += 1 }
        }

        @discardableResult
        mutating func value(parent: Int?, key: String?, index: Int?, depth: Int) -> Int? {
            skipSpace()
            guard let c = peek else { truncated = true; return nil }
            let id = nodes.count
            let start = position
            func add(_ kind: Kind, _ text: String) {
                nodes.append(Node(id: id, parent: parent, key: key, index: index, kind: kind, text: text, children: [], depth: depth,
                                  range: start..<position))
            }
            switch c {
            case "{", "[":
                let isObject = c == "{"
                nodes.append(Node(id: id, parent: parent, key: key, index: index, kind: isObject ? .object : .array, text: "",
                                  children: [], depth: depth, range: start..<start))
                position += 1
                var count = 0
                while !failed {
                    skipSpace()
                    guard let next = peek else { truncated = true; break }
                    if next == (isObject ? "}" : "]") { position += 1; break }
                    if next == "," { position += 1; continue }
                    var memberKey: String?
                    if isObject {
                        guard next == "\"" else { failed = true; break }
                        guard let name = string() else { truncated = true; break }
                        memberKey = String(name.dropFirst().dropLast())
                        skipSpace()
                        guard peek == ":" else { if peek == nil { truncated = true } else { failed = true }; break }
                        position += 1
                    }
                    guard let child = value(parent: id, key: memberKey, index: isObject ? nil : count, depth: depth + 1) else { break }
                    nodes[id].children.append(child)
                    count += 1
                }
                nodes[id].range = start..<position
                return failed ? nil : id
            case "\"":
                guard let text = string() else { truncated = true; return nil }
                add(.string, text)
            case "-", "0"..."9":
                while let d = peek, d.isNumber || "+-.eE".contains(d) { position += 1 }
                add(.number, String(chars[start..<position]))
            case "t", "f", "n":
                while let l = peek, l.isLetter { position += 1 }
                let word = String(chars[start..<position])
                guard ["true", "false", "null"].contains(word) else { failed = true; return nil }
                add(.literal, word)
            default:
                failed = true
                return nil
            }
            return id
        }

        /// A string literal with its quotes; nil when the text ends inside it.
        mutating func string() -> String? {
            let start = position
            position += 1
            var escaped = false
            while let c = peek {
                position += 1
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { return String(chars[start..<position]) }
            }
            return nil
        }
    }
}
