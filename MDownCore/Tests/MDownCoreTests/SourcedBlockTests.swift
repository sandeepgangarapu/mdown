import XCTest
@testable import MDownCore

final class SourcedBlockTests: XCTestCase {

    // MARK: - Helpers

    private func rebuild(markdown: String, blocks: [SourcedBlock]) -> String {
        let ns = markdown as NSString
        var cursor = 0
        var rebuilt = ""
        for block in blocks {
            if block.utf16Location > cursor {
                rebuilt += ns.substring(with: NSRange(location: cursor, length: block.utf16Location - cursor))
            }
            rebuilt += block.source(in: markdown)
            cursor = block.utf16Location + block.utf16Length
        }
        rebuilt += ns.substring(from: cursor)
        return rebuilt
    }

    @discardableResult
    private func assertRoundTrip(
        _ markdown: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [SourcedBlock] {
        let blocks = MarkdownRenderModel.sourcedBlocks(from: markdown)
        var cursor = 0
        let ns = markdown as NSString
        for block in blocks {
            XCTAssertGreaterThanOrEqual(block.utf16Location, cursor, file: file, line: line)
            XCTAssertGreaterThan(block.utf16Length, 0, file: file, line: line)
            let slice = block.source(in: markdown)
            XCTAssertEqual(
                slice,
                ns.substring(with: NSRange(location: block.utf16Location, length: block.utf16Length)),
                file: file,
                line: line
            )
            cursor = block.utf16Location + block.utf16Length
        }
        XCTAssertEqual(rebuild(markdown: markdown, blocks: blocks), markdown, file: file, line: line)
        return blocks
    }

    // 1. Empty string and whitespace-only.
    func testEmptyStringAndWhitespaceOnlyRoundTrip() {
        XCTAssertEqual(assertRoundTrip("").count, 0)

        let whitespace = "   \n\t  \n"
        let blocks = assertRoundTrip(whitespace)
        XCTAssertTrue(blocks.isEmpty, "Whitespace-only should produce no sourced blocks; gaps preserve the full string")
        XCTAssertEqual(rebuild(markdown: whitespace, blocks: blocks), whitespace)
    }

    // 2. Heading plus paragraph with no trailing newline.
    func testHeadingAndParagraphNoTrailingNewline() {
        let markdown = "# Title\n\nBody line"
        let blocks = assertRoundTrip(markdown)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks[0].source(in: markdown).hasPrefix("# Title"))
        guard case .heading(1, _) = blocks[0].block else { return XCTFail("Expected h1") }
        XCTAssertEqual(blocks[1].source(in: markdown), "Body line")
        guard case .paragraph = blocks[1].block else { return XCTFail("Expected paragraph") }
        XCTAssertFalse(markdown.hasSuffix("\n"))
    }

    // 3. CRLF (\r\n) heading and paragraph.
    func testCRLFHeadingAndParagraph() {
        let markdown = "# CRLF Title\r\n\r\nCRLF body\r\n"
        let blocks = assertRoundTrip(markdown)
        XCTAssertGreaterThanOrEqual(blocks.count, 2)
        XCTAssertEqual(
            blocks[0].source(in: markdown).trimmingCharacters(in: .whitespacesAndNewlines),
            "# CRLF Title"
        )
        XCTAssertTrue(blocks[1].source(in: markdown).contains("CRLF body"))
        let gapStart = blocks[0].utf16Location + blocks[0].utf16Length
        let gap = MarkdownText.substring(
            markdown,
            utf16Location: gapStart,
            utf16Length: blocks[1].utf16Location - gapStart
        )
        let carried = blocks[0].source(in: markdown) + gap + blocks[1].source(in: markdown)
        XCTAssertTrue(carried.contains("\r\n"))
        XCTAssertFalse(carried.contains("\n") && !carried.contains("\r"))
    }

    // 4. Emoji / non-BMP in heading and paragraph, plus emoji-only paragraph.
    func testEmojiAndNonBMPInBlocks() {
        let markdown = """
        # Cake 🎂

        Party 🎉 with text.

        🎂
        """
        let blocks = assertRoundTrip(markdown)
        XCTAssertGreaterThanOrEqual(blocks.count, 3)
        XCTAssertTrue(blocks[0].source(in: markdown).contains("🎂"))
        XCTAssertTrue(blocks[1].source(in: markdown).contains("🎉"))
        XCTAssertEqual(blocks[2].source(in: markdown).trimmingCharacters(in: .whitespacesAndNewlines), "🎂")
        XCTAssertEqual(MarkdownText.utf16Length(of: "🎂"), 2)
    }

    // 5. Fenced code block including the fences.
    func testFencedCodeBlockSourceIncludesFences() {
        let markdown = """
        Intro

        ```swift
        let n = 1
        ```

        Tail
        """
        let blocks = assertRoundTrip(markdown)
        guard let code = blocks.first(where: {
            if case .code = $0.block { return true } else { return false }
        }) else { return XCTFail("Missing code block") }
        let slice = code.source(in: markdown)
        XCTAssertTrue(slice.contains("```swift"))
        XCTAssertTrue(slice.contains("```"))
        XCTAssertTrue(slice.contains("let n = 1"))
        guard case let .code(language, source) = code.block else { return XCTFail("Expected code node") }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(source.contains("let n = 1"))
    }

    // 6. Block quote of two paragraphs; source includes "> " markers.
    func testBlockQuoteTwoParagraphsWithMarkers() {
        let markdown = """
        > First quoted line
        >
        > Second quoted line
        """
        let blocks = assertRoundTrip(markdown)
        guard let quote = blocks.first(where: {
            if case .quote = $0.block { return true } else { return false }
        }) else { return XCTFail("Missing block quote") }
        let slice = quote.source(in: markdown)
        XCTAssertTrue(slice.contains("> First"))
        XCTAssertTrue(slice.contains("> Second"))
        guard case let .quote(children) = quote.block else { return XCTFail("Expected quote") }
        XCTAssertEqual(children.count, 2)
    }

    // 7. Unordered, task, ordered (start 3), nested list inside parent list source.
    func testListsIncludingNestedInsideParentSource() {
        let markdown = """
        - Plain
        - [x] Done
        - [ ] Open
          - Nested child

        3. Third item
        """
        let blocks = assertRoundTrip(markdown)
        guard let bullet = blocks.first(where: {
            if case .bulletList = $0.block { return true } else { return false }
        }) else { return XCTFail("Missing bullet list") }
        let bulletSlice = bullet.source(in: markdown)
        XCTAssertTrue(bulletSlice.contains("- [x] Done"))
        XCTAssertTrue(bulletSlice.contains("- [ ] Open"))
        XCTAssertTrue(bulletSlice.contains("Nested child"))

        guard let ordered = blocks.first(where: {
            if case .orderedList = $0.block { return true } else { return false }
        }) else { return XCTFail("Missing ordered list") }
        XCTAssertTrue(ordered.source(in: markdown).contains("3. Third"))
        guard case let .orderedList(start, _) = ordered.block else { return XCTFail("Expected ordered list") }
        XCTAssertEqual(start, 3)

        guard case let .bulletList(items) = bullet.block else { return XCTFail("Expected bullet list node") }
        let nestedInParent = items.contains { item in
            item.children.contains { child in
                if case .bulletList = child { return true }
                return false
            }
        }
        XCTAssertTrue(nestedInParent)
    }

    // 8. GFM table including the alignment row.
    func testGFMTableIncludingAlignmentRow() {
        let markdown = """
        | Name | Center | Right |
        | --- | :---: | ---: |
        | Ada | b | 10 |
        """
        let blocks = assertRoundTrip(markdown)
        guard let tableBlock = blocks.first else { return XCTFail("Expected table block") }
        let slice = tableBlock.source(in: markdown)
        XCTAssertTrue(slice.contains("| Name |"))
        XCTAssertTrue(slice.contains(":---:"))
        XCTAssertTrue(slice.contains("---:"))
        guard case let .table(alignments, _, rows) = tableBlock.block else { return XCTFail("Expected table") }
        XCTAssertEqual(alignments, [.leading, .center, .trailing])
        XCTAssertEqual(rows.count, 1)
    }

    // 9. Thematic break.
    func testThematicBreak() {
        let markdown = """
        Before

        ---

        After
        """
        let blocks = assertRoundTrip(markdown)
        guard let rule = blocks.first(where: {
            if case .rule = $0.block { return true } else { return false }
        }) else { return XCTFail("Missing thematic break") }
        let slice = rule.source(in: markdown).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(slice == "---" || slice.hasPrefix("---"))
    }

    // 10. HTML block.
    func testHTMLBlock() {
        let markdown = "<section>\n<p>Hi</p>\n</section>\n"
        let blocks = assertRoundTrip(markdown)
        guard let htmlBlock = blocks.first else { return XCTFail("Expected html block") }
        guard case .html = htmlBlock.block else { return XCTFail("Expected html node") }
        XCTAssertTrue(htmlBlock.source(in: markdown).contains("<section>"))
    }

    // 11. Figure image and paragraph with inline image.
    func testFigureAndInlineImageParagraph() {
        let markdown = """
        ![Alt only](https://example.com/figure.png)

        Hello ![Inline](https://example.com/inline.png) world
        """
        let blocks = assertRoundTrip(markdown)
        XCTAssertGreaterThanOrEqual(blocks.count, 2)
        guard case .figure = blocks[0].block else { return XCTFail("First block should be figure") }
        XCTAssertTrue(blocks[0].source(in: markdown).contains("![Alt only]"))

        guard case let .paragraph(nodes) = blocks[1].block else { return XCTFail("Second block should be paragraph") }
        XCTAssertTrue(nodes.contains { if case .image = $0 { return true } else { return false } })
        XCTAssertTrue(blocks[1].source(in: markdown).contains("![Inline]"))
    }

    // 12. YAML front matter preserved in gaps when not its own block.
    func testYAMLFrontMatterPreservedInRoundTrip() {
        let markdown = """
        ---
        title: MDown
        draft: true
        ---

        # After front matter
        """
        let blocks = assertRoundTrip(markdown)
        XCTAssertFalse(blocks.isEmpty)
        let hasFrontMatterBlock = blocks.contains { block in
            block.source(in: markdown).contains("title: MDown")
        }
        if !hasFrontMatterBlock {
            let ns = markdown as NSString
            let firstBlockStart = blocks[0].utf16Location
            let gap = ns.substring(with: NSRange(location: 0, length: firstBlockStart))
            XCTAssertTrue(gap.contains("---"))
            XCTAssertTrue(gap.contains("title: MDown"))
        }
        XCTAssertTrue(blocks.contains { $0.source(in: markdown).contains("# After front matter") })
    }

    // 13. Replace middle block; neighbors byte-for-byte unchanged.
    func testReplaceMiddleBlockPreservesNeighbors() {
        let markdown = """
        # First

        Middle **bold**

        # Last
        """
        let blocks = assertRoundTrip(markdown)
        XCTAssertEqual(blocks.count, 3)
        let middle = blocks[1]
        let before = MarkdownText.substring(
            markdown,
            utf16Location: 0,
            utf16Length: middle.utf16Location
        )
        let afterStart = middle.utf16Location + middle.utf16Length
        let afterLength = MarkdownText.utf16Length(of: markdown) - afterStart
        let after = MarkdownText.substring(markdown, utf16Location: afterStart, utf16Length: afterLength)

        let replacement = "Replaced plain line"
        let replaced = MarkdownText.replace(
            markdown,
            utf16Location: middle.utf16Location,
            utf16Length: middle.utf16Length,
            with: replacement
        )
        XCTAssertEqual(replaced, before + replacement + after)

        let newBlocks = MarkdownRenderModel.sourcedBlocks(from: replaced)
        XCTAssertGreaterThanOrEqual(newBlocks.count, 3)
        XCTAssertEqual(newBlocks[0].source(in: replaced), blocks[0].source(in: markdown))
        XCTAssertEqual(newBlocks[newBlocks.count - 1].source(in: replaced), blocks[blocks.count - 1].source(in: markdown))
        XCTAssertTrue(newBlocks[1].source(in: replaced).contains("Replaced plain"))
        XCTAssertFalse(replaced.contains("Middle **bold**"))
    }

    // 14. Replace a block with "" and reparse; neighbors not duplicated or lost.
    func testReplaceBlockWithEmptyStringReparseNeighbors() {
        let markdown = """
        Alpha

        Beta line

        Gamma
        """
        let blocks = assertRoundTrip(markdown)
        XCTAssertEqual(blocks.count, 3)
        let victim = blocks[1]
        let alphaSource = blocks[0].source(in: markdown)
        let gammaSource = blocks[2].source(in: markdown)

        let cleared = MarkdownText.replace(
            markdown,
            utf16Location: victim.utf16Location,
            utf16Length: victim.utf16Length,
            with: ""
        )
        let again = MarkdownRenderModel.sourcedBlocks(from: cleared)
        XCTAssertEqual(again.count, 2)
        XCTAssertEqual(again[0].source(in: cleared), alphaSource)
        XCTAssertEqual(again[1].source(in: cleared), gammaSource)
        XCTAssertEqual(rebuild(markdown: cleared, blocks: again), cleared)
    }

    // 15. Document ending with no newline, and one ending with two newlines.
    func testDocumentTrailingNewlineVariants() {
        let noFinalNewline = "# End\n\nNo newline tail"
        let blocksNoNL = assertRoundTrip(noFinalNewline)
        XCTAssertFalse(noFinalNewline.hasSuffix("\n"))
        XCTAssertEqual(blocksNoNL.last?.source(in: noFinalNewline), "No newline tail")

        let twoTrailingNewlines = "# End\n\nTail line\n\n"
        let blocksTwoNL = assertRoundTrip(twoTrailingNewlines)
        XCTAssertTrue(twoTrailingNewlines.hasSuffix("\n\n"))
        XCTAssertTrue(blocksTwoNL.contains { $0.source(in: twoTrailingNewlines).contains("Tail line") })
        XCTAssertEqual(rebuild(markdown: twoTrailingNewlines, blocks: blocksTwoNL), twoTrailingNewlines)
    }
}
