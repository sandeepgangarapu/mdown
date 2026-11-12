import Foundation

/// Invisible markers around suggested text, placed in the Markdown before it is typeset so the
/// page can color each change and know which one was clicked. They are Unicode noncharacters,
/// which the standard sets aside for exactly this kind of internal use. A mark opens with
/// U+FDD0 (added) or U+FDD1 (removed), then the change's number in hex digits written as U+FDE0
/// through U+FDEF, then U+FDD2. U+FDD3 closes it. Any of these in a document itself are shown as
/// U+FFFD instead (see `sanitized`), so a document's own characters are never read as marks.
public enum ReviewMark {
    public enum Kind: Hashable, Sendable {
        case inserted
        case removed
    }

    public struct Mark: Hashable, Sendable {
        public var kind: Kind
        /// Index of the change in `ReviewPresentation.changes`.
        public var change: Int
    }

    public struct Piece: Hashable, Sendable {
        public var text: String
        public var mark: Mark?
    }

    private static let openInserted = Unicode.Scalar(0xFDD0)!
    private static let openRemoved = Unicode.Scalar(0xFDD1)!
    private static let numberEnd = Unicode.Scalar(0xFDD2)!
    static let close = Unicode.Scalar(0xFDD3)!
    private static let firstDigit: UInt32 = 0xFDE0
    private static let reserved: ClosedRange<UInt32> = 0xFDD0...0xFDEF

    static func open(_ kind: Kind, _ change: Int) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(kind == .inserted ? openInserted : openRemoved)
        for digit in String(max(change, 0), radix: 16) {
            scalars.append(Unicode.Scalar(firstDigit + UInt32(digit.hexDigitValue!))!)
        }
        scalars.append(numberEnd)
        return String(scalars)
    }

    public static func containsMarks(_ text: String) -> Bool {
        text.unicodeScalars.contains { reserved.contains($0.value) }
    }

    /// `text` with any of the characters marks are made of replaced by U+FFFD.
    static func sanitized(_ text: String) -> String {
        guard containsMarks(text) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(reserved.contains(scalar.value) ? "\u{FFFD}" : scalar)
        }
        return String(scalars)
    }

    /// Splits marked text into plain and marked pieces. `state` carries an open mark from one call
    /// to the next, for a change that runs across several inline runs (into bold text, say).
    public static func pieces(in text: String, state: inout Mark?) -> [Piece] {
        var result: [Piece] = []
        var buffer = String.UnicodeScalarView()
        var opening: Mark?
        func flush() {
            if !buffer.isEmpty {
                result.append(Piece(text: String(buffer), mark: state))
                buffer = String.UnicodeScalarView()
            }
        }
        for scalar in text.unicodeScalars {
            if var mark = opening {
                if scalar.value >= firstDigit, scalar.value < firstDigit + 16, mark.change < Int.max / 16 {
                    mark.change = mark.change * 16 + Int(scalar.value - firstDigit)
                    opening = mark
                    continue
                }
                opening = nil
                if scalar == numberEnd {
                    state = mark
                    continue
                }
            }
            if scalar == close {
                flush()
                state = nil
            } else if scalar == openInserted || scalar == openRemoved {
                flush()
                opening = Mark(kind: scalar == openInserted ? .inserted : .removed, change: 0)
            } else if !reserved.contains(scalar.value) {
                buffer.append(scalar)
            }
        }
        flush()
        return result
    }

    static func openCount(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + ($1 == openInserted || $1 == openRemoved ? 1 : 0) }
    }

    /// The text as one side would have it: `.inserted` keeps the new text (the file now), `.removed`
    /// keeps the old text (what you had).
    static func side(_ text: String, keeping kind: Kind) -> String {
        var state: Mark?
        return pieces(in: text, state: &state)
            .filter { $0.mark == nil || $0.mark?.kind == kind }
            .map(\.text)
            .joined()
    }
}

/// What the Changes tab shows: the document as it is now, one row per block, with each changed
/// block showing what was taken out and what was put in.
public struct ReviewPresentation: Sendable {
    public struct Row: Identifiable, Sendable {
        public enum Content: Sendable {
            /// A block with no changes, as it reads on the page.
            case unchanged(SourcedBlock)
            /// Changed blocks typeset with their changes marked.
            case typeset([SourcedBlock])
            /// A changed block whose changes can't be shown typeset (a table, code, a link address,
            /// a heading that changed level), shown as its Markdown with the changes marked.
            case source(String)
        }

        /// Unique among the rows. Rows of blocks keep theirs while you decide changes elsewhere.
        public var id: String
        /// Where the row starts in the current text.
        public var location: Int
        public var content: Content
        /// The changes in this row, as indexes into `changes`, in document order.
        public var changes: [Int]
    }

    public var changes: [ReviewChange]
    public var rows: [Row]

    public init(baseline: String, current: String) {
        self.init(changes: ChangeReview.changes(from: baseline, to: current), current: current)
    }

    public init(changes: [ReviewChange], current: String) {
        self.changes = changes
        rows = Self.rows(changes: changes, current: current)
    }

    /// Index of the row showing `change`.
    public func row(of change: Int) -> Int? {
        rows.firstIndex { $0.changes.contains(change) }
    }

    // MARK: - Rows

    private struct Group {
        var start: Int
        var end: Int
        var blocks: [Int] = []
        var changes: [Int] = []
        var standalone: Bool
        /// For removed text standing alone: where it was in the baseline. Several removed
        /// paragraphs share one spot in the current text, and this keeps them apart and in order.
        var baselineLocation = 0
    }

    private static func rows(changes: [ReviewChange], current: String) -> [Row] {
        let ns = current as NSString
        let blocks = MarkdownRenderModel.sourcedBlocks(from: current)

        // Which block each change belongs to. A change that reaches into several blocks joins them;
        // a removed paragraph between blocks gets a row of its own.
        var owner = Array(blocks.indices)
        func find(_ index: Int) -> Int {
            var index = index
            while owner[index] != index {
                owner[index] = owner[owner[index]]
                index = owner[index]
            }
            return index
        }
        var changeBlocks: [Int: [Int]] = [:]
        var standalone: [Int] = []
        for (index, change) in changes.enumerated() {
            let touched = blocksTouched(by: change, blocks: blocks, text: ns)
            if touched.isEmpty {
                standalone.append(index)
            } else {
                changeBlocks[index] = touched
                for block in touched.dropFirst() {
                    owner[find(block)] = find(touched[0])
                }
            }
        }

        var groups: [Int: Group] = [:]
        for (index, block) in blocks.enumerated() {
            let root = find(index)
            var group = groups[root] ?? Group(start: block.utf16Location, end: block.utf16Location + block.utf16Length, standalone: false)
            group.start = min(group.start, block.utf16Location)
            group.end = max(group.end, block.utf16Location + block.utf16Length)
            group.blocks.append(index)
            groups[root] = group
        }
        for (change, touched) in changeBlocks {
            let root = find(touched[0])
            groups[root]?.changes.append(change)
            if let start = groups[root]?.start, let end = groups[root]?.end {
                groups[root]?.start = min(start, changes[change].currentLocation)
                groups[root]?.end = max(end, changes[change].currentEnd)
            }
        }
        var all = Array(groups.values)
        for change in standalone {
            all.append(Group(
                start: changes[change].currentLocation,
                end: changes[change].currentEnd,
                changes: [change],
                standalone: true,
                baselineLocation: changes[change].baselineLocation
            ))
        }
        all.sort { ($0.start, $0.standalone ? 0 : 1, $0.baselineLocation) < ($1.start, $1.standalone ? 0 : 1, $1.baselineLocation) }

        return all.map { group in
            let id = group.standalone ? "removed \(group.start) \(group.baselineLocation)" : "block \(group.start)"
            let changeList = group.changes.sorted()
            if changeList.isEmpty, group.blocks.count == 1 {
                return Row(id: id, location: group.start, content: .unchanged(blocks[group.blocks[0]]), changes: [])
            }
            let range = NSRange(location: group.start, length: group.end - group.start)
            let typeset = merged(ns, range: range, changes: changeList.map { ($0, changes[$0]) }, skipMarkers: true)
            if typeset.faithful, let parsed = typesetBlocks(typeset.text) {
                return Row(id: id, location: group.start, content: .typeset(parsed), changes: changeList)
            }
            let source = merged(ns, range: range, changes: changeList.map { ($0, changes[$0]) }, skipMarkers: false)
            return Row(id: id, location: group.start, content: .source(source.text.trimmingCharacters(in: .newlines)), changes: changeList)
        }
    }

    private static func blocksTouched(by change: ReviewChange, blocks: [SourcedBlock], text: NSString) -> [Int] {
        if change.currentLength > 0 {
            return blocks.indices.filter {
                blocks[$0].utf16Location < change.currentEnd && change.currentLocation < blocks[$0].utf16Location + blocks[$0].utf16Length
            }
        }
        // Text taken out at one point. Whole lines removed between blocks stand alone; anything else
        // belongs to the block it was taken from.
        let point = change.currentLocation
        if let inside = blocks.indices.first(where: { blocks[$0].utf16Location < point && point < blocks[$0].utf16Location + blocks[$0].utf16Length }) {
            return [inside]
        }
        let wholeLines = change.removed.hasSuffix("\n") && (point == 0 || text.character(at: point - 1) == 0x0A)
        if wholeLines || change.isWhitespaceOnly { return [] }
        if let ending = blocks.indices.first(where: { blocks[$0].utf16Location + blocks[$0].utf16Length == point }) {
            return [ending]
        }
        if let starting = blocks.indices.first(where: { blocks[$0].utf16Location == point }) {
            return [starting]
        }
        return []
    }

    // MARK: - Marked Markdown

    /// The current text in `range` with each change's removed text put back next to its new text,
    /// both marked. With `skipMarkers`, marks on a line start after its list bullet, quote marker,
    /// or heading hashes, so the line still parses as the same kind of block. `faithful` is false
    /// when a change is in those markers themselves, which typeset text can't show.
    static func merged(_ text: NSString, range: NSRange, changes: [(Int, ReviewChange)], skipMarkers: Bool) -> (text: String, faithful: Bool) {
        var result = ""
        var faithful = true
        var position = range.location
        let end = NSMaxRange(range)
        func atLineStart() -> Bool {
            if let last = result.unicodeScalars.last { return last == "\n" }
            return range.location == 0 || text.character(at: range.location - 1) == 0x0A
        }
        func copy(_ start: Int, _ end: Int) -> String {
            ReviewMark.sanitized(text.substring(with: NSRange(location: start, length: end - start)))
        }
        for (index, change) in changes.sorted(by: { $0.1.currentLocation < $1.1.currentLocation }) {
            if change.currentLocation > position {
                result += copy(position, change.currentLocation)
            }
            if change.isWhitespaceOnly {
                let removedBreaks = change.removed.filter(\.isNewline).count
                let insertedBreaks = change.inserted.filter(\.isNewline).count
                let glyph = removedBreaks + insertedBreaks > 0 ? "¶" : "·"
                let kind: ReviewMark.Kind = insertedBreaks > removedBreaks
                    || (insertedBreaks == removedBreaks && change.inserted.utf16.count >= change.removed.utf16.count) ? .inserted : .removed
                result += ReviewMark.open(kind, index) + glyph + String(Character(ReviewMark.close))
                result += change.inserted
            } else {
                var removed = ReviewMark.sanitized(change.removed)
                let inserted = ReviewMark.sanitized(change.inserted)
                if !removed.isEmpty, !inserted.isEmpty,
                   removed.last.map({ !$0.isWhitespace }) == true,
                   inserted.first.map({ !$0.isWhitespace }) == true {
                    // A space between the old words and the new ones, so they don't run together.
                    removed += " "
                }
                if !removed.isEmpty {
                    let marked = mark(removed, .removed, index, atLineStart: atLineStart(), skipMarkers: skipMarkers)
                    result += marked.text
                    faithful = faithful && marked.faithful
                }
                if !inserted.isEmpty {
                    let marked = mark(inserted, .inserted, index, atLineStart: atLineStart(), skipMarkers: skipMarkers)
                    result += marked.text
                    faithful = faithful && marked.faithful
                }
            }
            position = max(position, change.currentEnd)
        }
        if end > position {
            result += copy(position, end)
        }
        return (result, faithful)
    }

    private static let lineMarkers = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:>[ \t]?)*[ \t]*(?:(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?|#{1,6}(?:[ \t]+|$))?"#
    )

    /// Marks each line of `text` separately, so a mark never spans a line break, and (with
    /// `skipMarkers`) starts after the line's block markers. Markers are only skipped on whole lines;
    /// a change that is only part of a line and starts in its markers isn't faithful.
    private static func mark(_ text: String, _ kind: ReviewMark.Kind, _ change: Int, atLineStart: Bool, skipMarkers: Bool) -> (text: String, faithful: Bool) {
        var faithful = true
        let open = ReviewMark.open(kind, change)
        let close = String(Character(ReviewMark.close))
        let ns = text as NSString
        var result = ""
        for (index, range) in ChangeReview.lineRanges(ns).enumerated() {
            var line = ns.substring(with: range)
            var terminator = ""
            if line.hasSuffix("\r\n") {
                terminator = "\r\n"
                line.removeLast()
            } else if line.hasSuffix("\n") {
                terminator = "\n"
                line.removeLast()
            }
            var prefix = ""
            if skipMarkers, index > 0 || atLineStart {
                let lineNS = line as NSString
                if let match = lineMarkers.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)), match.range.length > 0 {
                    if terminator.isEmpty {
                        faithful = false
                    } else {
                        prefix = lineNS.substring(with: match.range)
                        line = lineNS.substring(from: match.range.length)
                    }
                }
            } else if index > 0 || atLineStart {
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                prefix = String(indent)
                line.removeFirst(indent.count)
            }
            if line.isEmpty {
                result += prefix + terminator
            } else {
                result += prefix + open + line + close + terminator
            }
        }
        return (result, faithful)
    }

    // MARK: - Typesetting check

    /// The blocks for typeset marked text, or nil when typesetting would hide a change or draw a
    /// different kind of block than either version has. Those rows show their Markdown instead.
    static func typesetBlocks(_ marked: String) -> [SourcedBlock]? {
        let blocks = MarkdownRenderModel.sourcedBlocks(from: marked)
        guard !blocks.isEmpty else { return nil }
        guard blocks.allSatisfy({ isTypesettable($0.block) }) else { return nil }
        let visible = blocks.map { visibleText(of: $0.block) }.joined()
        guard ReviewMark.openCount(in: visible) == ReviewMark.openCount(in: marked) else { return nil }

        // Each side, typeset on its own, must read the same as the marked page does with the other
        // side's text left out. This catches marks that broke a link or turned text into syntax.
        let newBlocks = MarkdownRenderModel.blocks(from: ReviewMark.side(marked, keeping: .inserted))
        let oldBlocks = MarkdownRenderModel.blocks(from: ReviewMark.side(marked, keeping: .removed))
        guard ReviewMark.side(visible, keeping: .inserted) == newBlocks.map(visibleText(of:)).joined(),
              ReviewMark.side(visible, keeping: .removed) == oldBlocks.map(visibleText(of:)).joined() else { return nil }

        let newKinds = newBlocks.map(kind)
        let oldKinds = oldBlocks.map(kind)
        let mergedKinds = blocks.map { kind($0.block) }
        let known = Set(newKinds + oldKinds)
        guard mergedKinds.allSatisfy(known.contains), mergedKinds.count <= newKinds.count + oldKinds.count else { return nil }
        return blocks
    }

    private static func isTypesettable(_ block: BlockNode) -> Bool {
        switch block {
        case .paragraph, .heading:
            return true
        case let .quote(children):
            return children.allSatisfy(isTypesettable)
        case let .bulletList(items), let .orderedList(_, items):
            return items.allSatisfy { $0.children.allSatisfy(isTypesettable) }
        case .code, .rule, .table, .figure, .html:
            return false
        }
    }

    /// A short name for a block's kind, to tell whether marking changed what a block is.
    private static func kind(_ block: BlockNode) -> String {
        switch block {
        case .paragraph: "p"
        case let .heading(level, _): "h\(level)"
        case .quote: "quote"
        case .code: "code"
        case .bulletList: "ul"
        case .orderedList: "ol"
        case .rule: "hr"
        case .table: "table"
        case .figure: "figure"
        case .html: "html"
        }
    }

    /// The text a block shows on the page (not link addresses or image descriptions).
    static func visibleText(of block: BlockNode) -> String {
        switch block {
        case let .paragraph(inlines), let .heading(_, inlines):
            return visibleText(of: inlines)
        case let .quote(children):
            return children.map(visibleText(of:)).joined()
        case let .bulletList(items), let .orderedList(_, items):
            return items.flatMap(\.children).map(visibleText(of:)).joined()
        case .code, .rule, .table, .figure, .html:
            return ""
        }
    }

    private static func visibleText(of inlines: [InlineNode]) -> String {
        inlines.map { node in
            switch node {
            case let .text(value), let .code(value):
                return value
            case .softBreak, .lineBreak, .image:
                return ""
            case let .strong(children), let .emphasis(children), let .strikethrough(children):
                return visibleText(of: children)
            case let .link(_, _, children):
                return visibleText(of: children)
            }
        }.joined()
    }
}
