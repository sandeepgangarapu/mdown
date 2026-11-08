import Foundation

/// A Markdown file or a subfolder, as the sidebar's Folder section lists it.
public struct FolderEntry: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let isFolder: Bool

    public var id: URL { url }

    public init(url: URL, name: String, isFolder: Bool) {
        self.url = url
        self.name = name
        self.isFolder = isFolder
    }
}

/// What's in a folder, for browsing the files around the one you're reading: subfolders first,
/// then Markdown files, each sorted the way Finder sorts names.
public enum FolderListing {
    public static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mdwn", "mkd", "mkdn", "mdtxt", "mdtext",
    ]

    public static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// The same folder or file always becomes the same URL, so a file read from a document and one
    /// read from a folder listing compare equal.
    public static func normalized(_ url: URL, isFolder: Bool) -> URL {
        URL(
            filePath: url.standardizedFileURL.path(percentEncoded: false),
            directoryHint: isFolder ? .isDirectory : .notDirectory
        )
    }

    /// The folder that holds `file`.
    public static func folder(of file: URL) -> URL {
        normalized(file.deletingLastPathComponent(), isFolder: true)
    }

    /// Subfolders and Markdown files in `folder`. Hidden items and packages (apps, bundles) are
    /// left out. `file` is listed even when it isn't Markdown, so the document you're reading is
    /// always there.
    public static func entries(
        in folder: URL,
        including file: URL? = nil,
        fileManager: FileManager = .default
    ) -> [FolderEntry] {
        let folder = normalized(folder, isFolder: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let included = file.map { normalized($0, isFolder: false) }

        var folders: [FolderEntry] = []
        var files: [FolderEntry] = []
        for url in urls where !url.lastPathComponent.hasPrefix(".") {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            let entryURL = normalized(url, isFolder: isFolder)
            if isFolder {
                folders.append(FolderEntry(url: entryURL, name: url.lastPathComponent, isFolder: true))
            } else if values?.isDirectory != true, isMarkdown(url) || entryURL == included {
                let name = fileManager.displayName(atPath: url.path(percentEncoded: false))
                files.append(FolderEntry(url: entryURL, name: name, isFolder: false))
            }
        }
        let byName: (FolderEntry, FolderEntry) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return folders.sorted(by: byName) + files.sorted(by: byName)
    }

    /// The folders above `folder`, nearest first, ending at the root of the disk.
    public static func ancestors(of folder: URL) -> [URL] {
        var components = normalized(folder, isFolder: true).pathComponents
        var result: [URL] = []
        while components.count > 1 {
            components.removeLast()
            result.append(url(from: components))
        }
        return result
    }

    /// The folders from `root` down to `folder`, both included, or nil when `folder` isn't inside
    /// `root`.
    public static func path(from root: URL, to folder: URL) -> [URL]? {
        let rootComponents = normalized(root, isFolder: true).pathComponents
        let components = normalized(folder, isFolder: true).pathComponents
        guard components.starts(with: rootComponents) else { return nil }
        return (rootComponents.count...components.count).map { url(from: Array(components.prefix($0))) }
    }

    private static func url(from components: [String]) -> URL {
        let path = components.count <= 1 ? "/" : "/" + components.dropFirst().joined(separator: "/")
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}
