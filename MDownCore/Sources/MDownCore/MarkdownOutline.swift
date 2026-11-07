import Foundation

public struct OutlineEntry: Hashable, Sendable, Identifiable {
    public var level: Int
    public var title: String
    public var utf16Location: Int
    public var id: Int { utf16Location }

    public init(level: Int, title: String, utf16Location: Int) {
        self.level = level
        self.title = title
        self.utf16Location = utf16Location
    }
}

public enum MarkdownOutline {
    /// Top-level headings, in source order.
    public static func entries(from blocks: [SourcedBlock]) -> [OutlineEntry] {
        blocks.compactMap {
            guard case let .heading(level, inlines) = $0.block else { return nil }
            let title = InlinePlainText.string(from: inlines).trimmingCharacters(in: .whitespacesAndNewlines)
            return OutlineEntry(level: level, title: title.isEmpty ? "Untitled" : title, utf16Location: $0.utf16Location)
        }
    }
}
