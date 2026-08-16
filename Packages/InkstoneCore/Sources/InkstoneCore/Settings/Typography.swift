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
    /// Multiple of the font size.
    ///
    /// 1.6 matches Typora's default theme. Earlier this was 1.75, which is a
    /// reasonable figure for dense CJK but left Latin prose looking airy and
    /// pushed everything below the fold.
    public var lineHeightMultiple: Double = 1.6
    /// Space after a paragraph. One line of body text, as Typora uses.
    public var paragraphSpacing: Double = 16
    /// Maximum measure in points. Long lines are the enemy of reading comfort.
    /// Typora's default theme caps its column at 860pt including 30pt of padding
    /// each side, so ~800pt of text.
    public var readableLineWidth: Double = 800
    public var isReadableLineWidthEnabled: Bool = true
    /// Extra tracking, in points. Slight positive tracking helps dense CJK text.
    public var letterSpacing: Double = 0

    // Code blocks and inline code, deliberately separate from body text.
    public var codeFont: FontChoice = .monospaced
    public var codeFontSize: Double = 14
    public var codeLineHeightMultiple: Double = 1.45

    // Headings scale off the body size.
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

    /// Multipliers of the body size, one per heading level.
    ///
    /// These are Typora's (and GitHub's) ratios rather than a modular scale. The
    /// scale produced an h6 *larger* than body text, which is backwards — a
    /// level-six heading should read as a label, not as emphasis.
    static let headingRatios: [Double] = [2.25, 1.75, 1.5, 1.25, 1.125, 1.0]

    /// Point size for a heading of the given level.
    public func headingSize(level: Int) -> Double {
        let index = max(1, min(6, level)) - 1
        return editorFontSize * Self.headingRatios[index]
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
