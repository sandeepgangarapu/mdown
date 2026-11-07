import XCTest
@testable import MDownCore

final class MarkdownEditingTests: XCTestCase {
    private func apply(_ action: MarkdownAction, _ text: String, _ location: Int = 0, _ length: Int? = nil) -> MarkdownEdit {
        MarkdownFormat.apply(action, to: text, utf16Location: location, utf16Length: length ?? (text as NSString).length)
    }
    private func active(_ action: MarkdownAction, _ text: String, _ location: Int = 0) -> Bool {
        MarkdownFormat.isActive(action, in: text, utf16Location: location, utf16Length: 0)
    }

    func testHeadingConvertsListsAndTasksAndClampsLevel() {
        XCTAssertEqual(apply(.heading(2), "- [x] A\n3. B\n# C").text, "## A\n## B\n## C")
        XCTAssertEqual(apply(.heading(0), "A").text, "# A")
        XCTAssertEqual(apply(.heading(99), "A").text, "###### A")
        XCTAssertEqual(apply(.heading(2), "## A\n## B").text, "A\nB")
        XCTAssertEqual(apply(.heading(2), "## A\nB").text, "## A\n## B")
        XCTAssertEqual(apply(.heading(2), "## A\n\n## B").text, "A\n\nB")
        XCTAssertEqual(apply(.heading(1), "#").text, "")
    }

    func testParagraphStripsAllPrefixes() {
        XCTAssertEqual(apply(.paragraph, "# A\n> - [X] B\n  3. C\n* D").text, "A\nB\n  C\nD")
        for text in ["# A", "> A", "- A", "1. A", "- [ ] A", "```\nx\n```"] {
            XCTAssertFalse(active(.paragraph, text), text)
        }
        XCTAssertTrue(active(.paragraph, "  Body 🎂"))
        XCTAssertTrue(active(.paragraph, ""))
    }

    func testMutuallyExclusiveStylesAndTaskDetection() {
        XCTAssertEqual(apply(.bullet, "# A\n1. B\n+ [x] C").text, "- A\n- B\n- C")
        XCTAssertEqual(apply(.checklist, "- A\n2. B\n# C").text, "- [ ] A\n- [ ] B\n- [ ] C")
        XCTAssertEqual(apply(.checklist, "- [x] A\n* [ ] B\n1. [X] C").text, "A\nB\nC")
        XCTAssertEqual(apply(.bullet, "- A\nB").text, "- A\n- B")
        XCTAssertEqual(apply(.ordered, "1. A\n2. B").text, "A\nB")
        for text in ["- [ ] x", "* [x] x", "+ [X] x", "1. [ ] x"] {
            XCTAssertTrue(active(.checklist, text))
            XCTAssertFalse(active(.bullet, text))
            XCTAssertFalse(active(.ordered, text))
        }
        XCTAssertTrue(active(.ordered, "12) x"))
        XCTAssertTrue(active(.bullet, "  + x"))
    }

    func testIndentationNumberingAndCaret() {
        XCTAssertEqual(apply(.ordered, "- A\n  - B\n  - C\n- D\n\t- E").text, "1. A\n  1. B\n  2. C\n2. D\n\t1. E")
        let text = "  - [x] 🎂中文"
        let location = (text as NSString).range(of: "中").location
        let edit = apply(.heading(2), text, location, 0)
        XCTAssertEqual(edit.text, "  ## 🎂中文")
        XCTAssertEqual((edit.text as NSString).substring(from: edit.utf16Location), "中文")
        XCTAssertEqual(apply(.bullet, "  - A").text, "  A")
    }

    func testTouchedLinesCRLFAndEmptyFinalLine() {
        XCTAssertEqual(apply(.bullet, "A🎂\r\n中文\r\nZ", 1, 5).text, "- A🎂\r\n- 中文\r\nZ")
        XCTAssertEqual(apply(.bullet, "A\nB", 0, 2).text, "- A\nB")
        XCTAssertEqual(apply(.bullet, "A\n", 2, 0).text, "A\n- ")
        XCTAssertEqual(apply(.bullet, "A\r\nB", 2, 0).text, "- A\r\nB")
        XCTAssertEqual(apply(.heading(1), "").text, "# ")
        XCTAssertEqual(apply(.paragraph, "").text, "")
    }

    func testQuotesRemainIndependent() {
        XCTAssertEqual(apply(.quote, "> A\nB").text, "A\n> B")
        XCTAssertEqual(apply(.quote, "  - A").text, "  > - A")
    }

    func testCodeFenceWrappingAndCaret() {
        let edit = apply(.codeBlock, "")
        XCTAssertEqual(edit.text, "```\n\n```")
        XCTAssertEqual(edit.utf16Location, 4)
        let wrapped = apply(.codeBlock, "A\r\n🎂中\r\nZ", 5, 0)
        XCTAssertEqual(wrapped.text, "A\r\n```\r\n🎂中\r\n```\r\nZ")
        XCTAssertEqual(wrapped.utf16Location, 10)
        XCTAssertEqual(apply(.codeBlock, "abc", 1, 0).utf16Location, 5)
    }

    func testCodeFenceDetectionAndRemoval() {
        for fence in ["```", "~~~", "````"] {
            let text = "\(fence)swift\r\n🎂中\r\n\(fence)\r\n"
            for loc in [0, (text as NSString).range(of: "🎂").location, (text as NSString).length - 3] {
                XCTAssertTrue(active(.codeBlock, text, loc))
                XCTAssertFalse(active(.paragraph, text, loc))
                XCTAssertEqual(apply(.codeBlock, text, loc, 0).text, "🎂中\r\n")
            }
        }
        XCTAssertFalse(active(.codeBlock, "```\nx\n```\nbody", 12))
        XCTAssertTrue(active(.codeBlock, "```\nx", 4))
        XCTAssertEqual(apply(.codeBlock, "```\nx", 4, 0).text, "x")
        XCTAssertFalse(active(.codeBlock, "    ```\nx", 8))
        XCTAssertFalse(active(.codeBlock, "```bad`\nx", 8))
    }

    func testInlineActionsRemainUTF16Safe() {
        for action in [MarkdownAction.bold, .italic, .strikethrough, .code] {
            let edit = apply(action, "A🎂中", 1, 2)
            XCTAssertTrue(MarkdownFormat.isActive(action, in: edit.text, utf16Location: edit.utf16Location, utf16Length: 2))
            XCTAssertEqual(apply(action, edit.text, edit.utf16Location, 2).text, "A🎂中")
        }
    }
}
