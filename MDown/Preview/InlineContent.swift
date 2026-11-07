import AppKit
import MDownCore
import SwiftUI

struct InlineStyle {
    var strong = false
    var emphasis = false
    var strike = false
    var code = false
    var link: URL?
    var size: CGFloat
    var face: PageFace
    var weight: Font.Weight = .regular
    var colors: MDownPalette.Colors
    var color: NSColor? = nil

    init(style: PageStyle, size: CGFloat? = nil, weight: Font.Weight = .regular, color: NSColor? = nil) {
        self.size = size ?? style.size
        self.face = style.face
        self.weight = weight
        self.colors = style.colors
        self.color = color
    }
}

func safeLink(_ destination: String?) -> URL? {
    guard let destination, let url = URL(string: destination), let scheme = url.scheme?.lowercased() else {
        return nil
    }
    switch scheme {
    case "http", "https", "mailto":
        return url
    default:
        return nil
    }
}

func attributedInlines(_ nodes: [InlineNode], style: InlineStyle) -> AttributedString {
    var result = AttributedString()
    append(nodes, style: style, to: &result)
    return result
}

private func append(_ nodes: [InlineNode], style: InlineStyle, to result: inout AttributedString) {
    for node in nodes {
        switch node {
        case let .text(value):
            result += run(value, style: style)
        case .softBreak:
            result += run(" ", style: style)
        case .lineBreak:
            result += run("\n", style: style)
        case let .code(value):
            var next = style
            next.code = true
            result += run(value, style: next)
        case let .strong(children):
            var next = style
            next.strong = true
            append(children, style: next, to: &result)
        case let .emphasis(children):
            var next = style
            next.emphasis = true
            append(children, style: next, to: &result)
        case let .strikethrough(children):
            var next = style
            next.strike = true
            append(children, style: next, to: &result)
        case let .link(destination, _, children):
            var next = style
            next.link = safeLink(destination)
            append(children, style: next, to: &result)
        case let .image(_, _, alt):
            let label = InlinePlainText.string(from: alt)
            result += run(label.isEmpty ? "Image" : label, style: style)
        }
    }
}

private func run(_ string: String, style: InlineStyle) -> AttributedString {
    guard !string.isEmpty else { return AttributedString() }
    var text = AttributedString(string)
    var container = AttributeContainer()

    var weight = style.strong ? Font.Weight.bold : style.weight
    if style.strong, style.weight == .bold || style.weight == .semibold {
        weight = .heavy
    }
    let design: Font.Design = style.code ? .monospaced : style.face.design
    let size = style.code ? (style.size * 0.88).rounded() : style.size
    var font = Font.system(size: size, weight: weight, design: design)
    if style.emphasis {
        font = font.italic()
    }
    container.font = font

    let foreground: NSColor
    if style.link != nil {
        foreground = style.colors.link
    } else {
        foreground = style.color ?? style.colors.ink
    }
    container.foregroundColor = Color(nsColor: foreground)
    if style.code {
        container.backgroundColor = Color(nsColor: style.colors.codeBackground)
    }
    if style.strike {
        container.strikethroughStyle = .single
    }
    if let link = style.link {
        container.link = link
        container.underlineStyle = .single
    }
    text.mergeAttributes(container)
    return text
}

/// Marks every case- and accent-insensitive occurrence of `term` the way Find does in other Mac apps.
func highlightingMatches(of term: String, in text: AttributedString) -> AttributedString {
    let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return text }
    var result = text
    var searchStart = result.startIndex
    while searchStart < result.endIndex,
          let range = result[searchStart...].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
        result[range].backgroundColor = Color(nsColor: .findHighlightColor)
        result[range].foregroundColor = .black
        guard range.upperBound > searchStart else { break }
        searchStart = range.upperBound
    }
    return result
}

private struct FindTermKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    /// The current Find text, highlighted wherever it appears on the page.
    var findTerm: String {
        get { self[FindTermKey.self] }
        set { self[FindTermKey.self] = newValue }
    }
}

struct RichText: View {
    var nodes: [InlineNode]
    var style: InlineStyle
    var lineSpacing: CGFloat
    var alignment: TextAlignment = .leading

    @Environment(\.findTerm) private var findTerm

    var body: some View {
        Text(highlightingMatches(of: findTerm, in: attributedInlines(nodes, style: style)))
            .lineSpacing(lineSpacing)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }
}

func highlightedCode(_ code: String, language: String?, colors: MDownPalette.Colors, size: CGFloat) -> AttributedString {
    let ns = code as NSString
    let tokens = CodeHighlighter.tokens(in: code, language: language)
    let covered = tokens.reduce(0) { $0 + $1.utf16Length }
    guard let first = tokens.first, first.utf16Offset == 0, covered == ns.length else {
        var plain = AttributedString(code)
        plain.font = .system(size: size, design: .monospaced)
        plain.foregroundColor = Color(nsColor: colors.ink)
        return plain
    }

    var result = AttributedString()
    for token in tokens {
        let slice = ns.substring(with: NSRange(location: token.utf16Offset, length: token.utf16Length))
        var piece = AttributedString(slice)
        piece.font = .system(size: size, weight: token.kind == .keyword ? .semibold : .regular, design: .monospaced)
        piece.foregroundColor = Color(nsColor: codeColor(for: token.kind, colors: colors))
        result += piece
    }
    return result
}

func codeColor(for kind: CodeTokenKind, colors: MDownPalette.Colors) -> NSColor {
    switch kind {
    case .keyword: colors.keyword
    case .typeName: colors.typeName
    case .string: colors.string
    case .comment: colors.comment
    case .number: colors.number
    case .plain: colors.ink
    case .punctuation: colors.secondary
    }
}
