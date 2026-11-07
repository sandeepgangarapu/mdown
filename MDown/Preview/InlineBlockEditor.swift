import AppKit
import MDownCore
import SwiftUI

enum BlockNavigation {
    case up
    case down
    case left
    case right
    case deleteBackward
}

struct InlineEditorActions {
    var text: (String) -> Void
    var selection: (NSRange) -> Void
    var finish: () -> Void
    /// Returns true when the page moved to another block.
    var navigate: (BlockNavigation) -> Bool
    /// Returns true when the session handled Return.
    var returnKey: (NSRange) -> Bool
    /// Returns true when the session handled Tab (`false`) or Shift-Tab (`true`).
    var tab: (NSRange, Bool) -> Bool
}

/// The Markdown source of one block, edited in place of its typeset form. It is set in the page's
/// own typeface and sizes, with the Markdown syntax dimmed, so opening a block barely moves it.
struct InlineBlockEditor: View {
    var text: String
    var style: PageStyle
    var selection: NSRange
    var selectionRevision: Int
    var topPadding: CGFloat
    var actions: InlineEditorActions

    @State private var height: CGFloat = 0

    var body: some View {
        InlineTextRepresentable(
            text: text,
            style: style,
            selection: selection,
            selectionRevision: selectionRevision,
            actions: actions,
            onHeight: { next in
                if abs(next - height) > 0.5 {
                    height = next
                }
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: max(height, minimumHeight))
        .overlay(alignment: .topLeading) {
            if text.isEmpty {
                Text("Start writing")
                    .font(style.font())
                    .foregroundStyle(Color(nsColor: style.colors.tertiary))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: style.colors.fill))
                .padding(.horizontal, -10)
                .padding(.vertical, -6)
        }
        .padding(.top, topPadding)
    }

    private var minimumHeight: CGFloat {
        ceil(style.nsFont().boundingRectForFont.height * 0.9 + style.lineSpacing)
    }
}

private struct InlineTextRepresentable: NSViewRepresentable {
    var text: String
    var style: PageStyle
    var selection: NSRange
    var selectionRevision: Int
    var actions: InlineEditorActions
    var onHeight: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> InlineTextView {
        let textView = InlineTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        // The document owns undo: every change goes through the SwiftUI document binding, which
        // registers it with the window's undo manager. A second, private undo stack in the text view
        // would fight it and could undo the page into a state the document never had.
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.usesFontPanel = false
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.smartInsertDeleteEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Markdown")
        context.coordinator.textView = textView
        context.coordinator.wire(textView)
        return textView
    }

    func updateNSView(_ textView: InlineTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(to: textView)
    }

    static func dismantleNSView(_ textView: InlineTextView, coordinator: Coordinator) {
        textView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineTextRepresentable
        weak var textView: InlineTextView?
        private var isUpdatingFromModel = false
        private var didFocus = false
        private var reportedHeight: CGFloat = 0
        private var reportedWidth: CGFloat = 0
        private var appliedRevision = -1
        private var appliedStyleKey = ""

        init(parent: InlineTextRepresentable) {
            self.parent = parent
        }

        func wire(_ textView: InlineTextView) {
            textView.onEscape = { [weak self] in self?.parent.actions.finish() }
            textView.onNavigate = { [weak self] direction in self?.parent.actions.navigate(direction) ?? false }
            textView.onReturn = { [weak self] range in self?.parent.actions.returnKey(range) ?? false }
            textView.onTab = { [weak self] range, outdent in self?.parent.actions.tab(range, outdent) ?? false }
            textView.onLayout = { [weak self] view in self?.reportHeight(of: view) }
        }

        func apply(to textView: InlineTextView) {
            let colors = parent.style.colors
            textView.insertionPointColor = colors.accent
            textView.selectedTextAttributes = [.backgroundColor: colors.selection]

            let styleKey = "\(parent.style.size)|\(parent.style.face.rawValue)|\(colors.page)"
            let styleChanged = styleKey != appliedStyleKey
            appliedStyleKey = styleKey

            if parent.selectionRevision != appliedRevision {
                appliedRevision = parent.selectionRevision
                isUpdatingFromModel = true
                if textView.string != parent.text {
                    textView.string = parent.text
                }
                highlight(textView)
                textView.setSelectedRange(clamped(parent.selection, in: textView.string))
                isUpdatingFromModel = false
                focus(textView)
            } else if textView.string != parent.text {
                let selected = textView.selectedRange()
                isUpdatingFromModel = true
                textView.string = parent.text
                highlight(textView)
                textView.setSelectedRange(clamped(selected, in: textView.string))
                isUpdatingFromModel = false
            } else if styleChanged {
                highlight(textView)
            }
            if !didFocus {
                focus(textView)
            }
            reportHeight(of: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdatingFromModel, let textView else { return }
            parent.actions.selection(textView.selectedRange())
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromModel, let textView else { return }
            let next = textView.string
            highlight(textView)
            reportHeight(of: textView)
            if next != parent.text {
                parent.actions.text(next)
            }
        }

        private func focus(_ textView: NSTextView) {
            guard let window = textView.window else { return }
            didFocus = true
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
        }

        private func clamped(_ range: NSRange, in text: String) -> NSRange {
            let length = (text as NSString).length
            let location = min(max(range.location, 0), length)
            let span = min(max(range.length, 0), length - location)
            return NSRange(location: location, length: span)
        }

        func reportHeight(of textView: NSTextView) {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            let width = max(textView.bounds.width, 1)
            if abs(container.containerSize.width - width) > 0.5 {
                container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            }
            layoutManager.ensureLayout(for: container)
            var used = layoutManager.usedRect(for: container).height
            if layoutManager.extraLineFragmentTextContainer != nil {
                used = max(used, layoutManager.extraLineFragmentRect.maxY)
            }
            let height = ceil(used)
            guard abs(height - reportedHeight) > 0.5 || abs(width - reportedWidth) > 0.5 else { return }
            reportedHeight = height
            reportedWidth = width
            let onHeight = parent.onHeight
            DispatchQueue.main.async {
                onHeight(height)
            }
        }

        // MARK: Highlighting

        private func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage, !textView.hasMarkedText() else { return }
            let selected = textView.selectedRanges
            let style = parent.style
            let colors = style.colors
            let base = baseAttributes()
            let ns = storage.string as NSString

            storage.beginEditing()
            let full = NSRange(location: 0, length: storage.length)
            if full.length > 0 {
                storage.setAttributes(base, range: full)
            }
            if storage.length <= 200_000 {
                for span in MarkdownSourceHighlighter.spans(in: storage.string) {
                    guard span.utf16Offset >= 0, span.utf16Length > 0, span.utf16Offset < storage.length else { continue }
                    let range = NSRange(
                        location: span.utf16Offset,
                        length: min(span.utf16Length, storage.length - span.utf16Offset)
                    )
                    decorate(storage, range: range, kind: span.kind, in: ns, style: style, colors: colors)
                }
            }
            storage.endEditing()
            textView.selectedRanges = selected
            textView.typingAttributes = base
        }

        private func baseAttributes() -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = parent.style.lineSpacing
            return [
                .font: parent.style.nsFont(),
                .foregroundColor: parent.style.colors.ink,
                .paragraphStyle: paragraph
            ]
        }

        private func decorate(
            _ storage: NSTextStorage,
            range: NSRange,
            kind: SourceSpanKind,
            in ns: NSString,
            style: PageStyle,
            colors: MDownPalette.Colors
        ) {
            let dim: [NSAttributedString.Key: Any] = [.foregroundColor: colors.tertiary]
            let mono = PageStyle.nsFont(size: style.codeSize, design: .monospaced)
            switch kind {
            case let .heading(level):
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = style.lineSpacing * 0.6
                storage.addAttributes([
                    .font: style.nsFont(size: style.headingSize(level), weight: style.headingNSWeight(level)),
                    .paragraphStyle: paragraph
                ], range: range)
                let line = ns.substring(with: range)
                let marks = line.prefix(while: { $0 == "#" || $0 == " " || $0 == "\t" })
                let markLength = (String(marks) as NSString).length
                if markLength > 0 {
                    storage.addAttributes(dim, range: NSRange(location: range.location, length: min(markLength, range.length)))
                }
            case .quote:
                storage.addAttribute(.foregroundColor, value: colors.secondary, range: range)
            case .marker:
                storage.addAttributes([.foregroundColor: colors.tertiary], range: range)
            case .inlineCode:
                storage.addAttributes([
                    .font: mono,
                    .backgroundColor: colors.codeBackground
                ], range: range)
                dimEnds(storage, range: range, count: 1, dim: dim)
            case .strong:
                addTrait(.bold, to: storage, in: range)
                dimEnds(storage, range: range, count: 2, dim: dim)
            case .emphasis:
                addTrait(.italic, to: storage, in: range)
                dimEnds(storage, range: range, count: 1, dim: dim)
            case .strike:
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: colors.secondary
                ], range: range)
                dimEnds(storage, range: range, count: 2, dim: dim)
            case .link:
                let source = ns.substring(with: range) as NSString
                let close = source.range(of: "](")
                if close.location != NSNotFound {
                    let label = NSRange(location: range.location + 1, length: max(close.location - 1, 0))
                    storage.addAttribute(.foregroundColor, value: colors.link, range: label)
                    storage.addAttributes(dim, range: NSRange(location: range.location, length: 1))
                    storage.addAttributes(dim, range: NSRange(
                        location: range.location + close.location,
                        length: range.length - close.location
                    ))
                } else {
                    storage.addAttribute(.foregroundColor, value: colors.link, range: range)
                }
            case .rule:
                storage.addAttributes(dim, range: range)
            case .fence:
                storage.addAttributes([.font: mono, .foregroundColor: colors.tertiary], range: range)
            case .frontMatter:
                storage.addAttributes([.font: mono, .foregroundColor: colors.secondary], range: range)
            case .codeRun:
                storage.addAttributes([.font: mono, .foregroundColor: colors.ink], range: range)
            case let .token(tokenKind):
                storage.addAttribute(.foregroundColor, value: codeColor(for: tokenKind, colors: colors), range: range)
            }
        }

        private func dimEnds(_ storage: NSTextStorage, range: NSRange, count: Int, dim: [NSAttributedString.Key: Any]) {
            guard range.length >= count * 2 else { return }
            storage.addAttributes(dim, range: NSRange(location: range.location, length: count))
            storage.addAttributes(dim, range: NSRange(location: NSMaxRange(range) - count, length: count))
        }

        private func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, to storage: NSTextStorage, in range: NSRange) {
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                guard let font = value as? NSFont else { return }
                let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
                if let converted = NSFont(descriptor: descriptor, size: font.pointSize) {
                    storage.addAttribute(.font, value: converted, range: subrange)
                }
            }
        }
    }
}

final class InlineTextView: NSTextView {
    var onEscape: (() -> Void)?
    var onNavigate: ((BlockNavigation) -> Bool)?
    var onReturn: ((NSRange) -> Bool)?
    var onTab: ((NSRange, Bool) -> Bool)?
    var onLayout: ((InlineTextView) -> Void)?

    /// The editor only exists while a block is open, so it takes focus as soon as it is on screen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            onLayout?(self)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func insertNewline(_ sender: Any?) {
        if !hasMarkedText(), onReturn?(selectedRange()) == true { return }
        super.insertNewline(sender)
    }

    /// Shift-Return: a plain newline inside the block, never a Unicode line separator in the file.
    override func insertLineBreak(_ sender: Any?) {
        insertText("\n", replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        if onTab?(selectedRange(), false) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if onTab?(selectedRange(), true) == true { return }
        super.insertBacktab(sender)
    }

    override func moveUp(_ sender: Any?) {
        if selectedRange().length == 0, caretIsOnFirstLine, onNavigate?(.up) == true { return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if selectedRange().length == 0, caretIsOnLastLine, onNavigate?(.down) == true { return }
        super.moveDown(sender)
    }

    override func moveLeft(_ sender: Any?) {
        let range = selectedRange()
        if range.length == 0, range.location == 0, onNavigate?(.left) == true { return }
        super.moveLeft(sender)
    }

    override func moveRight(_ sender: Any?) {
        let range = selectedRange()
        if range.length == 0, range.location == (string as NSString).length, onNavigate?(.right) == true { return }
        super.moveRight(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        if string.isEmpty, onNavigate?(.deleteBackward) == true { return }
        super.deleteBackward(sender)
    }

    private var caretLineRect: NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let ns = string as NSString
        if ns.length == 0 { return .zero }
        let location = selectedRange().location
        if location >= ns.length {
            if layoutManager.extraLineFragmentTextContainer === textContainer {
                return layoutManager.extraLineFragmentRect
            }
            let glyph = layoutManager.glyphIndexForCharacter(at: ns.length - 1)
            return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    private var caretIsOnFirstLine: Bool {
        guard let rect = caretLineRect, let layoutManager, (string as NSString).length > 0 else { return true }
        let first = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        return rect.minY <= first.minY + 0.5
    }

    private var caretIsOnLastLine: Bool {
        guard let rect = caretLineRect, let layoutManager, let textContainer, (string as NSString).length > 0 else {
            return true
        }
        var bottom = layoutManager.usedRect(for: textContainer).maxY
        if layoutManager.extraLineFragmentTextContainer === textContainer {
            bottom = max(bottom, layoutManager.extraLineFragmentRect.maxY)
        }
        return rect.maxY >= bottom - 0.5
    }
}
