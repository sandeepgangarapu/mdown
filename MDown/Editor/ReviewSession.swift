import Foundation
import MDownCore
import Observation

/// Changes another app (usually an AI tool) made to the open file, waiting for you to accept or
/// reject them.
///
/// The file keeps the other app's version. The baseline is the text you had before it changed:
/// your own edits are carried into it, so they never show up as suggestions, and accepting a change
/// copies the change into it. Rejecting a change writes the baseline's text back into the
/// document. Once the two match again, there's nothing left to review.
@MainActor
@Observable
final class ReviewSession {
    enum Tab: Hashable {
        case page
        case changes
    }

    private(set) var baseline: String?
    var tab: Tab = .page
    /// The change Accept and Reject act on. After a change is decided, the next one takes its place.
    var selection: ReviewChange?

    @ObservationIgnored private var loadID: UUID?
    @ObservationIgnored private var lastText: String?
    /// The text undo or redo of a reject is about to bring back, so that change isn't taken for
    /// your own edit.
    @ObservationIgnored private var expectedRestore: String?
    @ObservationIgnored private var cache: (baseline: String, current: String, presentation: ReviewPresentation)?

    var isActive: Bool { baseline != nil }

    func start(loadID: UUID, text: String) {
        guard self.loadID == nil else { return }
        self.loadID = loadID
        lastText = text
    }

    func presentation(for current: String) -> ReviewPresentation? {
        guard let baseline else { return nil }
        // Exact comparison: canonically equal text can differ in length, and the cached changes'
        // offsets are UTF-16.
        if let cache, ChangeReview.identical(cache.baseline, baseline), ChangeReview.identical(cache.current, current) {
            return cache.presentation
        }
        let presentation = ReviewPresentation(baseline: baseline, current: current)
        cache = (baseline, current, presentation)
        return presentation
    }

    /// The selected change's index, or the first change when none is selected yet.
    func selectedIndex(in presentation: ReviewPresentation) -> Int? {
        let changes = presentation.changes
        guard !changes.isEmpty else { return nil }
        guard let selection else { return 0 }
        if let exact = changes.firstIndex(of: selection) {
            return exact
        }
        return changes.firstIndex { $0.currentLocation >= selection.currentLocation } ?? changes.count - 1
    }

    // MARK: - Following the document

    /// Every change to the document's text. A new load ID means the file was read from disk again
    /// because another app changed it: what you had becomes the baseline, unless a review is
    /// already under way. `ownWrite` edits were carried in already by `carry(from:to:)`. Anything
    /// else is undo or redo, which is yours too.
    func textDidChange(from old: String, to new: String, loadID: UUID, ownWrite: Bool) {
        defer {
            lastText = new
            settle(new)
        }
        if loadID != self.loadID {
            self.loadID = loadID
            expectedRestore = nil
            if baseline == nil {
                baseline = old
                selection = nil
            }
            return
        }
        if ownWrite { return }
        if let expected = expectedRestore {
            expectedRestore = nil
            if ChangeReview.identical(expected, new) { return }
        }
        carry(from: old, to: new)
    }

    /// The file was read again without its text changing. This mirrors when SwiftUI reports a text
    /// change (`==`, which treats canonically equal text as equal), so it deliberately isn't exact.
    func loadDidChange(to loadID: UUID, text: String) {
        if text == lastText {
            self.loadID = loadID
        }
    }

    /// An edit made in this window (typing, a checkbox).
    func carry(from old: String, to new: String) {
        guard let baseline, !ChangeReview.identical(old, new) else { return }
        let pending = cache.flatMap {
            ChangeReview.identical($0.baseline, baseline) && ChangeReview.identical($0.current, old) ? $0.presentation.changes : nil
        }
        self.baseline = ChangeReview.carryOwnEdit(baseline: baseline, from: old, to: new, pending: pending)
        settle(new)
    }

    // MARK: - Deciding

    func accept(_ changes: [ReviewChange], current: String, undoManager: UndoManager?) {
        guard let baseline, !changes.isEmpty else { return }
        let before = State(baseline: baseline, text: current)
        self.baseline = ChangeReview.accept(changes, into: baseline)
        record(changes.count == 1 ? "Accept Change" : "Accept Changes", from: before, to: State(baseline: self.baseline, text: current), undoManager: undoManager)
        settle(current)
    }

    /// Puts the baseline's text back for `changes`. `write` stores the new text in the document.
    func reject(_ changes: [ReviewChange], current: String, undoManager: UndoManager?, write: (String) -> Void) {
        guard let baseline, !changes.isEmpty else { return }
        let rejected = ChangeReview.reject(changes, in: current)
        record(changes.count == 1 ? "Reject Change" : "Reject Changes", from: State(baseline: baseline, text: current), to: State(baseline: baseline, text: rejected), undoManager: undoManager)
        write(rejected)
        settle(rejected)
    }

    private struct State {
        var baseline: String?
        var text: String
    }

    /// Undo restores the review as it was before. The document's own undo puts its text back; this
    /// only has to restore the baseline and recognize that text when it arrives.
    private func record(_ name: String, from before: State, to after: State, undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated {
                session.restore(before, expectingText: before.text != after.text)
                session.record(name, from: after, to: before, undoManager: undoManager)
            }
        }
        undoManager.setActionName(name)
    }

    private func restore(_ state: State, expectingText: Bool) {
        let wasOver = baseline == nil
        baseline = state.baseline
        if expectingText {
            expectedRestore = state.text
        }
        // Undoing the last decision brings the review back where it was.
        if wasOver, baseline != nil {
            tab = .changes
        }
        // An accept leaves the text alone, so redoing the last one ends the review right here. A
        // reject's text arrives through `textDidChange`, which checks then.
        if !expectingText {
            settle(state.text)
        }
    }

    /// Ends the review once nothing differs.
    private func settle(_ current: String) {
        guard let baseline, ChangeReview.identical(baseline, current) else { return }
        self.baseline = nil
        selection = nil
        tab = .page
        cache = nil
    }
}
