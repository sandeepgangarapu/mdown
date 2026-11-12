import CoreGraphics
import Foundation

/// A block that can break across pages, and the smaller blocks it breaks into. Each piece renders
/// like the matching part of the whole: code and raw HTML break between lines, lists between items
/// (a numbered list keeps counting), quotes between their blocks, and tables between rows, with the
/// header repeated on every page.
public struct BlockSplit {
    /// How many units the block has: lines, items, child blocks, or rows.
    public let count: Int
    private let make: (Range<Int>) -> BlockNode

    /// Nil when the block cannot break, or has only one unit.
    public init?(_ block: BlockNode) {
        switch block {
        case let .code(language, source):
            let lines = Self.lines(of: source)
            count = lines.count
            make = { .code(language: language, source: lines[$0].joined(separator: "\n") + "\n") }
        case let .html(raw):
            let lines = Self.lines(of: raw)
            count = lines.count
            make = { .html(lines[$0].joined(separator: "\n") + "\n") }
        case let .bulletList(items):
            count = items.count
            make = { .bulletList(Array(items[$0])) }
        case let .orderedList(start, items):
            count = items.count
            make = { .orderedList(start: start + $0.lowerBound, items: Array(items[$0])) }
        case let .quote(children):
            count = children.count
            make = { .quote(Array(children[$0])) }
        case let .table(alignments, header, rows):
            count = rows.count
            make = { .table(alignments: alignments, header: header, rows: Array(rows[$0])) }
        case .paragraph, .heading, .rule, .figure:
            return nil
        }
        guard count > 1 else { return nil }
    }

    /// The units in `range`, as a block of the same kind.
    public func block(_ range: Range<Int>) -> BlockNode {
        make(range)
    }

    private static func lines(of source: String) -> [String] {
        var lines = source.components(separatedBy: "\n")
        if source.hasSuffix("\n") {
            lines.removeLast()
        }
        return lines
    }
}

/// A block's place on a printed page.
public struct PrintPlacement: Equatable {
    /// Part of a block too tall for any page, drawn across several: the block is shifted up by
    /// `offset` and cut off after `height`.
    public struct Slice: Equatable {
        public var offset: CGFloat
        public var height: CGFloat
    }

    public var block: BlockNode
    /// The block opens its page, so a heading drops the space it keeps above itself.
    public var isFirst: Bool
    public var slice: Slice?
    /// For a numbered list, or a piece of one broken across pages: the whole list's last number.
    /// Every piece sizes its number column from it, so items line up the same way on each page.
    public var listEnd: Int?
}

/// Lays typeset blocks out on pages. Blocks stay whole where they fit. A block that does not fit
/// the space left breaks into pieces when it can (see `BlockSplit`), and otherwise starts the next
/// page. A heading never ends a page: it moves to the next one with the block that follows it.
public enum PrintPaginator {
    /// The fewest units of a broken block left at the bottom of a page, so a page does not end on
    /// one stray line of code or one list item.
    static let minimumUnitsAtPageEnd = 2

    /// - Parameters:
    ///   - measure: The typeset height of a placement. Its slice is always nil.
    /// - Returns: One array of placements per page, with at least one page.
    public static func pages(
        for blocks: [BlockNode],
        pageHeight: CGFloat,
        spacing: CGFloat,
        measure: (PrintPlacement) -> CGFloat
    ) -> [[PrintPlacement]] {
        withoutActuallyEscaping(measure) { measure in
            var layout = Layout(pageHeight: max(pageHeight, 1), spacing: spacing, measure: measure)
            for block in blocks {
                layout.place(block)
            }
            return layout.finish()
        }
    }

    private struct Layout {
        let pageHeight: CGFloat
        let spacing: CGFloat
        let measure: (PrintPlacement) -> CGFloat

        var pages: [[PrintPlacement]] = []
        var current: [PrintPlacement] = []
        var used: CGFloat = 0
        /// The last number of the numbered list being placed, if it is one.
        var listEnd: Int?
        /// How many units of the block being broken filled the last full page: where the search
        /// for the next page's piece starts.
        var unitsPerPage: Int?

        /// Typeset heights are fractional; a block this close to fitting still fits.
        private let tolerance: CGFloat = 0.5

        init(pageHeight: CGFloat, spacing: CGFloat, measure: @escaping (PrintPlacement) -> CGFloat) {
            self.pageHeight = pageHeight
            self.spacing = spacing
            self.measure = measure
        }

        mutating func place(_ block: BlockNode) {
            if case let .orderedList(start, items) = block {
                listEnd = start + max(items.count - 1, 0)
            } else {
                listEnd = nil
            }
            unitsPerPage = nil
            var pending: BlockNode? = block
            while let block = pending {
                pending = nil
                let first = current.isEmpty
                let space = pageHeight - used - (first ? 0 : spacing)

                guard let split = BlockSplit(block) else {
                    let blockHeight = height(of: block, isFirst: first)
                    if blockHeight <= space + tolerance {
                        append(block, height: blockHeight)
                    } else if !first {
                        breakPage()
                        pending = block
                    } else {
                        sliceAcrossPages(block, height: blockHeight)
                    }
                    continue
                }

                var units = largestPrefix(of: split, fitting: space, isFirst: first, guess: first ? unitsPerPage ?? 1 : 1)
                if units == split.count {
                    append(block, height: height(of: block, isFirst: first))
                    continue
                }
                if !first, units < PrintPaginator.minimumUnitsAtPageEnd {
                    units = 0
                }
                if units > 0 {
                    let head = split.block(0..<units)
                    append(head, height: height(of: head, isFirst: first))
                    if first {
                        unitsPerPage = units
                    }
                    startPage()
                    pending = split.block(units..<split.count)
                } else if !first {
                    breakPage()
                    pending = block
                } else {
                    // Even one unit is taller than a page.
                    let unit = split.block(0..<1)
                    sliceAcrossPages(unit, height: height(of: unit, isFirst: true))
                    pending = split.block(1..<split.count)
                }
            }
        }

        mutating func finish() -> [[PrintPlacement]] {
            if !current.isEmpty || pages.isEmpty {
                pages.append(current)
            }
            current = []
            return pages
        }

        private func height(of block: BlockNode, isFirst: Bool) -> CGFloat {
            measure(PrintPlacement(block: block, isFirst: isFirst, listEnd: listEnd))
        }

        private mutating func append(_ block: BlockNode, height: CGFloat, slice: PrintPlacement.Slice? = nil) {
            let first = current.isEmpty
            current.append(PrintPlacement(block: block, isFirst: first, slice: slice, listEnd: listEnd))
            used += (first ? 0 : spacing) + height
        }

        private mutating func startPage() {
            if !current.isEmpty {
                pages.append(current)
            }
            current = []
            used = 0
        }

        /// Starts the next page, taking along the headings at the bottom of this one so they stay
        /// with the block they introduce. A page of nothing but headings keeps them: moving them all
        /// would only leave the same page again.
        private mutating func breakPage() {
            let trailing = current.reversed().prefix { placement in
                if placement.slice == nil, case .heading = placement.block { return true }
                return false
            }.count
            var headings: [BlockNode] = []
            if trailing < current.count {
                headings = current.suffix(trailing).map(\.block)
                current.removeLast(trailing)
            }
            startPage()
            let blockListEnd = listEnd
            listEnd = nil
            for heading in headings {
                append(heading, height: height(of: heading, isFirst: current.isEmpty))
            }
            listEnd = blockListEnd
        }

        /// The most units, from the start, whose block fits in `space`: zero when one does not, and
        /// `count` when they all do. The search starts at `guess` and steps up by doubling, then
        /// narrows down, so a long block is never measured much past a page's worth. With a good
        /// guess (the last full page's count), a page costs two measurements.
        private func largestPrefix(of split: BlockSplit, fitting space: CGFloat, isFirst: Bool, guess: Int) -> Int {
            func fits(_ units: Int) -> Bool {
                height(of: split.block(0..<units), isFirst: isFirst) <= space + tolerance
            }
            // `low` units are known to fit, `high` known not to (`count + 1` until one fails).
            var low = 0
            var high = split.count + 1
            var probe = min(max(guess, 1), split.count)
            var step = 1
            while fits(probe) {
                low = probe
                if probe == split.count {
                    return probe
                }
                probe = min(low + step, split.count)
                step *= 2
            }
            high = probe
            while high - low > 1 {
                let middle = (low + high) / 2
                if fits(middle) {
                    low = middle
                } else {
                    high = middle
                }
            }
            return low
        }

        /// Draws a block taller than a page across as many pages as it needs, starting on an empty
        /// page. What follows it goes on the page with its last part.
        private mutating func sliceAcrossPages(_ block: BlockNode, height: CGFloat) {
            var offset: CGFloat = 0
            while height - offset > pageHeight + tolerance {
                append(block, height: pageHeight, slice: .init(offset: offset, height: pageHeight))
                startPage()
                offset += pageHeight
            }
            append(block, height: height - offset, slice: .init(offset: offset, height: height - offset))
        }
    }
}

extension ImageLocator {
    /// Every image source in the blocks, in document order, including images inside lists and
    /// quotes. Used to fetch linked images before the page is printed.
    public static func sources(in blocks: [BlockNode]) -> [String] {
        var result: [String] = []
        func visit(_ inlines: [InlineNode]) {
            for node in inlines {
                switch node {
                case let .image(source, _, _):
                    if let source, !source.isEmpty {
                        result.append(source)
                    }
                case let .strong(children), let .emphasis(children), let .strikethrough(children),
                     let .link(_, _, children):
                    visit(children)
                case .text, .softBreak, .lineBreak, .code:
                    break
                }
            }
        }
        func visit(_ block: BlockNode) {
            switch block {
            case let .paragraph(inlines), let .heading(_, inlines):
                visit(inlines)
            case let .figure(source, _, _):
                result.append(source)
            case let .quote(children):
                children.forEach(visit)
            case let .bulletList(items), let .orderedList(_, items):
                items.forEach { $0.children.forEach(visit) }
            case .code, .rule, .table, .html:
                break
            }
        }
        blocks.forEach(visit)
        return result
    }
}
