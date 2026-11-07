import XCTest
@testable import MDownCore

final class BlockKeyRulesTests: XCTestCase {
    private func length(_ s: String) -> Int { (s as NSString).length }
    private func enter(_ text: String, at caret: Int? = nil) -> ReturnOutcome {
        BlockKeyRules.returnKey(in: text, selection: NSRange(location: caret ?? length(text), length: 0))
    }
    private func paragraph(_ text: String) -> BlockNode { .paragraph([.text(text)]) }

    func testParagraphAndHeadingSplitsTrimAndParse() {
        for (text, caret, before, after) in [
            ("hello world", 5, "hello", "world"),
            ("hello \t  world", 8, "hello", "world"),
            ("# Heading paragraph", 9, "# Heading", "paragraph"),
            ("🎂 next", 2, "🎂", "next"),
            ("abc\n  def", 3, "abc", "def"),
            ("abc", 3, "abc", "")
        ] {
            XCTAssertEqual(enter(text, at: caret), .split(before: before, after: after), text)
            let inserted = EditingText.insertBlock(after, into: before, at: length(before))
            let blocks = MarkdownRenderModel.blocks(from: inserted.text)
            XCTAssertEqual(blocks.count, after.isEmpty ? 1 : 2)
            if text.hasPrefix("#") {
                XCTAssertEqual(blocks, [.heading(level: 1, inlines: [.text("Heading")]), paragraph("paragraph")])
            }
        }
    }

    func testReturnFallsThroughAtStartOrForSelection() {
        for text in ["", "abc", "# Heading", "- item", "> quote", "```swift"] {
            XCTAssertEqual(enter(text, at: 0), .none)
            XCTAssertEqual(BlockKeyRules.returnKey(in: text, selection: NSRange(location: 0, length: length(text))), .none)
        }
        XCTAssertEqual(enter("abc", at: 99), .none)
    }

    func testAllListMarkersContinueAndOrderedNumbersIncrement() {
        for (prefix, next) in [("- ", "- "), ("* ", "* "), ("+ ", "+ "), ("1. ", "2. "), ("9) ", "10) "), ("99. ", "100. "), ("  - ", "  - "), ("        + ", "        + "), ("-\t", "-\t")] {
            let text = prefix + "🎂AB"
            let caret = length(prefix + "🎂A")
            XCTAssertEqual(enter(text, at: caret), .replace(text: prefix + "🎂A\n" + next + "B", caret: caret + 1 + length(next)), prefix)
        }
        let text = "- A"
        guard case let .replace(updated, _) = enter(text) else { return XCTFail("Expected continuation") }
        XCTAssertEqual(MarkdownRenderModel.blocks(from: updated), [.bulletList([
            ListItemNode(check: nil, children: [paragraph("A")]), ListItemNode(check: nil, children: [])
        ])])
    }

    func testTaskContinuationResetsCheckboxAndKeepsTail() {
        for marker in ["-", "*", "+", "3.", "3)"] {
            for box in ["[ ]", "[x]", "[X]"] {
                let prefix = "  \(marker) \(box) "
                let nextMarker = marker == "3." ? "4." : marker == "3)" ? "4)" : marker
                let next = "  \(nextMarker) [ ] "
                XCTAssertEqual(enter(prefix + "AB", at: length(prefix + "A")), .replace(text: prefix + "A\n" + next + "B", caret: length(prefix + "A\n" + next)))
            }
        }
        guard case let .replace(updated, _) = enter("- [x] AB", at: 7) else { return XCTFail("Expected continuation") }
        guard case let .bulletList(items) = MarkdownRenderModel.blocks(from: updated).first else { return XCTFail("Expected task list") }
        XCTAssertEqual(items.map(\.check), [.checked, .unchecked])
        XCTAssertEqual(items.map(\.children), [[paragraph("A")], [paragraph("B")]])
    }

    func testReturnInsideListAndQuoteMarkersFallsThrough() {
        for prefix in ["- ", "  10. ", "- [x] ", "> ", "  >> "] {
            for offset in 0..<length(prefix) { XCTAssertEqual(enter(prefix + "A", at: offset), .none, "\(prefix), \(offset)") }
        }
    }

    func testEmptyListItemsLeaveAndPreserveFollowingIndentation() {
        for marker in ["- ", "* ", "+ ", "1. ", "1) ", "  - [ ] ", "- [x] ", "-", "1.", "- [x]"] {
            XCTAssertEqual(enter(marker), .split(before: "", after: ""), marker)
        }
        let text = "- A\n  - \n  - B\n- C"
        XCTAssertEqual(enter(text, at: length("- A\n  - ")), .split(before: "- A", after: "  - B\n- C"))
        XCTAssertEqual(enter("- A\r\n- \r\n- B", at: 8), .split(before: "- A", after: "- B"))
    }

    func testQuoteContinuationAndExit() {
        XCTAssertEqual(enter("> AB", at: 3), .replace(text: "> A\n> B", caret: 6))
        XCTAssertEqual(enter("  >> A"), .replace(text: "  >> A\n  >> ", caret: 12))
        for text in [">", "> ", ">> ", "   > \t"] { XCTAssertEqual(enter(text), .split(before: "", after: "")) }
        XCTAssertEqual(enter("> A\n> \n> B", at: 6), .split(before: "> A", after: "> B"))
        guard case let .replace(updated, _) = enter("> A") else { return XCTFail("Expected quote continuation") }
        guard case .quote = MarkdownRenderModel.blocks(from: updated).first else { return XCTFail("Lost quote") }
    }

    func testVerbatimBlocksKeepPlainReturnEverywhere() {
        for text in ["```swift\n- A\n```", "~~~\nx\n~~~", "| H |\n| - |\n| x |", "<div>\n- A\n</div>", "   ```\nx\n```"] {
            for offset in 0...length(text) { XCTAssertEqual(enter(text, at: offset), .none, text) }
            XCTAssertNil(BlockKeyRules.tab(in: text, selection: NSRange(location: 0, length: 0), outdent: false))
        }
    }

    func testOpeningFenceClosesAndCaretIsOnEmptyLine() {
        for (opening, closing, language) in [("```", "```", Optional<String>.none), ("```swift", "```", "swift"), ("~~~", "~~~", nil), ("~~~python", "~~~", "python"), ("  ```swift", "  ```", "swift"), ("````swift", "````", "swift"), ("~~~~", "~~~~", nil)] {
            let expected = opening + "\n\n" + closing
            XCTAssertEqual(enter(opening), .replace(text: expected, caret: length(opening) + 1))
            let blocks = MarkdownRenderModel.blocks(from: expected)
            XCTAssertEqual(blocks.count, 1)
            guard case let .code(actualLanguage, source) = blocks.first else { XCTFail("Expected code"); continue }
            XCTAssertEqual(actualLanguage, language)
            XCTAssertTrue(source.trimmingCharacters(in: .newlines).isEmpty)
            // Text appended after the closing fence must remain outside the code block.
            XCTAssertEqual(MarkdownRenderModel.blocks(from: expected + "\n\nTail").count, 2)
        }
        XCTAssertEqual(enter("```bad`info"), .none)
        XCTAssertEqual(enter("```swift\n"), .none)
    }

    func testTabMovesWholeSubtreeAndParserConfirmsNesting() throws {
        let text = "- A\n- B\n  - C"
        let result = try XCTUnwrap(BlockKeyRules.tab(in: text, selection: NSRange(location: 6, length: 0), outdent: false))
        XCTAssertEqual(result.text, "- A\n  - B\n    - C")
        XCTAssertEqual(result.selection, NSRange(location: 8, length: 0))
        let c = ListItemNode(check: nil, children: [paragraph("C")])
        let b = ListItemNode(check: nil, children: [paragraph("B"), .bulletList([c])])
        XCTAssertEqual(MarkdownRenderModel.blocks(from: result.text), [.bulletList([ListItemNode(check: nil, children: [paragraph("A"), .bulletList([b])])])])
        let restored = try XCTUnwrap(BlockKeyRules.tab(in: result.text, selection: result.selection, outdent: true))
        XCTAssertEqual(restored.text, text)
        XCTAssertEqual(restored.selection, NSRange(location: 6, length: 0))
    }

    func testOrderedParentMarkerWidthDeterminesNesting() throws {
        for (parent, width) in [("-", 2), ("1. A", 3), ("10. A", 4), ("10) A", 4), ("- [x] A", 2)] {
            let text = parent + "\n- B\n  - C\n- D"
            let offset = length(parent + "\n- ")
            let result = try XCTUnwrap(BlockKeyRules.tab(in: text, selection: NSRange(location: offset, length: 0), outdent: false))
            XCTAssertEqual(result.text, parent + "\n" + String(repeating: " ", count: width) + "- B\n" + String(repeating: " ", count: width + 2) + "- C\n- D")
            XCTAssertEqual(result.selection.location, offset + width)
            let blocks = MarkdownRenderModel.blocks(from: result.text)
            let items: [ListItemNode]
            switch blocks.first {
            case let .orderedList(_, value), let .bulletList(value): items = value
            default: return XCTFail("Missing parent list")
            }
            XCTAssertTrue(items[0].children.contains { if case .bulletList = $0 { return true }; return false })
        }
    }

    func testTabMovesContinuationLinesAndInternalBlanksButNotNextSibling() throws {
        let text = "- A\n- B\n\n  continuation 🎂\n  - C\n\n- D"
        let result = try XCTUnwrap(BlockKeyRules.tab(in: text, selection: NSRange(location: 6, length: 0), outdent: false))
        XCTAssertEqual(result.text, "- A\n  - B\n\n    continuation 🎂\n    - C\n\n- D")
        guard case let .bulletList(items) = MarkdownRenderModel.blocks(from: result.text).first else { return XCTFail("Missing list") }
        XCTAssertEqual(items.count, 2)
        guard case let .bulletList(nested) = items[0].children.last else { return XCTFail("Missing child") }
        XCTAssertEqual(nested.count, 1)
    }

    func testOutdentUsesNearestShallowerItemAndZeroFallback() throws {
        for (text, token, expected) in [
            ("- A\n   - B\n       - C\n         child", "C", "- A\n   - B\n   - C\n     child"),
            ("    - A", "A", "- A")
        ] {
            let offset = (text as NSString).range(of: token).location
            let result = try XCTUnwrap(BlockKeyRules.tab(in: text, selection: NSRange(location: offset, length: 0), outdent: true))
            XCTAssertEqual(result.text, expected)
            XCTAssertEqual((result.text as NSString).substring(with: NSRange(location: result.selection.location, length: 1)), token)
        }
    }

    func testTabNoOps() {
        for (text, offset, outdent) in [("paragraph", 2, false), ("- A", 2, false), ("- A\n  - B", 8, false), ("- A", 2, true), ("", 0, false), ("- A", 99, false)] {
            XCTAssertNil(BlockKeyRules.tab(in: text, selection: NSRange(location: offset, length: 0), outdent: outdent), text)
        }
    }

    func testTabSelectionTracksUTF16AndBothEndpointsAcrossSubtree() throws {
        let text = "- 🎂\n- Bee\n  - Child\n- Tail"
        let start = (text as NSString).range(of: "Bee").location
        let end = (text as NSString).range(of: "Child").location + 5
        let result = try XCTUnwrap(BlockKeyRules.tab(in: text, selection: NSRange(location: start, length: end - start), outdent: false))
        XCTAssertEqual(result.selection.location, start + 2)
        XCTAssertEqual(result.selection.length, end - start + 2)
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "Bee\n    - Child")
        let restored = try XCTUnwrap(BlockKeyRules.tab(in: result.text, selection: result.selection, outdent: true))
        XCTAssertEqual(restored.text, text)
        XCTAssertEqual(restored.selection, NSRange(location: start, length: end - start))
    }
    func testTabIndentationUsesCommonMarkColumnsAndReturnPreservesIndent() throws {
        XCTAssertEqual(enter("\t- A"), .replace(text: "\t- A\n\t- ", caret: 8))
        let text = "- A\n\t- B\n\t  - C"
        let result = try XCTUnwrap(BlockKeyRules.tab(in: text, selection: NSRange(location: 7, length: 0), outdent: true))
        XCTAssertEqual(result.text, "- A\n- B\n  - C")
        XCTAssertEqual(result.selection.location, 6)
        let tabSpaced = try XCTUnwrap(BlockKeyRules.tab(in: "-\tA\n- B", selection: NSRange(location: 6, length: 0), outdent: false))
        XCTAssertEqual(tabSpaced.text, "-\tA\n    - B")
        guard case let .bulletList(items) = MarkdownRenderModel.blocks(from: tabSpaced.text).first else { return XCTFail("Expected list") }
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].children.contains { if case .bulletList = $0 { return true }; return false })
    }

    func testTabCRLFPreservesLineEndingsAndSingleLineSelection() throws {
        let text = "- 🎂\r\n- Bee\r\n  - Child\r\n- Tail"
        let start = (text as NSString).range(of: "Bee").location
        let result = try XCTUnwrap(BlockKeyRules.tab(in: text, selection: NSRange(location: start, length: 3), outdent: false))
        XCTAssertEqual(result.text, "- 🎂\r\n  - Bee\r\n    - Child\r\n- Tail")
        XCTAssertEqual(result.selection, NSRange(location: start + 2, length: 3))
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "Bee")
    }

    func testInvalidSelectionsFallThrough() {
        for selection in [NSRange(location: -1, length: 0), NSRange(location: NSNotFound, length: 0), NSRange(location: 2, length: 100), NSRange(location: 2, length: -1)] {
            XCTAssertEqual(BlockKeyRules.returnKey(in: "- A", selection: selection), .none)
            XCTAssertNil(BlockKeyRules.tab(in: "- A", selection: selection, outdent: false))
        }
    }

}
