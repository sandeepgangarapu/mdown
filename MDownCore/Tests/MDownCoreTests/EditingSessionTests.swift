import XCTest
@testable import MDownCore

final class EditingSessionTests: XCTestCase {
    private func length(_ text: String) -> Int { (text as NSString).length }

    func testInsertionAddsOnlyMissingSeparators() {
        let cases: [(String, Int, String, Int)] = [
            ("", 0, "New", 0),
            ("Tail", 0, "New\n\nTail", 0),
            ("\nTail", 0, "New\n\nTail", 0),
            ("\n\nTail", 0, "New\n\nTail", 0),
            ("Head", 4, "Head\n\nNew", 6),
            ("Head\n", 5, "Head\n\nNew", 6),
            ("Head\n\n", 6, "Head\n\nNew", 6),
            ("Head\n\n\n", 7, "Head\n\n\nNew", 7),
            ("# H\nTail", 4, "# H\n\nNew\n\nTail", 5),
            ("HeadTail", 4, "Head\n\nNew\n\nTail", 6),
            ("Head\n\nTail", 6, "Head\n\nNew\n\nTail", 6),
            ("Head\r\nTail", 6, "Head\r\n\nNew\n\nTail", 7),
            ("Head\r\n\r\nTail", 8, "Head\r\n\r\nNew\n\nTail", 8),
            ("Head\r\nTail", 4, "Head\n\nNew\n\r\nTail", 6),
            ("🎂Tail", 2, "🎂\n\nNew\n\nTail", 4)
        ]
        for (text, offset, expected, anchor) in cases {
            let result = EditingText.insertBlock("New", into: text, at: offset)
            XCTAssertEqual(result.text, expected, "source: \(text.debugDescription), offset: \(offset)")
            XCTAssertEqual(result.location, anchor)
            XCTAssertEqual((result.text as NSString).substring(with: NSRange(location: anchor, length: 3)), "New")
            XCTAssertEqual(MarkdownRenderModel.blocks(from: result.text).count, text.isEmpty ? 1 : (offset == 0 || offset == length(text) ? 2 : 3))
        }
    }

    func testInsertionClampsOffsetsAndPreservesBlockBytes() {
        XCTAssertEqual(EditingText.insertBlock("X", into: "Y", at: -10).text, "X\n\nY")
        XCTAssertEqual(EditingText.insertBlock("X", into: "Y", at: 100).text, "Y\n\nX")
        let block = "```swift\n🎂\n```"
        let result = EditingText.insertBlock(block, into: "Before\n\nAfter", at: 8)
        XCTAssertEqual((result.text as NSString).substring(with: NSRange(location: result.location, length: length(block))), block)
        let parsed = MarkdownRenderModel.blocks(from: result.text)
        XCTAssertEqual(parsed.count, 3)
        guard case .code(language: "swift", source: _) = parsed[1] else { return XCTFail("Missing inserted code block") }
    }

    func testRemovalCollapsesNewlineRunsAndTracksFollowingOffset() {
        for (prefix, suffix, expected) in [
            ("A\n\n\n", "\n\n\nB", "A\n\nB"),
            ("A\r\n\r\n", "\r\n\r\nB", "A\n\nB"),
            ("", "\n\nB", "B"),
            ("A\n\n", "", "A\n"),
            ("", "", ""),
            ("🎂\n\n", "\n\nB", "🎂\n\nB")
        ] {
            let blank = " \t "
            let old = prefix + blank + suffix
            let result = EditingText.removeBlankBlock(in: old, at: length(prefix), length: length(blank))
            XCTAssertEqual(result.text, expected)
            XCTAssertEqual(result.delta, length(expected) - length(old))
            XCTAssertEqual(result.location, prefix.isEmpty ? 0 : length(prefix.trimmingCharacters(in: .newlines)))
            if suffix.contains("B") {
                let oldOffset = (old as NSString).range(of: "B").location
                XCTAssertEqual(oldOffset + result.delta, (result.text as NSString).range(of: "B").location)
            }
        }
    }

    func testInsertClearRemoveCycleKeepsNeighborsAsSeparateBlocks() {
        for (old, offset, expected) in [("A\n\nB", 3, "A\n\nB"), ("A", 1, "A\n"), ("B", 0, "B"), ("", 0, "")] {
            let inserted = EditingText.insertBlock("Draft 🎂", into: old, at: offset)
            let cleared = (inserted.text as NSString).replacingCharacters(in: NSRange(location: inserted.location, length: length("Draft 🎂")), with: "")
            let removed = EditingText.removeBlankBlock(in: cleared, at: inserted.location, length: 0)
            XCTAssertEqual(removed.text, expected)
            XCTAssertEqual(MarkdownRenderModel.blocks(from: removed.text).count, MarkdownRenderModel.blocks(from: old).count)
        }
    }

    func testPageEditingUsesUTF16AndPendingHasZeroLength() {
        let editing = PageEditing(location: 4, draft: "🎂x")
        XCTAssertEqual(editing.draftLength, 3)
        XCTAssertEqual(editing.end, 7)
        let pending = PageEditing(location: 4, draft: "🎂x", pending: true)
        XCTAssertEqual(pending.draftLength, 0)
        XCTAssertEqual(pending.end, 4)
    }

    func testRebaseChangesBeforeAfterAndInside() {
        let old = "Intro\n\nA🎂bc\n\nTail"
        let editing = PageEditing(location: 7, draft: "A🎂bc")
        let cases: [(String, PageEditing)] = [
            ("I\n\nA🎂bc\n\nTail", PageEditing(location: 3, draft: "A🎂bc")),
            ("Intro\nextra\nlines\n\nA🎂bc\n\nTail", PageEditing(location: 19, draft: "A🎂bc")),
            ("🎉Intro\n\nA🎂bc\n\nTail", PageEditing(location: 9, draft: "A🎂bc")),
            ("Intro\n\nA🎂bc\n\nLonger tail", editing),
            ("Intro\n\nA🎂b\n\nTail", PageEditing(location: 7, draft: "A🎂b")),
            ("Intro\n\nAbc\n\nTail", PageEditing(location: 7, draft: "Abc")),
            ("Intro\n\nA🎂XYZbc\n\nTail", PageEditing(location: 7, draft: "A🎂XYZbc")),
            (old, editing)
        ]
        for (new, expected) in cases { XCTAssertEqual(EditingText.rebase(editing, from: old, to: new), expected, new) }
    }

    func testRebaseRejectsChangesCrossingEitherEdgeAndRevert() {
        let old = "Before\n\nDraft\n\nAfter"
        let editing = PageEditing(location: 8, draft: "Draft")
        for new in ["Before\nXraft\n\nAfter", "Before\n\nDrafX\nAfter", "Entirely replaced", ""] {
            XCTAssertNil(EditingText.rebase(editing, from: old, to: new), new)
        }
    }

    func testPendingRebaseAndAmbiguousInsertionAtAnchor() {
        let pending = PageEditing(location: 3, draft: "", pending: true)
        XCTAssertEqual(EditingText.rebase(pending, from: "A\n\nB", to: "🎂A\n\nB"), PageEditing(location: 5, draft: "", pending: true))
        XCTAssertEqual(EditingText.rebase(pending, from: "A\n\nB", to: "A\n\nBee"), pending)
        XCTAssertEqual(EditingText.rebase(pending, from: "A\n\nB", to: "A\n\nB"), pending)
        XCTAssertNil(EditingText.rebase(pending, from: "A\n\nB", to: "A\n\nXB"))
        let atEnd = PageEditing(location: 1, draft: "", pending: true)
        XCTAssertEqual(EditingText.rebase(atEnd, from: "A", to: "A"), atEnd)
        XCTAssertNil(EditingText.rebase(atEnd, from: "A", to: "AX"))
    }

    func testCaretPlacementAndBlankDetection() {
        for (text, end) in [("", 0), ("abc", 3), ("🎂\r\n\r\n", 2), ("a\nbc\n", 4), (" \t\n", 2), ("\r\n", 0)] {
            XCTAssertEqual(EditingText.caret(in: text, placement: .start), 0)
            XCTAssertEqual(EditingText.caret(in: text, placement: .end), end)
        }
        for blank in ["", " \t\r\n", "\u{00a0}\u{2003}"] { XCTAssertTrue(EditingText.isBlank(blank)) }
        for nonblank in ["a", " \n🎂", "\u{200b}"] { XCTAssertFalse(EditingText.isBlank(nonblank)) }
    }
    func testRebaseBoundaryEditsAndWholeDraftReplacement() {
        let editing = PageEditing(location: 3, draft: "BC")
        for (new, expected) in [
            ("A\n\nXBC\n\nD", PageEditing(location: 3, draft: "XBC")),
            ("A\n\nBCX\n\nD", PageEditing(location: 3, draft: "BCX")),
            ("A\n\n\n\nD", PageEditing(location: 3, draft: "")),
            ("A\n\n🎂\n\nD", PageEditing(location: 3, draft: "🎂")),
            ("ABC\n\nD", PageEditing(location: 1, draft: "BC")),
            ("A\n\nBCD", editing)
        ] { XCTAssertEqual(EditingText.rebase(editing, from: "A\n\nBC\n\nD", to: new), expected, new) }
    }

    func testRebaseRejectsStaleAndInvalidDraftRanges() {
        for editing in [PageEditing(location: -1, draft: "A"), PageEditing(location: 99, draft: ""), PageEditing(location: 1, draft: "too long")] {
            XCTAssertNil(EditingText.rebase(editing, from: "AB", to: "AC"))
        }
    }

    func testRebaseRoundTripsUndoRedoWithEmojiAndCRLF() throws {
        let old = "🎂\r\n\r\nDraft🎉\r\n\r\nTail"
        let editing = PageEditing(location: 6, draft: "Draft🎉")
        for new in ["🎂\r\n\r\nDraf🎉\r\n\r\nTail", "🎂\r\nextra\r\n\r\nDraft🎉\r\n\r\nTail", "🎂\r\n\r\nDraft🎈\r\n\r\nTail"] {
            let rebased = try XCTUnwrap(EditingText.rebase(editing, from: old, to: new))
            XCTAssertEqual((new as NSString).substring(with: NSRange(location: rebased.location, length: rebased.draftLength)), rebased.draft)
            XCTAssertEqual(EditingText.rebase(rebased, from: new, to: old), editing)
        }
    }

    func testRebaseCanonicalEquivalentTextStillTracksUTF16Change() {
        let old = "é\n\nDraft"
        let new = "e\u{301}\n\nDraft"
        XCTAssertEqual(old, new) // Swift equality alone cannot detect UTF-16 edits.
        XCTAssertEqual(EditingText.rebase(PageEditing(location: 3, draft: "Draft"), from: old, to: new), PageEditing(location: 4, draft: "Draft"))
        let editing = PageEditing(location: 0, draft: "é")
        let rebased = EditingText.rebase(editing, from: "é", to: "e\u{301}")
        XCTAssertEqual(rebased?.draftLength, 2)
    }

}
