import Foundation

/// An sRGB colour stored as hex so themes can be shipped and shared as JSON.
public struct ThemeColor: Codable, Hashable, Sendable {
    public var hex: String

    public init(_ hex: String) { self.hex = hex }

    /// Returns red/green/blue/alpha in 0...1.
    public var components: (red: Double, green: Double, blue: Double, alpha: Double) {
        var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        if value.count == 6 { value += "FF" }
        guard value.count == 8, let number = UInt32(value, radix: 16) else {
            return (0, 0, 0, 1)
        }
        return (
            Double((number >> 24) & 0xFF) / 255,
            Double((number >> 16) & 0xFF) / 255,
            Double((number >> 8) & 0xFF) / 255,
            Double(number & 0xFF) / 255
        )
    }
}

/// The colour half of a theme, defined once per appearance.
public struct ThemePalette: Codable, Hashable, Sendable {
    public var accent: ThemeColor
    public var background: ThemeColor
    public var secondaryBackground: ThemeColor
    public var text: ThemeColor
    public var secondaryText: ThemeColor
    public var faintText: ThemeColor
    public var divider: ThemeColor
    public var link: ThemeColor
    /// Links pointing at notes that don't exist yet.
    public var unresolvedLink: ThemeColor
    public var tag: ThemeColor
    public var highlight: ThemeColor
    public var codeBackground: ThemeColor
    public var selection: ThemeColor

    public init(
        accent: ThemeColor,
        background: ThemeColor,
        secondaryBackground: ThemeColor,
        text: ThemeColor,
        secondaryText: ThemeColor,
        faintText: ThemeColor,
        divider: ThemeColor,
        link: ThemeColor,
        unresolvedLink: ThemeColor,
        tag: ThemeColor,
        highlight: ThemeColor,
        codeBackground: ThemeColor,
        selection: ThemeColor
    ) {
        self.accent = accent
        self.background = background
        self.secondaryBackground = secondaryBackground
        self.text = text
        self.secondaryText = secondaryText
        self.faintText = faintText
        self.divider = divider
        self.link = link
        self.unresolvedLink = unresolvedLink
        self.tag = tag
        self.highlight = highlight
        self.codeBackground = codeBackground
        self.selection = selection
    }
}

/// A complete theme: light and dark palettes under one name.
public struct Theme: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var author: String?
    public var light: ThemePalette
    public var dark: ThemePalette

    public init(id: String, name: String, author: String? = nil, light: ThemePalette, dark: ThemePalette) {
        self.id = id
        self.name = name
        self.author = author
        self.light = light
        self.dark = dark
    }

    public func palette(isDark: Bool) -> ThemePalette { isDark ? dark : light }
}

extension Theme {
    /// The default theme: near-monochrome, ink on paper, with a single restrained
    /// accent. Colour is reserved for meaning (links, tags, highlights) so the
    /// user's writing is the only thing competing for attention.
    public static let inkstone = Theme(
        id: "inkstone",
        name: "Inkstone",
        author: "Orris",
        // Cinnabar (朱砂) — the red of a carved seal pressed onto paper. Ink black,
        // paper white, one point of red. Every foreground below is checked against
        // its own background for WCAG AA (4.5:1 body, 3:1 large/non-text); see
        // ContrastTests.
        light: ThemePalette(
            accent: ThemeColor("#C0453B"),
            background: ThemeColor("#FCFBF8"),
            secondaryBackground: ThemeColor("#F4F2EC"),
            text: ThemeColor("#1F1D1A"),
            secondaryText: ThemeColor("#57534B"),
            faintText: ThemeColor("#78736A"),
            divider: ThemeColor("#E4E0D6"),
            link: ThemeColor("#B03A30"),
            unresolvedLink: ThemeColor("#8C8579"),
            tag: ThemeColor("#8A5A44"),
            highlight: ThemeColor("#F6E7A8"),
            codeBackground: ThemeColor("#F1EFE8"),
            selection: ThemeColor("#F5DAD6")
        ),
        dark: ThemePalette(
            accent: ThemeColor("#E0685C"),
            background: ThemeColor("#16161A"),
            secondaryBackground: ThemeColor("#1D1D22"),
            text: ThemeColor("#E8E6E1"),
            secondaryText: ThemeColor("#ADA89F"),
            faintText: ThemeColor("#8A857D"),
            divider: ThemeColor("#2C2C32"),
            link: ThemeColor("#E87F74"),
            unresolvedLink: ThemeColor("#7E7871"),
            tag: ThemeColor("#D9A38C"),
            highlight: ThemeColor("#5C5326"),
            codeBackground: ThemeColor("#1F1F25"),
            selection: ThemeColor("#4A2B27")
        )
    )

    /// A cooler, higher-contrast alternative.
    public static let slate = Theme(
        id: "slate",
        name: "Slate",
        author: "Orris",
        light: ThemePalette(
            accent: ThemeColor("#3A6EA5"),
            background: ThemeColor("#FFFFFF"),
            secondaryBackground: ThemeColor("#F4F6F8"),
            text: ThemeColor("#15181C"),
            secondaryText: ThemeColor("#525960"),
            faintText: ThemeColor("#828990"),
            divider: ThemeColor("#E2E6EA"),
            link: ThemeColor("#3A6EA5"),
            unresolvedLink: ThemeColor("#8A939C"),
            tag: ThemeColor("#7A4FA3"),
            highlight: ThemeColor("#FFF1A8"),
            codeBackground: ThemeColor("#F2F4F7"),
            selection: ThemeColor("#D6E4F5")
        ),
        dark: ThemePalette(
            accent: ThemeColor("#7FB2E5"),
            background: ThemeColor("#101317"),
            secondaryBackground: ThemeColor("#171B20"),
            text: ThemeColor("#E6EAEF"),
            secondaryText: ThemeColor("#9BA4AE"),
            faintText: ThemeColor("#666E77"),
            divider: ThemeColor("#242A31"),
            link: ThemeColor("#7FB2E5"),
            unresolvedLink: ThemeColor("#6A727C"),
            tag: ThemeColor("#C6A0E8"),
            highlight: ThemeColor("#4E4620"),
            codeBackground: ThemeColor("#191D23"),
            selection: ThemeColor("#26384B")
        )
    )

    public static let builtIn: [Theme] = [.inkstone, .slate]
}
