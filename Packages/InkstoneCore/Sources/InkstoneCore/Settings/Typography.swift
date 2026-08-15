import Foundation

/// A font selection that survives serialisation and degrades gracefully when the
/// chosen family isn't installed.
public enum FontChoice: Codable, Hashable, Sendable {
    /// San Francisco / PingFang — the platform default, best CJK+Latin metrics
    /// out of the box on Apple platforms.
    case system
    /// New York / Songti — for long-form reading.
    case serif
    case rounded
    case monospaced
    /// A specific installed family, e.g. "Source Han Serif SC" or "JetBrains Mono".
    case named(String)

    public var familyName: String? {
        if case .named(let name) = self { return name }
        return nil
    }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .serif: return "Serif"
        case .rounded: return "Rounded"
        case .monospaced: return "Monospaced"
        case .named(let name): return name
        }
    }
}

/// Typography settings.
///
/// Editor body text and code are configured independently because a font that
/// renders Chinese beautifully is rarely a good code font, and vice versa — this
/// is the single most requested typography control in note apps.
public struct Typography: Codable, Hashable, Sendable {
    // Interface chrome (sidebar, menus, panels).
    public var interfaceFont: FontChoice = .system
    public var interfaceFontSize: Double = 13

    // Editor + preview body text.
    public var editorFont: FontChoice = .system
    public var editorFontSize: Double = 16
    /// Multiple of the font size. 1.7–1.8 reads best for mixed CJK/Latin.
    public var lineHeightMultiple: Double = 1.75
    public var paragraphSpacing: Double = 10
    /// Maximum measure in points. Long lines are the enemy of reading comfort.
    public var readableLineWidth: Double = 700
    public var isReadableLineWidthEnabled: Bool = true
    /// Extra tracking, in points. Slight positive tracking helps dense CJK text.
    public var letterSpacing: Double = 0

    // Code blocks and inline code, deliberately separate from body text.
    public var codeFont: FontChoice = .monospaced
    public var codeFontSize: Double = 13.5
    public var codeLineHeightMultiple: Double = 1.5

    // Headings scale off the body size using a modular scale.
    public var headingScale: Double = 1.22
    public var headingWeightBoost: Bool = true

    /// Inserts a thin space between Han characters and adjacent Latin/digits.
    /// This is the "盘古之白" convention and is off by default because it edits
    /// rendering, never the underlying file.
    public var cjkLatinSpacing: Bool = true

    /// Uses the CJK-appropriate variant of shared punctuation and tightens
    /// full-width brackets, matching how good Chinese typesetting looks.
    public var cjkPunctuationCompression: Bool = true

    public init() {}

    /// Point size for a heading of the given level, derived from the modular scale.
    public func headingSize(level: Int) -> Double {
        let steps = Double(max(0, 7 - max(1, min(6, level))))
        return editorFontSize * pow(headingScale, steps / 1.6)
    }

    /// Curated font families that render Chinese well, offered first in pickers.
    public static let recommendedCJKFonts: [String] = [
        "PingFang SC", "PingFang TC", "PingFang HK",
        "Songti SC", "Songti TC",
        "Source Han Serif SC", "Source Han Sans SC",
        "Noto Serif CJK SC", "Noto Sans CJK SC",
        "LXGW WenKai", "霞鹜文楷",
        "Hiragino Sans GB", "STSong", "Kaiti SC",
    ]

    public static let recommendedCodeFonts: [String] = [
        "SF Mono", "Menlo", "JetBrains Mono", "Fira Code",
        "IBM Plex Mono", "Cascadia Code", "Sarasa Mono SC", "Iosevka",
    ]
}
