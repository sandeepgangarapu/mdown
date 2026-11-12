import AppKit
import SwiftUI

/// The page's background treatment. `paper`, the default, is a warm, book-like page. `standard`
/// ("Plain") follows the system (white in Light Mode, near black in Dark Mode) and the user's accent
/// color. Raw values are stored in user defaults, so they must not change.
enum PageTheme: String, CaseIterable, Identifiable {
    case paper
    case standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper: "Paper"
        case .standard: "Plain"
        }
    }
}

enum MDownPalette {
    struct Colors {
        var page: NSColor
        var ink: NSColor
        var secondary: NSColor
        var tertiary: NSColor
        var accent: NSColor
        var link: NSColor
        var fill: NSColor
        var codeBackground: NSColor
        var rule: NSColor
        var selection: NSColor
        var keyword: NSColor
        var string: NSColor
        var number: NSColor
        var typeName: NSColor
        var comment: NSColor
        /// Text a change adds, and text it takes out, on the Changes tab.
        var added: NSColor
        var removed: NSColor
    }

    static func colors(theme: PageTheme, scheme: ColorScheme) -> Colors {
        switch theme {
        case .standard:
            return standard
        case .paper:
            return scheme == .dark ? paperDark : paperLight
        }
    }

    /// Semantic system colors. They resolve against the current appearance at draw time and follow
    /// the accent color chosen in System Settings.
    private static let standard = Colors(
        page: .textBackgroundColor,
        ink: .labelColor,
        secondary: .secondaryLabelColor,
        tertiary: .tertiaryLabelColor,
        accent: .controlAccentColor,
        link: .linkColor,
        fill: .quaternarySystemFill,
        codeBackground: .quaternarySystemFill,
        rule: .separatorColor,
        selection: .selectedTextBackgroundColor,
        keyword: .systemPink,
        string: .systemRed,
        number: .systemPurple,
        typeName: .systemTeal,
        comment: .secondaryLabelColor,
        added: .systemGreen,
        removed: .systemRed
    )

    private static let paperLight = Colors(
        page: NSColor(srgbRed: 0.988, green: 0.976, blue: 0.953, alpha: 1),
        ink: NSColor(srgbRed: 0.118, green: 0.102, blue: 0.086, alpha: 1),
        secondary: NSColor(srgbRed: 0.431, green: 0.396, blue: 0.361, alpha: 1),
        tertiary: NSColor(srgbRed: 0.431, green: 0.396, blue: 0.361, alpha: 0.6),
        accent: NSColor(srgbRed: 0.769, green: 0.384, blue: 0.224, alpha: 1),
        link: NSColor(srgbRed: 0.690, green: 0.322, blue: 0.180, alpha: 1),
        fill: NSColor(srgbRed: 0.769, green: 0.384, blue: 0.224, alpha: 0.08),
        codeBackground: NSColor(srgbRed: 0.937, green: 0.910, blue: 0.863, alpha: 1),
        rule: NSColor(srgbRed: 0.867, green: 0.831, blue: 0.776, alpha: 1),
        selection: NSColor(srgbRed: 0.769, green: 0.384, blue: 0.224, alpha: 0.24),
        keyword: NSColor(srgbRed: 0.690, green: 0.243, blue: 0.333, alpha: 1),
        string: NSColor(srgbRed: 0.184, green: 0.416, blue: 0.271, alpha: 1),
        number: NSColor(srgbRed: 0.631, green: 0.361, blue: 0.180, alpha: 1),
        typeName: NSColor(srgbRed: 0.243, green: 0.337, blue: 0.471, alpha: 1),
        comment: NSColor(srgbRed: 0.541, green: 0.506, blue: 0.463, alpha: 1),
        added: NSColor(srgbRed: 0.231, green: 0.522, blue: 0.318, alpha: 1),
        removed: NSColor(srgbRed: 0.722, green: 0.212, blue: 0.161, alpha: 1)
    )

    private static let paperDark = Colors(
        page: NSColor(srgbRed: 0.110, green: 0.102, blue: 0.086, alpha: 1),
        ink: NSColor(srgbRed: 0.941, green: 0.910, blue: 0.855, alpha: 1),
        secondary: NSColor(srgbRed: 0.694, green: 0.655, blue: 0.604, alpha: 1),
        tertiary: NSColor(srgbRed: 0.694, green: 0.655, blue: 0.604, alpha: 0.6),
        accent: NSColor(srgbRed: 0.910, green: 0.580, blue: 0.420, alpha: 1),
        link: NSColor(srgbRed: 0.937, green: 0.635, blue: 0.490, alpha: 1),
        fill: NSColor(srgbRed: 0.910, green: 0.580, blue: 0.420, alpha: 0.10),
        codeBackground: NSColor(srgbRed: 0.149, green: 0.137, blue: 0.118, alpha: 1),
        rule: NSColor(srgbRed: 0.227, green: 0.204, blue: 0.173, alpha: 1),
        selection: NSColor(srgbRed: 0.910, green: 0.580, blue: 0.420, alpha: 0.32),
        keyword: NSColor(srgbRed: 0.937, green: 0.565, blue: 0.635, alpha: 1),
        string: NSColor(srgbRed: 0.718, green: 0.831, blue: 0.753, alpha: 1),
        number: NSColor(srgbRed: 0.886, green: 0.706, blue: 0.541, alpha: 1),
        typeName: NSColor(srgbRed: 0.773, green: 0.816, blue: 0.894, alpha: 1),
        comment: NSColor(srgbRed: 0.549, green: 0.514, blue: 0.471, alpha: 1),
        added: NSColor(srgbRed: 0.553, green: 0.788, blue: 0.592, alpha: 1),
        removed: NSColor(srgbRed: 0.945, green: 0.522, blue: 0.467, alpha: 1)
    )
}
