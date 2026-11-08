import AppKit
import SwiftUI

/// The typeface family used for the page.
enum PageFace: String, CaseIterable, Identifiable {
    case sans
    case serif
    case mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sans: "San Francisco"
        case .serif: "New York"
        case .mono: "SF Mono"
        }
    }

    var design: Font.Design {
        switch self {
        case .sans: .default
        case .serif: .serif
        case .mono: .monospaced
        }
    }

    var systemDesign: NSFontDescriptor.SystemDesign {
        switch self {
        case .sans: .default
        case .serif: .serif
        case .mono: .monospaced
        }
    }
}

enum MDownSettings {
    static let fontSize = "mdown.fontSize"
    static let face = "mdown.face"
    static let theme = "mdown.theme"
    static let showWordCount = "mdown.showWordCount"
    static let sidebarOpenExpanded = "mdown.sidebar.open"
    static let sidebarContentsExpanded = "mdown.sidebar.contents"
    static let sidebarRecentExpanded = "mdown.sidebar.recent"
    static let sidebarShowsOpen = "mdown.sidebar.showsOpen"
    static let sidebarShowsContents = "mdown.sidebar.showsContents"
    static let sidebarShowsFolder = "mdown.sidebar.showsFolder"
    static let sidebarShowsRecent = "mdown.sidebar.showsRecent"

    static let defaultFontSize = 17.0
    static let defaultFace = PageFace.sans
    static let defaultTheme = PageTheme.paper
    static let fontSizeRange: ClosedRange<Double> = 12...32
}

/// Everything a block needs to typeset itself, and the inline editor needs to match it.
struct PageStyle {
    var size: CGFloat
    var face: PageFace
    var colors: MDownPalette.Colors

    /// Extra space between lines, shared by the typeset page and the inline editor so a block does
    /// not change height when it opens for editing.
    var lineSpacing: CGFloat { (size * 0.3).rounded() }

    /// A comfortable measure of roughly 70 characters.
    var measure: CGFloat { max(560, size * 40) }

    var blockSpacing: CGFloat { (size * 0.75).rounded() }

    var codeSize: CGFloat { max(11, (size * 0.82).rounded()) }

    func headingSize(_ level: Int) -> CGFloat {
        let scale: CGFloat
        switch level {
        case 1: scale = 1.76
        case 2: scale = 1.38
        case 3: scale = 1.16
        default: scale = 1.0
        }
        return (size * scale).rounded()
    }

    func headingWeight(_ level: Int) -> Font.Weight {
        level <= 2 ? .bold : .semibold
    }

    func headingNSWeight(_ level: Int) -> NSFont.Weight {
        level <= 2 ? .bold : .semibold
    }

    func headingTopPadding(_ level: Int) -> CGFloat {
        switch level {
        case 1: (size * 0.9).rounded()
        case 2: (size * 0.7).rounded()
        default: (size * 0.35).rounded()
        }
    }

    func font(size: CGFloat? = nil, weight: Font.Weight = .regular) -> Font {
        .system(size: size ?? self.size, weight: weight, design: face.design)
    }

    func nsFont(size: CGFloat? = nil, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        Self.nsFont(size: size ?? self.size, weight: weight, design: face.systemDesign, italic: italic)
    }

    static func nsFont(
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        design: NSFontDescriptor.SystemDesign = .default,
        italic: Bool = false
    ) -> NSFont {
        var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        if design != .default, let designed = descriptor.withDesign(design) {
            descriptor = designed
        }
        if italic {
            descriptor = descriptor.withSymbolicTraits(.italic)
        }
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}
