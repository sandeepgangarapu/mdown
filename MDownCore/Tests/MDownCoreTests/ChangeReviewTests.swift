import XCTest
@testable import MDownCore

final class ChangeReviewTests: XCTestCase {
    private func assertComplete(_ baseline: String, _ current: String, file: StaticString = #filePath, line: UInt = #line) {
        // UTF-16 arrays, since String equality ignores differences in Unicode normalization.
        let changes = ChangeReview.changes(from: baseline, to: current)
        XCTAssertEqual(Array(ChangeReview.accept(changes, into: baseline).utf16), Array(current.utf16), "accept all", file: file, line: line)
        XCTAssertEqual(Array(ChangeReview.reject(changes, in: current).utf16), Array(baseline.utf16), "reject all", file: file, line: line)
        for change in changes {
            XCTAssertEqual(Array(MarkdownText.substring(baseline, utf16Location: change.baselineLocation, utf16Length: change.baselineLength).utf16), Array(change.removed.utf16), file: file, line: line)
            XCTAssertEqual(Array(MarkdownText.substring(current, utf16Location: change.currentLocation, utf16Length: change.currentLength).utf16), Array(change.inserted.utf16), file: file, line: line)
        }
    }

    func testNoChangesForEqualText() {
        XCTAssertEqual(ChangeReview.changes(from: "Same\n", to: "Same\n"), [])
    }

    func testWordEditsInOneParagraphAreSeparate() {
        let baseline = "# Plan\n\nWe ship the beta by March, and keep it fast.\n"
        let current = "# Plan\n\nWe ship the public release by April, and keep it small and fast.\n"
        let changes = ChangeReview.changes(from: baseline, to: current)
        XCTAssertEqual(changes.map(\.removed), ["beta", "March", ""])
        XCTAssertEqual(changes.map(\.inserted), ["public release", "April", "small and "])
        assertComplete(baseline, current)
    }

    func testNeighboringReplacedWordsAreOneChange() {
        let changes = ChangeReview.changes(from: "The quick brown fox.\n", to: "The slow red fox.\n")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].removed, "quick brown")
        XCTAssertEqual(changes[0].inserted, "slow red")
    }

    func testAcceptingOneChangeLeavesTheOthersPending() {
        let baseline = "We ship the beta by March.\n"
        let current = "We ship the public release by April.\n"
        let changes = ChangeReview.changes(from: baseline, to: current)
        let accepted = ChangeReview.accept([changes[1]], into: baseline)
        XCTAssertEqual(accepted, "We ship the beta by April.\n")
        let remaining = ChangeReview.changes(from: accepted, to: current)
        XCTAssertEqual(remaining.map(\.inserted), ["public release"])
    }

    func testRejectingOneChangeRestoresOnlyItsText() {
        let baseline = "We ship the beta by March.\n"
        let current = "We ship the public release by April.\n"
        let changes = ChangeReview.changes(from: baseline, to: current)
        let rejected = ChangeReview.reject([changes[0]], in: current)
        XCTAssertEqual(rejected, "We ship the beta by April.\n")
        XCTAssertEqual(ChangeReview.changes(from: baseline, to: rejected).map(\.inserted), ["April"])
    }

    func testAddedParagraphsAreOneChangeEach() {
        let baseline = "First.\n\nLast.\n"
        let current = "First.\n\nNew one.\n\nNew two.\n\nLast.\n"
        let changes = ChangeReview.changes(from: baseline, to: current)
        XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(changes.allSatisfy { $0.removed.isEmpty })
        XCTAssertEqual(changes.map { $0.inserted.trimmingCharacters(in: .newlines) }, ["New one.", "New two."])
        assertComplete(baseline, current)
        // Keeping only the second paragraph.
        let accepted = ChangeReview.accept([changes[1]], into: baseline)
        XCTAssertEqual(ChangeReview.changes(from: accepted, to: current).count, 1)
        XCTAssertFalse(accepted.contains("New one."))
        XCTAssertTrue(accepted.contains("New two."))
    }

    func testAddedListItemsAreOneChangeEach() {
        let baseline = "- a\n- b\n"
        let current = "- a\n- c\n- d\n- b\n"
        let changes = ChangeReview.changes(from: baseline, to: current)
        XCTAssertEqual(changes.map(\.inserted), ["- c\n", "- d\n"])
        assertComplete(baseline, current)
        XCTAssertEqual(ChangeReview.reject([changes[0]], in: current), "- a\n- d\n- b\n")
    }

    func testRemovedTableIsOneChange() {
        let baseline = "Intro.\n\nOne.\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\nEnd.\n"
        let changes = ChangeReview.changes(from: baseline, to: "Intro.\n\nEnd.\n")
        XCTAssertEqual(changes.count, 2, "\(changes.map(\.removed))")
        assertComplete(baseline, "Intro.\n\nEnd.\n")
    }

    func testRemovedParagraphsAreOneChangeEach() {
        let baseline = "One.\n\nTwo.\n\nThree.\n\nFour.\n"
        let current = "One.\n\nFour.\n"
        let changes = ChangeReview.changes(from: baseline, to: current)
        XCTAssertEqual(changes.count, 2)
        assertComplete(baseline, current)
        let partly = ChangeReview.reject([changes[0]], in: current)
        XCTAssertTrue(partly.contains("Two.") != partly.contains("Three."))
    }

    func testEditedLineNextToAddedLineSlidesToLineStart() {
        let baseline = "- a\n- b\n"
        let current = "- A\n- c\n- b\n"
        assertComplete(baseline, current)
        let changes = ChangeReview.changes(from: baseline, to: current)
        XCTAssertFalse(changes.contains { $0.inserted.hasSuffix("- ") }, "\(changes)")
    }

    func testEmojiCJKAndCRLF() {
        assertComplete("Cake 🎂 here\r\nand there\r\n", "Cake 🎂🎉 here\r\nand everywhere\r\n")
        assertComplete("我们发布测试版。\n", "我们发布正式版。\n")
        let cjk = ChangeReview.changes(from: "我们发布测试版。\n", to: "我们发布正式版。\n")
        XCTAssertEqual(cjk.map(\.removed), ["测试"])
        assertComplete("👍🏽 ok\n", "👍🏿 ok\n")
        assertComplete("", "New file\n")
        assertComplete("Old file\n", "")
        assertComplete("No newline", "No newline at end")
    }

    func testRandomEditsStayComplete() {
        var generator = SeededGenerator(seed: 7)
        let words = ["alpha", "beta", "gamma", "🎂", "- item", "## Head", "\n", "\n\n", " ", "**bold**", "| a | b |", "测试", "\r\n"]
        func randomText() -> String {
            (0..<Int.random(in: 0...40, using: &generator)).map { _ in words.randomElement(using: &generator)! }.joined(separator: Bool.random(using: &generator) ? " " : "")
        }
        for _ in 0..<300 {
            let baseline = randomText()
            var pieces = Array(baseline)
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                let insert = Array(words.randomElement(using: &generator)!)
                let at = Int.random(in: 0...pieces.count, using: &generator)
                if Bool.random(using: &generator), !pieces.isEmpty {
                    let end = min(pieces.count, at + Int.random(in: 1...8, using: &generator))
                    pieces.replaceSubrange(min(at, pieces.count - 1)..<end, with: insert)
                } else {
                    pieces.insert(contentsOf: insert, at: at)
                }
            }
            let current = String(pieces)
            assertComplete(baseline, current)

            // Accepting some changes and rejecting the rest meets in the middle.
            let changes = ChangeReview.changes(from: baseline, to: current)
            let keep = changes.filter { _ in Bool.random(using: &generator) }
            let drop = changes.filter { !keep.contains($0) }
            XCTAssertEqual(ChangeReview.accept(keep, into: baseline), ChangeReview.reject(drop, in: current))
        }
    }

    func testComparisonIsAShortestEditOnRandomInput() {
        var generator = SeededGenerator(seed: 11)
        for _ in 0..<2000 {
            let a = (0..<Int.random(in: 0...14, using: &generator)).map { _ in Int.random(in: 0...3, using: &generator) }
            let b = (0..<Int.random(in: 0...14, using: &generator)).map { _ in Int.random(in: 0...3, using: &generator) }
            var comparison = SequenceComparison(a, b, budget: .max)
            comparison.run()
            let keptA = a.indices.filter { !comparison.removed[$0] }.map { a[$0] }
            let keptB = b.indices.filter { !comparison.inserted[$0] }.map { b[$0] }
            XCTAssertEqual(keptA, keptB, "\(a) \(b)")

            // Longest common subsequence by brute force.
            var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
            XCTAssertEqual(keptA.count, table[0][0], "not shortest: \(a) \(b)")
        }
    }

    func testComparisonOverBudgetFallsBackToOneRun() {
        let hunks = ChangeReview.hunks(from: Array(0..<50), to: Array(50..<100) + [49], budget: 10)
        XCTAssertEqual(hunks, [ChangeReview.Hunk(old: 0..<49, new: 0..<50)])
    }

    func testOwnEditOutsideChangesMovesIntoBaseline() {
        let baseline = "Intro.\n\nWe ship the beta.\n"
        let current = "Intro.\n\nWe ship the release.\n"
        let typed = "Intro, edited.\n\nWe ship the release.\n"
        let carried = ChangeReview.carryOwnEdit(baseline: baseline, from: current, to: typed)
        XCTAssertEqual(carried, "Intro, edited.\n\nWe ship the beta.\n")
        XCTAssertEqual(ChangeReview.changes(from: carried, to: typed).map(\.inserted), ["release"])

        // After the change, offsets shift by the change's difference in length.
        let typedAfter = "Intro.\n\nWe ship the release. Done.\n"
        let carriedAfter = ChangeReview.carryOwnEdit(baseline: baseline, from: current, to: typedAfter)
        XCTAssertEqual(carriedAfter, "Intro.\n\nWe ship the beta. Done.\n")

        // Typing right against a suggestion continues it, so the suggestion is kept.
        let typedAgainst = "Intro.\n\nWe ship the releases.\n"
        XCTAssertEqual(ChangeReview.carryOwnEdit(baseline: baseline, from: current, to: typedAgainst), typedAgainst)
    }

    func testOwnEditInsideAChangeAcceptsIt() {
        let baseline = "We ship the beta.\n"
        let current = "We ship the release.\n"
        let typed = "We ship the releases.\n"
        let carried = ChangeReview.carryOwnEdit(baseline: baseline, from: current, to: typed)
        XCTAssertEqual(carried, typed)
        XCTAssertEqual(ChangeReview.changes(from: carried, to: typed), [])
    }

    func testLargeDocumentsStayFast() {
        let paragraphs = (0..<3000).map { "Paragraph \($0) has a few words about the plan and what comes next." }
        let baseline = paragraphs.joined(separator: "\n\n") + "\n"
        var edited = paragraphs
        for index in stride(from: 7, to: edited.count, by: 150) {
            edited[index] = edited[index].replacingOccurrences(of: "few words", with: "handful of new words")
        }
        let scattered = edited.joined(separator: "\n\n") + "\n"
        let rewritten = paragraphs.prefix(400).map { $0.uppercased() + " Rewritten." }.joined(separator: "\n\n") + "\n"

        let start = Date()
        let changes = ChangeReview.changes(from: baseline, to: scattered)
        _ = ReviewPresentation(changes: changes, current: scattered)
        let scatteredTime = Date().timeIntervalSince(start)
        XCTAssertEqual(changes.count, 20)

        let rewriteStart = Date()
        let rewriteChanges = ChangeReview.changes(from: baseline, to: rewritten)
        _ = ReviewPresentation(changes: rewriteChanges, current: rewritten)
        let rewriteTime = Date().timeIntervalSince(rewriteStart)
        XCTAssertEqual(ChangeReview.accept(rewriteChanges, into: baseline), rewritten)

        print("review timing: scattered \(scatteredTime)s, rewrite \(rewriteTime)s, \(rewriteChanges.count) changes")
        XCTAssertLessThan(scatteredTime, 1.0)
        XCTAssertLessThan(rewriteTime, 3.0)
    }

    func testTextIsComparedExactlyNotByUnicodeEquivalence() {
        // "é" as one code point in the baseline, as "e" plus a combining accent in the file.
        let baseline = "\u{E9} old tail\n"
        let current = "e\u{301} new tail\n"
        assertComplete(baseline, current)
        assertComplete("Caf\u{E9}\n", "Cafe\u{301}\n")
        XCTAssertFalse(ChangeReview.changes(from: "Caf\u{E9}\n", to: "Cafe\u{301}\n").isEmpty)

        let typed = "e\u{301} new TAIL\n"
        let carried = ChangeReview.carryOwnEdit(baseline: baseline, from: current, to: typed)
        XCTAssertEqual(Array(carried.utf16), Array("\u{E9} old TAIL\n".utf16))
        let appended = ChangeReview.carryOwnEdit(baseline: baseline, from: current, to: current + "END")
        XCTAssertEqual(Array(appended.utf16), Array((baseline + "END").utf16))
    }

    func testOwnEditDoesNotSplitSurrogatePairs() {
        let edit = ChangeReview.singleEdit(from: "a🎂b", to: "a🎉b")
        XCTAssertEqual(edit.replacement, "🎉")
        XCTAssertEqual(edit.length, 2)
    }
}

final class ReviewPresentationTests: XCTestCase {
    private func marks(in text: String) -> [ReviewMark.Piece] {
        var state: ReviewMark.Mark?
        return ReviewMark.pieces(in: text, state: &state)
    }

    func testParagraphEditsAreTypesetInPlace() {
        let baseline = "# Plan\n\nWe ship the beta by March.\n\nUnchanged.\n"
        let current = "# Plan\n\nWe ship the public release by April.\n\nUnchanged.\n"
        let presentation = ReviewPresentation(baseline: baseline, current: current)
        XCTAssertEqual(presentation.rows.count, 3)
        guard case .unchanged = presentation.rows[0].content, case .unchanged = presentation.rows[2].content else {
            return XCTFail("Unchanged blocks should stay plain")
        }
        guard case let .typeset(blocks) = presentation.rows[1].content, case let .paragraph(inlines) = blocks.first?.block else {
            return XCTFail("The edited paragraph should be typeset")
        }
        XCTAssertEqual(presentation.rows[1].changes, [0, 1])
        let pieces = marks(in: InlinePlainText.string(from: inlines))
        XCTAssertEqual(pieces.filter { $0.mark?.kind == .removed }.map(\.text), ["beta ", "March "])
        XCTAssertEqual(pieces.filter { $0.mark?.kind == .inserted }.map(\.text), ["public release", "April"])
    }

    func testAddedAndRemovedBlocksGetTheirOwnRows() {
        let baseline = "One.\n\nGone.\n\nThree.\n"
        let current = "One.\n\nThree.\n\nAdded.\n"
        let presentation = ReviewPresentation(baseline: baseline, current: current)
        XCTAssertEqual(presentation.changes.count, 2)
        let changed = presentation.rows.filter { !$0.changes.isEmpty }
        XCTAssertEqual(changed.count, 2)
        for row in changed {
            guard case .typeset = row.content else { return XCTFail("Whole paragraphs should be typeset: \(row.content)") }
        }
    }

    func testListItemEditsKeepTheListTypeset() {
        let presentation = ReviewPresentation(baseline: "- a\n- b\n", current: "- a\n- new\n- b\n")
        XCTAssertEqual(presentation.rows.count, 1)
        guard case let .typeset(blocks) = presentation.rows[0].content, case let .bulletList(items) = blocks.first?.block else {
            return XCTFail("The list should stay a list: \(presentation.rows[0].content)")
        }
        XCTAssertEqual(items.count, 3)
    }

    func testTablesCodeHeadingLevelsAndLinksShowMarkdown() {
        let cases: [(String, String)] = [
            ("| a | b |\n| - | - |\n| 1 | 2 |\n", "| a | b |\n| - | - |\n| 1 | 3 |\n"),
            ("```\nlet a = 1\n```\n", "```\nlet a = 2\n```\n"),
            ("## Title\n", "### Title\n"),
            ("See [docs](https://a.example).\n", "See [docs](https://b.example).\n"),
            ("Para one.\n", "# Para one.\n")
        ]
        for (baseline, current) in cases {
            let presentation = ReviewPresentation(baseline: baseline, current: current)
            let changed = presentation.rows.filter { !$0.changes.isEmpty }
            XCTAssertEqual(changed.count, 1, current)
            guard case let .source(text) = changed.first?.content else {
                XCTFail("Expected Markdown for \(current.debugDescription), got \(String(describing: changed.first?.content))")
                continue
            }
            XCTAssertEqual(ReviewMark.side(text, keeping: .inserted), current.trimmingCharacters(in: .newlines))
            XCTAssertFalse(marks(in: text).filter { $0.mark != nil }.isEmpty)
        }
    }

    func testEveryChangeHasARow() {
        let baseline = "[ref]: https://a.example\n\nText.\n"
        let current = "[ref]: https://b.example\n\nText.\n"
        let presentation = ReviewPresentation(baseline: baseline, current: current)
        let shown = Set(presentation.rows.flatMap(\.changes))
        XCTAssertEqual(shown, Set(presentation.changes.indices))
    }

    func testRowIDsAreUniqueAndInDocumentOrder() {
        let presentation = ReviewPresentation(baseline: "One.\n\nTwo.\n\nThree.\n", current: "")
        XCTAssertEqual(presentation.rows.count, 3)
        XCTAssertEqual(Set(presentation.rows.map(\.id)).count, 3)
        XCTAssertEqual(presentation.rows.flatMap(\.changes), [0, 1, 2])

        let mixed = ReviewPresentation(baseline: "A.\n\nGone one.\n\nGone two.\n\nB.\n", current: "A.\n\nB.\n")
        XCTAssertEqual(Set(mixed.rows.map(\.id)).count, mixed.rows.count)
    }

    func testCharactersAlreadyInTheDocumentAreNeverTakenForMarks() {
        // SF Symbols live in plane 16's private use area, icon fonts at U+E000, and noncharacters
        // are what the marks themselves use.
        let noncharacters = [0xFDD0, 0xFDD3].map { String(Character(Unicode.Scalar($0)!)) }
        for glyph in ["\u{100000}", "\u{F0001}", "\u{E000}"] + noncharacters {
            let presentation = ReviewPresentation(baseline: "icon \(glyph) name old\n", current: "icon \(glyph) name new\n")
            XCTAssertEqual(presentation.changes.count, 1)
            let text: String
            switch presentation.rows.first?.content {
            case let .typeset(blocks)?:
                guard case let .paragraph(inlines) = blocks.first?.block else { return XCTFail("paragraph") }
                text = InlinePlainText.string(from: inlines)
            case let .source(source)?:
                text = source
            default:
                return XCTFail("Expected a changed row")
            }
            let pieces = marks(in: text)
            XCTAssertEqual(pieces.filter { $0.mark != nil }.map { $0.text.trimmingCharacters(in: .whitespaces) }, ["old", "new"], glyph.debugDescription)
            let plain = pieces.filter { $0.mark == nil }.map(\.text).joined()
            if glyph.unicodeScalars.first!.properties.isNoncharacterCodePoint {
                XCTAssertTrue(plain.hasPrefix("icon \u{FFFD} name"), plain.debugDescription)
            } else {
                XCTAssertTrue(plain.hasPrefix("icon \(glyph) name"), plain.debugDescription)
            }
        }
    }

    func testMarksHoldAnyNumberOfChanges() {
        for change in [0, 9, 15, 16, 255, 65_534, 65_535, 1_000_000] {
            for kind in [ReviewMark.Kind.inserted, .removed] {
                let pieces = marks(in: "a" + ReviewMark.open(kind, change) + "b" + String(Character(ReviewMark.close)) + "c")
                XCTAssertEqual(pieces.map(\.text), ["a", "b", "c"])
                XCTAssertEqual(pieces[1].mark, ReviewMark.Mark(kind: kind, change: change))
            }
        }
    }

    func testWhitespaceChangesAreVisible() {
        let presentation = ReviewPresentation(baseline: "One two.\n", current: "One\n\ntwo.\n")
        XCTAssertEqual(presentation.changes.count, 1)
        let shown = Set(presentation.rows.flatMap(\.changes))
        XCTAssertEqual(shown, [0])
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
