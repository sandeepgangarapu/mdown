import MDownCore
import SwiftUI

/// What the toolbar and the Format menu act on: the open block and its selection.
struct EditorFormatting {
    var isEnabled: Bool
    var isActive: (MarkdownAction) -> Bool
    var apply: (MarkdownAction) -> Void
}

struct EditorFormattingKey: FocusedValueKey {
    typealias Value = EditorFormatting
}

extension FocusedValues {
    var editorFormatting: EditorFormatting? {
        get { self[EditorFormattingKey.self] }
        set { self[EditorFormattingKey.self] = newValue }
    }
}

/// Find actions for the frontmost document, for the Edit > Find menu.
struct EditorFind {
    var show: () -> Void
    var next: () -> Void
    var previous: () -> Void
    var hasMatches: Bool
}

struct EditorFindKey: FocusedValueKey {
    typealias Value = EditorFind
}

extension FocusedValues {
    var editorFind: EditorFind? {
        get { self[EditorFindKey.self] }
        set { self[EditorFindKey.self] = newValue }
    }
}

/// Paragraph styles, named the way Notes names them.
enum ParagraphStyle: CaseIterable, Identifiable {
    case title
    case heading
    case subheading
    case body
    case quote
    case codeBlock

    var id: Self { self }

    var title: String {
        switch self {
        case .title: "Title"
        case .heading: "Heading"
        case .subheading: "Subheading"
        case .body: "Body"
        case .quote: "Block Quote"
        case .codeBlock: "Code Block"
        }
    }

    var action: MarkdownAction {
        switch self {
        case .title: .heading(1)
        case .heading: .heading(2)
        case .subheading: .heading(3)
        case .body: .paragraph
        case .quote: .quote
        case .codeBlock: .codeBlock
        }
    }
}

/// Formatting controls in the window toolbar: a text style menu, inline styles, list styles, and
/// links. They act on the open block and dim when no block is open.
struct FormatToolbar: CustomizableToolbarContent {
    var formatting: EditorFormatting
    var shareURL: URL?

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "textStyle") {
            Menu {
                ForEach(ParagraphStyle.allCases) { style in
                    if style == .quote {
                        Divider()
                    }
                    Toggle(style.title, isOn: binding(for: style.action))
                }
            } label: {
                Label("Text Style", systemImage: "textformat")
            }
            .menuIndicator(.hidden)
            .help("Text Style")
            .disabled(!formatting.isEnabled)
        }

        ToolbarSpacer(.fixed)

        ToolbarItem(id: "bold") { toggle("Bold", systemImage: "bold", action: .bold) }
        ToolbarItem(id: "italic") { toggle("Italic", systemImage: "italic", action: .italic) }
        ToolbarItem(id: "strikethrough") { toggle("Strikethrough", systemImage: "strikethrough", action: .strikethrough) }
        ToolbarItem(id: "code") { toggle("Code", systemImage: "chevron.left.forwardslash.chevron.right", action: .code) }

        ToolbarSpacer(.fixed)

        ToolbarItem(id: "bulletedList") { toggle("Bulleted List", systemImage: "list.bullet", action: .bullet) }
        ToolbarItem(id: "numberedList") { toggle("Numbered List", systemImage: "list.number", action: .ordered) }
        ToolbarItem(id: "checklist") { toggle("Checklist", systemImage: "checklist", action: .checklist) }

        ToolbarSpacer(.fixed)

        ToolbarItem(id: "link") {
            Button {
                formatting.apply(.link)
            } label: {
                Label("Link", systemImage: "link")
            }
            .help("Add Link")
            .disabled(!formatting.isEnabled)
        }

        ToolbarSpacer(.fixed)

        ToolbarItem(id: "share") {
            if let shareURL {
                ShareLink(item: shareURL)
                    .help("Share")
            } else {
                Button {} label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(true)
                .help("Save the document to share it")
            }
        }
    }

    private func binding(for action: MarkdownAction) -> Binding<Bool> {
        Binding(
            get: { formatting.isEnabled && formatting.isActive(action) },
            set: { _ in formatting.apply(action) }
        )
    }

    private func toggle(_ title: String, systemImage: String, action: MarkdownAction) -> some View {
        Toggle(isOn: binding(for: action)) {
            Label(title, systemImage: systemImage)
        }
        .help(title)
        .disabled(!formatting.isEnabled)
    }
}
