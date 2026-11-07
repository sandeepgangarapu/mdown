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
        weak var window: NSWindow?

        var title: String {
            if let fileURL {
                return FileManager.default.displayName(atPath: fileURL.path)
            }
            return untitledName
        }

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.id == rhs.id && lhs.fileURL == rhs.fileURL && lhs.untitledName == rhs.untitledName
                && lhs.window === rhs.window
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var recentURLs: [URL] = []
    @ObservationIgnored private var titleObservations: [UUID: NSKeyValueObservation] = [:]

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
            entries.append(Entry(id: id, fileURL: fileURL, untitledName: name, window: window))
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

    func focus(id: UUID) {
        guard let window = entries.first(where: { $0.id == id })?.window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func close(id: UUID) {
        entries.first(where: { $0.id == id })?.window?.performClose(nil)
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
