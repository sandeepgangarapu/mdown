import XCTest
@testable import MDownCore

final class MarkdownNavigationTests: XCTestCase {
    func testTasksFollowRenderModelDepthFirstOrder() {
        let source = "> - [ ] 🎂 parent\r\n>   - [X] 中文 child\r\n>   - ordinary [ ] text\r\n> - [x] sibling\r\n>\r\n>   ```\r\n>   - [ ] fake\r\n>   ```\r\n"
        let needles = ["[ ] 🎂", "[X] 中文", "[x] sibling"]
        for (index, needle) in needles.enumerated() {
            let ns = source as NSString
            let character = ns.range(of: needle).location + 1
            let expected = ns.replacingCharacters(in: NSRange(location: character, length: 1), with: index == 0 ? "x" : " ")
            XCTAssertEqual(MarkdownTasks.toggle(taskAt: index, in: source), expected)
        }
        XCTAssertNil(MarkdownTasks.toggle(taskAt: 3, in: source))
        XCTAssertNil(MarkdownTasks.toggle(taskAt: -1, in: source))
    }

    func testTaskMarkersAndLookalikes() {
        for marker in ["-", "*", "+", "1.", "1)"] {
            let source = "\(marker) [ ] 中🎂\r\n"
            XCTAssertEqual(MarkdownTasks.toggle(taskAt: 0, in: source), source.replacingOccurrences(of: "[ ]", with: "[x]"))
        }
        for source in ["", "text [ ] hi", "```\n- [ ] fake\n```", "    - [ ] code", "- ordinary [ ] text"] {
            XCTAssertNil(MarkdownTasks.toggle(taskAt: 0, in: source), source)
        }
    }

    func testTaskIndicesMatchRenderedCheckNodes() {
        let source = "- [ ] parent\n  - [x] child\n    1. [ ] grandchild\n- plain\n- [X] end"
        func checks(_ blocks: [BlockNode]) -> [ListItemNode.Check] {
            blocks.flatMap { block -> [ListItemNode.Check] in
                switch block {
                case let .bulletList(items), let .orderedList(_, items):
                    return items.flatMap { item in (item.check.map { [$0] } ?? []) + checks(item.children) }
                case let .quote(children): return checks(children)
                default: return []
                }
            }
        }
        let original = checks(MarkdownRenderModel.blocks(from: source))
        XCTAssertEqual(original.count, 4)
        for index in original.indices {
            let updated = MarkdownTasks.toggle(taskAt: index, in: source)!
            var expected = original
            expected[index] = original[index] == .checked ? .unchecked : .checked
            XCTAssertEqual(checks(MarkdownRenderModel.blocks(from: updated)), expected)
        }
    }

    func testQuotedTasksRenderAndToggleFromSlicedBlock() {
        let document = "# Before\r\n\r\n> - [ ] **🎂**\r\n>   - [X] 中文\r\n\r\nAfter"
        let blocks = MarkdownRenderModel.sourcedBlocks(from: document)
        guard let quote = blocks.first(where: { if case .quote = $0.block { return true }; return false }),
              case let .quote(children) = quote.block,
              case let .bulletList(items) = children.first else { return XCTFail("Missing quote list") }
        XCTAssertEqual(items[0].check, .unchecked)
        guard case let .paragraph(inlines) = items[0].children.first else { return XCTFail("Missing paragraph") }
        XCTAssertEqual(InlinePlainText.string(from: inlines), "🎂")
        let slice = quote.source(in: document)
        let expected = slice.replacingOccurrences(of: "[X]", with: "[ ]")
        XCTAssertEqual(MarkdownTasks.toggle(taskAt: 1, in: slice).map { Array($0.utf8) }, Array(expected.utf8))
        XCTAssertNil(MarkdownTasks.toggle(taskAt: 0, in: "> - \\[ ] escaped"))
    }

    func testTaskStateComesFromItsOwnMarker() {
        let source = "- [ ] text containing [x] later"
        guard case let .bulletList(items) = MarkdownRenderModel.blocks(from: source).first else { return XCTFail("Missing list") }
        XCTAssertEqual(items[0].check, .unchecked)
        XCTAssertEqual(MarkdownTasks.toggle(taskAt: 0, in: source), "- [x] text containing [x] later")
    }

    func testOutlineOnlyIncludesTopLevelHeadings() {
        let source = "# **🎂** [中文](url) `code`\r\n\r\n> # Nested\r\n\r\n##\r\n\r\nSetext\r\n------\r\n\r\n```\r\n# Fake\r\n```"
        let blocks = MarkdownRenderModel.sourcedBlocks(from: source)
        let entries = MarkdownOutline.entries(from: blocks)
        XCTAssertEqual(entries.map(\.level), [1, 2, 2])
        XCTAssertEqual(entries.map(\.title), ["🎂 中文 code", "Untitled", "Setext"])
        XCTAssertEqual(entries.map(\.utf16Location), [0, (source as NSString).range(of: "##").location, (source as NSString).range(of: "Setext").location])
        XCTAssertEqual(entries.map(\.id), entries.map(\.utf16Location))
        XCTAssertEqual(Set(entries).count, 3)
        XCTAssertEqual(MarkdownOutline.entries(from: []), [])
        XCTAssertEqual(OutlineEntry(level: 3, title: "X", utf16Location: 9).id, 9)
    }

    func testLargeDocumentSlicesReparseInOrder() {
        let source = (0..<2000).map { index in
            "Paragraph \(index) 🎂 中文 " + String(repeating: "word ", count: 16) + "end\r\n\r\n"
        }.joined()
        XCTAssertGreaterThan(source.utf8.count, 200_000)
        let blocks = MarkdownRenderModel.sourcedBlocks(from: source)
        XCTAssertEqual(blocks.count, 2000)
        var cursor = 0
        let ns = source as NSString
        var rebuilt = ""
        for block in blocks {
            XCTAssertGreaterThanOrEqual(block.utf16Location, cursor)
            rebuilt += ns.substring(with: NSRange(location: cursor, length: block.utf16Location - cursor))
            let slice = block.source(in: source)
            XCTAssertEqual(MarkdownRenderModel.blocks(from: slice), [block.block])
            rebuilt += slice
            cursor = block.utf16Location + block.utf16Length
        }
        rebuilt += ns.substring(from: cursor)
        XCTAssertEqual(rebuilt, source)
    }

    func testUnicodeSourceOffsetsAndLineEndings() {
        for newline in ["\n", "\r", "\r\n"] {
            let source = "# e\u{301}🎂中文\(newline)\(newline)Second 👩🏽‍💻\(newline)\(newline)## End"
            let blocks = MarkdownRenderModel.sourcedBlocks(from: source)
            XCTAssertEqual(blocks.count, 3)
            XCTAssertEqual(blocks[0].source(in: source), "# e\u{301}🎂中文")
            XCTAssertEqual(blocks[1].source(in: source), "Second 👩🏽‍💻")
            XCTAssertEqual(blocks[2].source(in: source), "## End")
        }
    }
}
