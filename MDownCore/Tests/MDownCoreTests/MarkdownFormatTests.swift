import XCTest
@testable import MDownCore

final class MarkdownFormatTests: XCTestCase {
    func testBoldWrapsASelectionAndTogglesOff() {
        let wrapped = MarkdownFormat.apply(.bold, to: "Say hello there", utf16Location: 4, utf16Length: 5)
        XCTAssertEqual(wrapped.text, "Say **hello** there")
        XCTAssertEqual(wrapped.utf16Location, 6)
        XCTAssertEqual(wrapped.utf16Length, 5)

        let undone = MarkdownFormat.apply(.bold, to: wrapped.text, utf16Location: wrapped.utf16Location, utf16Length: wrapped.utf16Length)
        XCTAssertEqual(undone.text, "Say hello there")
        XCTAssertEqual(undone.utf16Location, 4)
        XCTAssertEqual(undone.utf16Length, 5)
    }

    func testEmptyCaretInsertsMarkersAndSitsBetweenThem() {
        let edit = MarkdownFormat.apply(.italic, to: "Note", utf16Location: 4, utf16Length: 0)
        XCTAssertEqual(edit.text, "Note**")
        XCTAssertEqual(edit.utf16Location, 5)
        XCTAssertEqual(edit.utf16Length, 0)
        XCTAssertFalse(MarkdownFormat.isActive(.italic, in: "Say **hello**", utf16Location: 6, utf16Length: 5))
        XCTAssertTrue(MarkdownFormat.isActive(.bold, in: "Say **hello**", utf16Location: 6, utf16Length: 5))
    }

    func testItalicDoesNotUnwrapBold() {
        let edit = MarkdownFormat.apply(.italic, to: "**hello**", utf16Location: 2, utf16Length: 5)
        XCTAssertEqual(edit.text, "***hello***")
    }

    func testLinkPutsTheCaretInTheURL() {
        let edit = MarkdownFormat.apply(.link, to: "See Swift now", utf16Location: 4, utf16Length: 5)
        XCTAssertEqual(edit.text, "See [Swift]() now")
        XCTAssertEqual(edit.utf16Location, 12)
        XCTAssertEqual(edit.utf16Length, 0)
    }

    func testHeadingTogglesAndChangesLevel() {
        let headed = MarkdownFormat.apply(.heading(2), to: "Section", utf16Location: 3, utf16Length: 0)
        XCTAssertEqual(headed.text, "## Section")
        XCTAssertEqual(headed.utf16Location, 6)

        let changed = MarkdownFormat.apply(.heading(1), to: headed.text, utf16Location: headed.utf16Location, utf16Length: 0)
        XCTAssertEqual(changed.text, "# Section")

        let cleared = MarkdownFormat.apply(.heading(1), to: changed.text, utf16Location: 4, utf16Length: 0)
        XCTAssertEqual(cleared.text, "Section")
        XCTAssertTrue(MarkdownFormat.isActive(.heading(2), in: "## Section", utf16Location: 4, utf16Length: 0))
    }

    func testQuoteBulletAndOrderedPrefixes() {
        XCTAssertEqual(
            MarkdownFormat.apply(.quote, to: "Spoken", utf16Location: 0, utf16Length: 0).text,
            "> Spoken"
        )
        XCTAssertEqual(
            MarkdownFormat.apply(.quote, to: "> Spoken", utf16Location: 2, utf16Length: 0).text,
            "Spoken"
        )
        XCTAssertEqual(
            MarkdownFormat.apply(.bullet, to: "Item", utf16Location: 0, utf16Length: 0).text,
            "- Item"
        )
        let numbered = MarkdownFormat.apply(.ordered, to: "One\nTwo", utf16Location: 0, utf16Length: 7)
        XCTAssertEqual(numbered.text, "1. One\n2. Two")
    }

    func testEmojiSelectionUsesUTF16() {
        let edit = MarkdownFormat.apply(.code, to: "A 🎂 cake", utf16Location: 2, utf16Length: 2)
        XCTAssertEqual(edit.text, "A `🎂` cake")
        XCTAssertEqual(edit.utf16Length, 2)
        XCTAssertEqual((edit.text as NSString).substring(with: NSRange(location: edit.utf16Location, length: edit.utf16Length)), "🎂")
    }
}
