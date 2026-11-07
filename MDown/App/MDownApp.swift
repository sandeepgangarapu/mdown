import AppKit
import SwiftUI

@main
struct MDownApp: App {
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
