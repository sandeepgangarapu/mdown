import Foundation
import Markdown

public enum ColumnAlign: Hashable, Sendable {
    case leading
    case center
    case trailing
}

public enum InlineNode: Hashable, Sendable {
    case text(String)
    case softBreak
    case lineBreak
    case code(String)
    case strong([InlineNode])
    case emphasis([InlineNode])
    case strikethrough([InlineNode])
    case link(destination: String?, title: String?, children: [InlineNode])
    case image(source: String?, title: String?, alt: [InlineNode])
}

public struct ListItemNode: Hashable, Sendable {
    public enum Check: Hashable, Sendable {
        case checked
        case unchecked
    }

    public var check: Check?
    public var children: [BlockNode]
}

public struct TableCellNode: Hashable, Sendable {
    public var inlines: [InlineNode]
    public var colspan: Int
}

public struct SourcedBlock: Hashable, Sendable {
    public var block: BlockNode
    public var utf16Location: Int
    public var utf16Length: Int

    public func source(in markdown: String) -> String {
        MarkdownText.substring(markdown, utf16Location: utf16Location, utf16Length: utf16Length)
    }
}

public enum MarkdownText {
    public static func utf16Length(of text: String) -> Int {
        (text as NSString).length
    }

    public static func substring(_ markdown: String, utf16Location: Int, utf16Length: Int) -> String {
        let ns = markdown as NSString
        let range = NSRange(location: utf16Location, length: utf16Length)
        guard utf16Location >= 0, utf16Length >= 0, utf16Location <= ns.length, utf16Length <= ns.length - utf16Location else { return "" }
        return ns.substring(with: range)
    }

    public static func replace(_ markdown: String, utf16Location: Int, utf16Length: Int, with replacement: String) -> String {
        let ns = markdown as NSString
        let range = NSRange(location: utf16Location, length: utf16Length)
        guard utf16Location >= 0, utf16Length >= 0, utf16Location <= ns.length, utf16Length <= ns.length - utf16Location else { return markdown }
        return ns.replacingCharacters(in: range, with: replacement)
    }
}

public enum BlockNode: Hashable, Sendable {
    case paragraph([InlineNode])
    case heading(level: Int, inlines: [InlineNode])
    case quote([BlockNode])
    case code(language: String?, source: String)
    case bulletList([ListItemNode])
    case orderedList(start: Int, items: [ListItemNode])
    case rule
    case table(alignments: [ColumnAlign], header: [TableCellNode], rows: [[TableCellNode]])
    case figure(source: String, title: String?, alt: String)
    case html(String)
}

public enum InlinePlainText {
    public static func string(from nodes: [InlineNode]) -> String {
        nodes.map(piece).joined()
    }

    private static func piece(_ node: InlineNode) -> String {
        switch node {
        case let .text(value):
            return value
        case .softBreak:
            return " "
        case .lineBreak:
            return "\n"
        case let .code(value):
            return value
        case let .strong(children), let .emphasis(children), let .strikethrough(children):
            return string(from: children)
        case let .link(_, _, children):
            return string(from: children)
        case let .image(_, _, alt):
            return string(from: alt)
        }
    }
}

public enum MarkdownRenderModel {
    public static func blocks(from markdown: String) -> [BlockNode] {
        sourcedBlocks(from: markdown).map(\.block)
    }

    /// Top-level blocks paired with the exact source slice they were parsed from.
    public static func sourcedBlocks(from markdown: String) -> [SourcedBlock] {
        let document = Document(parsing: markdown)
        let context = MarkdownTaskSource(markdown)
        let offsets = context.offsets
        return document.children.compactMap { markup in
            guard let block = block(from: markup, context: context), let range = markup.range else { return nil }
            guard let start = offsets.offset(of: range.lowerBound),
                  let end = offsets.offset(of: range.upperBound),
                  end >= start else { return nil }
            return SourcedBlock(block: block, utf16Location: start, utf16Length: end - start)
        }
    }

    private static func block(from markup: Markup, context: MarkdownTaskSource) -> BlockNode? {
        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level, inlines: inlines(from: heading))
        case let paragraph as Paragraph:
            let nodes = inlines(from: paragraph)
            if nodes.isEmpty {
                return nil
            }
            if nodes.count == 1, case let .image(source, title, alt) = nodes[0], let source, !source.isEmpty {
                return .figure(source: source, title: title, alt: InlinePlainText.string(from: alt))
            }
            return .paragraph(nodes)
        case let quote as BlockQuote:
            return .quote(quote.children.compactMap { block(from: $0, context: context) })
        case let code as CodeBlock:
            let language = code.language?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = (language?.isEmpty == false) ? language : nil
            return .code(language: normalized, source: code.code)
        case let list as UnorderedList:
            return .bulletList(list.children.compactMap { listItem(from: $0, context: context) })
        case let list as OrderedList:
            let start = max(Int(list.startIndex), 1)
            return .orderedList(start: start, items: list.children.compactMap { listItem(from: $0, context: context) })
        case is ThematicBreak:
            return .rule
        case let table as Table:
            let alignments = table.columnAlignments.map(columnAlign)
            let header = Array(table.head.cells.map(cell(from:)))
            let rows = table.body.rows.map { row in
                Array(row.cells.map(cell(from:)))
            }
            return .table(alignments: alignments, header: header, rows: Array(rows))
        case let html as HTMLBlock:
            return .html(html.rawHTML)
        default:
            let source = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
            return source.isEmpty ? nil : .paragraph([.text(source)])
        }
    }

    private static func listItem(from markup: Markup, context: MarkdownTaskSource) -> ListItemNode? {
        guard let item = markup as? ListItem else { return nil }
        let marker = context.checkbox(in: item)
        let check: ListItemNode.Check? = marker.map {
            context.text.substring(with: $0) == " " ? .unchecked : .checked
        }
        var children = item.children.compactMap { block(from: $0, context: context) }
        if marker != nil, item.checkbox == nil,
           case var .paragraph(inlines) = children.first,
           case let .text(text) = inlines.first {
            let pattern = #"^\[[ xX]\][ \t]*"#
            inlines[0] = .text(text.replacingOccurrences(of: pattern, with: "", options: .regularExpression))
            children[0] = .paragraph(inlines)
        }
        return ListItemNode(check: check, children: children)
    }

    private static func cell(from cell: Table.Cell) -> TableCellNode {
        TableCellNode(inlines: inlines(from: cell), colspan: max(Int(cell.colspan), 0))
    }

    private static func columnAlign(_ alignment: Table.ColumnAlignment?) -> ColumnAlign {
        switch alignment {
        case .center:
            return .center
        case .right:
            return .trailing
        case .left, nil:
            return .leading
        }
    }

    private static func inlines(from markup: Markup) -> [InlineNode] {
        markup.children.compactMap(inline(from:))
    }

    private static func inline(from markup: Markup) -> InlineNode? {
        switch markup {
        case let text as Text:
            return text.string.isEmpty ? nil : .text(text.string)
        case is SoftBreak:
            return .softBreak
        case is LineBreak:
            return .lineBreak
        case let code as InlineCode:
            return .code(code.code)
        case let strong as Strong:
            return .strong(inlines(from: strong))
        case let emphasis as Emphasis:
            return .emphasis(inlines(from: emphasis))
        case let strike as Strikethrough:
            return .strikethrough(inlines(from: strike))
        case let link as Link:
            return .link(destination: link.destination, title: link.title, children: inlines(from: link))
        case let image as Image:
            return .image(source: image.source, title: image.title, alt: inlines(from: image))
        case let html as InlineHTML:
            let raw = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if raw == "<br>" || raw == "<br/>" || raw == "<br />" {
                return .lineBreak
            }
            return html.rawHTML.isEmpty ? nil : .text(html.rawHTML)
        case let symbol as SymbolLink:
            return .code(symbol.destination ?? "")
        default:
            let source = markup.format()
            return source.isEmpty ? nil : .text(source)
        }
    }
}
