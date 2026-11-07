import Foundation
import Markdown

public enum MarkdownTasks {
    /// Toggles a parsed task in document order, including nested tasks.
    public static func toggle(taskAt index: Int, in source: String) -> String? {
        guard index >= 0 else { return nil }
        let document = Document(parsing: source)
        let context = MarkdownTaskSource(source)
        var tasks: [NSRange] = []
        func visit(_ node: Markup) {
            if let item = node as? ListItem, let range = context.checkbox(in: item) { tasks.append(range) }
            for child in node.children { visit(child) }
        }
        visit(document)
        guard index < tasks.count else { return nil }
        let bracket = tasks[index]
        return context.text.replacingCharacters(in: bracket, with: context.text.substring(with: bracket) == " " ? "x" : " ")
    }
}

/// cmark does not mark tasks inside block quotes. Inspect only parser-proven list items,
/// anchored at their source start, so task recognition and rendered indices remain identical.
struct MarkdownTaskSource {
    let text: NSString
    let offsets: MarkdownSourceOffsets
    private static let pattern = try! NSRegularExpression(pattern: #"^(?:[-*+]|[0-9]+[.)])[ \t]+\[([ xX])\](?=[ \t\r\n]|$)"#)

    init(_ source: String) {
        text = source as NSString
        offsets = MarkdownSourceOffsets(source)
    }

    func checkbox(in item: ListItem) -> NSRange? {
        guard item.child(at: 0) is Paragraph, let range = item.range,
              let start = offsets.offset(of: range.lowerBound),
              let end = offsets.offset(of: range.upperBound), end >= start else { return nil }
        let line = text.lineRange(for: NSRange(location: start, length: 0))
        let slice = text.substring(with: NSRange(location: start, length: min(end, NSMaxRange(line)) - start))
        guard let match = Self.pattern.firstMatch(in: slice, range: NSRange(location: 0, length: (slice as NSString).length)) else { return nil }
        return NSRange(location: start + match.range(at: 1).location, length: 1)
    }
}
