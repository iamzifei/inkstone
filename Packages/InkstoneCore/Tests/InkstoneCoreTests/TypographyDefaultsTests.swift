import Foundation
import Testing
@testable import InkstoneCore

/// The default text sizes differ per platform, so these assertions differ too.
///
/// Compiled for whichever platform the suite is running on, which means running
/// them on macOS alone proves only half of it. To cover the other branch:
///
///     xcodebuild test -scheme InkstoneCore \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
@Suite("Typography defaults")
struct TypographyDefaultsTests {

    /// The regression: 13pt is `NSFont.systemFontSize`, and it was the default
    /// on both platforms, so the iPhone drew its file list at Mac chrome size.
    @Test("Interface text matches the platform's own convention")
    func interfaceSize() {
        let size = Typography().interfaceFontSize
        #if os(macOS)
        #expect(size == 13)   // NSFont.systemFontSize
        #else
        #expect(size == 17)   // UIFont.preferredFont(forTextStyle: .body)
        #endif
    }

    @Test("Editor body text is at least as large as the interface")
    func editorIsNotSmallerThanChrome() {
        let typography = Typography()
        // Chrome larger than the prose it frames would be the wrong emphasis on
        // either platform, whatever the numbers happen to be.
        #expect(typography.editorFontSize >= typography.interfaceFontSize)
    }

    /// Sizes are stored, and a stored value must win over the default — that is
    /// what makes the platform default safe to change without overriding anyone
    /// who has already chosen a size.
    @Test("A saved size survives a change of default")
    func savedSizeWins() throws {
        var typography = Typography()
        typography.interfaceFontSize = 22
        let data = try JSONEncoder().encode(typography)
        let restored = try JSONDecoder().decode(Typography.self, from: data)
        #expect(restored.interfaceFontSize == 22)
    }

    /// And a settings file written before the field existed keeps the new
    /// default rather than failing to decode — the lenient decoding the settings
    /// blob relies on.
    @Test("An older settings file takes the new default")
    func absentKeyTakesTheDefault() throws {
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(SettingsData.self, from: data)
        #expect(decoded.typography.interfaceFontSize == Typography().interfaceFontSize)
    }
}
