import Foundation
import MDownCore
import Observation

/// The folder tree in a window's sidebar. It starts at the document's folder and can move up to
/// any folder above it. Shown folders are watched, so files that appear, move, or go away
/// (an AI tool writing a new plan, a rename in Finder) show up right away.
@MainActor
@Observable
final class FolderBrowser {
    private(set) var root: URL?
    private(set) var expanded: Set<URL> = []
    private(set) var contents: [URL: [FolderEntry]] = [:]
    /// The document this window shows.
    private(set) var file: URL?

    @ObservationIgnored private var watchers: [URL: DirectoryWatcher] = [:]

    /// Where a window was browsing when it opened a file, so the new window picks up the same tree.
    private static var handoffs: [URL: (root: URL, expanded: Set<URL>)] = [:]

    var fileFolder: URL? { file.map(FolderListing.folder(of:)) }

    var ancestors: [URL] { root.map(FolderListing.ancestors(of:)) ?? [] }

    func entries(in folder: URL) -> [FolderEntry]? { contents[folder] }

    func isExpanded(_ folder: URL) -> Bool { expanded.contains(folder) }

    /// Shows `file` in the tree. The tree keeps its root when the file is inside it, and opens the
    /// folders down to the file.
    func reveal(_ file: URL?) {
        let file = file.map { FolderListing.normalized($0, isFolder: false) }
        self.file = file
        guard let file else {
            root = nil
            expanded = []
            sync()
            return
        }
        if let handoff = Self.handoffs.removeValue(forKey: file) {
            root = handoff.root
            expanded = handoff.expanded
        }
        let folder = FolderListing.folder(of: file)
        if let root, let path = FolderListing.path(from: root, to: folder) {
            expanded.formUnion(path.dropFirst())
        } else {
            root = folder
            expanded = []
        }
        sync()
    }

    /// Browses `folder`, opening the folders down to the document when it's inside.
    func browse(_ folder: URL) {
        let folder = FolderListing.normalized(folder, isFolder: true)
        guard folder != root else { return }
        root = folder
        if let fileFolder, let path = FolderListing.path(from: folder, to: fileFolder) {
            expanded = Set(path.dropFirst())
        } else {
            expanded = []
        }
        sync()
    }

    func setExpanded(_ folder: URL, _ isExpanded: Bool) {
        guard expanded.contains(folder) != isExpanded else { return }
        if isExpanded {
            expanded.insert(folder)
        } else {
            expanded.remove(folder)
        }
        sync()
    }

    /// Opens the same tree in the window that shows `file` next.
    func handOff(to file: URL) {
        guard let root else { return }
        Self.handoffs[FolderListing.normalized(file, isFolder: false)] = (root, expanded)
    }

    /// Loads every folder that's on screen, and watches only those.
    private func sync() {
        var visible: Set<URL> = []
        var pending = root.map { [$0] } ?? []
        while let folder = pending.popLast() {
            visible.insert(folder)
            if contents[folder] == nil {
                contents[folder] = FolderListing.entries(in: folder, including: file)
            }
            for entry in contents[folder] ?? [] where entry.isFolder && expanded.contains(entry.url) {
                pending.append(entry.url)
            }
        }
        if contents.keys.contains(where: { !visible.contains($0) }) {
            contents = contents.filter { visible.contains($0.key) }
        }
        for folder in watchers.keys where !visible.contains(folder) {
            watchers[folder] = nil
        }
        for folder in visible where watchers[folder] == nil {
            watchers[folder] = DirectoryWatcher(folder: folder) { [weak self] moved in
                self?.folderChanged(folder, moved: moved)
            }
        }
    }

    private func folderChanged(_ folder: URL, moved: Bool) {
        guard contents[folder] != nil else { return }
        if moved {
            // The watcher follows the old folder. Look again by name.
            watchers[folder] = nil
            contents[folder] = nil
            sync()
            return
        }
        let entries = FolderListing.entries(in: folder, including: file)
        guard entries != contents[folder] else { return }
        contents[folder] = entries
        sync()
    }
}

/// Calls back on the main queue when a folder's entries change, or the folder itself is moved or
/// deleted.
private final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(folder: URL, onChange: @escaping @MainActor (_ moved: Bool) -> Void) {
        let descriptor = open(folder.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak source] in
            let moved = source.map { !$0.data.isDisjoint(with: [.delete, .rename]) } ?? false
            MainActor.assumeIsolated { onChange(moved) }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    deinit {
        source.cancel()
    }
}
