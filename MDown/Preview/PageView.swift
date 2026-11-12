import AppKit
import MDownCore
import SwiftUI

/// Callbacks from the page back to the editing session. A page without actions is read only.
struct PageActions {
    var edit: (SourcedBlock) -> Void
    var editAtEnd: () -> Void
    var finish: () -> Void
    var toggleTask: (SourcedBlock, Int) -> Void
    var editor: InlineEditorActions
}

/// Stable identity for each row of the page. Blocks after the open block are keyed relative to its
/// end, so typing does not give every following block a new identity on each keystroke.
enum PageRowID: Hashable {
    case block(Int)
    case after(Int)
    case editor
}

/// The typeset page. Every top-level block renders as typeset text; the open block, if any, is
/// replaced by its Markdown source. `blocks` are the blocks above the open block (all of them when
/// nothing is open) and `after` the blocks below it.
struct MarkdownPage: View {
    var blocks: [SourcedBlock]
    var after: [SourcedBlock] = []
    var style: PageStyle
    var baseDirectory: URL?
    var editing: PageEditing? = nil
    var selection = NSRange(location: 0, length: 0)
    var selectionRevision = 0
    var actions: PageActions? = nil

    private struct Row: Identifiable {
        var id: PageRowID
        var block: SourcedBlock
        var isFirst: Bool
    }

    var body: some View {
        let origin = editing?.end ?? 0
        let beforeRows = blocks.enumerated().map { index, block in
            Row(id: .block(block.utf16Location), block: block, isFirst: index == 0)
        }
        // Keyed relative to the end of the open block, so typing does not change their identity.
        let afterRows = after.map { block in
            Row(id: .after(block.utf16Location - origin), block: block, isFirst: false)
        }
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            if blocks.isEmpty && after.isEmpty && editing == nil {
                Text(actions == nil ? "Empty" : "Start writing")
                    .font(style.font())
                    .foregroundStyle(Color(nsColor: style.colors.tertiary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { actions?.editAtEnd() }
                    .pointerStyle(actions == nil ? nil : .horizontalText)
            }
            ForEach(beforeRows) { row in
                self.row(row.block, isFirst: row.isFirst)
                    .id(row.id)
            }
            if let editing, let actions {
                InlineBlockEditor(
                    text: editing.draft,
                    style: style,
                    selection: selection,
                    selectionRevision: selectionRevision,
                    topPadding: editorTopPadding(editing.draft, isFirst: blocks.isEmpty),
                    actions: actions.editor
                )
                .id(PageRowID.editor)
            }
            ForEach(afterRows) { row in
                self.row(row.block, isFirst: false)
                    .id(row.id)
            }
        }
        .scrollTargetLayout()
        .frame(maxWidth: style.measure, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .environment(\.openURL, OpenURLAction { url in
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto":
                return .systemAction
            default:
                return .discarded
            }
        })
    }

    /// Keeps a heading at the same height when it opens for editing.
    private func editorTopPadding(_ draft: String, isFirst: Bool) -> CGFloat {
        guard !isFirst else { return 0 }
        let hashes = draft.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), draft.dropFirst(hashes).first.map({ $0 == " " || $0 == "\t" }) ?? true else {
            return 0
        }
        return style.headingTopPadding(hashes)
    }

    private func row(_ block: SourcedBlock, isFirst: Bool) -> some View {
        BlockView(block: block.block, style: style, baseDirectory: baseDirectory, isFirst: isFirst, path: [])
            .environment(\.taskContext, taskContext(for: block))
            .contentShape(Rectangle())
            .onTapGesture { actions?.edit(block) }
            .pointerStyle(actions == nil ? nil : .horizontalText)
            .accessibilityAction(named: "Edit") { actions?.edit(block) }
    }

    private func taskContext(for block: SourcedBlock) -> TaskContext? {
        guard let actions else { return nil }
        let indices = TaskContext.indices(in: block.block)
        guard !indices.isEmpty else { return nil }
        return TaskContext(indices: indices) { index in
            actions.toggleTask(block, index)
        }
    }
}

// MARK: - Task checkboxes

/// Maps each task item in a block (by its position in the block tree) to its index in document
/// order, which is the order `MarkdownTasks` counts in.
struct TaskContext {
    var indices: [[Int]: Int]
    var toggle: (Int) -> Void

    static func indices(in block: BlockNode) -> [[Int]: Int] {
        var result: [[Int]: Int] = [:]
        var counter = 0
        func visit(_ block: BlockNode, path: [Int]) {
            switch block {
            case let .quote(children):
                for (index, child) in children.enumerated() {
                    visit(child, path: path + [index])
                }
            case let .bulletList(items), let .orderedList(_, items):
                for (itemIndex, item) in items.enumerated() {
                    let itemPath = path + [itemIndex]
                    if item.check != nil {
                        result[itemPath] = counter
                        counter += 1
                    }
                    for (childIndex, child) in item.children.enumerated() {
                        visit(child, path: itemPath + [childIndex])
                    }
                }
            default:
                break
            }
        }
        visit(block, path: [])
        return result
    }
}

private struct TaskContextKey: EnvironmentKey {
    static let defaultValue: TaskContext? = nil
}

extension EnvironmentValues {
    var taskContext: TaskContext? {
        get { self[TaskContextKey.self] }
        set { self[TaskContextKey.self] = newValue }
    }
}

// MARK: - Blocks

private struct BlockList: View {
    var blocks: [BlockNode]
    var style: PageStyle
    var baseDirectory: URL?
    var path: [Int]
    var spacing: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                BlockView(
                    block: block,
                    style: style,
                    baseDirectory: baseDirectory,
                    isFirst: index == 0,
                    path: path + [index]
                )
            }
        }
    }
}

struct BlockView: View {
    var block: BlockNode
    var style: PageStyle
    var baseDirectory: URL?
    var isFirst: Bool
    var path: [Int]

    @Environment(\.taskContext) private var taskContext

    var body: some View {
        switch block {
        case let .paragraph(nodes):
            ParagraphView(nodes: nodes, style: style, baseDirectory: baseDirectory)
        case let .heading(level, inlines):
            RichText(
                nodes: inlines,
                style: InlineStyle(style: style, size: style.headingSize(level), weight: style.headingWeight(level)),
                lineSpacing: style.lineSpacing * 0.6
            )
            .padding(.top, isFirst ? 0 : style.headingTopPadding(level))
            .accessibilityAddTraits(.isHeader)
        case let .quote(children):
            HStack(alignment: .top, spacing: 14) {
                Capsule()
                    .fill(Color(nsColor: style.colors.tertiary))
                    .frame(width: 3)
                BlockList(
                    blocks: children,
                    style: style,
                    baseDirectory: baseDirectory,
                    path: path,
                    spacing: style.blockSpacing
                )
                .foregroundStyle(Color(nsColor: style.colors.secondary))
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .code(language, source):
            CodeBlockView(language: language, source: source, colors: style.colors, size: style.codeSize)
        case let .bulletList(items):
            itemList(items, orderedStart: nil)
        case let .orderedList(start, items):
            itemList(items, orderedStart: start)
        case .rule:
            Rectangle()
                .fill(Color(nsColor: style.colors.rule))
                .frame(height: 1)
                .padding(.vertical, style.size * 0.5)
                .accessibilityLabel("Divider")
        case let .table(alignments, header, rows):
            MarkdownTable(alignments: alignments, header: header, rows: rows, style: style)
        case let .figure(source, title, alt):
            MarkdownImage(source: source, title: title, alt: alt, link: nil, baseDirectory: baseDirectory, colors: style.colors)
        case let .html(raw):
            Text(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: style.codeSize, design: .monospaced))
                .foregroundStyle(Color(nsColor: style.colors.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: style.colors.codeBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func itemList(_ items: [ListItemNode], orderedStart: Int?) -> some View {
        let lastNumber = (orderedStart ?? 1) + max(items.count - 1, 0)
        let numberWidth = CGFloat("\(lastNumber).".count) * style.size * 0.56
        return VStack(alignment: .leading, spacing: style.size * 0.35) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let itemPath = path + [index]
                HStack(alignment: .firstTextBaseline, spacing: style.size * 0.45) {
                    marker(for: item, path: itemPath, number: orderedStart.map { $0 + index }, numberWidth: numberWidth)
                    BlockList(
                        blocks: item.children,
                        style: style,
                        baseDirectory: baseDirectory,
                        path: itemPath,
                        spacing: style.size * 0.35
                    )
                    .opacity(item.check == .checked ? 0.55 : 1)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for item: ListItemNode, path: [Int], number: Int?, numberWidth: CGFloat) -> some View {
        if let check = item.check {
            let checked = check == .checked
            let toggle = taskContext.flatMap { context in context.indices[path].map { index in { context.toggle(index) } } }
            Button {
                toggle?()
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: style.size * 0.95, weight: .regular))
                    .foregroundStyle(checked ? Color(nsColor: style.colors.accent) : Color(nsColor: style.colors.tertiary))
                    .frame(width: style.size * 1.2, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(toggle == nil)
            .pointerStyle(toggle == nil ? nil : .link)
            .accessibilityLabel(checked ? "Completed" : "Not completed")
            .accessibilityAddTraits(.isToggle)
        } else if let number {
            Text("\(number).")
                .font(style.font())
                .monospacedDigit()
                .foregroundStyle(Color(nsColor: style.colors.secondary))
                .frame(minWidth: numberWidth, alignment: .trailing)
        } else {
            Text("•")
                .font(style.font(weight: .bold))
                .foregroundStyle(Color(nsColor: style.colors.secondary))
                .frame(width: style.size * 0.9, alignment: .center)
        }
    }
}

private enum ParagraphSegment {
    case text([InlineNode])
    case image(source: String, title: String?, alt: String, link: URL?)
}

private struct ParagraphView: View {
    var nodes: [InlineNode]
    var style: PageStyle
    var baseDirectory: URL?

    var body: some View {
        let segments = segments(from: nodes)
        if segments.count == 1, case let .text(textNodes) = segments[0] {
            RichText(nodes: textNodes, style: InlineStyle(style: style), lineSpacing: style.lineSpacing)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case let .text(textNodes):
                        RichText(nodes: textNodes, style: InlineStyle(style: style), lineSpacing: style.lineSpacing)
                    case let .image(source, title, alt, link):
                        MarkdownImage(
                            source: source,
                            title: title,
                            alt: alt,
                            link: link,
                            baseDirectory: baseDirectory,
                            colors: style.colors
                        )
                    }
                }
            }
        }
    }

    private func segments(from nodes: [InlineNode]) -> [ParagraphSegment] {
        var result: [ParagraphSegment] = []
        var buffer: [InlineNode] = []
        func flush() {
            if !buffer.isEmpty {
                result.append(.text(buffer))
                buffer.removeAll()
            }
        }
        for node in nodes {
            if case let .image(source, title, alt) = node, let source, !source.isEmpty {
                flush()
                result.append(.image(source: source, title: title, alt: InlinePlainText.string(from: alt), link: nil))
            } else if case let .link(destination, _, children) = node,
                      children.count == 1,
                      case let .image(source, title, alt) = children[0],
                      let source, !source.isEmpty {
                flush()
                result.append(.image(
                    source: source,
                    title: title,
                    alt: InlinePlainText.string(from: alt),
                    link: safeLink(destination)
                ))
            } else {
                buffer.append(node)
            }
        }
        flush()
        return result
    }
}

private struct CodeBlockView: View {
    var language: String?
    var source: String
    var colors: MDownPalette.Colors
    var size: CGFloat

    @State private var hovering = false
    @State private var copied = false
    @Environment(\.findTerm) private var findTerm

    private var displayCode: String {
        source.hasSuffix("\n") ? String(source.dropLast()) : source
    }

    var body: some View {
        ScrollView(.horizontal) {
            Text(highlightingMatches(of: findTerm, in: highlightedCode(displayCode, language: language, colors: colors, size: size)))
                .lineSpacing(size * 0.3)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: colors.codeBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Group {
                if hovering || copied {
                    Button(action: copy) {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 26, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy Code")
                    .transition(.opacity)
                } else if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(nsColor: colors.tertiary))
                        .padding(.vertical, 4)
                }
            }
            .padding(6)
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayCode, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}

private struct MarkdownTable: View {
    var alignments: [ColumnAlign]
    var header: [TableCellNode]
    var rows: [[TableCellNode]]
    var style: PageStyle

    var body: some View {
        let cellStyle = InlineStyle(style: style, size: (style.size * 0.9).rounded())
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            if !header.isEmpty {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                        tableCell(cell, index: index, style: headerStyle(cellStyle))
                    }
                }
                .background(Color(nsColor: style.colors.fill))
                separator
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                        tableCell(cell, index: index, style: cellStyle)
                    }
                }
                if rowIndex < rows.count - 1 {
                    separator
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: style.colors.rule), lineWidth: 1)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(nsColor: style.colors.rule))
            .frame(height: 1)
            .gridCellUnsizedAxes(.horizontal)
    }

    private func tableCell(_ cell: TableCellNode, index: Int, style cellStyle: InlineStyle) -> some View {
        RichText(nodes: cell.inlines, style: cellStyle, lineSpacing: style.lineSpacing * 0.5, alignment: textAlignment(at: index))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: frameAlignment(at: index))
            .gridCellColumns(max(cell.colspan, 1))
    }

    private func headerStyle(_ base: InlineStyle) -> InlineStyle {
        var next = base
        next.weight = .semibold
        return next
    }

    private func align(at index: Int) -> ColumnAlign {
        index < alignments.count ? alignments[index] : .leading
    }

    private func textAlignment(at index: Int) -> TextAlignment {
        switch align(at: index) {
        case .center: .center
        case .trailing: .trailing
        case .leading: .leading
        }
    }

    private func frameAlignment(at index: Int) -> Alignment {
        switch align(at: index) {
        case .center: .center
        case .trailing: .trailing
        case .leading: .leading
        }
    }
}

/// Decoded local images, so typing elsewhere on the page does not re-read files from disk.
@MainActor
private enum ImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(at url: URL) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.absoluteString)|\(modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func image(data: Data) -> NSImage? {
        let key = "data:\(data.count):\(data.hashValue)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

private struct MarkdownImage: View {
    var source: String
    var title: String?
    var alt: String
    var link: URL?
    var baseDirectory: URL?
    var colors: MDownPalette.Colors

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            image
                .accessibilityLabel(alt.isEmpty ? "Image" : alt)
            if let title, !title.isEmpty {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: colors.secondary))
            }
        }
        .help(alt)
        .onTapGesture {
            if let link {
                NSWorkspace.shared.open(link)
            }
        }
        .pointerStyle(link == nil ? nil : .link)
    }

    @ViewBuilder
    private var image: some View {
        switch ImageLocator.resolve(source: source, relativeTo: baseDirectory) {
        case let .remote(url):
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    framed(image)
                case .failure:
                    missing(caption: alt.isEmpty ? url.absoluteString : alt)
                default:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
        case let .file(url):
            if let nsImage = ImageCache.image(at: url) {
                framed(Image(nsImage: nsImage))
            } else {
                missing(caption: url.lastPathComponent)
            }
        case let .data(data):
            if let nsImage = ImageCache.image(data: data) {
                framed(Image(nsImage: nsImage))
            } else {
                missing(caption: alt.isEmpty ? "Image" : alt)
            }
        case let .bundle(name):
            if let nsImage = NSImage(named: name) {
                framed(Image(nsImage: nsImage))
            } else {
                missing(caption: alt.isEmpty ? name : alt)
            }
        case let .unresolved(raw):
            missing(caption: raw)
        }
    }

    private func framed(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 460, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func missing(caption: String) -> some View {
        Label(caption, systemImage: "photo")
            .lineLimit(2)
            .font(.callout)
            .foregroundStyle(Color(nsColor: colors.secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(nsColor: colors.codeBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

#Preview("Guide") {
    ScrollView {
        MarkdownPage(
            blocks: MarkdownRenderModel.sourcedBlocks(from: WelcomeMarkdown.text),
            style: PageStyle(size: 17, face: MDownSettings.defaultFace, colors: MDownPalette.colors(theme: MDownSettings.defaultTheme, scheme: .light)),
            baseDirectory: nil
        )
        .padding(40)
    }
    .frame(width: 860, height: 900)
}
