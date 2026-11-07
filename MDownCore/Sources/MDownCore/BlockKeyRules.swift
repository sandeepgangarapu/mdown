import Foundation

/// What Return should do inside the open block.
public enum ReturnOutcome: Equatable, Sendable {
    /// Let the text view insert a plain newline.
    case none
    /// Replace the block's Markdown and put the caret here.
    case replace(text: String, caret: Int)
    /// End the block at the caret: `before` stays, `after` becomes a new block below it.
    case split(before: String, after: String)
}

/// Word-processor behavior for Return and Tab on top of raw Markdown, modeled on Notes:
/// Return starts a new paragraph, continues a list, and leaves a list from an empty item.
public enum BlockKeyRules {
    public static func returnKey(in text: String, selection: NSRange) -> ReturnOutcome {
        let ns = text as NSString
        guard selection.length == 0, selection.location >= 0, selection.location <= ns.length else { return .none }
        let caret = selection.location
        if let closed = closingFence(ns, caret: caret) { return closed }
        if isVerbatimBlock(ns) { return .none }

        let lineRange = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
        let lineStart = lineRange.location
        let contentEnd = lineStart + contentLength(of: lineRange, in: ns)
        let content = ns.substring(with: NSRange(location: lineStart, length: contentEnd - lineStart))
        let column = caret - lineStart

        if let item = ListLine(content) {
            guard column >= item.prefixLength else { return .none }
            if item.isEmpty {
                return leave(ns, lineRange: lineRange, lineStart: lineStart)
            }
            let insertion = "\n" + item.continuation
            let updated = ns.replacingCharacters(in: NSRange(location: caret, length: 0), with: insertion)
            return .replace(text: updated, caret: caret + (insertion as NSString).length)
        }

        if let quote = QuoteLine(content) {
            guard column >= quote.prefixLength else { return .none }
            if quote.isEmpty {
                return leave(ns, lineRange: lineRange, lineStart: lineStart)
            }
            let insertion = "\n" + quote.prefix
            let updated = ns.replacingCharacters(in: NSRange(location: caret, length: 0), with: insertion)
            return .replace(text: updated, caret: caret + (insertion as NSString).length)
        }

        // A paragraph or heading: Return ends it here and starts a new paragraph below.
        guard caret > 0 else { return .none }
        let before = trimTrailingSpaces(ns.substring(to: caret))
        let after = trimLeadingWhitespace(ns.substring(from: caret))
        guard !before.isEmpty else { return .none }
        return .split(before: before, after: after)
    }

    /// Tab nests a list item under the one above it; Shift-Tab moves it back out. Returns nil when
    /// the caret line is not a list item that can move, so the key falls through.
    public static func tab(in text: String, selection: NSRange, outdent: Bool) -> (text: String, selection: NSRange)? {
        let ns = text as NSString
        guard selection.location >= 0, selection.location <= ns.length,
              selection.length >= 0, selection.length <= ns.length - selection.location,
              !isVerbatimBlock(ns) else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: min(selection.location, ns.length), length: 0))
        let lineStart = lineRange.location
        let content = ns.substring(with: NSRange(location: lineStart, length: contentLength(of: lineRange, in: ns)))
        guard let item = ListLine(content) else { return nil }

        let previous = previousListLines(in: ns, before: lineStart)
        let newIndent: Int
        if outdent {
            guard item.indent > 0 else { return nil }
            newIndent = previous.last(where: { $0.indent < item.indent })?.indent ?? 0
        } else {
            guard let parent = previous.last(where: { $0.indent <= item.indent }) else { return nil }
            let target = parent.indent + parent.markerWidth
            guard target > item.indent else { return nil }
            newIndent = target
        }

        // Move the item together with everything nested under it, so its children stay its children.
        let delta = newIndent - item.indent
        var lines = [lineRange]
        var pendingBlank: [NSRange] = []
        var index = NSMaxRange(lineRange)
        while index < ns.length {
            let range = ns.lineRange(for: NSRange(location: index, length: 0))
            let content = ns.substring(with: NSRange(location: range.location, length: contentLength(of: range, in: ns)))
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                pendingBlank.append(range)
            } else if indentationColumns(String(content.prefix(while: { $0 == " " || $0 == "\t" }))) > item.indent {
                lines += pendingBlank
                pendingBlank.removeAll()
                lines.append(range)
            } else {
                break
            }
            let next = NSMaxRange(range)
            if next <= index { break }
            index = next
        }

        let updated = NSMutableString(string: ns)
        var edits: [(location: Int, removed: Int, added: Int)] = []
        for range in lines.reversed() {
            let content = updated.substring(with: NSRange(location: range.location, length: contentLength(of: range, in: updated)))
            guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indentation = String(content.prefix(while: { $0 == " " || $0 == "\t" }))
            if indentation.contains("\t") {
                // A tab occupies columns up to the next four-column stop. Normalize only
                // the moved indentation so the subtree shifts by the same visual width.
                let width = max(0, indentationColumns(indentation) + delta)
                updated.replaceCharacters(in: NSRange(location: range.location, length: (indentation as NSString).length),
                                          with: String(repeating: " ", count: width))
                edits.append((range.location, (indentation as NSString).length, width))
            } else if delta > 0 {
                updated.insert(String(repeating: " ", count: delta), at: range.location)
                edits.append((range.location, 0, delta))
            } else {
                let removable = min(-delta, indentation.count)
                updated.deleteCharacters(in: NSRange(location: range.location, length: removable))
                edits.append((range.location, removable, 0))
            }
        }
        // Map both endpoints through every indentation edit, including descendants.
        func mapped(_ offset: Int) -> Int {
            var result = offset
            for edit in edits where edit.location <= offset {
                result += edit.added - min(edit.removed, offset - edit.location)
            }
            return result
        }
        let location = mapped(selection.location)
        let end = mapped(NSMaxRange(selection))
        return (updated as String, NSRange(location: location, length: end - location))
    }

    // MARK: - Fences

    /// Return at the end of a lone opening fence closes it and puts the caret on the line inside,
    /// so the rest of the page is never swallowed into a code block.
    private static func closingFence(_ ns: NSString, caret: Int) -> ReturnOutcome? {
        let text = ns as String
        guard caret == ns.length, !text.contains(where: \.isNewline) else { return nil }
        let trimmed = text.drop(while: { $0 == " " })
        guard text.count - trimmed.count <= 3,
              let character = trimmed.first, character == "`" || character == "~" else { return nil }
        let fence = String(trimmed.prefix(while: { $0 == character }))
        guard fence.count >= 3 else { return nil }
        let info = trimmed.dropFirst(fence.count)
        guard character != "`" || !info.contains("`") else { return nil }
        let indent = String(repeating: " ", count: text.count - trimmed.count)
        let updated = text + "\n\n" + indent + fence
        return .replace(text: updated, caret: ns.length + 1)
    }

    // MARK: - Helpers

    /// Fenced code, tables, and HTML keep Return as a plain newline.
    private static func isVerbatimBlock(_ ns: NSString) -> Bool {
        let trimmed = (ns as String).drop(while: { $0 == " " })
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed.hasPrefix("|") || trimmed.hasPrefix("<")
    }

    /// Return on an empty list item or quote line: drop that line's marker and end the block there.
    private static func leave(_ ns: NSString, lineRange: NSRange, lineStart: Int) -> ReturnOutcome {
        let before = trimTrailingNewlines(ns.substring(to: lineStart))
        let after = ns.substring(from: NSMaxRange(lineRange))
        return .split(before: before, after: after)
    }

    private static func previousListLines(in ns: NSString, before location: Int) -> [ListLine] {
        var lines: [ListLine] = []
        var index = 0
        while index < location {
            let range = ns.lineRange(for: NSRange(location: index, length: 0))
            let content = ns.substring(with: NSRange(location: range.location, length: contentLength(of: range, in: ns)))
            if let item = ListLine(content) {
                lines.append(item)
            }
            let next = NSMaxRange(range)
            if next <= index { break }
            index = next
        }
        return lines
    }

    private static func contentLength(of lineRange: NSRange, in ns: NSString) -> Int {
        var length = lineRange.length
        while length > 0 {
            let character = ns.character(at: lineRange.location + length - 1)
            if character == 0x000A || character == 0x000D {
                length -= 1
            } else {
                break
            }
        }
        return length
    }

    private static func trimTrailingSpaces(_ text: String) -> String {
        var result = text
        while let last = result.last, last == " " || last == "\t" {
            result.removeLast()
        }
        return result
    }

    private static func trimTrailingNewlines(_ text: String) -> String {
        var result = text
        while let last = result.last, last.isNewline {
            result.removeLast()
        }
        return result
    }

    private static func trimLeadingWhitespace(_ text: String) -> String {
        String(text.drop(while: { $0 == " " || $0 == "\t" || $0.isNewline }))
    }
}

/// A list item line: indentation, marker, spacing, and an optional task box.
private struct ListLine {
    var indent: Int
    var indentation: String
    var marker: String
    var spacing: String
    var task: Bool
    var prefixLength: Int
    var isEmpty: Bool

    /// Width from the line start to the item's content, which is where a nested item must start.
    var markerWidth: Int { indentationColumns(indentation + marker + (spacing.isEmpty ? " " : spacing)) - indent }

    init?(_ line: String) {
        let ns = line as NSString
        guard let match = Self.pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        indentation = ns.substring(with: match.range(at: 1))
        indent = indentationColumns(indentation)
        marker = ns.substring(with: match.range(at: 2))
        spacing = ns.substring(with: match.range(at: 3))
        task = match.range(at: 4).location != NSNotFound
        prefixLength = match.range.length
        isEmpty = ns.substring(from: prefixLength).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The prefix for the next item: the same bullet, the next number, and an empty task box.
    var continuation: String {
        var next = marker
        if let last = marker.last, last == "." || last == ")", let number = Int(marker.dropLast()) {
            next = "\(number + 1)\(last)"
        }
        let space = spacing.isEmpty ? " " : (spacing.contains("\t") ? spacing : " ")
        return indentation + next + space + (task ? "[ ] " : "")
    }

    private static let pattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|[0-9]{1,9}[.)])([ \t]+|$)(\[[ xX]\](?:[ \t]+|$))?"#)
}

private struct QuoteLine {
    var prefix: String
    var prefixLength: Int
    var isEmpty: Bool

    init?(_ line: String) {
        let ns = line as NSString
        guard let match = Self.pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        prefixLength = match.range.length
        let raw = ns.substring(with: match.range)
        prefix = raw.hasSuffix(" ") ? raw : raw + " "
        isEmpty = ns.substring(from: prefixLength).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static let pattern = try! NSRegularExpression(pattern: #"^ {0,3}(?:> ?)+"#)
}

/// CommonMark tab stops apply to marker spacing as well as leading indentation.
private func indentationColumns(_ prefix: String) -> Int {
    prefix.reduce(0) { column, character in
        character == "\t" ? column + 4 - column % 4 : column + 1
    }
}
