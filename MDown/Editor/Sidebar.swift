import AppKit
import MDownCore
import Observation
import SwiftUI

/// Which part of the page is on screen, written by the page's scroll view and read only by the
/// sidebar, so scrolling never re-renders the page itself.
@MainActor
@Observable
final class PageTracker {
    var topVisibleLocation: Int?
    var isAtBottom = false
    /// Keep a clicked heading active when the end of the page prevents top alignment.
    var requestedHeadingLocation: Int?
}

private enum SidebarItem: Hashable {
    case document(UUID)
    case heading(Int)
    case folder(URL)
    case file(URL)
    case recent(URL)
}

/// The window's sidebar: every open document, the current document's headings, the files in its
/// folder, and recent files, each in a collapsible section.
struct Sidebar: View {
    var documentID: UUID
    var fileURL: URL?
    var folder: FolderBrowser
    var outline: [OutlineEntry]
    var tracker: PageTracker
    var editingLocation: Int?
    var onSelectHeading: (OutlineEntry) -> Void

    @Environment(\.newDocument) private var newDocument
    @AppStorage(MDownSettings.sidebarShowsOpen) private var showsOpen = true
    @AppStorage(MDownSettings.sidebarShowsContents) private var showsContents = true
    @AppStorage(MDownSettings.sidebarShowsFolder) private var showsFolder = true
    @AppStorage(MDownSettings.sidebarShowsRecent) private var showsRecent = true
    @AppStorage(MDownSettings.sidebarOpenExpanded) private var openExpanded = true
    @AppStorage(MDownSettings.sidebarContentsExpanded) private var contentsExpanded = true
    @AppStorage(MDownSettings.sidebarRecentExpanded) private var recentExpanded = true
    @State private var selection: SidebarItem?

    private var documents: OpenDocuments { .shared }

    var body: some View {
        let current = currentHeading
        List(selection: $selection) {
            if showsOpen {
                Section(isExpanded: $openExpanded) {
                    ForEach(documents.entries) { entry in
                        DocumentRow(entry: entry, isCurrent: entry.id == documentID)
                            .tag(SidebarItem.document(entry.id))
                            .contextMenu {
                                if entry.id != documentID {
                                    Button("Show") { documents.focus(id: entry.id, over: documentID) }
                                }
                                if let url = entry.fileURL {
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    }
                                }
                                Divider()
                                Button("Close") { documents.close(id: entry.id) }
                            }
                    }
                } header: {
                    Text("Open")
                }
            }

            if showsContents {
                Section(isExpanded: $contentsExpanded) {
                    if outline.isEmpty {
                        Text("Headings appear here")
                            .foregroundStyle(.tertiary)
                            .selectionDisabled()
                    } else {
                        let base = outline.map(\.level).min() ?? 1
                        ForEach(outline) { entry in
                            HeadingRow(entry: entry, indent: entry.level - base, isCurrent: entry.id == current)
                                .tag(SidebarItem.heading(entry.utf16Location))
                        }
                    }
                } header: {
                    Text("Contents")
                }
            }

            if showsFolder, let root = folder.root {
                Section(isExpanded: Bindable(documents).folderSectionExpanded) {
                    FolderPathMenu(folder: folder, root: root)
                        .selectionDisabled()
                    FolderRows(folder: folder, parent: root, onOpen: { open($0, inNewWindow: $1) })
                } header: {
                    Text("Folder")
                }
            }

            if showsRecent, !documents.recentURLs.isEmpty {
                Section(isExpanded: $recentExpanded) {
                    ForEach(documents.recentURLs.prefix(8), id: \.self) { url in
                        Label {
                            Text(FileManager.default.displayName(atPath: url.path))
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .help(url.path(percentEncoded: false))
                        .tag(SidebarItem.recent(url))
                        .openInNewWindowOnCommandClick { open(url, inNewWindow: true) }
                        .contextMenu {
                            Button("Open") { open(url) }
                            Button("Open in New Window") { open(url, inNewWindow: true) }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            Divider()
                            Button("Clear Recents") { documents.clearRecents() }
                        }
                    }
                } header: {
                    Text("Recent")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    newDocument(MarkdownDocument())
                } label: {
                    Label("New Document", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Document")
                Spacer()
                DefaultMarkdownHelpButton()
                UpdateButton()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onAppear {
            selection = .document(documentID)
            documents.refreshRecents()
        }
        .onChange(of: fileURL, initial: true) { _, url in
            folder.reveal(url)
        }
        .onChange(of: showsFolder && documents.folderSectionExpanded, initial: true) { _, isOnScreen in
            folder.isActive = isOnScreen
        }
        .onChange(of: selection) { _, item in
            handle(item)
        }
    }

    private var currentHeading: Int? {
        if let anchor = tracker.requestedHeadingLocation ?? editingLocation {
            return MarkdownOutline.activeEntry(in: outline, at: anchor)?.id
        }
        return MarkdownOutline.activeEntry(
            in: outline,
            at: tracker.topVisibleLocation,
            reachedEnd: tracker.isAtBottom
        )?.id
    }

    private func handle(_ item: SidebarItem?) {
        guard let item, item != .document(documentID) else { return }
        switch item {
        case let .document(id):
            documents.focus(id: id, over: documentID)
        case let .heading(location):
            if let entry = outline.first(where: { $0.utf16Location == location }) {
                onSelectHeading(entry)
            }
        case let .folder(url):
            folder.setExpanded(url, !folder.isExpanded(url))
        case let .file(url), let .recent(url):
            // A Command-click is the row's to handle: it opens a new window.
            if !NSEvent.modifierFlags.contains(.command) {
                open(url)
            }
        }
        selection = .document(documentID)
    }

    /// Shows `url` in this window's spot, keeping the current file open behind it, or in a new
    /// window. Either way the folder tree comes along, so browsing picks up where it was.
    private func open(_ url: URL, inNewWindow: Bool = false) {
        folder.handOff(to: url)
        documents.open(url, over: inNewWindow ? nil : documentID)
    }
}

private struct DocumentRow: View {
    var entry: OpenDocuments.Entry
    var isCurrent: Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(entry.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: isCurrent ? "doc.text.fill" : "doc.text")
            }
            Spacer(minLength: 0)
            if hovering {
                Button {
                    OpenDocuments.shared.close(id: entry.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close \(entry.title)")
                .accessibilityLabel("Close \(entry.title)")
            }
        }
        .onHover { hovering = $0 }
        .help(entry.fileURL?.path(percentEncoded: false) ?? entry.title)
    }
}

/// The folder the tree starts at. The arrow moves the tree up one folder, and the folder's menu
/// moves it to any folder above.
private struct FolderPathMenu: View {
    var folder: FolderBrowser
    var root: URL

    var body: some View {
        HStack(spacing: 6) {
            menu
            Spacer(minLength: 0)
            if let parent = folder.ancestors.first {
                Button {
                    folder.browse(parent)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Go up to “\(Self.name(of: parent))”")
                .accessibilityLabel("Go up to \(Self.name(of: parent))")
            }
        }
    }

    private var menu: some View {
        Menu {
            Section("Enclosing Folders") {
                ForEach(folder.ancestors, id: \.self) { url in
                    Button {
                        folder.browse(url)
                    } label: {
                        Label(Self.name(of: url), systemImage: "folder")
                    }
                }
            }
            if let home = folder.fileFolder, home != root {
                Divider()
                Button("Back to “\(Self.name(of: home))”") {
                    folder.browse(home)
                }
            }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([root])
            }
        } label: {
            HStack(spacing: 4) {
                Label(Self.name(of: root), systemImage: "folder.fill")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(root.path(percentEncoded: false))
        .accessibilityLabel("Folder: \(Self.name(of: root))")
        .accessibilityHint("Shows the folders above this one")
    }

    static func name(of folder: URL) -> String {
        FileManager.default.displayName(atPath: folder.path(percentEncoded: false))
    }
}

/// One folder's subfolders and Markdown files. Subfolders open in place, so the whole tree reads
/// as one list.
///
/// A folder shows its first 50 entries, and 50 more each time you ask. The sidebar list builds
/// every row up front and slows down sharply as rows are added: 200 rows add about 260 ms to
/// opening a window, 2,000 take about 5 seconds to show, and 5,000 more than 40. The file being
/// read is always shown.
private struct FolderRows: View {
    static let pageSize = 50

    var folder: FolderBrowser
    var parent: URL
    var onOpen: (_ url: URL, _ inNewWindow: Bool) -> Void

    @State private var limit = Self.pageSize

    var body: some View {
        if let entries = folder.entries(in: parent) {
            if entries.isEmpty {
                Text("No Markdown files")
                    .foregroundStyle(.tertiary)
                    .selectionDisabled()
            }
            ForEach(shown(entries)) { entry in
                if entry.isFolder {
                    DisclosureGroup(isExpanded: expansion(of: entry.url)) {
                        AnyView(FolderRows(folder: folder, parent: entry.url, onOpen: onOpen))
                    } label: {
                        Label(entry.name, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(entry.url.path(percentEncoded: false))
                            .tag(SidebarItem.folder(entry.url))
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                                }
                            }
                    }
                } else {
                    let isCurrent = entry.url == folder.file
                    Label {
                        Text(entry.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: isCurrent ? "doc.text.fill" : "doc.text")
                    }
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .help(entry.url.path(percentEncoded: false))
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    .tag(SidebarItem.file(entry.url))
                    .openInNewWindowOnCommandClick { onOpen(entry.url, true) }
                    .contextMenu {
                        if !isCurrent {
                            Button("Open") { onOpen(entry.url, false) }
                            Button("Open in New Window") { onOpen(entry.url, true) }
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                    }
                }
            }
            if entries.count > limit {
                let hidden = entries.count - limit
                Button {
                    limit += Self.pageSize
                } label: {
                    Label("Show \(min(hidden, Self.pageSize)) more…", systemImage: "ellipsis")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("\(hidden) more in this folder")
                .selectionDisabled()
            }
        }
    }

    /// The first `limit` entries, plus the file being read when it's further down.
    private func shown(_ entries: [FolderEntry]) -> [FolderEntry] {
        guard entries.count > limit else { return entries }
        var shown = Array(entries.prefix(limit))
        if let file = folder.file, let current = entries.dropFirst(limit).first(where: { $0.url == file }) {
            shown.append(current)
        }
        return shown
    }

    private func expansion(of url: URL) -> Binding<Bool> {
        Binding(
            get: { folder.isExpanded(url) },
            set: { folder.setExpanded(url, $0) }
        )
    }
}

private struct HeadingRow: View {
    var entry: OutlineEntry
    var indent: Int
    var isCurrent: Bool

    var body: some View {
        Text(entry.title)
            .lineLimit(1)
            .truncationMode(.tail)
            .fontWeight(entry.level == 1 || isCurrent ? .semibold : .regular)
            .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.leading, CGFloat(min(indent, 4)) * 12)
            .help(entry.title)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

private extension View {
    /// Command-click opens a file in a new window, the way it opens a link in a new window.
    func openInNewWindowOnCommandClick(_ action: @escaping () -> Void) -> some View {
        simultaneousGesture(TapGesture().modifiers(.command).onEnded(action))
    }
}
