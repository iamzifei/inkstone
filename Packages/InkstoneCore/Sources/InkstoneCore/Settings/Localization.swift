import Foundation
import os

extension AppLanguage {
    /// The language the app will show when the setting is left on "System",
    /// worked out from the system's preferred-language list.
    ///
    /// Walks the list in order and takes the first entry that is English or
    /// Chinese, which is how the app bundle itself picks a localisation. Chinese
    /// splits by script and region: `zh-Hant`, `zh-TW`, `zh-HK` and `zh-MO` are
    /// Traditional; every other `zh` (`zh-Hans`, `zh-CN`, `zh-SG`, bare `zh`) is
    /// Simplified. A list with neither falls back to English.
    ///
    /// Used to pre-select the welcome guide's language picker. It never returns
    /// `.system`.
    public static func resolving(preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        for identifier in preferred {
            let parts = identifier.replacingOccurrences(of: "_", with: "-")
                .lowercased().split(separator: "-").map(String.init)
            guard let language = parts.first else { continue }
            if language == "en" { return .english }
            guard language == "zh" else { continue }
            if parts.contains("hant") { return .traditionalChinese }
            if parts.contains("hans") { return .simplifiedChinese }
            if parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) { return .traditionalChinese }
            return .simplifiedChinese
        }
        return .english
    }
}

/// Makes strings built outside SwiftUI follow the in-app language setting.
///
/// SwiftUI's `Text("…")` reads the `\.locale` the app injects, so it already
/// followed the picker. `String(localized:)` does not: it asks the main bundle,
/// which answers in the *system* language. Errors, status lines and menu titles
/// are built that way, so they ignored the picker. `localized(_:)` below looks
/// the string up in the chosen language's `.lproj` instead.
public enum Localization {
    private static let chosen = OSAllocatedUnfairLock<AppLanguage>(initialState: .system)

    /// Called whenever the language setting is loaded or changed.
    public static func use(_ language: AppLanguage) {
        chosen.withLock { $0 = language }
    }

    /// The bundle strings are looked up in: the chosen language's `.lproj`, or
    /// the main bundle when following the system (or when that language has no
    /// `.lproj`, as in the package's own tests).
    public static var bundle: Bundle {
        guard let id = chosen.withLock({ $0 }).localeIdentifier,
              let path = Bundle.main.path(forResource: id, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return .main }
        return bundle
    }

    /// The locale numbers and dates inside those strings are formatted with.
    public static var locale: Locale {
        chosen.withLock { $0 }.localeIdentifier.map(Locale.init(identifier:)) ?? .current
    }
}

/// `String(localized:)`, resolved against the in-app language instead of the
/// system's. Use this for any text that is not a SwiftUI `Text` literal.
public func localized(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: Localization.bundle, locale: Localization.locale)
}
