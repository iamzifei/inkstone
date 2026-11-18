import Foundation

/// When to show the first-run welcome guide, and how its pages step.
///
/// Pure logic so it can be unit-tested without a window. The window itself
/// lives in the app target (`OnboardingView`).
public enum Onboarding {
    /// UserDefaults key holding the last guide version the user was shown.
    public static let seenVersionKey = "onboardingSeenVersion"

    /// Bump this when the guide gains content worth showing to existing users
    /// again. Version 1 was the first guide (0.2.0). Version 2 (0.2.1) adds the
    /// language picker and fixes the window not reliably opening in front, so
    /// people who had already dismissed or missed version 1 see it once more.
    public static let currentVersion = 2

    /// Base names of the pages' screenshots, in page order: folder, links, quick
    /// switcher, graph, canvas, sync. Each exists as an image set per language,
    /// `<name>-en`, `<name>-zh-Hans` and `<name>-zh-Hant`.
    public static let screenshots = [
        "GuideFolder", "GuideLinks", "GuideSwitcher", "GuideGraph", "GuideCanvas", "GuideSync",
    ]

    public static var pageCount: Int { screenshots.count }

    /// The stored value is the version last shown. It is 0 when the key is
    /// missing, which covers both a fresh install and an upgrade from 0.1.x, so
    /// people updating see the guide once too.
    public static func shouldShow(seenVersion: Int) -> Bool {
        seenVersion < currentVersion
    }

    /// Moves `step` pages from `index`, never past either end.
    public static func page(_ index: Int, step: Int) -> Int {
        min(max(0, index + step), pageCount - 1)
    }

    /// Decides whether this launch should open the guide, and records that it
    /// has been shown.
    ///
    /// The flag is written at the moment of deciding: closing the window early
    /// is a clear "not now", and Help > Show Welcome Guide is one click away.
    /// A brand-new install has no value for the key, which reads as 0, so it is
    /// shown; so is an upgrade from a build whose stored value is lower.
    public static func consumeFirstShow(in defaults: UserDefaults) -> Bool {
        let seen = defaults.integer(forKey: seenVersionKey)
        guard shouldShow(seenVersion: seen) else { return false }
        defaults.set(currentVersion, forKey: seenVersionKey)
        return true
    }
}
