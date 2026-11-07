import AppKit
import MDownCore
import SwiftUI

@main
struct MDownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { configuration in
            EditorView(document: configuration.$document, fileURL: configuration.fileURL)
        }
        .defaultSize(width: 1120, height: 800)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            MDownCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The first time MDown runs, the guide opens instead of an empty Untitled document.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        Guide.hasBeenShown
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdater.shared.start()
        guard !Guide.hasBeenShown else { return }
        Guide.hasBeenShown = true
        DispatchQueue.main.async {
            Guide.open()
        }
    }
}

/// The MDown guide, kept as a real Guide.md in Application Support so it opens like any other
/// file: closing it never asks to save, and any notes added to it stay.
enum Guide {
    private static let shownKey = "mdown.didShowGuide"

    static var hasBeenShown: Bool {
        get { UserDefaults.standard.bool(forKey: shownKey) }
        set { UserDefaults.standard.set(newValue, forKey: shownKey) }
    }

    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MDown", isDirectory: true).appendingPathComponent("Guide.md")
    }

    @MainActor
    static func open() {
        let url = url
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try WelcomeMarkdown.text.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            NSApp.presentError(error)
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                NSApp.presentError(error)
            }
        }
    }
}
