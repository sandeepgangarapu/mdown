import AppKit

/// Calls back on the main queue shortly after a file changes on disk, whether it was written in
/// place or replaced by a new file under the same name (how most editors and AI tools save).
/// Bursts of writes are coalesced into one call. A file that goes missing (deleted, or gone for a
/// branch switch) is picked up again whenever it comes back.
final class FileWatcher {
    private let path: String
    private let folder: String
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    /// While the file is missing: its folder, to notice when the file is back.
    private var folderSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var reopenAttempts = 0
    private static let settleDelay: TimeInterval = 0.15

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.path = url.path(percentEncoded: false)
        self.folder = url.deletingLastPathComponent().path(percentEncoded: false)
        self.onChange = onChange
        if !attach() {
            retryOpen()
        }
    }

    deinit {
        pending?.cancel()
        source?.cancel()
        folderSource?.cancel()
    }

    /// Starts watching the file under its name. Returns false when there's no file by that name.
    private func attach() -> Bool {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        reopenAttempts = 0
        folderSource?.cancel()
        folderSource = nil
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                // The name now points at a new file, or nothing yet. Follow the name, not the old file.
                source.cancel()
                self.source = nil
                self.retryOpen()
            }
            self.scheduleChange()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
        return true
    }

    /// An atomic save removes the old file a moment before the new one takes its name, so try again
    /// quickly for a couple of seconds, then wait for the folder to change.
    private func retryOpen() {
        guard reopenAttempts < 20 else {
            watchFolder()
            return
        }
        reopenAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.source == nil else { return }
            if self.attach() {
                self.scheduleChange()
            } else {
                self.retryOpen()
            }
        }
    }

    private func watchFolder() {
        guard folderSource == nil else { return }
        let descriptor = open(folder, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.source == nil else { return }
            if self.attach() {
                self.scheduleChange()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        folderSource = source
    }

    private func scheduleChange() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.onChange() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: item)
    }
}

/// Reads a window's document again when another app changes its file, such as an AI tool editing
/// the Markdown you're reading. It goes through the document's own revert, so the document knows
/// the file's new date and later saves don't run into the other app's version.
@MainActor
final class DocumentReloader {
    weak var window: NSWindow?
    /// The document's text as the window has it now.
    var contents: (() -> String)?
    private var url: URL?
    private var watcher: FileWatcher?

    func watch(_ url: URL?) {
        guard url != self.url else { return }
        self.url = url
        watcher = url.map { url in
            FileWatcher(url: url) { [weak self] in self?.fileChanged() }
        }
    }

    /// Saves right away instead of at the next autosave, so the other app reads your decision on
    /// its next look at the file. SwiftUI hands a text change to the document a moment later, so
    /// this waits (up to a second) until the document has something to save.
    func saveSoon(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) { [weak self] in
            guard let self, let window = self.window,
                  let document = NSDocumentController.shared.document(for: window),
                  document.fileURL != nil else { return }
            if document.hasUnautosavedChanges {
                document.autosave(withImplicitCancellability: false) { _ in }
            } else if attempt < 20 {
                self.saveSoon(attempt: attempt + 1)
            }
        }
    }

    private func fileChanged() {
        guard let url, let window, let document = NSDocumentController.shared.document(for: window),
              let type = document.fileType else { return }
        let path = url.path(percentEncoded: false)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let modified = attributes?[.modificationDate] as? Date else { return }
        if let known = document.fileModificationDate, abs(modified.timeIntervalSince(known)) <= 0.001 {
            // The same date is usually the document's own save. But a tool can keep the old date,
            // and some disks store whole seconds, so with nothing waiting to be saved, compare the
            // words too.
            guard !document.hasUnautosavedChanges, let contents,
                  let data = FileManager.default.contents(atPath: path),
                  data != Data(contents().utf8) else { return }
        }
        // A file caught halfway through being written fails to read; the next change retries.
        try? document.revert(toContentsOf: url, ofType: type)
    }
}
