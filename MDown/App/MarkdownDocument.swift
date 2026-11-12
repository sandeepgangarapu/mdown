import MDownCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var markdown: UTType {
        UTType("net.daringfireball.markdown") ?? .plainText
    }
}

struct MarkdownDocument: FileDocument {
    var text: String
    /// New each time the text is read from disk, so the editor can tell a reload (another app,
    /// such as an AI tool, changed the file) from undo and redo, which keep the same value.
    var loadID = UUID()

    init(text: String = "") {
        self.text = text
    }

    static var readableContentTypes: [UTType] {
        [.markdown, .plainText]
    }

    static var writableContentTypes: [UTType] {
        [.markdown, .plainText]
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let string = String(data: data, encoding: .utf8) {
            text = Self.droppingByteOrderMark(string)
            return
        }
        // Only trust UTF-16 when the file says so. Without a byte order mark almost any byte
        // sequence decodes as UTF-16, which would turn a Latin-1 "café" into CJK characters.
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let string = String(data: data, encoding: .utf16) {
            text = Self.droppingByteOrderMark(string)
            return
        }
        if let string = String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) {
            text = string
            return
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    private static func droppingByteOrderMark(_ string: String) -> String {
        string.hasPrefix("\u{FEFF}") ? String(string.dropFirst()) : string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
