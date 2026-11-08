import XCTest
@testable import MDownCore

final class FolderListingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "FolderListingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appending(path: "notes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appending(path: "Archive"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appending(path: ".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appending(path: "Tool.app"), withIntermediateDirectories: true)
        for name in ["plan 10.md", "plan 2.md", "README.markdown", "draft.txt", "image.png", ".hidden.md"] {
            try Data("x".utf8).write(to: folder.appending(path: name))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testListsFoldersFirstThenMarkdownFilesInFinderOrder() {
        let entries = FolderListing.entries(in: folder)
        XCTAssertEqual(entries.map(\.url.lastPathComponent), ["Archive", "notes", "plan 2.md", "plan 10.md", "README.markdown"])
        XCTAssertEqual(entries.map(\.isFolder), [true, true, false, false, false])
    }

    func testListsTheOpenFileEvenWhenItIsNotMarkdown() {
        let draft = folder.appending(path: "draft.txt")
        let entries = FolderListing.entries(in: folder, including: draft)
        XCTAssertTrue(entries.contains { $0.url == FolderListing.normalized(draft, isFolder: false) })
        XCTAssertFalse(entries.contains { $0.url.lastPathComponent == "image.png" })
    }

    func testEntryURLsMatchURLsMadeFromADocument() {
        let file = URL(fileURLWithPath: folder.path + "/./notes/../plan 2.md")
        let entry = FolderListing.entries(in: folder).first { $0.name.hasPrefix("plan 2") }
        XCTAssertEqual(entry?.url, FolderListing.normalized(file, isFolder: false))
        XCTAssertEqual(FolderListing.folder(of: file), FolderListing.normalized(folder, isFolder: true))
    }

    func testMissingFolderListsNothing() {
        XCTAssertEqual(FolderListing.entries(in: folder.appending(path: "gone")), [])
    }

    func testAncestorsRunFromTheParentToTheDiskRoot() {
        let ancestors = FolderListing.ancestors(of: URL(filePath: "/Users/me/projects/", directoryHint: .isDirectory))
        XCTAssertEqual(ancestors.map { $0.path(percentEncoded: false) }, ["/Users/me/", "/Users/", "/"])
        XCTAssertEqual(FolderListing.ancestors(of: URL(filePath: "/")), [])
    }

    func testPathFromRootToANestedFolder() {
        let root = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        let nested = URL(filePath: "/Users/me/projects/notes", directoryHint: .isDirectory)
        XCTAssertEqual(
            FolderListing.path(from: root, to: nested)?.map { $0.path(percentEncoded: false) },
            ["/Users/me/", "/Users/me/projects/", "/Users/me/projects/notes/"]
        )
        XCTAssertEqual(FolderListing.path(from: root, to: root)?.count, 1)
        XCTAssertNil(FolderListing.path(from: nested, to: root))
        XCTAssertNil(FolderListing.path(from: URL(filePath: "/Users/m"), to: nested))
    }
}
