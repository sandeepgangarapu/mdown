import Foundation

/// The block whose Markdown is open in place of its typeset form.
public struct PageEditing: Equatable, Sendable {
    /// UTF-16 offset of the draft in the document.
    public var location: Int
    /// The block's Markdown as currently edited.
    public var draft: String
    /// A new, still-empty block that has not been written into the document yet. It is inserted
    /// with the right blank lines around it once the first character is typed, so opening a new
    /// line and leaving it again never marks the document as changed.
    public var pending = false

    public init(location: Int, draft: String, pending: Bool = false) {
        self.location = location
        self.draft = draft
        self.pending = pending
    }

    public var draftLength: Int { pending ? 0 : MarkdownText.utf16Length(of: draft) }
    public var end: Int { location + draftLength }
}

public enum CaretPlacement: Sendable {
    case start
    case end
}

/// Pure text operations behind the editing session. All offsets are UTF-16.
public enum EditingText {
    public struct Insertion: Equatable, Sendable {
        public var text: String
        /// Where the inserted block starts in `text`.
        public var location: Int
    }

    public struct Removal: Equatable, Sendable {
        public var text: String
        /// Where the removed block was; the caret anchor after removal.
        public var location: Int
        /// How far text that followed the removed block moved.
        public var delta: Int
    }

    /// Inserts `block` as its own Markdown block at `location`, adding just enough blank lines
    /// before and after it that it does not merge with its neighbors.
    public static func insertBlock(_ block: String, into text: String, at location: Int) -> Insertion {
        let ns = text as NSString
        let location = min(max(location, 0), ns.length)
        let before = ns.substring(to: location)
        let after = ns.substring(from: location)

        let prefix: String
        if before.isEmpty || before.hasSuffix("\n\n") || before.hasSuffix("\r\n\r\n") {
            prefix = ""
        } else if before.hasSuffix("\n") || before.hasSuffix("\r\n") {
            prefix = "\n"
        } else {
            prefix = "\n\n"
        }

        let suffix: String
        if after.isEmpty || after.hasPrefix("\n\n") || after.hasPrefix("\r\n\r\n") {
            suffix = ""
        } else if after.hasPrefix("\n") || after.hasPrefix("\r\n") {
            suffix = "\n"
        } else {
            suffix = "\n\n"
        }

        let updated = before + prefix + block + suffix + after
        return Insertion(text: updated, location: location + MarkdownText.utf16Length(of: prefix))
    }

    /// Removes the (blank) block at `location` and collapses the blank lines around it, so deleting
    /// everything in a block does not leave a run of empty lines behind.
    public static func removeBlankBlock(in text: String, at location: Int, length: Int) -> Removal {
        let ns = text as NSString
        let start = min(max(location, 0), ns.length)
        let end = min(start + max(length, 0), ns.length)

        var runStart = start
        while runStart > 0, isNewline(ns.character(at: runStart - 1)) {
            runStart -= 1
        }
        var runEnd = end
        while runEnd < ns.length, isNewline(ns.character(at: runEnd)) {
            runEnd += 1
        }

        let replacement: String
        if runStart == 0 {
            replacement = ""
        } else if runEnd == ns.length {
            replacement = "\n"
        } else {
            replacement = "\n\n"
        }

        let updated = ns.replacingCharacters(in: NSRange(location: runStart, length: runEnd - runStart), with: replacement)
        let removedLength = runEnd - runStart
        let anchor = runStart == 0 ? 0 : runStart
        return Removal(
            text: updated,
            location: anchor,
            delta: MarkdownText.utf16Length(of: replacement) - removedLength
        )
    }

    /// Re-anchors the open block after the document changed underneath it (undo, redo, revert, or
    /// the file changing on disk). Returns nil when the change touched the block's edges and the
    /// block can no longer be identified, in which case editing should end.
    public static func rebase(_ editing: PageEditing, from old: String, to new: String) -> PageEditing? {
        let oldNS = old as NSString
        let newNS = new as NSString
        let oldLength = oldNS.length
        let newLength = newNS.length
        guard editing.location >= 0, editing.location <= oldLength,
              editing.draftLength <= oldLength - editing.location else { return nil }

        var prefix = 0
        let limit = min(oldLength, newLength)
        while prefix < limit, oldNS.character(at: prefix) == newNS.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < limit - prefix,
              oldNS.character(at: oldLength - 1 - suffix) == newNS.character(at: newLength - 1 - suffix) {
            suffix += 1
        }

        if prefix == oldLength, oldLength == newLength { return editing }

        let changeStart = prefix
        let oldChangeEnd = oldLength - suffix
        let delta = newLength - oldLength
        var next = editing

        if oldChangeEnd < editing.location || (oldChangeEnd == editing.location && changeStart < editing.location) {
            next.location += delta
            return next
        }
        if changeStart > editing.end || (changeStart == editing.end && oldChangeEnd > editing.end) {
            return next
        }
        if editing.pending {
            return nil
        }
        if changeStart >= editing.location && oldChangeEnd <= editing.end {
            let length = editing.draftLength + delta
            guard length >= 0, editing.location + length <= newLength else { return nil }
            next.draft = newNS.substring(with: NSRange(location: editing.location, length: length))
            return next
        }
        return nil
    }

    /// Where the caret goes when a block opens: its start, or the end of its last line.
    public static func caret(in source: String, placement: CaretPlacement) -> Int {
        switch placement {
        case .start:
            return 0
        case .end:
            let ns = source as NSString
            var end = ns.length
            while end > 0, isNewline(ns.character(at: end - 1)) {
                end -= 1
            }
            return end
        }
    }

    public static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }

    private static func isNewline(_ character: unichar) -> Bool {
        character == 0x000A || character == 0x000D
    }
}
