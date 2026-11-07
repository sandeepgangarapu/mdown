import XCTest
@testable import MDownCore

final class CoreRegressionTests: XCTestCase {
    func testExtremeRangesDoNotOverflow() {
        XCTAssertEqual(MarkdownText.substring("abc", utf16Location: Int.max, utf16Length: Int.max), "")
        XCTAssertEqual(MarkdownText.replace("abc", utf16Location: Int.max, utf16Length: Int.max, with: "x"), "abc")
        XCTAssertEqual(MarkdownText.substring("abc", utf16Location: -1, utf16Length: 1), "")
    }

    func testCRLFCommentsAndUnterminatedStringsStopAtNewline() {
        for (language, comment) in [("swift", "// 🎂"), ("python", "# 中文")] {
            let source = "\(comment)\r\nreturn 1"
            let tokens = CodeHighlighter.tokens(in: source, language: language)
            XCTAssertEqual(tokens.first?.utf16Length, (comment as NSString).length)
            XCTAssertTrue(tokens.contains { $0.kind == .keyword && (source as NSString).substring(with: NSRange(location: $0.utf16Offset, length: $0.utf16Length)) == "return" })
        }
        let source = "\"oops\r\nreturn 1"
        XCTAssertEqual(CodeHighlighter.tokens(in: source, language: "swift").first?.utf16Length, 5)
    }

    func testEncodedLocalImagePathsDecodeOnce() {
        let base = URL(fileURLWithPath: "/tmp/notes", isDirectory: true)
        for (source, expected) in [("images/my%20photo.png", "/tmp/notes/images/my photo.png"), ("../a%23b.png", "/tmp/notes/../a#b.png"), ("/tmp/%E4%B8%AD.png", "/tmp/中.png"), ("a%2520b.png", "/tmp/notes/a%20b.png")] {
            XCTAssertEqual(ImageLocator.resolve(source: source, relativeTo: base), .file(URL(fileURLWithPath: expected)))
        }
    }

    func testHighlighterRangesAndTokenCoverageWithUnicodeCRLF() {
        let inputs = ["# 🎂 **中文**\r\n> `e\u{301}`\r\n- [ ] 👩🏽‍💻\r\n```swift\r\n// hi\r\nreturn 1\r\n```", "***", "[]()", "**🎂**", String(repeating: "[", count: 100)]
        for source in inputs {
            let length = (source as NSString).length
            for span in MarkdownSourceHighlighter.spans(in: source) {
                XCTAssertGreaterThanOrEqual(span.utf16Offset, 0)
                XCTAssertGreaterThan(span.utf16Length, 0)
                XCTAssertLessThanOrEqual(span.utf16Offset + span.utf16Length, length)
            }
            var cursor = 0
            for token in CodeHighlighter.tokens(in: source, language: "swift") {
                XCTAssertEqual(token.utf16Offset, cursor)
                cursor += token.utf16Length
            }
            XCTAssertEqual(cursor, length)
        }
    }

    func testDocumentStatsUnicodeAndReadingBoundary() {
        let text = "🎂 e\u{301} 中文\r\nhello"
        XCTAssertEqual(DocumentStats.measure(text).characters, text.count)
        XCTAssertGreaterThan(DocumentStats.measure(text).words, 0)
        XCTAssertEqual(DocumentStats.measure(" \r\n\t").readingMinutes, 0)
        XCTAssertEqual(DocumentStats.measure(Array(repeating: "word", count: 220).joined(separator: " ")).readingMinutes, 1)
    }
}
