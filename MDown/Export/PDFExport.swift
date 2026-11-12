import AppKit
import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// What File > Export as PDF and File > Print act on: the frontmost document.
struct EditorExport {
    var request: () -> PDFRequest
    var window: () -> NSWindow?
}

struct EditorExportKey: FocusedValueKey {
    typealias Value = EditorExport
}

extension FocusedValues {
    var editorExport: EditorExport? {
        get { self[EditorExportKey.self] }
        set { self[EditorExportKey.self] = newValue }
    }
}

/// Export as PDF, Page Setup, and Print. Both outputs come from the same PDF, so a printout and an
/// exported file look the same.
@MainActor
@Observable
final class PDFExport: NSObject {
    static let shared = PDFExport()

    /// An export or print is under way, from its save panel or typesetting until its file is
    /// written or its print panel closes. Export and Print are disabled meanwhile, so a request is
    /// never dropped without a word.
    private(set) var isBusy = false

    func exportPDF(_ export: EditorExport) {
        guard begin() else { return }
        let request = export.request()
        let window = export.window()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = request.title + ".pdf"
        if let folder = request.baseDirectory {
            panel.directoryURL = folder
        }
        let save: (NSApplication.ModalResponse) -> Void = { [self] response in
            guard response == .OK, let url = panel.url else {
                isBusy = false
                return
            }
            Task { @MainActor in
                let data = await PDFRenderer.render(request)
                isBusy = false
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    present(error, in: window)
                }
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(panel.runModal())
        }
    }

    /// Chooses the paper, for printing and for exported PDFs.
    func pageSetup() {
        NSPageLayout().runModal(with: NSPrintInfo.shared)
    }

    func print(_ export: EditorExport) {
        guard begin() else { return }
        let request = export.request()
        let window = export.window()
        Task { @MainActor in
            let data = await PDFRenderer.render(request)
            // The PDF already has its margins.
            let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
            info.topMargin = 0
            info.bottomMargin = 0
            info.leftMargin = 0
            info.rightMargin = 0
            guard let document = PDFDocument(data: data),
                  let operation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: false) else {
                isBusy = false
                NSSound.beep()
                return
            }
            operation.jobTitle = request.title
            if let window {
                operation.runModal(
                    for: window,
                    delegate: self,
                    didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                    contextInfo: nil
                )
            } else {
                operation.run()
                isBusy = false
            }
        }
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        isBusy = false
    }

    /// Starts an export or print, or beeps when one is already under way.
    private func begin() -> Bool {
        guard !isBusy else {
            NSSound.beep()
            return false
        }
        isBusy = true
        return true
    }

    private func present(_ error: Error, in window: NSWindow?) {
        if let window {
            window.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
        } else {
            NSApp.presentError(error)
        }
    }
}
