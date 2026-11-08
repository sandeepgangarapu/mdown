import AppKit
import Observation
import SwiftUI

/// Every open document window, in the order they were opened. Each window's sidebar lists these so
/// any open file is one click away, and closing a window removes it everywhere.
@MainActor
@Observable
final class OpenDocuments {
    static let shared = OpenDocuments()

    struct Entry: Identifiable, Equatable {
        let id: UUID
        var fileURL: URL?
        var untitledName: String
        /// Documents opened in each other's place share a stack: one spot on screen, with any of
        /// them in front.
        var stack: UUID
        weak var window: NSWindow?

        var title: String {
            if let fileURL {
                return FileManager.default.displayName(atPath: fileURL.path)
            }
            return untitledName
        }

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.id == rhs.id && lhs.fileURL == rhs.fileURL && lhs.untitledName == rhs.untitledName
                && lhs.stack == rhs.stack && lhs.window === rhs.window
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var recentURLs: [URL] = []
    /// Whether the sidebar's Folder section is open. Every window shares it while MDown runs, so
    /// browsing from one file to the next keeps it open, and each launch starts with it closed.
    var folderSectionExpanded = false
    @ObservationIgnored private var titleObservations: [UUID: NSKeyValueObservation] = [:]
    /// The stack a file joins when it opens in another window's spot.
    @ObservationIgnored private var pendingStacks: [URL: UUID] = [:]
    /// Files on their way to a window, so a second click doesn't open one twice.
    @ObservationIgnored private var opening: Set<URL> = []

    private init() {
        refreshRecents()
    }

    func register(id: UUID, window: NSWindow, fileURL: URL?) {
        let name = Self.untitledName(for: window)
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].window = window
            entries[index].fileURL = fileURL
            entries[index].untitledName = name
        } else {
            let stack = fileURL.flatMap { pendingStacks.removeValue(forKey: $0.standardizedFileURL) } ?? id
            entries.append(Entry(id: id, fileURL: fileURL, untitledName: name, stack: stack, window: window))
        }
        titleObservations[id] = window.observe(\.title, options: [.new]) { window, _ in
            MainActor.assumeIsolated {
                OpenDocuments.shared.titleChanged(id: id, window: window)
            }
        }
        refreshRecents()
    }

    private func titleChanged(id: UUID, window: NSWindow) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let name = Self.untitledName(for: window)
        if entries[index].untitledName != name {
            entries[index].untitledName = name
        }
    }

    func update(id: UUID, fileURL: URL?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].fileURL = fileURL
        if let window = entries[index].window {
            entries[index].untitledName = Self.untitledName(for: window)
        }
        refreshRecents()
    }

    func remove(id: UUID) {
        titleObservations[id] = nil
        entries.removeAll { $0.id == id }
        refreshRecents()
    }

    /// Brings document `id` forward. When it shares a stack with document `current`, it comes
    /// forward in that window's spot, so switching files reads as one window.
    func focus(id: UUID, over current: UUID? = nil) {
        guard let entry = entries.first(where: { $0.id == id }), let window = entry.window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if let front = entries.first(where: { $0.id == current && $0.id != id && $0.stack == entry.stack }),
           let frontWindow = front.window,
           !frontWindow.styleMask.contains(.fullScreen), !window.styleMask.contains(.fullScreen) {
            window.setFrame(frontWindow.frame, display: false)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func close(id: UUID) {
        entries.first(where: { $0.id == id })?.window?.performClose(nil)
    }

    /// Shows `url` in the spot of document `id`'s window, or in a new window when `id` is nil. The
    /// file that was there stays open behind it, and in Open, until it's closed. A file that's
    /// already open comes forward instead.
    func open(_ url: URL, over id: UUID?) {
        let target = url.standardizedFileURL
        if let entry = entries.first(where: { $0.fileURL?.standardizedFileURL == target }) {
            focus(id: entry.id, over: id)
            return
        }
        guard opening.insert(target).inserted else { return }
        let front = entries.first { $0.id == id }
        if let front {
            pendingStacks[target] = front.stack
        }
        Task {
            defer { opening.remove(target) }
            do {
                let (document, alreadyOpen) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: false)
                if document.windowControllers.isEmpty {
                    document.makeWindowControllers()
                }
                if !alreadyOpen, let frontWindow = front?.window, let window = document.windowControllers.first?.window {
                    show(document, in: window, over: frontWindow)
                } else {
                    pendingStacks[target] = nil
                    document.showWindows()
                }
            } catch {
                pendingStacks[target] = nil
                NSApp.presentError(error)
            }
        }
    }

    /// Shows a new document's window exactly over `front`, so it reads as the same window showing
    /// another file.
    private func show(_ document: NSDocument, in window: NSWindow, over front: NSWindow) {
        let frame = front.frame
        let animation = window.animationBehavior
        window.animationBehavior = .none
        window.setFrame(frame, display: false)
        if front.styleMask.contains(.fullScreen) || (front.tabbedWindows?.count ?? 0) > 1 {
            front.addTabbedWindow(window, ordered: .above)
        }
        document.showWindows()
        window.setFrame(frame, display: true)
        window.animationBehavior = animation
    }

    func refreshRecents() {
        let open = Set(entries.compactMap { $0.fileURL?.standardizedFileURL })
        let next = NSDocumentController.shared.recentDocumentURLs
            .filter { !open.contains($0.standardizedFileURL) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if next != recentURLs {
            recentURLs = next
        }
    }

    func clearRecents() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentURLs = []
    }

    private static func untitledName(for window: NSWindow) -> String {
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled" : title
    }
}

/// Reports the hosting `NSWindow` once the view is in one.
struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onWindow?(window)
            }
        }
    }
}
