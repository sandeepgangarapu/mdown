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
}

private enum SidebarItem: Hashable {
    case document(UUID)
    case heading(Int)
    case recent(URL)
}

/// The window's sidebar: every open document, the current document's headings, and recent files,
/// each in a collapsible section.
struct Sidebar: View {
    var documentID: UUID
    var outline: [OutlineEntry]
    var tracker: PageTracker
    var editingLocation: Int?
    var onSelectHeading: (OutlineEntry) -> Void

    @Environment(\.openDocument) private var openDocument
    @Environment(\.newDocument) private var newDocument
    @AppStorage(MDownSettings.sidebarOpenExpanded) private var openExpanded = true
    @AppStorage(MDownSettings.sidebarContentsExpanded) private var contentsExpanded = true
    @AppStorage(MDownSettings.sidebarRecentExpanded) private var recentExpanded = true
    @State private var selection: SidebarItem?

    private var documents: OpenDocuments { .shared }

    var body: some View {
        let current = currentHeading
        List(selection: $selection) {
            Section(isExpanded: $openExpanded) {
                ForEach(documents.entries) { entry in
                    DocumentRow(entry: entry, isCurrent: entry.id == documentID)
                        .tag(SidebarItem.document(entry.id))
                        .contextMenu {
                            if entry.id != documentID {
                                Button("Show") { documents.focus(id: entry.id) }
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

            if !documents.recentURLs.isEmpty {
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
                        .contextMenu {
                            Button("Open") { open(url) }
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onAppear {
            selection = .document(documentID)
            documents.refreshRecents()
        }
        .onChange(of: selection) { _, item in
            handle(item)
        }
    }

    private var currentHeading: Int? {
        guard let anchor = editingLocation ?? tracker.topVisibleLocation else { return outline.first?.id }
        return outline.last(where: { $0.utf16Location <= anchor })?.id ?? outline.first?.id
    }

    private func handle(_ item: SidebarItem?) {
        guard let item, item != .document(documentID) else { return }
        switch item {
        case let .document(id):
            documents.focus(id: id)
        case let .heading(location):
            if let entry = outline.first(where: { $0.utf16Location == location }) {
                onSelectHeading(entry)
            }
        case let .recent(url):
            open(url)
        }
        selection = .document(documentID)
    }

    private func open(_ url: URL) {
        Task {
            try? await openDocument(at: url)
            documents.refreshRecents()
        }
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
