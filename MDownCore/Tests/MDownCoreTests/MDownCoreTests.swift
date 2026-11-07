import XCTest
@testable import MDownCore

final class MDownCoreTests: XCTestCase {
    func testHeadingsParagraphAndInlineMarkup() {
        let blocks = MarkdownRenderModel.blocks(from: """
        # Title

        A **bold** and *italic* word with `code` and ~~gone~~.
        """)
        guard case let .heading(level, inlines) = blocks[0] else {
            return XCTFail("Expected a heading, got \(blocks)")
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(InlinePlainText.string(from: inlines), "Title")

        guard case let .paragraph(nodes) = blocks[1] else {
            return XCTFail("Expected a paragraph")
        }
        XCTAssertTrue(nodes.contains { if case .strong = $0 { return true } else { return false } })
        XCTAssertTrue(nodes.contains { if case .emphasis = $0 { return true } else { return false } })
        XCTAssertTrue(nodes.contains { if case .code("code") = $0 { return true } else { return false } })
        XCTAssertTrue(nodes.contains { if case .strikethrough = $0 { return true } else { return false } })
    }

    func testLinkAndHardBreak() {
        let blocks = MarkdownRenderModel.blocks(from: "See [Swift](https://www.swift.org).\n\nLine one  \nLine two\n")
        guard case let .paragraph(first) = blocks[0] else { return XCTFail("Missing paragraph") }
        guard case let .link(destination, _, children) = first.dropFirst().first ?? first[1] else {
            return XCTFail("Missing link in \(first)")
        }
        XCTAssertEqual(destination, "https://www.swift.org")
        XCTAssertEqual(InlinePlainText.string(from: children), "Swift")

        guard case let .paragraph(second) = blocks[1] else { return XCTFail("Missing hard break paragraph: \(blocks)") }
        XCTAssertTrue(second.contains { if case .lineBreak = $0 { return true } else { return false } })
    }

    func testListsQuoteAndRule() {
        let blocks = MarkdownRenderModel.blocks(from: """
        > Quoted

        - [x] Done
        - [ ] Open
          - Nested

        3. Third

        ---
        """)
        XCTAssertTrue(blocks.contains { if case .quote = $0 { return true } else { return false } })
        guard let tasks = blocks.compactMap({ block -> [ListItemNode]? in
            if case let .bulletList(items) = block { return items }
            return nil
        }).first else {
            return XCTFail("Missing task list: \(blocks)")
        }
        XCTAssertEqual(tasks[0].check, .checked)
        XCTAssertEqual(tasks[1].check, .unchecked)
        XCTAssertTrue(tasks[1].children.contains { if case .bulletList = $0 { return true } else { return false } })

        guard case let .orderedList(start, items) = blocks.first(where: {
            if case .orderedList = $0 { return true } else { return false }
        }) else {
            return XCTFail("Missing ordered list")
        }
        XCTAssertEqual(start, 3)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(blocks.contains { if case .rule = $0 { return true } else { return false } })
    }

    func testTableCodeAndFigure() {
        let blocks = MarkdownRenderModel.blocks(from: """
        | Name | Score |
        | --- | ---: |
        | Ada | 10 |

        ```swift
        let value = 1
        ```

        ![Alt text](https://example.com/paper.png)

        Hello ![Inline](https://example.com/inline.png)
        """)
        guard case let .table(alignments, header, rows) = blocks[0] else {
            return XCTFail("Missing table: \(blocks)")
        }
        XCTAssertEqual(alignments.last, .trailing)
        XCTAssertEqual(InlinePlainText.string(from: header[0].inlines), "Name")
        XCTAssertEqual(InlinePlainText.string(from: rows[0][1].inlines), "10")

        guard case let .code(language, source) = blocks[1] else { return XCTFail("Missing code") }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(source.contains("let value = 1"))

        guard case let .figure(sourceURL, _, alt) = blocks[2] else { return XCTFail("Missing figure: \(blocks)") }
        XCTAssertEqual(sourceURL, "https://example.com/paper.png")
        XCTAssertEqual(alt, "Alt text")

        guard case let .paragraph(nodes) = blocks[3] else { return XCTFail("Inline image should stay in a paragraph") }
        XCTAssertTrue(nodes.contains { if case .image = $0 { return true } else { return false } })
    }

    func testHTMLIsPreservedAsText() {
        let blocks = MarkdownRenderModel.blocks(from: "<div>Hello</div>\n")
        guard case let .html(raw) = blocks.first else { return XCTFail("Expected html block, got \(blocks)") }
        XCTAssertTrue(raw.contains("<div>"))
        XCTAssertFalse(raw.contains("onerror"))
    }

    func testWelcomeDocument() {
        let blocks = MarkdownRenderModel.blocks(from: WelcomeMarkdown.text)
        guard case let .heading(level, inlines) = blocks.first else {
            return XCTFail("Welcome should open with a heading")
        }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(InlinePlainText.string(from: inlines), "Welcome to MDown")
        XCTAssertTrue(blocks.contains { if case .quote = $0 { return true } else { return false } })
        XCTAssertTrue(blocks.contains { if case .table = $0 { return true } else { return false } })
        XCTAssertTrue(blocks.contains { if case let .code(language, _) = $0 { return language == "swift" } else { return false } })
        XCTAssertTrue(blocks.contains { if case let .figure(source, _, _) = $0 { return source == "bundle://SampleBanner" } else { return false } })
        XCTAssertTrue(blocks.contains { if case .rule = $0 { return true } else { return false } })
    }

    func testCodeHighlighterCoverageAndKeywords() {
        let samples = [
            ("swift", "let name = \"MDown\" // hi\nlet n = 3\n/* block */\nstruct Note {}\n"),
            ("python", "def hi():\n    return \"x\"  # note\n"),
            ("javascript", "const s = `tick ${1}`\n"),
            ("html", "<p class=\"a\">Hi</p>\n"),
            ("json", "{\"ok\": true, \"n\": 2}\n"),
            ("bash", "echo \"hi\" # comment\n"),
            ("", "plain text 🎂\n")
        ]
        for (language, code) in samples {
            assertCovers(code, language: language)
        }

        let swiftSource = "let name = \"MDown\" // hi\n"
        let swift = CodeHighlighter.tokens(in: swiftSource, language: "Swift")
        XCTAssertTrue(swift.contains { $0.kind == .keyword && slice(swiftSource, $0) == "let" })
        XCTAssertTrue(swift.contains { $0.kind == .string && slice(swiftSource, $0) == "\"MDown\"" })
        XCTAssertTrue(swift.contains { $0.kind == .comment })

        let noteSource = "struct Note {}\n"
        let note = CodeHighlighter.tokens(in: noteSource, language: "swift")
        XCTAssertTrue(note.contains { $0.kind == .typeName && slice(noteSource, $0) == "Note" })
    }

    func testSourceHighlighterMarksMarkdown() {
        let text = """
        ---
        title: MDown
        ---
        # Title

        **bold** and `code` and [Swift](https://www.swift.org)

        - Item

        ```swift
        let value = 1
        ```

        ---
        """
        let spans = MarkdownSourceHighlighter.spans(in: text)
        assertSpansInBounds(spans, text: text)
        XCTAssertTrue(spans.contains { if case .frontMatter = $0.kind { return true } else { return false } })
        XCTAssertTrue(spans.contains { if case .heading(1) = $0.kind { return true } else { return false } })
        XCTAssertTrue(spans.contains { if case .strong = $0.kind { return true } else { return false } })
        XCTAssertTrue(spans.contains { if case .inlineCode = $0.kind { return true } else { return false } })
        XCTAssertTrue(spans.contains { if case .link = $0.kind { return true } else { return false } })
        XCTAssertTrue(spans.contains { if case .marker = $0.kind { return true } else { return false } })
        XCTAssertTrue(spans.contains { if case .fence = $0.kind { return true } else { return false } })
        XCTAssertTrue(spans.contains { if case .token(.keyword) = $0.kind { return true } else { return false } })
        XCTAssertTrue(spans.contains { if case .rule = $0.kind { return true } else { return false } })
    }

    func testImageLocator() {
        XCTAssertEqual(
            ImageLocator.resolve(source: "https://example.com/a.png", relativeTo: nil),
            .remote(URL(string: "https://example.com/a.png")!)
        )
        XCTAssertEqual(
            ImageLocator.resolve(source: "javascript:alert(1)", relativeTo: nil),
            .unresolved("javascript:alert(1)")
        )
        XCTAssertEqual(ImageLocator.resolve(source: "bundle://SampleBanner", relativeTo: nil), .bundle("SampleBanner"))

        let base = URL(fileURLWithPath: "/tmp/notes")
        XCTAssertEqual(
            ImageLocator.resolve(source: "images/paper.png", relativeTo: base),
            .file(URL(fileURLWithPath: "/tmp/notes/images/paper.png"))
        )

        let payload = Data("mdown".utf8).base64EncodedString()
        let resolved = ImageLocator.resolve(source: "data:image/png;base64,\(payload)", relativeTo: nil)
        XCTAssertEqual(resolved, .data(Data("mdown".utf8)))
    }

    func testSourcedBlocksRoundTripToTheOriginalMarkdown() {
        let text = """
        # Title

        A **bold** word and a 🎂 line.

        > Quoted

        - [x] Done
        - Open

        ```swift
        let value = 1
        ```

        ---
        """
        let blocks = MarkdownRenderModel.sourcedBlocks(from: text)
        XCTAssertGreaterThanOrEqual(blocks.count, 6)
        let ns = text as NSString
        var cursor = 0
        var rebuilt = ""
        for block in blocks {
            XCTAssertGreaterThanOrEqual(block.utf16Location, cursor)
            XCTAssertGreaterThan(block.utf16Length, 0)
            let slice = block.source(in: text)
            XCTAssertEqual(
                slice,
                ns.substring(with: NSRange(location: block.utf16Location, length: block.utf16Length))
            )
            XCTAssertFalse(slice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if block.utf16Location > cursor {
                rebuilt += ns.substring(with: NSRange(location: cursor, length: block.utf16Location - cursor))
            }
            rebuilt += slice
            cursor = block.utf16Location + block.utf16Length
        }
        rebuilt += ns.substring(from: cursor)
        XCTAssertEqual(rebuilt, text)
        XCTAssertTrue(blocks[0].source(in: text).hasPrefix("# Title"))

        let renamed = MarkdownText.replace(
            text,
            utf16Location: blocks[0].utf16Location,
            utf16Length: blocks[0].utf16Length,
            with: "# Renamed"
        )
        XCTAssertTrue(renamed.contains("# Renamed"))
        XCTAssertFalse(renamed.contains("# Title"))
        XCTAssertTrue(renamed.contains("A **bold** word"))
    }

    func testDocumentStats() {
        XCTAssertEqual(DocumentStats.measure("").statusLabel, "Empty page")
        let stats = DocumentStats.measure("one two three")
        XCTAssertEqual(stats.words, 3)
        XCTAssertEqual(stats.readingMinutes, 1)
        XCTAssertEqual(stats.statusLabel, "3 words · 1 min read")

        let many = Array(repeating: "word", count: 221).joined(separator: " ")
        XCTAssertEqual(DocumentStats.measure(many).readingMinutes, 2)
    }

    private func assertCovers(_ code: String, language: String, file: StaticString = #filePath, line: UInt = #line) {
        let tokens = CodeHighlighter.tokens(in: code, language: language)
        let ns = code as NSString
        var cursor = 0
        for token in tokens {
            XCTAssertEqual(token.utf16Offset, cursor, "gap before \(token.kind) in \(language)", file: file, line: line)
            XCTAssertGreaterThan(token.utf16Length, 0, file: file, line: line)
            cursor += token.utf16Length
        }
        XCTAssertEqual(cursor, ns.length, "coverage failed for \(language)", file: file, line: line)
    }

    private func assertSpansInBounds(_ spans: [SourceSpan], text: String, file: StaticString = #filePath, line: UInt = #line) {
        let length = (text as NSString).length
        for span in spans {
            XCTAssertGreaterThanOrEqual(span.utf16Offset, 0, file: file, line: line)
            XCTAssertGreaterThan(span.utf16Length, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(span.utf16Offset + span.utf16Length, length, file: file, line: line)
        }
    }

    private func slice(_ code: String, _ token: CodeToken) -> String {
        (code as NSString).substring(with: NSRange(location: token.utf16Offset, length: token.utf16Length))
    }
}
