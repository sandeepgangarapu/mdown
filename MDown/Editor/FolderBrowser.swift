import Foundation
import MDownCore
import Observation

/// The folder tree in a window's sidebar. It starts at the document's folder and can move up to
/// any folder above it. Shown folders are watched, so files that appear, move, or go away
/// (an AI tool writing a new plan, a rename in Finder) show up right away.
///
/// Folders are listed in the background, so a big folder never holds up a click or a window
/// opening, and nothing is listed or watched while the Folder section is closed.
@MainActor
@Observable
final class FolderBrowser {
    private(set) var root: URL?
    private(set) var expanded: Set<URL> = []
    private(set) var contents: [URL: [FolderEntry]] = [:]
    /// The document this window shows.
    private(set) var file: URL?
    /// Whether the tree is on screen. Turning it on shows the last listing at once and refreshes
    /// it in the background.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                contents.keys.forEach(load)
            }
            sync()
        }
    }

    @ObservationIgnored private var watchers: [URL: DirectoryWatcher] = [:]
    /// Folders being listed, and those that changed again while they were.
    @ObservationIgnored private var loading: Set<URL> = []
    @ObservationIgnored private var stale: Set<URL> = []

    /// Where a window was browsing when it opened a file, so the new window picks up the same tree
    /// without listing it again.
    private struct Handoff {
        var root: URL
        var expanded: Set<URL>
        var contents: [URL: [FolderEntry]]
    }

    private static var handoffs: [URL: Handoff] = [:]

    var fileFolder: URL? { file.map(FolderListing.folder(of:)) }

    var ancestors: [URL] { root.map(FolderListing.ancestors(of:)) ?? [] }

    /// A folder's subfolders and Markdown files, or nil while it's still being listed.
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
        let folder = FolderListing.folder(of: file)
        if let handoff = Self.handoffs.removeValue(forKey: file) {
            root = handoff.root
            expanded = handoff.expanded
            contents = handoff.contents
            // A file that isn't Markdown is only listed when it's the one being read.
            if !FolderListing.isMarkdown(file) {
                contents[folder] = nil
            }
        }
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
        Self.handoffs[FolderListing.normalized(file, isFolder: false)] = Handoff(
            root: root,
            expanded: expanded,
            contents: contents
        )
    }

    /// Lists every folder that's on screen and not listed yet, and watches only those.
    private func sync() {
        guard isActive, let root else {
            watchers = [:]
            return
        }
        var visible: Set<URL> = []
        var pending = [root]
        while let folder = pending.popLast() {
            visible.insert(folder)
            guard let entries = contents[folder] else {
                load(folder)
                continue
            }
            for entry in entries where entry.isFolder && expanded.contains(entry.url) {
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

    /// Lists `folder` off the main thread. A folder that changes while it's being listed is listed
    /// again when that finishes.
    private func load(_ folder: URL) {
        guard loading.insert(folder).inserted else {
            stale.insert(folder)
            return
        }
        let file = file
        Task.detached(priority: .userInitiated) { [weak self] in
            let entries = FolderListing.entries(in: folder, including: file)
            await self?.loaded(entries, in: folder)
        }
    }

    private func loaded(_ entries: [FolderEntry], in folder: URL) {
        loading.remove(folder)
        if stale.remove(folder) != nil {
            load(folder)
        }
        if contents[folder] != entries {
            contents[folder] = entries
        }
        sync()
    }

    private func folderChanged(_ folder: URL, moved: Bool) {
        guard contents[folder] != nil else { return }
        if moved {
            // The watcher follows the old folder. Watch it again by name once it's listed.
            watchers[folder] = nil
        }
        load(folder)
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
