import AppKit
import MDownCore
import SwiftUI

// MARK: - Print mode

private struct IsPrintingKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PrintImagesKey: EnvironmentKey {
    static let defaultValue: [URL: NSImage] = [:]
}

private struct PrintListEndKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    /// Set while the page is typeset for a PDF or a printer. Views that only work on screen
    /// (scrolling, buttons, images that load as they appear) draw a still version instead.
    var isPrinting: Bool {
        get { self[IsPrintingKey.self] }
        set { self[IsPrintingKey.self] = newValue }
    }

    /// Linked images, fetched before printing, since a printed page is drawn only once.
    var printImages: [URL: NSImage] {
        get { self[PrintImagesKey.self] }
        set { self[PrintImagesKey.self] = newValue }
    }

    /// For a numbered list broken across pages, the whole list's last number, so each piece
    /// keeps the same number column.
    var printListEnd: Int? {
        get { self[PrintListEndKey.self] }
        set { self[PrintListEndKey.self] = newValue }
    }
}

/// Marks link text, so the PDF can find where each link was drawn and make it clickable.
struct PrintLink: TextAttribute {
    var url: URL
}

/// The same text, with each link marked as a `PrintLink`.
func linkMarkedText(_ string: AttributedString) -> Text {
    var result: Text?
    for (link, range) in string.runs[\.link] {
        var piece = Text(AttributedString(string[range]))
        if let link {
            piece = piece.customAttribute(PrintLink(url: link))
        }
        result = result.map { Text("\($0)\(piece)") } ?? piece
    }
    return result ?? Text(verbatim: "")
}

// MARK: - Rendering

/// What to print: the document's Markdown and what it needs to typeset.
struct PDFRequest {
    var markdown: String
    var title: String
    var baseDirectory: URL?
    var face: PageFace
}

/// A printed page's paper and margins, in points.
struct PrintPageSetup {
    var paperSize: CGSize
    var margin: CGFloat = 72

    var contentRect: CGRect {
        CGRect(x: margin, y: margin, width: paperSize.width - margin * 2, height: paperSize.height - margin * 2)
    }

    /// The paper chosen in Page Setup: Letter or A4 by default, depending on the region.
    static var current: PrintPageSetup {
        PrintPageSetup(paperSize: NSPrintInfo.shared.paperSize)
    }
}

/// Typesets a document as PDF pages with the same views that draw the page on screen, so the
/// PDF looks like MDown. Text stays text (sharp, searchable, selectable) and links stay clickable.
@MainActor
enum PDFRenderer {
    /// Body text size on paper. Headings, code, and tables scale from it as they do on screen.
    static let bodySize: CGFloat = 11

    static func render(_ request: PDFRequest, setup: PrintPageSetup = .current) async -> Data {
        let blocks = MarkdownRenderModel.blocks(from: request.markdown)
        let images = await fetchImages(in: blocks, baseDirectory: request.baseDirectory)
        return render(blocks: blocks, request: request, images: images, setup: setup)
    }

    /// Paper's light colors on a white page, whatever the window's theme and appearance.
    static func style(face: PageFace) -> PageStyle {
        PageStyle(
            size: bodySize,
            face: face,
            colors: MDownPalette.colors(theme: .paper, scheme: .light),
            minimumCodeSize: 8
        )
    }

    private static func render(blocks: [BlockNode], request: PDFRequest, images: [URL: NSImage], setup: PrintPageSetup) -> Data {
        let typesetter = PrintTypesetter(
            style: style(face: request.face),
            baseDirectory: request.baseDirectory,
            images: images,
            width: setup.contentRect.width
        )
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: setup.paperSize)
        let info = [kCGPDFContextTitle: request.title, kCGPDFContextCreator: "MDown"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, info) else {
            return Data()
        }

        let appearance = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            let pages = PrintPaginator.pages(
                for: blocks,
                pageHeight: setup.contentRect.height,
                spacing: typesetter.style.blockSpacing
            ) { placement in
                typesetter.height(of: placement)
            }
            for placements in pages {
                let links = PrintLinks(visible: setup.contentRect)
                let renderer = ImageRenderer(content: PrintPage(
                    placements: placements,
                    typesetter: typesetter,
                    setup: setup,
                    links: links
                ))
                renderer.proposedSize = ProposedViewSize(setup.paperSize)
                pdf.beginPDFPage(nil)
                renderer.render { _, draw in
                    draw(pdf)
                }
                // Links go on after drawing: SwiftUI records its drawing and replays it, so a link
                // set from inside it never reaches the PDF. PDF space starts at the bottom left.
                for link in links.found {
                    let rect = CGRect(
                        x: link.rect.minX,
                        y: setup.paperSize.height - link.rect.maxY,
                        width: link.rect.width,
                        height: link.rect.height
                    )
                    pdf.setURL(link.url as CFURL, for: rect)
                }
                pdf.endPDFPage()
            }
        }
        pdf.closePDF()
        return data as Data
    }

    /// Downloads the document's linked images, so they appear in the PDF. An image that fails or
    /// takes too long prints as its caption, the way a missing image shows on screen.
    private static func fetchImages(in blocks: [BlockNode], baseDirectory: URL?) async -> [URL: NSImage] {
        let urls = Set(ImageLocator.sources(in: blocks).compactMap { source -> URL? in
            if case let .remote(url) = ImageLocator.resolve(source: source, relativeTo: baseDirectory) {
                return url
            }
            return nil
        })
        guard !urls.isEmpty else { return [:] }
        let downloads = await withTaskGroup(of: (URL, Data?).self) { group in
            for url in urls {
                group.addTask {
                    let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
                    return (url, try? await URLSession.shared.data(for: request).0)
                }
            }
            var results: [(URL, Data?)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        var images: [URL: NSImage] = [:]
        for (url, data) in downloads {
            if let data, let image = NSImage(data: data) {
                images[url] = image
            }
        }
        return images
    }
}

/// Draws blocks at the printed page's width, and measures them for the paginator.
@MainActor
private final class PrintTypesetter {
    let style: PageStyle
    let baseDirectory: URL?
    let images: [URL: NSImage]
    let width: CGFloat

    private struct Key: Hashable {
        var block: BlockNode
        var isFirst: Bool
        var listEnd: Int?
    }

    /// The paginator measures the same pieces more than once while it fits a page.
    private var heights: [Key: CGFloat] = [:]

    init(style: PageStyle, baseDirectory: URL?, images: [URL: NSImage], width: CGFloat) {
        self.style = style
        self.baseDirectory = baseDirectory
        self.images = images
        self.width = width
    }

    func view(_ placement: PrintPlacement) -> some View {
        BlockView(block: placement.block, style: style, baseDirectory: baseDirectory, isFirst: placement.isFirst, path: [])
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.isPrinting, true)
            .environment(\.printImages, images)
            .environment(\.printListEnd, placement.listEnd)
            .environment(\.colorScheme, .light)
    }

    func height(of placement: PrintPlacement) -> CGFloat {
        let key = Key(block: placement.block, isFirst: placement.isFirst, listEnd: placement.listEnd)
        if let height = heights[key] {
            return height
        }
        let renderer = ImageRenderer(content: view(placement))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        var height: CGFloat = 0
        renderer.render { size, _ in
            height = size.height
        }
        heights[key] = height
        return height
    }
}

/// One sheet of paper: its blocks inside the margins, on white.
private struct PrintPage: View {
    var placements: [PrintPlacement]
    var typesetter: PrintTypesetter
    var setup: PrintPageSetup
    var links: PrintLinks

    var body: some View {
        let content = setup.contentRect
        VStack(alignment: .leading, spacing: typesetter.style.blockSpacing) {
            ForEach(Array(placements.enumerated()), id: \.offset) { _, placement in
                if let slice = placement.slice {
                    // Part of a block taller than a page: shift it up, and cut it off at the page end.
                    typesetter.view(placement)
                        .offset(y: -slice.offset)
                        .frame(width: content.width, height: slice.height, alignment: .top)
                        .clipped()
                } else {
                    typesetter.view(placement)
                }
            }
        }
        .frame(width: content.width, height: content.height, alignment: .topLeading)
        .padding(setup.margin)
        .frame(width: setup.paperSize.width, height: setup.paperSize.height, alignment: .topLeading)
        .background(Color.white)
        .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
            GeometryReader { proxy in
                let _ = links.collect(layouts, in: proxy)
                Color.clear
            }
        }
    }
}

/// Where the page drew each link, from the layout of every text on it.
@MainActor
private final class PrintLinks {
    struct Found {
        var url: URL
        var rect: CGRect
    }

    /// The page inside its margins. Text outside it, such as the hidden part of a sliced block,
    /// isn't on the page.
    let visible: CGRect
    private(set) var found: [Found] = []

    init(visible: CGRect) {
        self.visible = visible
    }

    func collect(_ layouts: [Text.LayoutKey.AnchoredLayout], in proxy: GeometryProxy) -> Bool {
        found = []
        for anchored in layouts {
            let origin = proxy[anchored.origin]
            for line in anchored.layout {
                for run in line {
                    guard let link = run[PrintLink.self] else { continue }
                    let rect = run.typographicBounds.rect
                        .offsetBy(dx: origin.x, dy: origin.y)
                        .intersection(visible)
                    guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
                    // A link split into runs (bold inside a link) stays one link on each line.
                    if let last = found.last, last.url == link.url,
                       abs(last.rect.minY - rect.minY) < 1, abs(last.rect.maxX - rect.minX) < 1 {
                        found[found.count - 1].rect = last.rect.union(rect)
                    } else {
                        found.append(Found(url: link.url, rect: rect))
                    }
                }
            }
        }
        return true
    }
}
