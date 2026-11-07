import XCTest
@testable import MDownCore

/// Simulates MDown's click-to-edit splice. The app target is not importable, so
/// `updateDraft`, `editAtEnd`, and `partition` are re-implemented here from
/// `EditorView` / `MarkdownPage`.
final class EditSpliceTests: XCTestCase {

    // MARK: - Re-implemented editor rules

    private struct PageEditing: Equatable {
        var location: Int
        var draft: String
    }

    private struct Session {
        var document: String
        var editing: PageEditing
    }

    /// `EditorView.updateDraft`: replace `document[location, location+oldDraftUTF16]`
    /// with the new draft via `MarkdownText.replace`. Location is unchanged.
    private func updateDraft(_ session: Session, _ newValue: String) -> Session {
        let updated = MarkdownText.replace(
            session.document,
            utf16Location: session.editing.location,
            utf16Length: MarkdownText.utf16Length(of: session.editing.draft),
            with: newValue
        )
        return Session(
            document: updated,
            editing: PageEditing(location: session.editing.location, draft: newValue)
        )
    }

    /// `EditorView.beginEditing`: draft is the sourced block slice at its UTF-16 location.
    private func beginEditing(_ document: String, block: SourcedBlock) -> Session {
        Session(
            document: document,
            editing: PageEditing(location: block.utf16Location, draft: block.source(in: document))
        )
    }

    /// `EditorView.editAtEnd` newline padding, then a new empty draft at the end.
    /// If text is non-empty and does not already end with `\n\n`, append the missing
    /// newlines. The new line is inserted afterward with a zero-length `updateDraft`.
    ///
    /// Applied once per call. Calling this twice conceptually (pad, then insert)
    /// is one append plus one zero-length replace, not two appends.
    private func editAtEnd(_ document: String) -> Session {
        var text = document
        if !text.isEmpty {
            if !text.hasSuffix("\n") {
                text += "\n\n"
            } else if !text.hasSuffix("\n\n") {
                text += "\n"
            }
        }
        return Session(
            document: text,
            editing: PageEditing(location: MarkdownText.utf16Length(of: text), draft: "")
        )
    }

    /// `MarkdownPage.partition`: blocks whose end <= location are before; blocks
    /// whose start >= location+draftUTF16 are after; overlapping blocks are omitted.
    private func partition(
        _ blocks: [SourcedBlock],
        editing: PageEditing
    ) -> (before: [SourcedBlock], after: [SourcedBlock]) {
        let end = editing.location + MarkdownText.utf16Length(of: editing.draft)
        return (
            blocks.filter { $0.utf16Location + $0.utf16Length <= editing.location },
            blocks.filter { $0.utf16Location >= end }
        )
    }

    // MARK: - Fixtures

    private func headingParagraphCodeDocument() -> String {
        """
        # Stay Put

        Middle paragraph to edit.

        ```swift
        let stay = true
        ```
        """
    }

    private func requireBlocks(
        _ markdown: String,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [SourcedBlock] {
        let blocks = MarkdownRenderModel.sourcedBlocks(from: markdown)
        XCTAssertEqual(blocks.count, count, "unexpected block count for:\n\(markdown)", file: file, line: line)
        return blocks
    }

    private func isHeading(_ block: SourcedBlock) -> Bool {
        if case .heading = block.block { return true }
        return false
    }

    private func isCode(_ block: SourcedBlock) -> Bool {
        if case .code = block.block { return true }
        return false
    }

    private func isParagraph(_ block: SourcedBlock) -> Bool {
        if case .paragraph = block.block { return true }
        return false
    }

    // MARK: - 1. Middle replace preserves neighbors byte-for-byte

    func testReplaceMiddleParagraphPreservesHeadingAndCodeByteForByte() {
        let markdown = headingParagraphCodeDocument()
        let blocks = requireBlocks(markdown, count: 3)
        XCTAssertTrue(isHeading(blocks[0]))
        XCTAssertTrue(isParagraph(blocks[1]))
        XCTAssertTrue(isCode(blocks[2]))

        let headingSource = blocks[0].source(in: markdown)
        let codeSource = blocks[2].source(in: markdown)

        let session = updateDraft(beginEditing(markdown, block: blocks[1]), "Replacement paragraph.\n")
        let after = MarkdownRenderModel.sourcedBlocks(from: session.document)

        guard let heading = after.first(where: isHeading) else {
            return XCTFail("heading missing after splice")
        }
        guard let code = after.first(where: isCode) else {
            return XCTFail("code block missing after splice")
        }
        XCTAssertEqual(heading.source(in: session.document), headingSource)
        XCTAssertEqual(code.source(in: session.document), codeSource)
        XCTAssertTrue(session.document.contains("Replacement paragraph."))
        XCTAssertFalse(session.document.contains("Middle paragraph to edit."))
    }

    // MARK: - 2. Grow one paragraph into two; follower unchanged

    func testGrowParagraphIntoTwoPreservesFollowingBlockSource() {
        let markdown = """
        Short para.

        Following block stays.
        """
        let blocks = requireBlocks(markdown, count: 2)
        let followingSource = blocks[1].source(in: markdown)

        let grown = "First grown paragraph.\n\nSecond grown paragraph.\n"
        let session = updateDraft(beginEditing(markdown, block: blocks[0]), grown)
        let after = MarkdownRenderModel.sourcedBlocks(from: session.document)

        XCTAssertGreaterThanOrEqual(after.count, 3)
        XCTAssertEqual(after.last?.source(in: session.document), followingSource)
        XCTAssertTrue(session.document.contains("First grown paragraph."))
        XCTAssertTrue(session.document.contains("Second grown paragraph."))
        XCTAssertTrue(session.document.contains("Following block stays."))
    }

    // MARK: - 3. Shrink a block

    func testShrinkBlock() {
        let markdown = """
        # Stay Put

        A fairly long paragraph that will shrink to something shorter.

        Tail paragraph.
        """
        let blocks = requireBlocks(markdown, count: 3)
        let headingSource = blocks[0].source(in: markdown)
        let tailSource = blocks[2].source(in: markdown)
        let originalLength = MarkdownText.utf16Length(of: blocks[1].source(in: markdown))

        let session = updateDraft(beginEditing(markdown, block: blocks[1]), "Short.\n")
        let after = MarkdownRenderModel.sourcedBlocks(from: session.document)

        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after[0].source(in: session.document), headingSource)
        XCTAssertEqual(after[2].source(in: session.document), tailSource)
        XCTAssertTrue(after[1].source(in: session.document).contains("Short."))
        XCTAssertLessThan(MarkdownText.utf16Length(of: session.editing.draft), originalLength)
        XCTAssertFalse(session.document.contains("fairly long paragraph"))
    }

    // MARK: - 4. Delete a whole block with ""

    func testDeleteWholeBlockWithEmptyReplacement() {
        let markdown = """
        Alpha heading-adjacent

        Beta line to remove.

        Gamma stays.
        """
        let blocks = requireBlocks(markdown, count: 3)
        let alphaSource = blocks[0].source(in: markdown)
        let gammaSource = blocks[2].source(in: markdown)

        let session = updateDraft(beginEditing(markdown, block: blocks[1]), "")
        let after = MarkdownRenderModel.sourcedBlocks(from: session.document)

        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[0].source(in: session.document), alphaSource)
        XCTAssertEqual(after[1].source(in: session.document), gammaSource)
        XCTAssertFalse(session.document.contains("Beta line to remove."))
        XCTAssertEqual(session.editing.draft, "")
    }

    // MARK: - 5. editAtEnd on "Hello", then insert "Next" (one append)

    func testEditAtEndHelloThenInsertNext() {
        // Pad once, then a single zero-length replace. Do not run editAtEnd twice
        // (the app would clear editing on a second call instead of appending again).
        let padded = editAtEnd("Hello")
        XCTAssertEqual(padded.document, "Hello\n\n")
        XCTAssertEqual(padded.editing.draft, "")
        XCTAssertEqual(padded.editing.location, MarkdownText.utf16Length(of: padded.document))

        let session = updateDraft(padded, "Next")
        XCTAssertTrue(session.document.contains("Hello"))
        XCTAssertTrue(session.document.contains("\n\n"))
        XCTAssertTrue(session.document.contains("Next"))
        XCTAssertEqual(session.document, "Hello\n\nNext")
    }

    // MARK: - 6. Emoji paragraph replaced with a longer string; ASCII intact

    func testReplaceEmojiParagraphPreservesFollowingASCII() {
        let markdown = """
        🎂 emoji paragraph

        ASCII after
        """
        let blocks = requireBlocks(markdown, count: 2)
        XCTAssertTrue(blocks[0].source(in: markdown).contains("🎂"))
        XCTAssertEqual(MarkdownText.utf16Length(of: "🎂"), 2)

        let asciiSource = blocks[1].source(in: markdown)
        XCTAssertEqual(asciiSource.trimmingCharacters(in: .whitespacesAndNewlines), "ASCII after")

        let longer = "A much longer replacement that outgrows the original emoji paragraph UTF-16 length."
        XCTAssertGreaterThan(
            MarkdownText.utf16Length(of: longer),
            MarkdownText.utf16Length(of: blocks[0].source(in: markdown))
        )

        let session = updateDraft(beginEditing(markdown, block: blocks[0]), longer)
        let after = MarkdownRenderModel.sourcedBlocks(from: session.document)

        XCTAssertGreaterThanOrEqual(after.count, 2)
        XCTAssertEqual(after.last?.source(in: session.document), asciiSource)
        XCTAssertTrue(session.document.contains(longer))
        XCTAssertTrue(session.document.contains("ASCII after"))
        XCTAssertFalse(session.document.contains("🎂"))
    }

    // MARK: - 7. Partition omits the edited range; neighbors stay on the correct side

    func testPartitionOmitsEditedRangeAndKeepsNeighborsOnCorrectSides() {
        let markdown = headingParagraphCodeDocument()
        let blocks = requireBlocks(markdown, count: 3)
        let headingSource = blocks[0].source(in: markdown)
        let codeSource = blocks[2].source(in: markdown)
        let replacement = "Edited draft that must not also render as a block.\n"

        let session = updateDraft(beginEditing(markdown, block: blocks[1]), replacement)
        let parsed = MarkdownRenderModel.sourcedBlocks(from: session.document)
        let parts = partition(parsed, editing: session.editing)

        XCTAssertEqual(parts.before.count, 1)
        XCTAssertTrue(isHeading(parts.before[0]))
        XCTAssertEqual(parts.before[0].source(in: session.document), headingSource)

        XCTAssertEqual(parts.after.count, 1)
        XCTAssertTrue(isCode(parts.after[0]))
        XCTAssertEqual(parts.after[0].source(in: session.document), codeSource)

        let draftText = session.editing.draft
        XCTAssertFalse(
            parts.before.contains { $0.source(in: session.document).contains(draftText.trimmingCharacters(in: .newlines)) },
            "edited draft leaked into before"
        )
        XCTAssertFalse(
            parts.after.contains { $0.source(in: session.document).contains(draftText.trimmingCharacters(in: .newlines)) },
            "edited draft leaked into after"
        )

        let omitted = parsed.filter { block in
            !parts.before.contains(block) && !parts.after.contains(block)
        }
        XCTAssertFalse(omitted.isEmpty, "overlapping edited blocks should be omitted from both sides")
        XCTAssertTrue(
            omitted.contains { $0.source(in: session.document).contains("Edited draft") },
            "the reparsed edited block should be the omitted overlap, not a duplicated neighbor"
        )

        let end = session.editing.location + MarkdownText.utf16Length(of: session.editing.draft)
        for block in parts.before {
            XCTAssertLessThanOrEqual(block.utf16Location + block.utf16Length, session.editing.location)
        }
        for block in parts.after {
            XCTAssertGreaterThanOrEqual(block.utf16Location, end)
        }
        for block in omitted {
            let blockEnd = block.utf16Location + block.utf16Length
            let overlaps = blockEnd > session.editing.location && block.utf16Location < end
            XCTAssertTrue(overlaps, "omitted block should overlap the draft range")
        }
    }
}
