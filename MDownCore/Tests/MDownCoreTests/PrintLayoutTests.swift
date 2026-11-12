import CoreGraphics
import XCTest
@testable import MDownCore

final class PrintLayoutTests: XCTestCase {

    // MARK: - Helpers

    private func paragraph(_ text: String) -> BlockNode {
        .paragraph([.text(text)])
    }

    private func item(_ text: String) -> ListItemNode {
        ListItemNode(check: nil, children: [paragraph(text)])
    }

    private func code(lines: Int) -> BlockNode {
        .code(language: "swift", source: (1...lines).map { "line \($0)" }.joined(separator: "\n") + "\n")
    }

    /// Fake typeset heights: a paragraph is 100, a heading 30 (plus 10 above it unless it opens the
    /// page), code 20 plus 10 per line, a list 25 per item, anything else 50.
    private func measure(_ block: BlockNode, isFirst: Bool) -> CGFloat {
        switch block {
        case .paragraph:
            return 100
        case .heading:
            return isFirst ? 30 : 40
        case let .code(_, source):
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).count - 1
            return 20 + CGFloat(lines) * 10
        case let .bulletList(items), let .orderedList(_, items):
            return CGFloat(items.count) * 25
        default:
            return 50
        }
    }

    private func pages(_ blocks: [BlockNode], height: CGFloat = 300, spacing: CGFloat = 10) -> [[PrintPlacement]] {
        PrintPaginator.pages(for: blocks, pageHeight: height, spacing: spacing) { measure($0.block, isFirst: $0.isFirst) }
    }

    private func codeLines(_ block: BlockNode) -> [String] {
        guard case let .code(_, source) = block else { return [] }
        return source.split(separator: "\n").map(String.init)
    }

    // MARK: - Splitting

    func testCodeSplitsBetweenLinesAndRejoinsExactly() throws {
        let source = "let a = 1\nlet b = 2\n\nlet c = 3\n"
        let split = try XCTUnwrap(BlockSplit(.code(language: "swift", source: source)))
        XCTAssertEqual(split.count, 4)
        XCTAssertEqual(split.block(0..<4), .code(language: "swift", source: source))
        XCTAssertEqual(split.block(0..<2), .code(language: "swift", source: "let a = 1\nlet b = 2\n"))
        XCTAssertEqual(split.block(2..<4), .code(language: "swift", source: "\nlet c = 3\n"))
    }

    func testNumberedListKeepsCountingAfterABreak() throws {
        let split = try XCTUnwrap(BlockSplit(.orderedList(start: 3, items: [item("a"), item("b"), item("c")])))
        XCTAssertEqual(split.block(0..<1), .orderedList(start: 3, items: [item("a")]))
        XCTAssertEqual(split.block(1..<3), .orderedList(start: 4, items: [item("b"), item("c")]))
    }

    func testTableRepeatsItsHeaderOnEachPiece() throws {
        let header = [TableCellNode(inlines: [.text("Name")], colspan: 1)]
        let rows = (1...3).map { [TableCellNode(inlines: [.text("Row \($0)")], colspan: 1)] }
        let split = try XCTUnwrap(BlockSplit(.table(alignments: [.leading], header: header, rows: rows)))
        XCTAssertEqual(split.count, 3)
        XCTAssertEqual(split.block(2..<3), .table(alignments: [.leading], header: header, rows: [rows[2]]))
    }

    func testBlocksThatCannotBreak() {
        XCTAssertNil(BlockSplit(paragraph("Words")))
        XCTAssertNil(BlockSplit(.heading(level: 1, inlines: [.text("Title")])))
        XCTAssertNil(BlockSplit(.rule))
        XCTAssertNil(BlockSplit(.bulletList([item("only one")])))
        XCTAssertNil(BlockSplit(.code(language: nil, source: "one line\n")))
    }

    // MARK: - Pages

    func testBlocksThatFitShareAPage() {
        let result = pages([paragraph("a"), paragraph("b")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].map(\.isFirst), [true, false])
    }

    func testABlockThatDoesNotFitStartsTheNextPage() {
        // 100 + 10 + 100 + 10 + 100 = 320 > 300.
        let result = pages([paragraph("a"), paragraph("b"), paragraph("c")])
        XCTAssertEqual(result.map(\.count), [2, 1])
        XCTAssertTrue(result[1][0].isFirst)
        XCTAssertNil(result[1][0].slice)
    }

    func testAHeadingMovesToTheNextPageWithItsBlock() {
        // 100 + 10 + 100 + 10 + 40 = 260 fits, but the paragraph after the heading does not.
        let heading = BlockNode.heading(level: 2, inlines: [.text("Next")])
        let result = pages([paragraph("a"), paragraph("b"), heading, paragraph("c")])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].map(\.block), [paragraph("a"), paragraph("b")])
        XCTAssertEqual(result[1].map(\.block), [heading, paragraph("c")])
        XCTAssertTrue(result[1][0].isFirst)
    }

    func testConsecutiveHeadingsAllMoveWithTheirBlock() {
        // 100 + 10 + 40 + 10 + 40 = 200 fits a page of 220, but the paragraph after does not.
        let a = BlockNode.heading(level: 1, inlines: [.text("A")])
        let b = BlockNode.heading(level: 2, inlines: [.text("B")])
        let result = pages([paragraph("x"), a, b, paragraph("y")], height: 220)
        XCTAssertEqual(result.map { $0.map(\.block) }, [[paragraph("x")], [a, b, paragraph("y")]])
        XCTAssertEqual(result[1].map(\.isFirst), [true, false, false])
    }

    func testAPageOfOnlyHeadingsKeepsThem() {
        // Two headings fill most of a page of 80; the paragraph after needs a page of its own.
        let a = BlockNode.heading(level: 1, inlines: [.text("A")])
        let b = BlockNode.heading(level: 2, inlines: [.text("B")])
        let result = pages([a, b, paragraph("y")], height: 120)
        XCTAssertEqual(result.map { $0.map(\.block) }, [[a, b], [paragraph("y")]])
    }

    func testAVeryLongBlockIsMeasuredAboutAPageAtATime() {
        // A page of 300 holds 28 lines (20 + 28 × 10). A 5,000-line block must never be measured
        // whole, or the work grows with the square of its length.
        var largest = 0
        var calls = 0
        let result = PrintPaginator.pages(for: [code(lines: 5000)], pageHeight: 300, spacing: 10) { placement in
            calls += 1
            largest = max(largest, codeLines(placement.block).count)
            return measure(placement.block, isFirst: placement.isFirst)
        }
        XCTAssertEqual(result.flatMap { $0 }.flatMap { codeLines($0.block) }, (1...5000).map { "line \($0)" })
        XCTAssertLessThanOrEqual(largest, 56)
        // After the first page, each page starts from the last page's count: about two measurements.
        XCTAssertLessThanOrEqual(calls, result.count * 3 + 20)
    }

    func testLongCodeBreaksBetweenLinesAcrossPages() {
        // 100 + 10 leaves 190: code of 17 lines (190) fits, the other 33 continue.
        let result = pages([paragraph("a"), code(lines: 50)])
        XCTAssertEqual(result.count, 3)
        let pieces = result.flatMap { $0 }.filter { if case .code = $0.block { true } else { false } }
        let lines = pieces.flatMap { codeLines($0.block) }
        XCTAssertEqual(lines, (1...50).map { "line \($0)" })
        XCTAssertEqual(codeLines(pieces[0].block).count, 17)
        XCTAssertTrue(pieces.allSatisfy { $0.slice == nil })
        // Every page stays within its height.
        for page in result {
            let height = page.enumerated().reduce(CGFloat(0)) { total, entry in
                total + (entry.offset == 0 ? 0 : 10) + measure(entry.element.block, isFirst: entry.element.isFirst)
            }
            XCTAssertLessThanOrEqual(height, 300)
        }
    }

    func testABrokenBlockLeavesAtLeastTwoUnitsAtThePageEnd() {
        // 100 + 10 + 100 + 10 leaves 80: room for three list items (75) of six.
        let list = BlockNode.bulletList((1...6).map { item("\($0)") })
        let result = pages([paragraph("a"), paragraph("b"), list])
        XCTAssertEqual(result[0].last?.block, .bulletList([item("1"), item("2"), item("3")]))

        let tight = pages([paragraph("a"), paragraph("b"), list], height: 250)
        // 250 - 220 leaves 30: room for only one item, so the list starts the next page whole.
        XCTAssertEqual(tight[0].map(\.block), [paragraph("a"), paragraph("b")])
        XCTAssertEqual(tight[1].first?.block, list)
    }

    func testABlockTallerThanAPageIsSlicedAcrossPages() {
        // A figure cannot break; with a page of 40 its height of 50 needs two slices.
        let result = pages([.figure(source: "a.png", title: nil, alt: ""), paragraph("x")], height: 40)
        XCTAssertEqual(result[0].first?.slice, PrintPlacement.Slice(offset: 0, height: 40))
        XCTAssertEqual(result[1].first?.slice, PrintPlacement.Slice(offset: 40, height: 10))
        // The paragraph after it is taller than a page too, so it starts its own page and slices.
        let slices = result.flatMap { $0 }.filter { $0.block == paragraph("x") }.map(\.slice)
        XCTAssertEqual(slices, [.init(offset: 0, height: 40), .init(offset: 40, height: 40), .init(offset: 80, height: 20)])
        XCTAssertEqual(result.count, 5)
    }

    func testPiecesOfANumberedListShareTheWholeListsLastNumber() {
        // 25 per item: 12 items fit a page of 300, so a list of 30 starting at 5 breaks in three.
        let list = BlockNode.orderedList(start: 5, items: (1...30).map { item("\($0)") })
        let heading = BlockNode.heading(level: 1, inlines: [.text("After")])
        let placements = pages([list, heading]).flatMap { $0 }
        let pieces = placements.filter { if case .orderedList = $0.block { true } else { false } }
        XCTAssertEqual(pieces.count, 3)
        XCTAssertTrue(pieces.allSatisfy { $0.listEnd == 34 })
        XCTAssertEqual(placements.last?.block, heading)
        XCTAssertNil(placements.last?.listEnd)
    }

    func testAnEmptyDocumentStillHasOnePage() {
        XCTAssertEqual(pages([]).count, 1)
        XCTAssertTrue(pages([])[0].isEmpty)
    }

    // MARK: - Images

    func testImageSourcesIncludeNestedImages() {
        let blocks: [BlockNode] = [
            .figure(source: "https://example.com/a.png", title: nil, alt: ""),
            .bulletList([ListItemNode(check: nil, children: [
                .paragraph([.link(destination: "https://x.com", title: nil, children: [
                    .image(source: "b.png", title: nil, alt: []),
                ])]),
            ])]),
            .quote([.paragraph([.text("no image")])]),
        ]
        XCTAssertEqual(ImageLocator.sources(in: blocks), ["https://example.com/a.png", "b.png"])
    }
}
