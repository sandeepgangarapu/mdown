import AppKit
import MDownCore
import SwiftUI

/// What the Changes tab can do. Changes are indexes into the presentation's `changes`.
struct ReviewActions {
    var select: (Int) -> Void
    var accept: ([Int]) -> Void
    var reject: ([Int]) -> Void
}

/// The Changes tab: the document as it is now, with every change another app made marked where it
/// happened. Removed text is struck through in red and added text sits on a green tint. Click a
/// change to select it; the block it's in shows buttons for it and for the whole block.
struct ChangesPage: View {
    var presentation: ReviewPresentation
    var style: PageStyle
    var baseDirectory: URL?
    var selected: Int?
    var actions: ReviewActions

    var body: some View {
        let marks = ReviewMarkStyle(added: style.colors.added, removed: style.colors.removed, selected: selected)
        let selectedRow = selected.flatMap(presentation.row(of:))
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(Array(presentation.rows.enumerated()), id: \.element.id) { index, row in
                rowView(row, isFirst: index == 0, marks: marks, isSelectedRow: index == selectedRow)
                    .id(row.id)
            }
        }
        .frame(maxWidth: style.measure, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .environment(\.openURL, OpenURLAction { url in
            if let change = ReviewMarkStyle.change(from: url), presentation.changes.indices.contains(change) {
                actions.select(change)
                return .handled
            }
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto":
                return .systemAction
            default:
                return .discarded
            }
        })
    }

    @ViewBuilder
    private func rowView(_ row: ReviewPresentation.Row, isFirst: Bool, marks: ReviewMarkStyle, isSelectedRow: Bool) -> some View {
        switch row.content {
        case let .unchanged(block):
            BlockView(block: block.block, style: style, baseDirectory: baseDirectory, isFirst: isFirst, path: [])
        case let .typeset(blocks):
            changedRow(row, isSelected: isSelectedRow) {
                VStack(alignment: .leading, spacing: style.blockSpacing) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        BlockView(block: block.block, style: style, baseDirectory: baseDirectory, isFirst: isFirst && index == 0, path: [])
                    }
                }
                .environment(\.reviewMarks, marks)
            }
        case let .source(text):
            changedRow(row, isSelected: isSelectedRow) {
                MarkedSource(text: text, style: style, marks: marks)
                    .padding(.top, isFirst ? 0 : 4)
            }
        }
    }

    private func changedRow(_ row: ReviewPresentation.Row, isSelected: Bool, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color(nsColor: isSelected ? style.colors.accent : style.colors.tertiary))
                        .frame(width: 3)
                        .padding(.vertical, 2)
                        .offset(x: -20)
                        .accessibilityHidden(true)
                }
            if isSelected, let selected, row.changes.contains(selected) {
                RowActions(row: row, selected: selected, actions: actions)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.changes.count == 1 ? "Changed block" : "Changed block, \(row.changes.count) changes")
    }
}

/// Buttons under the block holding the selected change.
private struct RowActions: View {
    var row: ReviewPresentation.Row
    var selected: Int
    var actions: ReviewActions

    var body: some View {
        HStack(spacing: 8) {
            Button {
                actions.accept([selected])
            } label: {
                Label("Accept", systemImage: "checkmark")
            }
            .help("Keep this change")
            Button {
                actions.reject([selected])
            } label: {
                Label("Reject", systemImage: "xmark")
            }
            .help("Put back the text this change replaced")
            if row.changes.count > 1 {
                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 4)
                Button("Accept Block") { actions.accept(row.changes) }
                    .help("Keep all \(row.changes.count) changes in this block")
                Button("Reject Block") { actions.reject(row.changes) }
                    .help("Put back the text of all \(row.changes.count) changes in this block")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }
}

/// A changed block shown as its Markdown, for changes the typeset page can't show (a table cell,
/// code, a link's address, a heading that changed level).
struct MarkedSource: View {
    var text: String
    var style: PageStyle
    var marks: ReviewMarkStyle

    var body: some View {
        Text(attributed)
            .lineSpacing(style.lineSpacing * 0.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: style.colors.fill))
                    .padding(.horizontal, -10)
                    .padding(.vertical, -6)
            }
    }

    private var attributed: AttributedString {
        var open: ReviewMark.Mark?
        var result = AttributedString()
        for piece in ReviewMark.pieces(in: text, state: &open) {
            var run = AttributedString(piece.text)
            run.font = .system(size: style.codeSize, design: .monospaced)
            run.foregroundColor = Color(nsColor: style.colors.ink)
            if let mark = piece.mark {
                run.mergeAttributes(marks.attributes(for: mark))
            }
            result += run
        }
        return result
    }
}

/// The floating bar on the Changes tab: step through changes, or decide all of them at once.
struct ReviewBar: View {
    var count: Int
    var selected: Int?
    var step: (Int) -> Void
    var acceptAll: () -> Void
    var rejectAll: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                step(-1)
            } label: {
                Label("Previous Change", systemImage: "chevron.up")
            }
            .help("Previous change (⇧Tab)")
            Text(position)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 64)
            Button {
                step(1)
            } label: {
                Label("Next Change", systemImage: "chevron.down")
            }
            .help("Next change (Tab)")
            Divider()
                .frame(height: 18)
            Button("Accept All", action: acceptAll)
                .help("Keep every change")
            Button("Reject All", action: rejectAll)
                .help("Put back the text of every change")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: Capsule())
    }

    private var position: String {
        guard let selected else { return count == 1 ? "1 change" : "\(count) changes" }
        return "\(selected + 1) of \(count)"
    }
}
