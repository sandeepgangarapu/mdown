import AppKit
import MDownCore
import SwiftUI

/// Parses the document once per text change, however often the view body runs (selection
/// changes, scrolling, focus, window activation).
@MainActor
final class ParseCache {
    private var text: String?
    private var blocks: [SourcedBlock] = []

    func blocks(for text: String) -> [SourcedBlock] {
        if let cached = self.text, cached == text {
            return blocks
        }
        blocks = MarkdownRenderModel.sourcedBlocks(from: text)
        self.text = text
        return blocks
    }
}

struct EditorView: View {
    @Binding var document: MarkdownDocument
    var fileURL: URL?

    @AppStorage(MDownSettings.fontSize) private var fontSize = MDownSettings.defaultFontSize
    @AppStorage(MDownSettings.face) private var face: PageFace = MDownSettings.defaultFace
    @AppStorage(MDownSettings.theme) private var theme: PageTheme = .standard
    @AppStorage(MDownSettings.showWordCount) private var showWordCount = false
    @Environment(\.colorScheme) private var colorScheme

    @State private var documentID = UUID()
    @State private var parseCache = ParseCache()
    @State private var prefixCache = ParseCache()
    @State private var suffixCache = ParseCache()
    @State private var tracker = PageTracker()
    @State private var editing: PageEditing?
    @State private var caret = NSRange(location: 0, length: 0)
    @State private var caretRevision = 0
    @State private var scrollRequest: ScrollRequest?
    /// The last text this view wrote, to tell its own edits from undo, redo, and reverts.
    @State private var writtenText: String?
    @State private var findText = ""
    @State private var findPresented = false
    @State private var findIndex: Int?

    private struct ScrollRequest: Equatable {
        var id: PageRowID
        var anchor: UnitPoint?
        var token = UUID()
    }

    var body: some View {
        let style = PageStyle(
            size: CGFloat(min(max(fontSize, MDownSettings.fontSizeRange.lowerBound), MDownSettings.fontSizeRange.upperBound)),
            face: face,
            colors: MDownPalette.colors(theme: theme, scheme: colorScheme)
        )
        let blocks = parseCache.blocks(for: document.text)
        let outline = MarkdownOutline.entries(from: blocks)
        let layout = layout(of: document.text)
        let formatting = self.formatting

        NavigationSplitView {
            Sidebar(
                documentID: documentID,
                outline: outline,
                tracker: tracker,
                editingLocation: editing?.location,
                onSelectHeading: { scroll(toHeading: $0) }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            page(layout: layout, style: style)
                .toolbar(id: "mdown.editor") {
                    FormatToolbar(formatting: formatting, shareURL: fileURL)
                }
                .searchable(text: $findText, isPresented: $findPresented, placement: .toolbar, prompt: "Find")
                .onSubmit(of: .search) { stepFind(forward: true) }
        }
        .navigationSubtitle(subtitle(blocks: blocks))
        .frame(minWidth: 680, minHeight: 420)
        .background {
            WindowReader { window in
                OpenDocuments.shared.register(id: documentID, window: window, fileURL: fileURL)
            }
        }
        .focusedSceneValue(\.editorFormatting, formatting)
        .focusedSceneValue(\.editorFind, EditorFind(
            show: { findPresented = true },
            next: { stepFind(forward: true) },
            previous: { stepFind(forward: false) },
            hasMatches: !findMatches(in: blocks).isEmpty
        ))
        .onChange(of: findText) { _, _ in
            findIndex = nil
        }
        .onChange(of: fileURL) { _, url in
            OpenDocuments.shared.update(id: documentID, fileURL: url)
        }
        .onChange(of: document.text) { old, new in
            documentChanged(from: old, to: new)
        }
        .onAppear {
            if document.text.isEmpty, editing == nil {
                startNewBlock(at: 0)
            }
            #if DEBUG
            openDebugBlockIfRequested()
            #endif
        }
        .onDisappear {
            OpenDocuments.shared.remove(id: documentID)
        }
    }

    // MARK: - Page

    private func page(layout: PageLayout, style: PageStyle) -> some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        MarkdownPage(
                            blocks: layout.before,
                            after: layout.after,
                            style: style,
                            baseDirectory: fileURL?.deletingLastPathComponent(),
                            editing: editing,
                            selection: caret,
                            selectionRevision: caretRevision,
                            actions: pageActions
                        )
                        .environment(\.findTerm, findText)
                        .padding(.horizontal, 48)
                        .padding(.top, 32)
                        .padding(.bottom, 24)

                        // The empty page below the last block: a click there writes a new line.
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { tapBelowPage() }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(editing == nil ? "New line" : "Done editing")
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                    .background {
                        // Clicks in the margins beside the text column set the open block again.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { finishEditing() }
                    }
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onScrollTargetVisibilityChange(idType: PageRowID.self, threshold: 0.01) { ids in
                    tracker.topVisibleLocation = topLocation(of: ids)
                }
                .onChange(of: scrollRequest) { _, request in
                    guard let request else { return }
                    withAnimation(.smooth(duration: 0.3)) {
                        proxy.scrollTo(request.id, anchor: request.anchor)
                    }
                }
            }
        }
        .background(Color(nsColor: style.colors.page))
    }

    private var pageActions: PageActions {
        PageActions(
            edit: { beginEditing($0, caretAt: .end) },
            editAtEnd: { tapBelowPage() },
            finish: { finishEditing() },
            toggleTask: { toggleTask(in: $0, index: $1) },
            editor: InlineEditorActions(
                text: { updateDraft($0) },
                selection: { caret = $0 },
                finish: { finishEditing() },
                navigate: { navigate($0) },
                returnKey: { handleReturn($0) },
                tab: { handleTab($0, outdent: $1) }
            )
        )
    }

    private var formatting: EditorFormatting {
        let editing = self.editing
        let caret = self.caret
        return EditorFormatting(
            isEnabled: editing != nil,
            isActive: { action in
                guard let editing else { return false }
                return MarkdownFormat.isActive(
                    action,
                    in: editing.draft,
                    utf16Location: caret.location,
                    utf16Length: caret.length
                )
            },
            apply: { applyFormat($0) }
        )
    }

    // MARK: - Find

    private var trimmedFindText: String {
        findText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Top-level blocks whose Markdown contains the Find text, in document order.
    private func findMatches(in blocks: [SourcedBlock]) -> [SourcedBlock] {
        let term = trimmedFindText
        guard !term.isEmpty else { return [] }
        let text = document.text
        return blocks.filter {
            $0.source(in: text).range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func stepFind(forward: Bool) {
        let matches = findMatches(in: parseCache.blocks(for: document.text))
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }
        let next: Int
        if let findIndex {
            next = (findIndex + (forward ? 1 : -1) + matches.count) % matches.count
        } else {
            let anchor = editing?.location ?? tracker.topVisibleLocation ?? 0
            next = forward
                ? (matches.firstIndex(where: { $0.utf16Location >= anchor }) ?? 0)
                : (matches.lastIndex(where: { $0.utf16Location < anchor }) ?? matches.count - 1)
        }
        findIndex = next
        finishEditing()
        scrollRequest = ScrollRequest(id: rowID(forLocation: matches[next].utf16Location), anchor: .center)
    }

    private func subtitle(blocks: [SourcedBlock]) -> String {
        if !trimmedFindText.isEmpty {
            let count = findMatches(in: blocks).count
            switch count {
            case 0: return "No matches"
            case 1: return "1 matching block"
            default:
                if let findIndex { return "\(findIndex + 1) of \(count) matching blocks" }
                return "\(count) matching blocks"
            }
        }
        return showWordCount ? DocumentStats.measure(document.text).statusLabel : ""
    }

    // MARK: - Layout

    struct PageLayout {
        var before: [SourcedBlock]
        var after: [SourcedBlock]
    }

    /// Splits the page around the open block. Normally that is just the document's blocks on either
    /// side. When a block crosses the open block's edges (Body applied to a heading that runs into
    /// the next line, a list item typed right under a list, an unclosed code fence), the text on
    /// each side is typeset on its own, so nothing on the page disappears while you edit.
    private func layout(of text: String) -> PageLayout {
        let blocks = parseCache.blocks(for: text)
        guard let editing else { return PageLayout(before: blocks, after: []) }
        let start = editing.location
        let end = editing.end
        let length = MarkdownText.utf16Length(of: text)

        var before = blocks.filter { $0.utf16Location < start && $0.utf16Location + $0.utf16Length <= start }
        var after = blocks.filter { $0.utf16Location >= end && $0.utf16Location + $0.utf16Length > start }

        if blocks.contains(where: { $0.utf16Location < start && $0.utf16Location + $0.utf16Length > start }) {
            let prefix = MarkdownText.substring(text, utf16Location: 0, utf16Length: min(start, length))
            before = prefixCache.blocks(for: prefix)
        }
        if end <= length, blocks.contains(where: { $0.utf16Location < end && $0.utf16Location + $0.utf16Length > end }) {
            let suffix = MarkdownText.substring(text, utf16Location: end, utf16Length: length - end)
            after = suffixCache.blocks(for: suffix).map { block in
                var shifted = block
                shifted.utf16Location += end
                return shifted
            }
        }
        return PageLayout(before: before, after: after)
    }

    /// The block to open at `location` in `text`: the one starting there, else the one containing it.
    private func block(at location: Int, in text: String) -> SourcedBlock? {
        let blocks = parseCache.blocks(for: text)
        if let exact = blocks.first(where: { $0.utf16Location == location }) {
            return exact
        }
        if let containing = blocks.first(where: { $0.utf16Location <= location && location < $0.utf16Location + $0.utf16Length }) {
            return containing
        }
        return blocks.first(where: { $0.utf16Location >= location })
    }

    // MARK: - Editing session

    private func write(_ text: String) {
        writtenText = text
        if text != document.text {
            document.text = text
        }
    }

    private func setCaret(_ location: Int, length: Int = 0) {
        caret = NSRange(location: location, length: length)
        caretRevision += 1
    }

    private func beginEditing(_ block: SourcedBlock, caretAt placement: CaretPlacement) {
        var target = block
        var text = document.text
        if let current = editing {
            if !current.pending, current.location == block.utf16Location { return }
            let currentEnd = current.end
            let closed = closeEditing()
            text = closed.text
            if closed.delta != 0, block.utf16Location >= currentEnd {
                guard let resolved = self.block(at: block.utf16Location + closed.delta, in: text) else { return }
                target = resolved
            }
        }
        let source = target.source(in: text)
        editing = PageEditing(location: target.utf16Location, draft: source)
        setCaret(EditingText.caret(in: source, placement: placement))
    }

    private func startNewBlock(at location: Int) {
        editing = PageEditing(location: location, draft: "", pending: true)
        setCaret(0)
    }

    /// Ends editing. A block left blank is removed along with the blank lines around it.
    @discardableResult
    private func closeEditing() -> (text: String, delta: Int) {
        let text = document.text
        guard let current = editing else { return (text, 0) }
        editing = nil
        guard !current.pending, EditingText.isBlank(current.draft) else { return (text, 0) }
        let removal = EditingText.removeBlankBlock(in: text, at: current.location, length: current.draftLength)
        write(removal.text)
        return (removal.text, removal.delta)
    }

    private func finishEditing() {
        guard editing != nil else { return }
        closeEditing()
    }

    private func tapBelowPage() {
        if editing != nil {
            finishEditing()
        } else {
            startNewBlock(at: MarkdownText.utf16Length(of: document.text))
            scrollRequest = ScrollRequest(id: .editor, anchor: nil)
        }
    }

    private func updateDraft(_ newValue: String) {
        guard var current = editing else { return }
        if current.pending {
            current.draft = newValue
            if !newValue.isEmpty {
                let insertion = EditingText.insertBlock(newValue, into: document.text, at: current.location)
                current.location = insertion.location
                current.pending = false
                editing = current
                write(insertion.text)
            } else {
                editing = current
            }
            return
        }
        let updated = MarkdownText.replace(
            document.text,
            utf16Location: current.location,
            utf16Length: current.draftLength,
            with: newValue
        )
        current.draft = newValue
        editing = current
        write(updated)
    }

    private func applyFormat(_ action: MarkdownAction) {
        guard let current = editing else { return }
        let result = MarkdownFormat.apply(
            action,
            to: current.draft,
            utf16Location: caret.location,
            utf16Length: caret.length
        )
        updateDraft(result.text)
        setCaret(result.utf16Location, length: result.utf16Length)
    }

    private func handleReturn(_ selection: NSRange) -> Bool {
        guard let current = editing else { return false }
        if EditingText.isBlank(current.draft) { return true }
        switch BlockKeyRules.returnKey(in: current.draft, selection: selection) {
        case .none:
            return false
        case let .replace(text, caret):
            updateDraft(text)
            setCaret(caret)
            return true
        case let .split(before, after):
            split(before: before, after: after)
            return true
        }
    }

    /// Return in the middle or at the end of a block: the text before the caret stays, and the
    /// rest becomes a new block below with the caret at its start.
    private func split(before: String, after: String) {
        guard editing != nil else { return }
        if before.isEmpty {
            updateDraft(after)
            setCaret(0)
            return
        }
        updateDraft(before)
        guard let committed = editing, !committed.pending else { return }
        if after.isEmpty {
            editing = PageEditing(location: committed.end, draft: "", pending: true)
        } else {
            let insertion = EditingText.insertBlock(after, into: document.text, at: committed.end)
            editing = PageEditing(location: insertion.location, draft: after)
            write(insertion.text)
        }
        setCaret(0)
        scrollRequest = ScrollRequest(id: .editor, anchor: nil)
    }

    private func handleTab(_ selection: NSRange, outdent: Bool) -> Bool {
        guard let current = editing,
              let result = BlockKeyRules.tab(in: current.draft, selection: selection, outdent: outdent) else {
            return false
        }
        updateDraft(result.text)
        setCaret(result.selection.location, length: result.selection.length)
        return true
    }

    /// Arrow keys past the first or last line move to the neighboring block, so the page reads as
    /// one continuous document.
    private func navigate(_ direction: BlockNavigation) -> Bool {
        guard let current = editing else { return false }
        let layout = layout(of: document.text)
        switch direction {
        case .up, .left, .deleteBackward:
            if direction == .deleteBackward, !EditingText.isBlank(current.draft) { return false }
            guard let previous = layout.before.last else { return false }
            closeEditing()
            beginEditing(previous, caretAt: .end)
        case .down, .right:
            if let next = layout.after.first {
                let closed = closeEditing()
                guard let resolved = block(at: next.utf16Location + closed.delta, in: closed.text) else { return true }
                beginEditing(resolved, caretAt: .start)
            } else {
                guard direction == .down, !current.pending, !EditingText.isBlank(current.draft) else { return false }
                closeEditing()
                startNewBlock(at: MarkdownText.utf16Length(of: document.text))
            }
        }
        scrollRequest = ScrollRequest(id: .editor, anchor: nil)
        return true
    }

    private func toggleTask(in block: SourcedBlock, index: Int) {
        let text = document.text
        let source = block.source(in: text)
        guard let toggled = MarkdownTasks.toggle(taskAt: index, in: source),
              MarkdownText.utf16Length(of: toggled) == block.utf16Length else { return }
        write(MarkdownText.replace(text, utf16Location: block.utf16Location, utf16Length: block.utf16Length, with: toggled))
    }

    /// The document changed without going through this view: undo, redo, Revert To, or the file
    /// changing on disk. Keep the open block anchored, or close it if it can't be found.
    private func documentChanged(from old: String, to new: String) {
        guard new != writtenText else { return }
        writtenText = new
        guard let current = editing else { return }
        if let rebased = EditingText.rebase(current, from: old, to: new) {
            if rebased != current {
                editing = rebased
            }
        } else {
            editing = nil
        }
    }

    #if DEBUG
    /// `-MDownDebugEditBlock <index>` opens that top-level block for editing on launch, so the
    /// editing state can be inspected without driving the mouse.
    private func openDebugBlockIfRequested() {
        if UserDefaults.standard.string(forKey: "MDownDebugAppearance") == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        if let path = UserDefaults.standard.string(forKey: "MDownDebugDumpMenu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                func dump(_ menu: NSMenu, depth: Int) -> [String] {
                    menu.items.flatMap { item -> [String] in
                        let key = item.keyEquivalent.isEmpty ? "" : "  [\(item.keyEquivalentModifierMask.rawValue)+\(item.keyEquivalent)]"
                        let line = String(repeating: "  ", count: depth) + (item.isSeparatorItem ? "---" : item.title) + key
                        return [line] + (item.submenu.map { dump($0, depth: depth + 1) } ?? [])
                    }
                }
                let lines = NSApp.mainMenu.map { dump($0, depth: 0) } ?? []
                try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        if let term = UserDefaults.standard.string(forKey: "MDownDebugFind") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { findPresented = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { findText = term }
        }
        guard let raw = UserDefaults.standard.string(forKey: "MDownDebugEditBlock"), let index = Int(raw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let blocks = parseCache.blocks(for: document.text)
            guard blocks.indices.contains(index) else { return }
            beginEditing(blocks[index], caretAt: .end)
        }
    }
    #endif

    // MARK: - Scrolling

    private func rowID(forLocation location: Int) -> PageRowID {
        guard let editing, location >= editing.location else { return .block(location) }
        if !editing.pending, location < editing.end {
            return .editor
        }
        return .after(location - editing.end)
    }

    private func scroll(toHeading entry: OutlineEntry) {
        scrollRequest = ScrollRequest(id: rowID(forLocation: entry.utf16Location), anchor: .top)
    }

    private func topLocation(of ids: [PageRowID]) -> Int? {
        ids.map { id -> Int in
            switch id {
            case let .block(location): location
            case let .after(offset): (editing?.end ?? 0) + offset
            case .editor: editing?.location ?? 0
            }
        }.min()
    }
}
