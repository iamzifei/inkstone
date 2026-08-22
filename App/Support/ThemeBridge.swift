import SwiftUI
import InkstoneCore

#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#endif

extension ThemeColor {
    var color: Color {
        let c = components
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }

    var platformColor: PlatformColor {
        let c = components
        return PlatformColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }
}

extension FontChoice {
    /// Resolves to a concrete platform font, falling back to the system font when
    /// a named family isn't installed on this device — iOS in particular ships a
    /// much smaller font set than macOS.
    func platformFont(size: CGFloat, weight: PlatformFont.Weight = .regular) -> PlatformFont {
        switch self {
        case .system:
            return .systemFont(ofSize: size, weight: weight)
        case .monospaced:
            return .monospacedSystemFont(ofSize: size, weight: weight)
        case .serif:
            #if os(macOS)
            let descriptor = NSFont.systemFont(ofSize: size, weight: weight)
                .fontDescriptor.withDesign(.serif)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) }
                ?? .systemFont(ofSize: size, weight: weight)
            #else
            let descriptor = UIFont.systemFont(ofSize: size, weight: weight)
                .fontDescriptor.withDesign(.serif)
            return descriptor.map { UIFont(descriptor: $0, size: size) }
                ?? .systemFont(ofSize: size, weight: weight)
            #endif
        case .rounded:
            #if os(macOS)
            let descriptor = NSFont.systemFont(ofSize: size, weight: weight)
                .fontDescriptor.withDesign(.rounded)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) }
                ?? .systemFont(ofSize: size, weight: weight)
            #else
            let descriptor = UIFont.systemFont(ofSize: size, weight: weight)
                .fontDescriptor.withDesign(.rounded)
            return descriptor.map { UIFont(descriptor: $0, size: size) }
                ?? .systemFont(ofSize: size, weight: weight)
            #endif
        case .named(let family):
            return PlatformFont(name: family, size: size)
                ?? .systemFont(ofSize: size, weight: weight)
        }
    }

    func font(size: CGFloat) -> Font {
        switch self {
        case .system: return .system(size: size)
        case .serif: return .system(size: size, design: .serif)
        case .rounded: return .system(size: size, design: .rounded)
        case .monospaced: return .system(size: size, design: .monospaced)
        case .named(let family): return .custom(family, size: size)
        }
    }
}

/// Resolved theme + typography for the current appearance, injected once at the
/// root so no view has to recompute colours per render.
struct Style: Sendable {
    var palette: ThemePalette
    var typography: Typography
    var isDark: Bool

    var accent: Color { palette.accent.color }
    var background: Color { palette.background.color }
    var secondaryBackground: Color { palette.secondaryBackground.color }
    var text: Color { palette.text.color }
    var secondaryText: Color { palette.secondaryText.color }
    var faintText: Color { palette.faintText.color }
    var divider: Color { palette.divider.color }
    var link: Color { palette.link.color }
    var unresolvedLink: Color { palette.unresolvedLink.color }
    var tagColor: Color { palette.tag.color }
    var highlight: Color { palette.highlight.color }
    var codeBackground: Color { palette.codeBackground.color }
    var selection: Color { palette.selection.color }

    var bodyFont: Font { typography.editorFont.font(size: typography.editorFontSize) }
    var codeFont: Font { typography.codeFont.font(size: typography.codeFontSize) }
    var uiFont: Font { typography.interfaceFont.font(size: typography.interfaceFontSize) }

    /// A glyph sized in proportion to the interface text it sits beside.
    ///
    /// Sidebar icons were written as fixed point sizes chosen against 13pt
    /// chrome. That was invisible while 13 was the only size there had ever
    /// been; once the interface size became a platform default and then a
    /// setting, a fixed 11pt icon next to 17pt or 20pt text stops looking like
    /// an icon and starts looking like a mistake.
    ///
    /// - Parameter ratio: the glyph's size as a fraction of the text size, so
    ///   the proportions that were tuned against 13pt survive the move.
    func uiIcon(_ ratio: Double, weight: Font.Weight = .regular) -> Font {
        .system(size: typography.interfaceFontSize * ratio, weight: weight)
    }

    /// Point size of the interface text, for laying out beside it.
    var uiFontSize: Double { typography.interfaceFontSize }

    func headingFont(level: Int) -> Font {
        typography.editorFont.font(size: typography.headingSize(level: level))
    }

    static let fallback = Style(
        palette: Theme.inkstone.light,
        typography: Typography(),
        isDark: false
    )
}

private struct StyleKey: EnvironmentKey {
    static let defaultValue = Style.fallback
}

extension EnvironmentValues {
    var style: Style {
        get { self[StyleKey.self] }
        set { self[StyleKey.self] = newValue }
    }
}

/// Resolves the palette for the current appearance and injects it as `\.style`.
///
/// This has to live in a *view*, not in the `App` struct. `@Environment(\.colorScheme)`
/// read from an `App` is not attached to any rendered window, so it always reports
/// `.light` and never updates — which silently pinned the whole UI to the light
/// palette even while macOS was in dark mode. Reading it here, inside the view
/// hierarchy, makes "follow system" actually follow the system and re-render when
/// the user flips appearance.
struct StyledRoot<Content: View>: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder var content: Content

    var body: some View {
        content
            .environment(\.style, style)
            // Without this, every stock SwiftUI control (toggles, segmented
            // pickers, selected tabs) paints itself in the *system* accent colour
            // the user set in System Settings, so the app's own accent only ever
            // showed up on text we coloured by hand.
            .tint(style.accent)
    }

    private var style: Style {
        // `.light`/`.dark` are honoured explicitly rather than trusting the
        // environment to reflect `.preferredColorScheme`, so an override is
        // correct on the very first frame.
        let isDark: Bool
        switch workspace.settings.data.appearance {
        case .system: isDark = colorScheme == .dark
        case .light: isDark = false
        case .dark: isDark = true
        }
        return Style(
            palette: workspace.settings.theme.palette(isDark: isDark),
            typography: workspace.settings.data.typography,
            isDark: isDark
        )
    }
}
