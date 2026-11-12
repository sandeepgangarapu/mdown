import Foundation

/// One difference between the text you had (the baseline) and the text in the file now (current),
/// such as a few words an AI tool rewrote. Offsets are UTF-16.
public struct ReviewChange: Hashable, Sendable {
    public var baselineLocation: Int
    public var baselineLength: Int
    public var currentLocation: Int
    public var currentLength: Int
    /// The baseline text this change takes out, and the text it puts in its place.
    public var removed: String
    public var inserted: String

    public init(baselineLocation: Int, baselineLength: Int, currentLocation: Int, currentLength: Int, removed: String, inserted: String) {
        self.baselineLocation = baselineLocation
        self.baselineLength = baselineLength
        self.currentLocation = currentLocation
        self.currentLength = currentLength
        self.removed = removed
        self.inserted = inserted
    }

    public var baselineEnd: Int { baselineLocation + baselineLength }
    public var currentEnd: Int { currentLocation + currentLength }
    public var isWhitespaceOnly: Bool {
        removed.allSatisfy(\.isWhitespace) && inserted.allSatisfy(\.isWhitespace)
    }
}

/// Finds the changes between two versions of a document, word by word, and accepts or rejects any
/// of them. The changes always cover every difference, so accepting all of them turns the baseline
/// into the current text and rejecting all of them turns the current text back into the baseline.
public enum ChangeReview {
    public static func changes(from baseline: String, to current: String) -> [ReviewChange] {
        guard !identical(baseline, current) else { return [] }
        let old = baseline as NSString
        let new = current as NSString
        let oldLines = lineRanges(old)
        let newLines = lineRanges(new)
        let oldStrings = oldLines.map(old.substring(with:))
        let newStrings = newLines.map(new.substring(with:))

        var result: [ReviewChange] = []
        for hunk in hunks(from: oldStrings.map(ExactText.init), to: newStrings.map(ExactText.init)) {
            let oldStart = start(of: hunk.old.lowerBound, in: oldLines, total: old.length)
            let oldEnd = start(of: hunk.old.upperBound, in: oldLines, total: old.length)
            let newStart = start(of: hunk.new.lowerBound, in: newLines, total: new.length)
            let newEnd = start(of: hunk.new.upperBound, in: newLines, total: new.length)
            if hunk.old.isEmpty || hunk.new.isEmpty {
                result.append(change(old, oldStart, oldEnd, new, newStart, newEnd))
            } else {
                result += wordChanges(old, oldStart, oldEnd, new, newStart, newEnd)
            }
        }
        result = slideToLineStarts(result, old: old, new: new)
        return result.flatMap { splitIntoBlocks($0, old: old, new: new) }
    }

    /// The baseline with `changes` accepted: their new text replaces what they took out.
    public static func accept(_ changes: [ReviewChange], into baseline: String) -> String {
        let text = NSMutableString(string: baseline)
        for change in changes.sorted(by: { ($0.baselineLocation, $0.currentLocation) > ($1.baselineLocation, $1.currentLocation) }) {
            let range = NSRange(location: change.baselineLocation, length: change.baselineLength)
            guard range.location >= 0, NSMaxRange(range) <= text.length else { continue }
            text.replaceCharacters(in: range, with: change.inserted)
        }
        return text as String
    }

    /// The current text with `changes` rejected: the baseline's text goes back in their place.
    public static func reject(_ changes: [ReviewChange], in current: String) -> String {
        let text = NSMutableString(string: current)
        for change in changes.sorted(by: { ($0.currentLocation, $0.baselineLocation) > ($1.currentLocation, $1.baselineLocation) }) {
            let range = NSRange(location: change.currentLocation, length: change.currentLength)
            guard range.location >= 0, NSMaxRange(range) <= text.length else { continue }
            text.replaceCharacters(in: range, with: change.removed)
        }
        return text as String
    }

    /// Carries an edit you made yourself (typing, a checkbox, undo) into the baseline, so your own
    /// words never show up as a suggestion. Suggestions the edit touches are accepted first, since
    /// you're now editing the suggested text.
    /// `pending` can pass in the changes from `baseline` to `oldCurrent` when they're known already.
    public static func carryOwnEdit(baseline: String, from oldCurrent: String, to newCurrent: String, pending: [ReviewChange]? = nil) -> String {
        guard !identical(oldCurrent, newCurrent) else { return baseline }
        let edit = singleEdit(from: oldCurrent, to: newCurrent)
        let pending = pending ?? changes(from: baseline, to: oldCurrent)
        let editEnd = edit.location + edit.length
        let touched = pending.filter { $0.currentLocation <= editEnd && $0.currentEnd >= edit.location }
        let shift = pending
            .filter { $0.currentEnd < edit.location && !touched.contains($0) }
            .reduce(0) { $0 + $1.baselineLength - $1.currentLength }
        let accepted = accept(touched, into: baseline)
        return MarkdownText.replace(accepted, utf16Location: edit.location + shift, utf16Length: edit.length, with: edit.replacement)
    }

    /// Whether two texts have the same UTF-16 code units. Swift's `==` treats canonically
    /// equivalent text as equal ("é" as one code point, or "e" plus a combining accent), but the two
    /// differ in length, and every offset here is UTF-16.
    public static func identical(_ a: String, _ b: String) -> Bool {
        a.utf16.count == b.utf16.count && a.utf16.elementsEqual(b.utf16)
    }

    /// Text that hashes and compares by its UTF-16 code units, for the same reason.
    struct ExactText: Hashable {
        var text: String

        static func == (lhs: ExactText, rhs: ExactText) -> Bool {
            identical(lhs.text, rhs.text)
        }

        func hash(into hasher: inout Hasher) {
            for unit in text.utf16 {
                hasher.combine(unit)
            }
        }
    }

    // MARK: - Lines

    static func lineRanges(_ text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var start = 0
        let length = text.length
        var index = 0
        while index < length {
            if text.character(at: index) == 0x0A {
                result.append(NSRange(location: start, length: index + 1 - start))
                start = index + 1
            }
            index += 1
        }
        if start < length {
            result.append(NSRange(location: start, length: length - start))
        }
        return result
    }

    private static func start(of line: Int, in lines: [NSRange], total: Int) -> Int {
        line < lines.count ? lines[line].location : total
    }

    private static func change(_ old: NSString, _ oldStart: Int, _ oldEnd: Int, _ new: NSString, _ newStart: Int, _ newEnd: Int) -> ReviewChange {
        ReviewChange(
            baselineLocation: oldStart,
            baselineLength: oldEnd - oldStart,
            currentLocation: newStart,
            currentLength: newEnd - newStart,
            removed: old.substring(with: NSRange(location: oldStart, length: oldEnd - oldStart)),
            inserted: new.substring(with: NSRange(location: newStart, length: newEnd - newStart))
        )
    }

    // MARK: - Sequence comparison

    struct Hunk: Equatable {
        var old: Range<Int>
        var new: Range<Int>
    }

    /// The runs where `new` differs from `old`, in order. When comparing would take more than
    /// `budget` steps (two unrelated versions of a long document), everything between the equal
    /// ends counts as one run.
    static func hunks<Element: Hashable>(from old: [Element], to new: [Element], budget: Int = comparisonBudget) -> [Hunk] {
        var ids: [Element: Int] = [:]
        func id(_ element: Element) -> Int {
            if let known = ids[element] { return known }
            let next = ids.count
            ids[element] = next
            return next
        }
        let a = old.map(id)
        let b = new.map(id)
        var comparison = SequenceComparison(a, b, budget: budget)
        comparison.run()

        var removed = comparison.removed
        var inserted = comparison.inserted
        if comparison.exceeded {
            var prefix = 0
            while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
            removed = a.indices.map { $0 >= prefix && $0 < a.count - suffix }
            inserted = b.indices.map { $0 >= prefix && $0 < b.count - suffix }
        }

        var result: [Hunk] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            let inRemoval = i < a.count && removed[i]
            let inInsertion = j < b.count && inserted[j]
            if inRemoval || inInsertion {
                let startI = i
                let startJ = j
                while (i < a.count && removed[i]) || (j < b.count && inserted[j]) {
                    if i < a.count && removed[i] { i += 1 }
                    if j < b.count && inserted[j] { j += 1 }
                }
                result.append(Hunk(old: startI..<i, new: startJ..<j))
            } else {
                i += 1
                j += 1
            }
        }
        return result
    }

    /// About a tenth of a second of comparing in a release build.
    static let comparisonBudget = 30_000_000

    // MARK: - Words

    struct Token {
        enum Kind { case word, space, newline, other }
        var text: String
        var location: Int
        var length: Int
        var kind: Kind
    }

    /// Words, runs of spaces, line breaks, and punctuation (a run of the same mark, like `**` or
    /// `##`, is one token). Each CJK character is its own word, since those languages don't put
    /// spaces between words.
    static func tokens(in text: String, offset: Int = 0) -> [Token] {
        var result: [Token] = []
        var location = offset
        for character in text {
            let length = character.utf16.count
            let kind: Token.Kind
            var joins = false
            if character.isNewline {
                kind = .newline
            } else if character == " " || character == "\t" || (character.isWhitespace && !character.isNewline) {
                kind = .space
                joins = true
            } else if character.unicodeScalars.first?.properties.isIdeographic == true {
                kind = .word
            } else if character.isLetter || character.isNumber || character == "_" {
                kind = .word
                joins = true
            } else {
                kind = .other
                joins = result.last.map { $0.kind == .other && $0.text.last == character } ?? false
            }
            if joins, var last = result.last, last.kind == kind, kind != .newline,
               kind != .word || last.text.last.map(isJoinableWordCharacter) == true {
                last.text.append(character)
                last.length += length
                result[result.count - 1] = last
            } else {
                result.append(Token(text: String(character), location: location, length: length, kind: kind))
            }
            location += length
        }
        return result
    }

    private static func isJoinableWordCharacter(_ character: Character) -> Bool {
        (character.isLetter || character.isNumber || character == "_")
            && character.unicodeScalars.first?.properties.isIdeographic != true
    }

    /// Compares one changed run of lines word by word. Edits separated only by spaces become one
    /// change, so "quick brown" → "slow red" reads as a single edit.
    private static func wordChanges(_ old: NSString, _ oldStart: Int, _ oldEnd: Int, _ new: NSString, _ newStart: Int, _ newEnd: Int) -> [ReviewChange] {
        let oldTokens = tokens(in: old.substring(with: NSRange(location: oldStart, length: oldEnd - oldStart)), offset: oldStart)
        let newTokens = tokens(in: new.substring(with: NSRange(location: newStart, length: newEnd - newStart)), offset: newStart)
        let raw = hunks(from: oldTokens.map { ExactText(text: $0.text) }, to: newTokens.map { ExactText(text: $0.text) })
        var merged: [Hunk] = []
        for (index, found) in raw.enumerated() {
            let next = index + 1 < raw.count ? raw[index + 1] : nil
            guard let hunk = tidy(found, old: oldTokens, new: newTokens, nextOld: next?.old.lowerBound ?? oldTokens.count, nextNew: next?.new.lowerBound ?? newTokens.count) else { continue }
            if let last = merged.last,
               (last.old.upperBound..<hunk.old.lowerBound).allSatisfy({ oldTokens[$0].kind == .space }) {
                merged[merged.count - 1] = Hunk(old: last.old.lowerBound..<hunk.old.upperBound, new: last.new.lowerBound..<hunk.new.upperBound)
            } else {
                merged.append(hunk)
            }
        }
        return merged.compactMap { tidy($0, old: oldTokens, new: newTokens, nextOld: $0.old.upperBound, nextNew: $0.new.upperBound) }.map { hunk in
            let a = hunk.old.isEmpty ? tokenStart(hunk.old.lowerBound, oldTokens, end: oldEnd) : oldTokens[hunk.old.lowerBound].location
            let b = hunk.old.isEmpty ? a : oldTokens[hunk.old.upperBound - 1].location + oldTokens[hunk.old.upperBound - 1].length
            let c = hunk.new.isEmpty ? tokenStart(hunk.new.lowerBound, newTokens, end: newEnd) : newTokens[hunk.new.lowerBound].location
            let d = hunk.new.isEmpty ? c : newTokens[hunk.new.upperBound - 1].location + newTokens[hunk.new.upperBound - 1].length
            return change(old, a, b, new, c, d)
        }
    }

    /// Keeps spaces out of the edges of a change: drops tokens both sides share, and moves an added
    /// or removed run that starts with a space so the space comes after it ("small and " rather
    /// than " small and").
    private static func tidy(_ hunk: Hunk, old: [Token], new: [Token], nextOld: Int, nextNew: Int) -> Hunk? {
        var oldRange = hunk.old
        var newRange = hunk.new
        while !oldRange.isEmpty, !newRange.isEmpty, identical(old[oldRange.upperBound - 1].text, new[newRange.upperBound - 1].text) {
            oldRange = oldRange.lowerBound..<(oldRange.upperBound - 1)
            newRange = newRange.lowerBound..<(newRange.upperBound - 1)
        }
        while !oldRange.isEmpty, !newRange.isEmpty, identical(old[oldRange.lowerBound].text, new[newRange.lowerBound].text) {
            oldRange = (oldRange.lowerBound + 1)..<oldRange.upperBound
            newRange = (newRange.lowerBound + 1)..<newRange.upperBound
        }
        if oldRange.isEmpty && newRange.isEmpty { return nil }
        if oldRange.isEmpty != newRange.isEmpty {
            let tokens = oldRange.isEmpty ? new : old
            var range = oldRange.isEmpty ? newRange : oldRange
            let limit = oldRange.isEmpty ? nextNew : nextOld
            var shift = 0
            while tokens[range.lowerBound].kind == .space, range.upperBound < limit,
                  identical(tokens[range.upperBound].text, tokens[range.lowerBound].text) {
                range = (range.lowerBound + 1)..<(range.upperBound + 1)
                shift += 1
            }
            if oldRange.isEmpty {
                newRange = range
                oldRange = (oldRange.lowerBound + shift)..<(oldRange.lowerBound + shift)
            } else {
                oldRange = range
                newRange = (newRange.lowerBound + shift)..<(newRange.lowerBound + shift)
            }
        }
        return Hunk(old: oldRange, new: newRange)
    }

    private static func tokenStart(_ index: Int, _ tokens: [Token], end: Int) -> Int {
        index < tokens.count ? tokens[index].location : end
    }

    // MARK: - Tidying

    /// A whole line added or removed in the middle of other edits can come out shifted, like
    /// "c\n- " instead of "- c\n". Slide such changes back to the start of the line, where they
    /// read as the line that changed.
    private static func slideToLineStarts(_ changes: [ReviewChange], old: NSString, new: NSString) -> [ReviewChange] {
        var result = changes
        for index in result.indices {
            let change = result[index]
            let isInsertion = change.baselineLength == 0 && change.currentLength > 0
            let isDeletion = change.currentLength == 0 && change.baselineLength > 0
            guard isInsertion || isDeletion else { continue }
            let text = isInsertion ? new : old
            var location = isInsertion ? change.currentLocation : change.baselineLocation
            let length = isInsertion ? change.currentLength : change.baselineLength
            guard text.substring(with: NSRange(location: location, length: length)).contains("\n") else { continue }
            let previousEnd = index > 0 ? (isInsertion ? result[index - 1].currentEnd : result[index - 1].baselineEnd) : 0
            var steps = 0
            while location > previousEnd, text.character(at: location - 1) != 0x0A,
                  text.character(at: location - 1) == text.character(at: location + length - 1) {
                location -= 1
                steps += 1
            }
            guard steps > 0, location == 0 || text.character(at: location - 1) == 0x0A else { continue }
            var slid = change
            slid.baselineLocation -= steps
            slid.currentLocation -= steps
            if isInsertion {
                slid.inserted = text.substring(with: NSRange(location: slid.currentLocation, length: length))
            } else {
                slid.removed = text.substring(with: NSRange(location: slid.baselineLocation, length: length))
            }
            result[index] = slid
        }
        return result
    }

    /// Several whole paragraphs or list items added (or removed) in one place become one change
    /// each, so each can be kept or dropped on its own.
    private static func splitIntoBlocks(_ change: ReviewChange, old: NSString, new: NSString) -> [ReviewChange] {
        let isInsertion = change.baselineLength == 0 && change.currentLength > 0
        let isDeletion = change.currentLength == 0 && change.baselineLength > 0
        guard isInsertion || isDeletion else { return [change] }
        let text = isInsertion ? change.inserted : change.removed
        let location = isInsertion ? change.currentLocation : change.baselineLocation
        let source = isInsertion ? new : old
        guard text.hasSuffix("\n"), location == 0 || source.character(at: location - 1) == 0x0A else { return [change] }

        let ns = text as NSString
        var pieces: [String] = []
        var current = ""
        var currentHasContent = false
        var previousBlank = false
        for range in lineRanges(ns) {
            let line = ns.substring(with: range)
            let blank = line.allSatisfy(\.isWhitespace)
            if !blank, currentHasContent, previousBlank || startsBlock(line) {
                pieces.append(current)
                current = ""
                currentHasContent = false
            }
            current += line
            currentHasContent = currentHasContent || !blank
            previousBlank = blank
        }
        pieces.append(current)
        guard pieces.count > 1 else { return [change] }

        var result: [ReviewChange] = []
        var offset = location
        for piece in pieces {
            let length = MarkdownText.utf16Length(of: piece)
            if isInsertion {
                result.append(ReviewChange(baselineLocation: change.baselineLocation, baselineLength: 0, currentLocation: offset, currentLength: length, removed: "", inserted: piece))
            } else {
                result.append(ReviewChange(baselineLocation: offset, baselineLength: length, currentLocation: change.currentLocation, currentLength: 0, removed: piece, inserted: ""))
            }
            offset += length
        }
        return result
    }

    /// Lines that start a new block even without a blank line before them: list items, headings,
    /// and quotes. Not table rows, which belong to the table above them.
    private static let blockStart = try! NSRegularExpression(pattern: #"^ {0,3}(?:[-*+][ \t]|\d{1,9}[.)][ \t]|#{1,6}(?:[ \t]|$)|>)"#)

    private static func startsBlock(_ line: String) -> Bool {
        blockStart.firstMatch(in: line, range: NSRange(location: 0, length: MarkdownText.utf16Length(of: line))) != nil
    }

    // MARK: - Own edits

    struct Edit: Equatable {
        var location: Int
        var length: Int
        var replacement: String
    }

    /// The one contiguous edit that turns `old` into `new`.
    static func singleEdit(from old: String, to new: String) -> Edit {
        let a = old as NSString
        let b = new as NSString
        let limit = min(a.length, b.length)
        var prefix = 0
        while prefix < limit, a.character(at: prefix) == b.character(at: prefix) {
            prefix += 1
        }
        if prefix > 0, prefix < limit, UTF16.isLeadSurrogate(a.character(at: prefix - 1)) {
            prefix -= 1
        }
        var suffix = 0
        while suffix < limit - prefix, a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) {
            suffix += 1
        }
        if suffix > 0, a.length - suffix < a.length, UTF16.isTrailSurrogate(a.character(at: a.length - suffix)) {
            suffix -= 1
        }
        return Edit(
            location: prefix,
            length: a.length - suffix - prefix,
            replacement: b.substring(with: NSRange(location: prefix, length: b.length - suffix - prefix))
        )
    }
}

/// Myers' difference algorithm in linear space ("An O(ND) Difference Algorithm and Its Variations",
/// 1986): finds the middle of a shortest edit path, then solves each half. Time grows with the
/// size of the inputs times the number of differences; memory only with the size of the inputs.
struct SequenceComparison {
    private let a: [Int]
    private let b: [Int]
    private(set) var removed: [Bool]
    private(set) var inserted: [Bool]
    private(set) var exceeded = false
    private var budget: Int
    private var forward: [Int]
    private var backward: [Int]

    init(_ a: [Int], _ b: [Int], budget: Int) {
        self.a = a
        self.b = b
        removed = Array(repeating: false, count: a.count)
        inserted = Array(repeating: false, count: b.count)
        self.budget = budget
        let size = 2 * ((a.count + b.count + 1) / 2) + 3
        forward = Array(repeating: 0, count: size)
        backward = Array(repeating: 0, count: size)
    }

    mutating func run() {
        compare(left: 0, right: a.count, top: 0, bottom: b.count)
    }

    private mutating func compare(left: Int, right: Int, top: Int, bottom: Int) {
        guard !exceeded else { return }
        var left = left, right = right, top = top, bottom = bottom
        while left < right, top < bottom, a[left] == b[top] {
            left += 1
            top += 1
        }
        while left < right, top < bottom, a[right - 1] == b[bottom - 1] {
            right -= 1
            bottom -= 1
        }
        if left == right {
            for j in top..<bottom { inserted[j] = true }
            return
        }
        if top == bottom {
            for i in left..<right { removed[i] = true }
            return
        }
        guard let (start, end) = midpoint(left: left, right: right, top: top, bottom: bottom) else {
            exceeded = true
            return
        }
        compare(left: left, right: start.x, top: top, bottom: start.y)
        compare(left: start.x, right: end.x, top: start.y, bottom: end.y)
        compare(left: end.x, right: right, top: end.y, bottom: bottom)
    }

    /// The middle snake of the box: a run of equal elements (with the edit just before or after it)
    /// that lies on a shortest path through the box.
    private mutating func midpoint(left: Int, right: Int, top: Int, bottom: Int) -> (start: (x: Int, y: Int), end: (x: Int, y: Int))? {
        let width = right - left
        let height = bottom - top
        let delta = width - height
        let odd = delta & 1 != 0
        let limit = (width + height + 1) / 2
        let offset = limit + 1
        forward[offset + 1] = left
        backward[offset + 1] = bottom
        for d in 0...limit {
            var k = d
            while k >= -d {
                let c = k - delta
                let previous: Int
                var x: Int
                if k == -d || (k != d && forward[offset + k - 1] < forward[offset + k + 1]) {
                    previous = forward[offset + k + 1]
                    x = previous
                } else {
                    previous = forward[offset + k - 1]
                    x = previous + 1
                }
                var y = top + (x - left) - k
                let previousY = (d == 0 || x != previous) ? y : y - 1
                while x < right, y < bottom, a[x] == b[y] {
                    x += 1
                    y += 1
                    budget -= 1
                }
                forward[offset + k] = x
                if odd, c >= -(d - 1), c <= d - 1, y >= backward[offset + c] {
                    return ((previous, previousY), (x, y))
                }
                k -= 2
            }
            var c = d
            while c >= -d {
                let k = c + delta
                let previous: Int
                var y: Int
                if c == -d || (c != d && backward[offset + c - 1] > backward[offset + c + 1]) {
                    previous = backward[offset + c + 1]
                    y = previous
                } else {
                    previous = backward[offset + c - 1]
                    y = previous - 1
                }
                var x = left + (y - top) + k
                let previousX = (d == 0 || y != previous) ? x : x + 1
                while x > left, y > top, a[x - 1] == b[y - 1] {
                    x -= 1
                    y -= 1
                    budget -= 1
                }
                backward[offset + c] = y
                if !odd, k >= -d, k <= d, x <= forward[offset + k] {
                    return ((x, y), (previousX, previous))
                }
                c -= 2
            }
            budget -= 2 * d + 2
            if budget < 0 { return nil }
        }
        return nil
    }
}
