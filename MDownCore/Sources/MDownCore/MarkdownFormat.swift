import Foundation

public enum MarkdownAction: Equatable, Sendable {
    case bold
    case italic
    case strikethrough
    case code
    case link
    case heading(Int)
    case paragraph
    case quote
    case bullet
    case ordered
    case checklist
    case codeBlock
}

public struct MarkdownEdit: Equatable, Sendable {
    public var text: String
    public var utf16Location: Int
    public var utf16Length: Int
}

public enum MarkdownFormat {
    public static func apply(
        _ action: MarkdownAction,
        to text: String,
        utf16Location: Int,
        utf16Length: Int
    ) -> MarkdownEdit {
        switch action {
        case .bold:
            return toggleWrap(text, location: utf16Location, length: utf16Length, marker: "**")
        case .italic:
            return toggleWrap(text, location: utf16Location, length: utf16Length, marker: "*", avoidDoubling: true)
        case .strikethrough:
            return toggleWrap(text, location: utf16Location, length: utf16Length, marker: "~~")
        case .code:
            return toggleWrap(text, location: utf16Location, length: utf16Length, marker: "`")
        case .link:
            return insertLink(text, location: utf16Location, length: utf16Length)
        case .heading, .paragraph, .quote, .bullet, .ordered, .checklist:
            return applyLines(action, text: text, location: utf16Location, length: utf16Length)
        case .codeBlock:
            return editFence(text, location: utf16Location, length: utf16Length)

        }
    }

    public static func isActive(
        _ action: MarkdownAction,
        in text: String,
        utf16Location: Int,
        utf16Length: Int
    ) -> Bool {
        let ns = text as NSString
        let location = clamp(utf16Location, to: ns.length)
        let length = min(max(utf16Length, 0), ns.length - location)
        switch action {
        case .bold:
            return insideWrap(ns, location: location, length: length, marker: "**", avoidDoubling: false)
        case .italic:
            return insideWrap(ns, location: location, length: length, marker: "*", avoidDoubling: true)
        case .strikethrough:
            return insideWrap(ns, location: location, length: length, marker: "~~", avoidDoubling: false)
        case .code:
            return insideWrap(ns, location: location, length: length, marker: "`", avoidDoubling: false)
        case .link:
            return false
        case .codeBlock:
            let lines = lineSlices(ns)
            let index = lines.firstIndex { overlaps($0, location: location, length: 0) } ?? 0
            return fenceBlocks(lines).contains { $0.contains(index) }
        case .paragraph:
            return !isActive(.codeBlock, in: text, utf16Location: location, utf16Length: 0)
                && lineContents(ns, location: location).allSatisfy { stripped($0, quote: true) == $0 }
        case let .heading(level):
            return lineContents(ns, location: location).contains { headingLevel(unindented($0).body) == max(1, min(level, 6)) }
        case .quote:
            return lineContents(ns, location: location).contains { prefixRange(unindented($0).body, pattern: quotePattern) != nil }
        case .bullet, .ordered, .checklist:
            return lineContents(ns, location: location).contains { style(of: $0) == action }

        }
    }

    private static func toggleWrap(
        _ text: String,
        location: Int,
        length: Int,
        marker: String,
        avoidDoubling: Bool = false
    ) -> MarkdownEdit {
        let ns = text as NSString
        let loc = clamp(location, to: ns.length)
        let len = min(max(length, 0), ns.length - loc)
        let markerLength = utf16Length(marker)
        if surrounded(ns, location: loc, length: len, marker: marker, markerLength: markerLength, avoidDoubling: avoidDoubling) {
            let inner = ns.substring(with: NSRange(location: loc, length: len))
            let updated = ns.replacingCharacters(
                in: NSRange(location: loc - markerLength, length: len + markerLength * 2),
                with: inner
            )
            return MarkdownEdit(text: updated, utf16Location: loc - markerLength, utf16Length: len)
        }
        if len >= markerLength * 2 {
            let selected = ns.substring(with: NSRange(location: loc, length: len))
            let selectedNS = selected as NSString
            if selectedNS.length >= markerLength * 2,
               selectedNS.substring(with: NSRange(location: 0, length: markerLength)) == marker,
               selectedNS.substring(with: NSRange(location: selectedNS.length - markerLength, length: markerLength)) == marker,
               !(avoidDoubling && marker == "*" && selectedNS.length >= 4 && selected.hasPrefix("**") && selected.hasSuffix("**")) {
                let inner = selectedNS.substring(with: NSRange(location: markerLength, length: selectedNS.length - markerLength * 2))
                let updated = ns.replacingCharacters(in: NSRange(location: loc, length: len), with: inner)
                return MarkdownEdit(text: updated, utf16Location: loc, utf16Length: (inner as NSString).length)
            }
        }
        let selected = len == 0 ? "" : ns.substring(with: NSRange(location: loc, length: len))
        let wrapped = marker + selected + marker
        let updated = ns.replacingCharacters(in: NSRange(location: loc, length: len), with: wrapped)
        return MarkdownEdit(
            text: updated,
            utf16Location: loc + markerLength,
            utf16Length: len
        )
    }

    private static func insertLink(_ text: String, location: Int, length: Int) -> MarkdownEdit {
        let ns = text as NSString
        let loc = clamp(location, to: ns.length)
        let len = min(max(length, 0), ns.length - loc)
        let selected = len == 0 ? "" : ns.substring(with: NSRange(location: loc, length: len))
        let replacement = "[\(selected)]()"
        let updated = ns.replacingCharacters(in: NSRange(location: loc, length: len), with: replacement)
        let caret = loc + 1 + (selected as NSString).length + 2
        return MarkdownEdit(text: updated, utf16Location: caret, utf16Length: 0)
    }

    private static func unindented(_ line: String) -> (indent: String, body: String) {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        return (indent, String(line.dropFirst(indent.count)))
    }

    private static let taskPattern = try! NSRegularExpression(pattern: #"^(?:[-*+]|[0-9]+[.)])[ \t]+\[[ xX]\](?:[ \t]+|$)"#)

    private static func style(of line: String) -> MarkdownAction? {
        let body = unindented(line).body
        if prefixRange(body, pattern: taskPattern) != nil { return .checklist }
        if prefixRange(body, pattern: bulletPattern) != nil { return .bullet }
        if prefixRange(body, pattern: orderedPattern) != nil { return .ordered }
        return nil
    }

    private static func stripped(_ line: String, quote: Bool = false) -> String {
        let (indent, original) = unindented(line)
        var body = original
        let patterns = (quote ? [quotePattern] : []) + [taskPattern, bulletPattern, orderedPattern, headingPattern]
        // Repeated prefixes can arise when converting a quoted list or a list heading.
        while let range = patterns.compactMap({ prefixRange(body, pattern: $0) }).first {
            body = (body as NSString).substring(from: NSMaxRange(range))
        }
        return indent + body
    }

    private static func applyLines(_ action: MarkdownAction, text: String, location: Int, length: Int) -> MarkdownEdit {
        let ns = text as NSString
        let loc = clamp(location, to: ns.length)
        let len = min(max(0, length), ns.length - loc)
        let lines = lineSlices(ns)
        let targets = lines.indices.filter { overlaps(lines[$0], location: loc, length: len) }
        let nonempty = targets.filter { !lines[$0].content.trimmingCharacters(in: .whitespaces).isEmpty }
        let remove = !nonempty.isEmpty && nonempty.allSatisfy {
            if case let .heading(n) = action {
                return headingLevel(unindented(lines[$0].content).body) == max(1, min(n, 6))
            }
            return style(of: lines[$0].content) == action
        }
        var numbers: [String: Int] = [:]
        var rewritten: [Int: String] = [:]
        for i in targets {
            let line = lines[i].content
            if action == .quote {
                let (indent, body) = unindented(line)
                rewritten[i] = indent + togglePrefix(body, pattern: quotePattern, insert: "> ")
                continue
            }
            let clean = stripped(line, quote: action == .paragraph)
            let (indent, body) = unindented(clean)
            let marker: String
            switch action {
            case let .heading(n): marker = remove ? "" : String(repeating: "#", count: max(1, min(n, 6))) + " "
            case .bullet: marker = remove ? "" : "- "
            case .checklist: marker = remove ? "" : "- [ ] "
            case .ordered:
                numbers[indent, default: 0] += 1
                marker = remove ? "" : "\(numbers[indent]!). "
            default: marker = ""
            }
            rewritten[i] = indent + marker + body
        }
        var result = ""
        var offset = 0
        var caret = loc
        for (i, line) in lines.enumerated() {
            let content = rewritten[i] ?? line.content
            if overlaps(line, location: loc, length: 0) {
                caret = offset + min(max(0, loc - line.range.location + utf16Length(content) - utf16Length(line.content)), utf16Length(content))
            }
            result += content + line.newline
            offset += utf16Length(content) + utf16Length(line.newline)
        }
        return MarkdownEdit(text: result, utf16Location: caret, utf16Length: 0)
    }

    private static func fenceBlocks(_ lines: [LineSlice]) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        var opened: (index: Int, character: Character, count: Int)?
        for (i, line) in lines.enumerated() {
            let (indent, body) = unindented(line.content)
            guard indent.count <= 3, let first = body.first, first == "`" || first == "~" else { continue }
            let count = body.prefix { $0 == first }.count
            let rest = body.dropFirst(count)
            if let open = opened {
                if first == open.character && count >= open.count && rest.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    result.append(open.index...i)
                    opened = nil
                }
            } else if count >= 3 && !(first == "`" && rest.contains("`")) {
                opened = (i, first, count)
            }
        }
        if let open = opened { result.append(open.index...(lines.count - 1)) }
        return result
    }

    private static func editFence(_ text: String, location: Int, length: Int) -> MarkdownEdit {
        let ns = text as NSString
        let loc = clamp(location, to: ns.length)
        let len = min(max(0, length), ns.length - loc)
        let lines = lineSlices(ns)
        let touched = lines.indices.filter { overlaps(lines[$0], location: loc, length: len) }
        guard let first = touched.first, let last = touched.last else {
            return MarkdownEdit(text: text, utf16Location: loc, utf16Length: 0)
        }
        if let block = fenceBlocks(lines).first(where: { $0.contains(first) && $0.contains(last) }) {
            let opening = lines[block.lowerBound]
            // An unclosed fence has no closing line to delete.
            let closingBody = unindented(lines[block.upperBound].content).body
            let openingBody = unindented(opening.content).body
            let marker = openingBody.first!
            let closing = block.upperBound > block.lowerBound && closingBody.prefix(while: { $0 == marker }).count >= openingBody.prefix(while: { $0 == marker }).count && closingBody.allSatisfy { $0 == marker || $0 == " " || $0 == "\t" }
            var result = ""
            var caret = loc
            for i in lines.indices {
                if i == block.lowerBound || (closing && i == block.upperBound) {
                    if lines[i].range.location < loc { caret -= min(loc - lines[i].range.location, lines[i].range.length) }
                } else { result += lines[i].content + lines[i].newline }
            }
            return MarkdownEdit(text: result, utf16Location: clamp(caret, to: utf16Length(result)), utf16Length: 0)
        }
        let newline = lines.first(where: { !$0.newline.isEmpty })?.newline ?? "\n"
        let start = lines[first].range.location
        let end = NSMaxRange(lines[last].range)
        let selected = ns.substring(with: NSRange(location: start, length: end - start))
        // Use a longer fence when the selection contains backtick fence runs.
        let longest = lines[first...last].map { unindented($0.content).body.prefix { $0 == "`" }.count }.max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let wrapped = fence + newline + selected + (lines[last].newline.isEmpty ? newline : "") + fence + (end < ns.length || !lines[last].newline.isEmpty ? newline : "")
        return MarkdownEdit(text: ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: wrapped), utf16Location: loc + utf16Length(fence + newline), utf16Length: 0)
    }

    private static func togglePrefix(_ line: String, pattern: NSRegularExpression, insert: String) -> String {
        if let range = prefixRange(line, pattern: pattern) {
            return (line as NSString).substring(from: range.location + range.length)
        }
        return insert + line
    }

    private static func headingLevel(_ line: String) -> Int? {
        guard let range = prefixRange(line, pattern: headingPattern) else { return nil }
        let marks = (line as NSString).substring(with: range).trimmingCharacters(in: .whitespaces)
        return marks.count
    }

    private static func insideWrap(
        _ ns: NSString,
        location: Int,
        length: Int,
        marker: String,
        avoidDoubling: Bool
    ) -> Bool {
        let markerLength = utf16Length(marker)
        if surrounded(ns, location: location, length: length, marker: marker, markerLength: markerLength, avoidDoubling: avoidDoubling) {
            return true
        }
        guard length == 0, markerLength > 0 else { return false }
        let slices = lineSlices(ns)
        guard let line = slices.first(where: { $0.range.location <= location && location <= NSMaxRange($0.range) }) else {
            return false
        }
        let relative = location - line.range.location
        let content = line.content as NSString
        guard relative >= markerLength, relative + markerLength <= content.length else { return false }
        let before = content.substring(with: NSRange(location: relative - markerLength, length: markerLength))
        let afterStart = relative
        guard afterStart + markerLength <= content.length else { return false }
        let after = content.substring(with: NSRange(location: afterStart, length: markerLength))
        if before == marker && after == marker {
            if avoidDoubling && marker == "*" {
                let beforeIsBold = relative - markerLength >= 1 && content.character(at: relative - markerLength - 1) == 42
                let afterIsBold = afterStart + markerLength < content.length && content.character(at: afterStart + markerLength) == 42
                if beforeIsBold || afterIsBold { return false }
            }
            return true
        }
        return false
    }

    private static func surrounded(
        _ ns: NSString,
        location: Int,
        length: Int,
        marker: String,
        markerLength: Int,
        avoidDoubling: Bool
    ) -> Bool {
        guard location >= markerLength, location + length + markerLength <= ns.length else { return false }
        let before = ns.substring(with: NSRange(location: location - markerLength, length: markerLength))
        let after = ns.substring(with: NSRange(location: location + length, length: markerLength))
        guard before == marker, after == marker else { return false }
        if avoidDoubling && marker == "*" {
            if location - markerLength >= 1 && ns.character(at: location - markerLength - 1) == 42 { return false }
            if location + length + markerLength < ns.length && ns.character(at: location + length + markerLength) == 42 { return false }
        }
        return true
    }

    private struct LineSlice {
        var range: NSRange
        var content: String
        var newline: String
    }

    private static func lineSlices(_ ns: NSString) -> [LineSlice] {
        if ns.length == 0 {
            return [LineSlice(range: NSRange(location: 0, length: 0), content: "", newline: "")]
        }
        var slices: [LineSlice] = []
        var index = 0
        while index < ns.length {
            let range = ns.lineRange(for: NSRange(location: index, length: 0))
            let raw = ns.substring(with: range)
            let newline: String
            let content: String
            if raw.hasSuffix("\r\n") {
                newline = "\r\n"
                content = (raw as NSString).substring(to: (raw as NSString).length - 2)
            } else if raw.hasSuffix("\n") {
                newline = "\n"
                content = String(raw.dropLast())
            } else if raw.hasSuffix("\r") {
                newline = "\r"
                content = String(raw.dropLast())
            } else {
                newline = ""
                content = raw
            }
            slices.append(LineSlice(range: range, content: content, newline: newline))
            let next = NSMaxRange(range)
            if next <= index { break }
            index = next
        }
        if slices.last?.newline.isEmpty == false {
            slices.append(LineSlice(range: NSRange(location: ns.length, length: 0), content: "", newline: ""))
        }
        return slices
    }

    private static func lineContents(_ ns: NSString, location: Int) -> [String] {
        let loc = clamp(location, to: ns.length)
        return lineSlices(ns).filter { overlaps($0, location: loc, length: 0) }.map(\.content)
    }

    private static func overlaps(_ line: LineSlice, location: Int, length: Int) -> Bool {
        let start = line.range.location
        let end = start + utf16Length(line.content)
        let selectionEnd = location + max(length, 0)
        if length == 0 {
            return location >= start && (location < NSMaxRange(line.range) || (line.newline.isEmpty && location == end))
        }
        return start < selectionEnd && NSMaxRange(line.range) > location
    }

    private static func prefixRange(_ line: String, pattern: NSRegularExpression) -> NSRange? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard range.length > 0 else { return nil }
        return pattern.firstMatch(in: line, range: range)?.range
    }

    private static func clamp(_ location: Int, to length: Int) -> Int {
        min(max(location, 0), length)
    }

    private static func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }

    private static let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,6})(?:[ \t]+|$)"#)
    private static let bulletPattern = try! NSRegularExpression(pattern: #"^[-*+][ \t]+"#)
    private static let orderedPattern = try! NSRegularExpression(pattern: #"^[0-9]+[.)][ \t]+"#)
    private static let quotePattern = try! NSRegularExpression(pattern: #"^>[ \t]?"#)
}
