import MDownCore
import SwiftUI

/// Menu bar commands. Format shortcuts follow Notes, so they work the way Mac users already know.
struct MDownCommands: Commands {
    @FocusedValue(\.editorFormatting) private var formatting
    @FocusedValue(\.editorFind) private var find
    @AppStorage(MDownSettings.fontSize) private var fontSize = MDownSettings.defaultFontSize
    @AppStorage(MDownSettings.showWordCount) private var showWordCount = false

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { find?.show() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(find == nil)
            Button("Find Next") { find?.next() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(find?.hasMatches != true)
            Button("Find Previous") { find?.previous() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(find?.hasMatches != true)
        }

        CommandGroup(after: .sidebar) {
            Toggle("Show Word Count", isOn: $showWordCount)
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Actual Size") { fontSize = MDownSettings.defaultFontSize }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(fontSize == MDownSettings.defaultFontSize)
            Button("Zoom In") { fontSize = min(fontSize + 1, MDownSettings.fontSizeRange.upperBound) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(fontSize >= MDownSettings.fontSizeRange.upperBound)
            Button("Zoom Out") { fontSize = max(fontSize - 1, MDownSettings.fontSizeRange.lowerBound) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(fontSize <= MDownSettings.fontSizeRange.lowerBound)
        }

        CommandMenu("Format") {
            formatButton("Title", .heading(1), key: "t", modifiers: [.command, .shift])
            formatButton("Heading", .heading(2), key: "h", modifiers: [.command, .shift])
            formatButton("Subheading", .heading(3), key: "j", modifiers: [.command, .shift])
            formatButton("Body", .paragraph, key: "b", modifiers: [.command, .shift])
            Divider()
            formatButton("Bulleted List", .bullet, key: "7", modifiers: [.command, .shift])
            formatButton("Numbered List", .ordered, key: "9", modifiers: [.command, .shift])
            formatButton("Checklist", .checklist, key: "l", modifiers: [.command, .shift])
            Divider()
            formatButton("Block Quote", .quote, key: "'", modifiers: .command)
            formatButton("Code Block", .codeBlock, key: "m", modifiers: [.command, .shift])
            Divider()
            formatButton("Bold", .bold, key: "b", modifiers: .command)
            formatButton("Italic", .italic, key: "i", modifiers: .command)
            formatButton("Strikethrough", .strikethrough, key: "x", modifiers: [.command, .shift])
            formatButton("Code", .code)
            Divider()
            formatButton("Add Link", .link, key: "k", modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            Button("MDown Guide") {
                Guide.open()
            }
            Link("Markdown Syntax", destination: URL(string: "https://commonmark.org/help/")!)
        }
    }

    private func formatButton(
        _ title: String,
        _ action: MarkdownAction,
        key: KeyEquivalent? = nil,
        modifiers: EventModifiers = .command
    ) -> some View {
        Button(title) { formatting?.apply(action) }
            .keyboardShortcut(key.map { KeyboardShortcut($0, modifiers: modifiers) })
            .disabled(formatting?.isEnabled != true)
    }
}
