import Foundation

public enum ResolvedImage: Equatable, Sendable {
    case remote(URL)
    case file(URL)
    case data(Data)
    case bundle(String)
    case unresolved(String)
}

public enum ImageLocator {
    public static func resolve(source: String, relativeTo baseDirectory: URL?) -> ResolvedImage {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unresolved(source) }

        if trimmed.lowercased().hasPrefix("bundle://") {
            let name = String(trimmed.dropFirst("bundle://".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? .unresolved(trimmed) : .bundle(name)
        }

        if trimmed.lowercased().hasPrefix("data:") {
            if let data = decodeDataURL(trimmed) {
                return .data(data)
            }
            return .unresolved(trimmed)
        }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                return .remote(url)
            case "file":
                return .file(url)
            default:
                return .unresolved(trimmed)
            }
        }

        // Markdown destinations are URL references: decode escapes once before making a file URL.
        let path = URLComponents(string: trimmed)?.path ?? trimmed.removingPercentEncoding ?? trimmed
        if path.hasPrefix("/") {
            return .file(URL(fileURLWithPath: path))
        }

        if path.hasPrefix("~") {
            let expanded = NSString(string: path).expandingTildeInPath
            return .file(URL(fileURLWithPath: expanded))
        }

        if let baseDirectory {
            return .file(baseDirectory.appendingPathComponent(path))
        }

        return .unresolved(trimmed)
    }

    private static func decodeDataURL(_ source: String) -> Data? {
        guard let comma = source.firstIndex(of: ",") else { return nil }
        let meta = source[..<comma].lowercased()
        guard meta.hasPrefix("data:image/"), meta.contains(";base64") else { return nil }
        let payload = source[source.index(after: comma)...]
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        return Data(base64Encoded: String(payload), options: [.ignoreUnknownCharacters])
    }
}
