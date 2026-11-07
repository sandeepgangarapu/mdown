import XCTest
@testable import MDownCore

final class MarkdownOutlineTests: XCTestCase {
    private let markdown = """
    # Document

    ## Previous section

    This paragraph can remain visible above a short final section.

    ## Final section

    | Item | Status |
    | --- | --- |
    | Example | Ready |
    """

    func testFinalSectionIsActiveAtDocumentEndWithPreviousParagraphStillVisible() {
        let blocks = MarkdownRenderModel.sourcedBlocks(from: markdown)
        let outline = MarkdownOutline.entries(from: blocks)
        let paragraph = blocks.first { if case .paragraph = $0.block { return true }; return false }!

        XCTAssertEqual(MarkdownOutline.activeEntry(in: outline, at: paragraph.utf16Location)?.title, "Previous section")
        XCTAssertEqual(
            MarkdownOutline.activeEntry(in: outline, at: paragraph.utf16Location, reachedEnd: true)?.title,
            "Final section"
        )
    }

    func testScrollingBackUpRestoresTheSectionAtTheReadingPosition() {
        let outline = MarkdownOutline.entries(from: MarkdownRenderModel.sourcedBlocks(from: markdown))
        XCTAssertEqual(MarkdownOutline.activeEntry(in: outline, at: outline[1].utf16Location)?.title, "Previous section")
        XCTAssertEqual(MarkdownOutline.activeEntry(in: outline, at: outline[2].utf16Location)?.title, "Final section")
    }

    func testInitialPositionUsesFirstHeadingAndEmptyDocumentHasNoActiveHeading() {
        let outline = MarkdownOutline.entries(from: MarkdownRenderModel.sourcedBlocks(from: markdown))
        XCTAssertEqual(MarkdownOutline.activeEntry(in: outline, at: nil)?.title, "Document")
        XCTAssertEqual(MarkdownOutline.activeEntry(in: outline, at: 0)?.title, "Document")
        XCTAssertNil(MarkdownOutline.activeEntry(in: [], at: nil))
        XCTAssertNil(MarkdownOutline.activeEntry(in: [], at: 0, reachedEnd: true))
    }
}
