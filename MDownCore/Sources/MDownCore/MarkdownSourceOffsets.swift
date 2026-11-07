import Foundation
import Markdown

/// One pass over the source; lookup is constant time even for many blocks on a long line.
struct MarkdownSourceOffsets {
    private var lines: [[Int]] = [[]]

    init(_ source: String) {
        var offset = 0
        var previousCR = false
        lines = [[0]]
        for scalar in source.unicodeScalars {
            if scalar == "\n" && previousCR {
                offset += 1
                lines[lines.count - 1] = [offset]
                previousCR = false
                continue
            }
            previousCR = scalar == "\r"
            if scalar == "\r" || scalar == "\n" {
                offset += 1
                lines.append([offset])
            } else {
                offset += scalar.utf16.count
                for _ in 0..<scalar.utf8.count { lines[lines.count - 1].append(offset) }
            }
        }
    }

    func offset(of location: SourceLocation) -> Int? {
        guard location.line > 0, location.line <= lines.count, location.column > 0 else { return nil }
        let line = lines[location.line - 1]
        return line[min(location.column - 1, line.count - 1)]
    }
}
