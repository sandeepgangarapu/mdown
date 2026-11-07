import Foundation

public enum SourceSpanKind: Hashable, Sendable {
    case heading(Int)
    case quote
    case marker
    case inlineCode
    case strong
    case emphasis
    case strike
    case link
    case rule
    case fence
    case frontMatter
    case codeRun
    case token(CodeTokenKind)
}

public struct SourceSpan: Hashable, Sendable {
    public var utf16Offset: Int
    public var utf16Length: Int
    public var kind: SourceSpanKind
}

public enum MarkdownSourceHighlighter {
    public static func spans(in text: String) -> [SourceSpan] {
        let ns = text as NSString
        var spans: [SourceSpan] = []
        var location = 0
        var fence: Fence?

        if let closing = frontMatterClosingLine(in: ns) {
            let end = NSMaxRange(closing)
            spans.append(SourceSpan(utf16Offset: 0, utf16Length: end, kind: .frontMatter))
            location = end
        }

        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let contentRange = strippingNewline(lineRange, in: ns)
            let content = ns.substring(with: contentRange)

            if let currentFence = fence {
                if closes(content, fence: currentFence) {
                    spans.append(span(lineRange, kind: .fence))
                    fence = nil
                } else {
                    spans.append(span(lineRange, kind: .codeRun))
                    appendCodeTokens(content, range: contentRange, language: currentFence.language, to: &spans)
                }
                location = NSMaxRange(lineRange)
                continue
            }

            if let opened = openingFence(content) {
                spans.append(span(lineRange, kind: .fence))
                fence = opened
                location = NSMaxRange(lineRange)
                continue
            }

            classifyProse(content, contentRange: contentRange, into: &spans)
            location = NSMaxRange(lineRange)
        }

        return spans
    }

    private static func classifyProse(_ content: String, contentRange: NSRange, into spans: inout [SourceSpan]) {
        guard contentRange.length > 0 else { return }
        let ns = content as NSString
        if isRule(content) {
            spans.append(span(contentRange, kind: .rule))
            return
        }
        if let level = headingLevel(content) {
            spans.append(span(contentRange, kind: .heading(level)))
            let markerLength = headingMarkerLength(content, level: level)
            let remainder = NSRange(location: markerLength, length: max(0, ns.length - markerLength))
            if remainder.length > 0, remainder.length <= 8_000 {
                scanInline(ns, range: remainder, base: contentRange.location, into: &spans)
            }
            return
        }
        if content.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
            spans.append(span(contentRange, kind: .quote))
            let markerLength = quotePrefixLength(content)
            spans.append(SourceSpan(utf16Offset: contentRange.location, utf16Length: markerLength, kind: .marker))
            let remainder = NSRange(location: markerLength, length: max(0, ns.length - markerLength))
            if remainder.length > 0, remainder.length <= 8_000 {
                scanInline(ns, range: remainder, base: contentRange.location, into: &spans)
            }
            return
        }
        if let markerLength = listMarkerLength(content), markerLength > 0 {
            spans.append(SourceSpan(utf16Offset: contentRange.location, utf16Length: markerLength, kind: .marker))
            let remainder = NSRange(location: markerLength, length: max(0, ns.length - markerLength))
            if remainder.length > 0, remainder.length <= 8_000 {
                scanInline(ns, range: remainder, base: contentRange.location, into: &spans)
            }
            return
        }
        if ns.length <= 8_000 {
            scanInline(ns, range: NSRange(location: 0, length: ns.length), base: contentRange.location, into: &spans)
        }
    }

    private static func appendCodeTokens(_ content: String, range: NSRange, language: String?, to spans: inout [SourceSpan]) {
        let tokens = CodeHighlighter.tokens(in: content, language: language)
        for token in tokens {
            switch token.kind {
            case .plain, .punctuation:
                continue
            case .keyword, .typeName, .string, .comment, .number:
                spans.append(SourceSpan(
                    utf16Offset: range.location + token.utf16Offset,
                    utf16Length: token.utf16Length,
                    kind: .token(token.kind)
                ))
            }
        }
    }

    private static func scanInline(_ ns: NSString, range: NSRange, base: Int, into spans: inout [SourceSpan]) {
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            if match(ns, at: index, end: end, prefix: "`"),
               let close = find(ns, marker: "`", from: index + 1, to: end) {
                append(from: index, to: close + 1, base: base, kind: .inlineCode, into: &spans)
                index = close + 1
                continue
            }
            if let marker = strongMarker(ns, at: index, end: end),
               let close = find(ns, marker: marker, from: index + marker.utf16.count, to: end),
               close > index + marker.utf16.count {
                let markerLength = marker.utf16.count
                append(from: index, to: close + markerLength, base: base, kind: .strong, into: &spans)
                let interior = NSRange(location: index + markerLength, length: close - (index + markerLength))
                scanInline(ns, range: interior, base: base, into: &spans)
                index = close + markerLength
                continue
            }
            if match(ns, at: index, end: end, prefix: "~~"),
               let close = find(ns, marker: "~~", from: index + 2, to: end),
               close > index + 2 {
                append(from: index, to: close + 2, base: base, kind: .strike, into: &spans)
                scanInline(ns, range: NSRange(location: index + 2, length: close - (index + 2)), base: base, into: &spans)
                index = close + 2
                continue
            }
            if isSingleStar(ns, at: index, end: end),
               let close = closingStar(ns, from: index + 1, to: end) {
                append(from: index, to: close + 1, base: base, kind: .emphasis, into: &spans)
                scanInline(ns, range: NSRange(location: index + 1, length: close - (index + 1)), base: base, into: &spans)
                index = close + 1
                continue
            }
            if let linkEnd = linkEnd(ns, at: index, end: end) {
                append(from: index, to: linkEnd, base: base, kind: .link, into: &spans)
                if let label = linkLabelRange(ns, at: index, end: linkEnd) {
                    scanInline(ns, range: label, base: base, into: &spans)
                }
                index = linkEnd
                continue
            }
            index += 1
        }
    }

    private static func append(from start: Int, to end: Int, base: Int, kind: SourceSpanKind, into spans: inout [SourceSpan]) {
        guard end > start else { return }
        spans.append(SourceSpan(utf16Offset: base + start, utf16Length: end - start, kind: kind))
    }

    private static func strongMarker(_ ns: NSString, at index: Int, end: Int) -> String? {
        if match(ns, at: index, end: end, prefix: "**") { return "**" }
        if match(ns, at: index, end: end, prefix: "__") { return "__" }
        return nil
    }

    private static func isSingleStar(_ ns: NSString, at index: Int, end: Int) -> Bool {
        guard index < end, ns.character(at: index) == 42 else { return false }
        let nextIsStar = index + 1 < end && ns.character(at: index + 1) == 42
        return !nextIsStar
    }

    private static func closingStar(_ ns: NSString, from: Int, to: Int) -> Int? {
        var index = from
        while index < to {
            if ns.character(at: index) == 42 {
                let previousIsStar = index > 0 && ns.character(at: index - 1) == 42
                let nextIsStar = index + 1 < to && ns.character(at: index + 1) == 42
                if !previousIsStar && !nextIsStar { return index }
            }
            index += 1
        }
        return nil
    }

    private static func linkEnd(_ ns: NSString, at index: Int, end: Int) -> Int? {
        let labelStart: Int
        if match(ns, at: index, end: end, prefix: "![") {
            labelStart = index + 2
        } else if match(ns, at: index, end: end, prefix: "[") {
            labelStart = index + 1
        } else {
            return nil
        }
        guard let labelEnd = find(ns, marker: "]", from: labelStart, to: end),
              labelEnd + 1 < end,
              ns.character(at: labelEnd + 1) == 40,
              let urlEnd = find(ns, marker: ")", from: labelEnd + 2, to: end) else {
            return nil
        }
        return urlEnd + 1
    }

    private static func linkLabelRange(_ ns: NSString, at index: Int, end: Int) -> NSRange? {
        let labelStart = match(ns, at: index, end: end, prefix: "![") ? index + 2 : index + 1
        guard let labelEnd = find(ns, marker: "]", from: labelStart, to: end), labelEnd >= labelStart else { return nil }
        return NSRange(location: labelStart, length: labelEnd - labelStart)
    }

    private static func match(_ ns: NSString, at index: Int, end: Int, prefix: String) -> Bool {
        let length = prefix.utf16.count
        guard index + length <= end else { return false }
        return ns.substring(with: NSRange(location: index, length: length)) == prefix
    }

    private static func find(_ ns: NSString, marker: String, from: Int, to: Int) -> Int? {
        let length = marker.utf16.count
        guard length > 0 else { return nil }
        var index = from
        while index + length <= to {
            if ns.substring(with: NSRange(location: index, length: length)) == marker {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func span(_ range: NSRange, kind: SourceSpanKind) -> SourceSpan {
        SourceSpan(utf16Offset: range.location, utf16Length: range.length, kind: kind)
    }

    private static func strippingNewline(_ lineRange: NSRange, in ns: NSString) -> NSRange {
        var length = lineRange.length
        while length > 0 {
            let character = ns.character(at: lineRange.location + length - 1)
            if character == 10 || character == 13 {
                length -= 1
            } else {
                break
            }
        }
        return NSRange(location: lineRange.location, length: length)
    }

    private static func frontMatterClosingLine(in ns: NSString) -> NSRange? {
        guard ns.length >= 4 else { return nil }
        let first = ns.lineRange(for: NSRange(location: 0, length: 0))
        let firstContent = ns.substring(with: strippingNewline(first, in: ns))
        guard firstContent.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var location = NSMaxRange(first)
        var seen = 0
        while location < ns.length && seen < 40 {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: strippingNewline(line, in: ns)).trimmingCharacters(in: .whitespaces)
            if content == "---" { return line }
            location = NSMaxRange(line)
            seen += 1
        }
        return nil
    }

    private static func isRule(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, let first = trimmed.first else { return false }
        guard first == "-" || first == "*" || first == "_" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func headingLevel(_ content: String) -> Int? {
        var count = 0
        for character in content {
            if character == "#" {
                count += 1
            } else {
                break
            }
        }
        guard (1...6).contains(count) else { return nil }
        let rest = content.dropFirst(count)
        if rest.isEmpty || rest.first == " " || rest.first == "\t" {
            return count
        }
        return nil
    }

    private static func headingMarkerLength(_ content: String, level: Int) -> Int {
        let ns = content as NSString
        var length = level
        if length < ns.length {
            let character = ns.character(at: length)
            if character == 32 || character == 9 { length += 1 }
        }
        return min(length, ns.length)
    }

    private static func quotePrefixLength(_ content: String) -> Int {
        let ns = content as NSString
        var index = 0
        var consumedMarker = false
        while index < ns.length {
            let character = ns.character(at: index)
            if character == 62 {
                consumedMarker = true
                index += 1
                if index < ns.length {
                    let next = ns.character(at: index)
                    if next == 32 || next == 9 { index += 1 }
                }
                continue
            }
            if !consumedMarker && (character == 32 || character == 9) && index < 3 {
                index += 1
                continue
            }
            break
        }
        return index
    }

    private static func listMarkerLength(_ content: String) -> Int? {
        let ns = content as NSString
        var index = 0
        while index < ns.length && index < 3 && (ns.character(at: index) == 32 || ns.character(at: index) == 9) {
            index += 1
        }
        guard index < ns.length else { return nil }
        let character = ns.character(at: index)
        if character == 45 || character == 42 || character == 43 {
            let markerStart = index
            index += 1
            guard index < ns.length, ns.character(at: index) == 32 || ns.character(at: index) == 9 else { return nil }
            index += 1
            if character == 45 {
                let task = ns.substring(with: NSRange(location: markerStart, length: min(6, ns.length - markerStart)))
                if task.hasPrefix("- [ ] ") || task.lowercased().hasPrefix("- [x] ") {
                    return markerStart + 6
                }
            }
            return index
        }
        var numberEnd = index
        while numberEnd < ns.length, let scalar = UnicodeScalar(ns.character(at: numberEnd)), CharacterSet.decimalDigits.contains(scalar) {
            numberEnd += 1
        }
        guard numberEnd > index, numberEnd + 1 < ns.length, ns.character(at: numberEnd) == 46 else { return nil }
        let afterDot = numberEnd + 1
        guard afterDot < ns.length, ns.character(at: afterDot) == 32 || ns.character(at: afterDot) == 9 else { return nil }
        return afterDot + 1
    }

    private static func openingFence(_ content: String) -> Fence? {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        var count = 0
        for character in trimmed {
            if character == first {
                count += 1
            } else {
                break
            }
        }
        guard count >= 3 else { return nil }
        let info = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        let language = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return Fence(character: first, count: count, language: language)
    }

    private static func closes(_ content: String, fence: Fence) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= fence.count else { return false }
        return trimmed.allSatisfy { $0 == fence.character }
    }
}

private struct Fence {
    var character: Character
    var count: Int
    var language: String?
}
