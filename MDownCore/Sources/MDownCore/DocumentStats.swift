import Foundation

public struct DocumentStats: Equatable, Sendable {
    public var words: Int
    public var characters: Int
    public var readingMinutes: Int

    public var statusLabel: String {
        guard words > 0 else { return "Empty page" }
        let wordLabel = words == 1 ? "1 word" : "\(words.formatted()) words"
        let minuteLabel = readingMinutes == 1 ? "1 min read" : "\(readingMinutes.formatted()) min read"
        return "\(wordLabel) · \(minuteLabel)"
    }

    public static func measure(_ text: String) -> DocumentStats {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .localized]) { _, _, _, _ in
            words += 1
        }
        let minutes: Int
        if words == 0 {
            minutes = 0
        } else {
            minutes = max(1, Int((Double(words) / 220.0).rounded(.up)))
        }
        return DocumentStats(words: words, characters: text.count, readingMinutes: minutes)
    }
}
