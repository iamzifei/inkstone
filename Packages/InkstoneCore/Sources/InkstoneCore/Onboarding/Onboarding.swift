import Foundation

/// When to show the first-run welcome guide, and how its pages step.
///
/// Pure logic so it can be unit-tested without a window. The window itself
/// lives in the app target (`OnboardingView`).
public enum Onboarding {
    /// UserDefaults key holding the last guide version the user was shown.
    public static let seenVersionKey = "onboardingSeenVersion"

    /// Bump this when the guide gains content worth showing to existing users
    /// again. Version 1 is the first guide (Inkstone 0.2.0).
    public static let currentVersion = 1

    /// Pages: folder, links, quick switcher, graph, canvas, sync.
    public static let pageCount = 6

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
}
