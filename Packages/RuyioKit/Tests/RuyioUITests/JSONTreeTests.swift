import Testing
@testable import RuyioUI

struct JSONTreeTests {
    let sample = #"{"name": "Ruyio", "version": 1.10, "tags": ["a", "b"], "nested": {"ok": true, "none": null}, "empty": {}}"#

    @Test func keepsOrderSpellingAndStructure() throws {
        let tree = try #require(JSONTree(sample))
        let root = try #require(tree.root)
        #expect(root.kind == .object)
        #expect(root.children.map { tree.node($0).key } == ["name", "version", "tags", "nested", "empty"])
        #expect(tree.node(root.children[1]).text == "1.10", "numbers keep their spelling")
        #expect(tree.node(root.children[0]).text == "\"Ruyio\"")
        #expect(tree.sourceText(of: root.children[3]) == #"{"ok": true, "none": null}"#)
        #expect(!tree.isTruncated)
    }

    @Test func linesFoldCollapsedContainers() throws {
        let tree = try #require(JSONTree(sample))
        let all = tree.lines(collapsed: [])
        // Root, 2 scalars, tags open + 2 + close, nested open + 2 + close, empty (one line), root close.
        #expect(all.count == 13)
        let tags = try #require(tree.root?.children[2])
        let folded = tree.lines(collapsed: [tags])
        #expect(folded.count == 10)
        #expect(folded.contains { $0.node == tags && $0.role == .open })
        #expect(!folded.contains { $0.node == tags && $0.role == .close })
        #expect(tree.lines(collapsed: [0]).count == 1, "a collapsed root is one line")
        #expect(tree.hasComma(after: tags) && !tree.hasComma(after: tree.root!.children.last!))
    }

    @Test func searchFindsKeysAndValuesAndOpensTheirParents() throws {
        let tree = try #require(JSONTree(sample))
        let hits = tree.matches("O")
        // "Ruyio" (a value), then the keys "version", "ok" and "none": case-insensitive, in document order.
        #expect(hits.map { tree.node($0).key } == ["name", "version", "ok", "none"])
        let nested = tree.root!.children[3]
        #expect(tree.ancestors(of: hits) == [0, nested])
        #expect(tree.matches("  ").isEmpty)
        #expect(tree.matches("1.1").count == 1, "numbers match as written")
    }

    @Test func pathsReadLikeJavaScript() throws {
        let tree = try #require(JSONTree(#"{"data": {"items": [{"first name": "A", "id": 7}]}}"#))
        let item = tree.node(tree.node(tree.root!.children[0]).children[0]).children[0]
        let fields = tree.node(item).children
        #expect(tree.path(of: fields[0]) == #"$.data.items[0]["first name"]"#)
        #expect(tree.path(of: fields[1]) == "$.data.items[0].id")
        #expect(tree.path(of: 0) == "$")
    }

    @Test func truncatedTextStillParses() throws {
        let tree = try #require(JSONTree(#"{"a": [1, 2, {"b": "cut sho"#))
        #expect(tree.isTruncated)
        #expect(tree.node(tree.root!.children[0]).children.count == 3)
        let cutInKey = try #require(JSONTree(#"{"a": 1, "ke"#))
        #expect(cutInKey.isTruncated && cutInKey.root?.children.count == 1)
    }

    @Test func notJSONGivesNoTree() {
        #expect(JSONTree("hello") == nil)
        #expect(JSONTree("42") == nil)
        #expect(JSONTree(#"{"a": nope}"#) == nil)
        #expect(JSONTree(#"{"a" 1}"#) == nil)
    }

    @Test func largeDocumentsStartWithTheOutline() throws {
        let big = "[" + (0..<300).map { #"{"id": \#($0), "tags": ["x", "y"]}"# }.joined(separator: ",") + "]"
        let tree = try #require(JSONTree(big))
        let collapsed = tree.defaultCollapsed()
        #expect(!collapsed.isEmpty)
        #expect(collapsed.allSatisfy { tree.node($0).depth >= 2 })
        #expect(JSONTree(sample)?.defaultCollapsed().isEmpty == true)
    }
}
