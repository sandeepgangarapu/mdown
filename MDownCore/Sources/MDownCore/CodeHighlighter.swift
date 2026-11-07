import Foundation

public enum CodeTokenKind: Hashable, Sendable {
    case plain
    case keyword
    case typeName
    case string
    case comment
    case number
    case punctuation
}

public struct CodeToken: Hashable, Sendable {
    public var utf16Offset: Int
    public var utf16Length: Int
    public var kind: CodeTokenKind
}

public enum CodeHighlighter {
    public static func tokens(in code: String, language: String?) -> [CodeToken] {
        var lexer = Lexer(code: code, language: canonicalLanguage(language))
        return lexer.tokenize()
    }

    public static func canonicalLanguage(_ language: String?) -> String {
        let value = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch value {
        case "js", "jsx", "node", "javascript":
            return "javascript"
        case "ts", "tsx", "typescript":
            return "typescript"
        case "sh", "shell", "zsh", "bash":
            return "bash"
        case "yml", "yaml":
            return "yaml"
        case "py", "python":
            return "python"
        case "rb", "ruby":
            return "ruby"
        case "rs", "rust":
            return "rust"
        case "md", "markdown":
            return "markdown"
        case "objc", "objective-c", "objectivec":
            return "objc"
        case "c++", "cc", "cpp":
            return "cpp"
        case "kt", "kotlin":
            return "kotlin"
        case "text", "plain", "txt":
            return "text"
        default:
            return value
        }
    }
}

private struct Lexer {
    let code: String
    let language: String
    var index: String.Index
    var utf16Cursor = 0
    var tokens: [CodeToken] = []

    init(code: String, language: String) {
        self.code = code
        self.language = language
        self.index = code.startIndex
    }

    mutating func tokenize() -> [CodeToken] {
        while index < code.endIndex {
            if consumeNewline() { continue }
            if consumeWhitespace() { continue }
            if consumeComment() { continue }
            if consumeString() { continue }
            if consumeHTMLTag() { continue }
            if consumeNumber() { continue }
            if consumeIdentifier() { continue }
            consumePunctuation()
        }
        return tokens
    }

    private var commentStyle: CommentStyle {
        switch language {
        case "python", "ruby", "bash", "yaml", "toml", "r", "perl", "elixir":
            return .hash
        case "html", "xml":
            return .html
        case "json", "text", "markdown", "":
            return .none
        default:
            return .slash
        }
    }

    private var supportsTripleQuotes: Bool {
        language == "swift" || language == "python" || language == "kotlin"
    }

    private var supportsTemplateStrings: Bool {
        language == "javascript" || language == "typescript"
    }

    private var colorsUppercaseTypes: Bool {
        switch language {
        case "swift", "rust", "java", "kotlin", "typescript", "go":
            return true
        default:
            return false
        }
    }

    private mutating func consumeNewline() -> Bool {
        if peek()?.isNewline == true {
            let start = index
            advance()
            emit(from: start, kind: .plain)
            return true
        }
        return false
    }

    private mutating func consumeWhitespace() -> Bool {
        guard let character = peek(), character == " " || character == "\t" else { return false }
        let start = index
        while let character = peek(), character == " " || character == "\t" {
            advance()
        }
        emit(from: start, kind: .plain)
        return true
    }

    private mutating func consumeComment() -> Bool {
        switch commentStyle {
        case .slash:
            if peek() == "/", peek(1) == "/" {
                let start = index
                while let character = peek(), !character.isNewline {
                    advance()
                }
                emit(from: start, kind: .comment)
                return true
            }
            if peek() == "/", peek(1) == "*" {
                let start = index
                advance()
                advance()
                while index < code.endIndex {
                    if peek() == "*", peek(1) == "/" {
                        advance()
                        advance()
                        break
                    }
                    advance()
                }
                emit(from: start, kind: .comment)
                return true
            }
        case .hash:
            if peek() == "#" {
                let start = index
                while let character = peek(), !character.isNewline {
                    advance()
                }
                emit(from: start, kind: .comment)
                return true
            }
        case .html:
            if starts(with: "<!--") {
                let start = index
                advance(4)
                while index < code.endIndex {
                    if starts(with: "-->") {
                        advance(3)
                        break
                    }
                    advance()
                }
                emit(from: start, kind: .comment)
                return true
            }
        case .none:
            break
        }
        return false
    }

    private mutating func consumeString() -> Bool {
        if supportsTemplateStrings, peek() == "`" {
            return consumeQuoted(quote: "`", triple: false)
        }
        guard let quote = peek(), quote == "\"" || quote == "'" else { return false }
        if language == "json", quote == "'" { return false }
        if quote == "\"", supportsTripleQuotes, peek(1) == "\"", peek(2) == "\"" {
            return consumeQuoted(quote: "\"", triple: true)
        }
        return consumeQuoted(quote: quote, triple: false)
    }

    private mutating func consumeQuoted(quote: Character, triple: Bool) -> Bool {
        let start = index
        if triple {
            advance(3)
        } else {
            advance()
        }
        while index < code.endIndex {
            if peek() == "\\" {
                advance()
                if index < code.endIndex { advance() }
                continue
            }
            if !triple, peek()?.isNewline == true {
                break
            }
            if triple, starts(with: "\"\"\"") {
                advance(3)
                break
            }
            if !triple, peek() == quote {
                advance()
                break
            }
            advance()
        }
        emit(from: start, kind: .string)
        return true
    }

    private mutating func consumeHTMLTag() -> Bool {
        guard language == "html" || language == "xml", peek() == "<" else { return false }
        if starts(with: "<!--") { return false }
        let start = index
        advance()
        while index < code.endIndex {
            if peek()?.isNewline == true { break }
            if peek() == ">" {
                advance()
                break
            }
            advance()
        }
        emit(from: start, kind: .keyword)
        return true
    }

    private mutating func consumeNumber() -> Bool {
        guard let character = peek(), character.isNumber else { return false }
        let start = index
        if character == "0", let mark = peek(1), mark == "x" || mark == "X" {
            advance()
            advance()
            while let hex = peek(), hex.isHexDigit || hex == "_" {
                advance()
            }
            emit(from: start, kind: .number)
            return true
        }
        while let digit = peek(), digit.isNumber || digit == "_" {
            advance()
        }
        if peek() == ".", let next = peek(1), next.isNumber {
            advance()
            while let digit = peek(), digit.isNumber || digit == "_" {
                advance()
            }
        }
        emit(from: start, kind: .number)
        return true
    }

    private mutating func consumeIdentifier() -> Bool {
        guard let character = peek(), character.isLetter || character == "_" else { return false }
        let start = index
        advance()
        while let next = peek(), next.isLetter || next.isNumber || next == "_" {
            advance()
        }
        let word = String(code[start..<index])
        emit(from: start, kind: kind(for: word))
        return true
    }

    private mutating func consumePunctuation() {
        let start = index
        advance()
        emit(from: start, kind: .punctuation)
    }

    private func kind(for word: String) -> CodeTokenKind {
        if keywords.contains(word) { return .keyword }
        if typeNames.contains(word) { return .typeName }
        if colorsUppercaseTypes,
           word.count > 1,
           word.first?.isUppercase == true,
           word != word.uppercased() {
            return .typeName
        }
        return .plain
    }

    private var keywords: Set<String> {
        switch language {
        case "swift":
            return Lexer.swiftKeywords
        case "python":
            return Lexer.pythonKeywords
        case "javascript":
            return Lexer.javascriptKeywords
        case "typescript":
            return Lexer.javascriptKeywords.union(Lexer.typescriptKeywords)
        case "go":
            return Lexer.goKeywords
        case "rust":
            return Lexer.rustKeywords
        case "bash":
            return Lexer.bashKeywords
        case "ruby":
            return Lexer.rubyKeywords
        case "java", "kotlin":
            return Lexer.javaKeywords
        case "json":
            return ["true", "false", "null"]
        case "css":
            return Lexer.cssKeywords
        default:
            return []
        }
    }

    private var typeNames: Set<String> {
        switch language {
        case "swift":
            return ["String", "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "Double", "Float", "Bool", "Character", "Void", "Any", "AnyObject", "Never", "Array", "Dictionary", "Set", "Optional", "Result", "Error", "URL", "Data", "Date", "UUID"]
        case "rust":
            return ["String", "Vec", "Option", "Result", "Box", "i8", "i16", "i32", "i64", "u8", "u32", "u64", "usize", "bool", "str"]
        case "go":
            return ["string", "int", "int64", "float64", "bool", "byte", "rune", "error", "any"]
        case "typescript", "javascript":
            return ["string", "number", "boolean", "object", "symbol", "bigint", "undefined", "null"]
        default:
            return []
        }
    }

    private mutating func emit(from start: String.Index, kind: CodeTokenKind) {
        let length = code.utf16.distance(from: start, to: index)
        guard length > 0 else { return }
        tokens.append(CodeToken(utf16Offset: utf16Cursor, utf16Length: length, kind: kind))
        utf16Cursor += length
    }

    private func peek(_ offset: Int = 0) -> Character? {
        var cursor = index
        var remaining = offset
        while remaining > 0 {
            guard cursor < code.endIndex else { return nil }
            cursor = code.index(after: cursor)
            remaining -= 1
        }
        guard cursor < code.endIndex else { return nil }
        return code[cursor]
    }

    private func starts(with prefix: String) -> Bool {
        code[index...].hasPrefix(prefix)
    }

    private mutating func advance(_ count: Int = 1) {
        var remaining = count
        while remaining > 0, index < code.endIndex {
            index = code.index(after: index)
            remaining -= 1
        }
    }
}

private enum CommentStyle {
    case slash
    case hash
    case html
    case none
}

private extension Lexer {
    static let swiftKeywords: Set<String> = [
        "let", "var", "func", "struct", "class", "enum", "protocol", "extension", "import", "return",
        "if", "else", "switch", "case", "default", "for", "while", "guard", "in", "where", "break",
        "continue", "nil", "true", "false", "self", "Self", "super", "init", "deinit", "subscript",
        "typealias", "associatedtype", "some", "any", "async", "await", "throws", "throw", "try",
        "catch", "do", "as", "is", "public", "private", "internal", "fileprivate", "open", "static",
        "final", "override", "mutating", "nonmutating", "convenience", "required", "lazy", "weak",
        "unowned", "inout", "defer", "fallthrough", "repeat", "indirect"
    ]

    static let pythonKeywords: Set<String> = [
        "def", "class", "return", "if", "elif", "else", "for", "while", "import", "from", "as", "try",
        "except", "finally", "with", "lambda", "yield", "pass", "break", "continue", "and", "or", "not",
        "in", "is", "None", "True", "False", "async", "await", "raise", "global", "nonlocal", "assert", "del"
    ]

    static let javascriptKeywords: Set<String> = [
        "const", "let", "var", "function", "return", "if", "else", "for", "while", "switch", "case",
        "break", "continue", "new", "this", "class", "extends", "super", "import", "export", "from",
        "default", "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "of",
        "in", "null", "undefined", "true", "false", "yield", "static"
    ]

    static let typescriptKeywords: Set<String> = [
        "type", "interface", "implements", "public", "private", "protected", "readonly", "enum",
        "namespace", "declare", "as", "keyof", "infer", "never", "unknown", "any"
    ]

    static let goKeywords: Set<String> = [
        "func", "package", "import", "return", "if", "else", "for", "range", "switch", "case", "default",
        "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "select", "break",
        "continue", "fallthrough", "nil", "true", "false"
    ]

    static let rustKeywords: Set<String> = [
        "fn", "let", "mut", "struct", "enum", "impl", "trait", "pub", "use", "mod", "return", "if", "else",
        "match", "for", "while", "loop", "break", "continue", "where", "in", "as", "async", "await",
        "self", "super", "crate", "move", "ref", "type", "const", "static", "unsafe", "dyn", "true", "false"
    ]

    static let bashKeywords: Set<String> = [
        "if", "then", "else", "fi", "for", "do", "done", "while", "case", "esac", "function", "return",
        "echo", "local", "export", "readonly", "exit", "in", "select", "until", "elif"
    ]

    static let rubyKeywords: Set<String> = [
        "def", "end", "class", "module", "do", "if", "else", "elsif", "unless", "while", "until", "for",
        "return", "yield", "begin", "rescue", "ensure", "case", "when", "then", "and", "or", "not",
        "nil", "true", "false", "self", "super", "require"
    ]

    static let javaKeywords: Set<String> = [
        "class", "interface", "enum", "public", "private", "protected", "static", "final", "void", "return",
        "if", "else", "for", "while", "switch", "case", "break", "continue", "new", "this", "super",
        "import", "package", "try", "catch", "finally", "throw", "throws", "true", "false", "null", "var"
    ]

    static let cssKeywords: Set<String> = [
        "color", "background", "margin", "padding", "display", "flex", "grid", "font", "border", "width",
        "height", "position", "content", "none", "auto", "solid", "relative", "absolute"
    ]
}
