import Testing
import Foundation
@testable import InkstoneCore

/// Contrast is the one part of a theme that is objectively right or wrong, so it
/// is asserted rather than eyeballed. Every built-in theme has to clear WCAG 2.1
/// AA in *both* appearances — a palette that only works in light mode is a bug we
/// want a red test for, not a bug a user reports from a dark room.
@Suite("Theme contrast")
struct ContrastTests {

    // MARK: - WCAG 2.1 maths

    /// Relative luminance per WCAG 2.1, including the sRGB gamma expansion.
    private static func luminance(_ color: ThemeColor) -> Double {
        let (r, g, b, _) = color.components
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// Contrast ratio in the range 1...21.
    private static func ratio(_ a: ThemeColor, _ b: ThemeColor) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// One foreground/background pair that has to clear a threshold.
    private struct Pair {
        let label: String
        let foreground: ThemeColor
        let background: ThemeColor
        /// 4.5 for body-size text, 3.0 for large text and non-text UI.
        let minimum: Double
    }

    /// The pairs that actually occur on screen. Backgrounds matter: tags and
    /// links are drawn on the editor background, sidebar text on the secondary
    /// background, so each is checked against the surface it really sits on.
    private static func pairs(_ p: ThemePalette) -> [Pair] {
        [
            Pair(label: "text on background", foreground: p.text, background: p.background, minimum: 4.5),
            Pair(label: "text on secondaryBackground", foreground: p.text, background: p.secondaryBackground, minimum: 4.5),
            Pair(label: "secondaryText on background", foreground: p.secondaryText, background: p.background, minimum: 4.5),
            Pair(label: "secondaryText on secondaryBackground", foreground: p.secondaryText, background: p.secondaryBackground, minimum: 4.5),
            Pair(label: "link on background", foreground: p.link, background: p.background, minimum: 4.5),
            Pair(label: "tag on background", foreground: p.tag, background: p.background, minimum: 4.5),
            Pair(label: "text on codeBackground", foreground: p.text, background: p.codeBackground, minimum: 4.5),
            Pair(label: "text on selection", foreground: p.text, background: p.selection, minimum: 4.5),
            Pair(label: "text on highlight", foreground: p.text, background: p.highlight, minimum: 4.5),
            // Non-text and de-emphasised roles: AA large-text / UI threshold.
            Pair(label: "accent on background", foreground: p.accent, background: p.background, minimum: 3.0),
            Pair(label: "accent on secondaryBackground", foreground: p.accent, background: p.secondaryBackground, minimum: 3.0),
            Pair(label: "faintText on background", foreground: p.faintText, background: p.background, minimum: 3.0),
            Pair(label: "faintText on secondaryBackground", foreground: p.faintText, background: p.secondaryBackground, minimum: 3.0),
            Pair(label: "unresolvedLink on background", foreground: p.unresolvedLink, background: p.background, minimum: 3.0),
        ]
    }

    // MARK: - Tests

    @Test("Every built-in theme clears WCAG AA in both appearances", arguments: Theme.builtIn)
    func builtInThemesClearAA(theme: Theme) {
        for (appearance, palette) in [("light", theme.light), ("dark", theme.dark)] {
            for pair in Self.pairs(palette) {
                let value = Self.ratio(pair.foreground, pair.background)
                #expect(
                    value >= pair.minimum,
                    """
                    \(theme.name) \(appearance): \(pair.label) is \
                    \(String(format: "%.2f", value)):1, needs \(pair.minimum):1 \
                    (\(pair.foreground.hex) on \(pair.background.hex))
                    """
                )
            }
        }
    }

    @Test("Unresolved links stay visibly weaker than resolved ones")
    func unresolvedLinksAreDeemphasised() {
        for theme in Theme.builtIn {
            for palette in [theme.light, theme.dark] {
                let resolved = Self.ratio(palette.link, palette.background)
                let unresolved = Self.ratio(palette.unresolvedLink, palette.background)
                #expect(
                    unresolved < resolved,
                    "\(theme.name): an unresolved link must read as weaker than a real one"
                )
            }
        }
    }

    @Test("Known-bad contrast is actually caught")
    func detectsInsufficientContrast() {
        // Guards the maths itself: mid grey on white is ~2.8:1 and must fail AA.
        let ratio = Self.ratio(ThemeColor("#999999"), ThemeColor("#FFFFFF"))
        #expect(ratio < 4.5)
        // And black on white is the 21:1 ceiling.
        #expect(Self.ratio(ThemeColor("#000000"), ThemeColor("#FFFFFF")) > 20.9)
    }
}
