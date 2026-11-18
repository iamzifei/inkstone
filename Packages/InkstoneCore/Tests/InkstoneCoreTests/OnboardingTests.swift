import Testing
import Foundation
@testable import InkstoneCore

@Suite struct OnboardingTests {
    @Test func freshInstallAndUpgradeFrom0_1_xSeeTheGuide() {
        // A missing key reads back as 0, which is both a new install and every
        // existing user upgrading from a version that had no guide.
        #expect(Onboarding.shouldShow(seenVersion: 0))
    }

    @Test func seenCurrentVersionIsNotShownAgain() {
        #expect(!Onboarding.shouldShow(seenVersion: Onboarding.currentVersion))
        #expect(!Onboarding.shouldShow(seenVersion: Onboarding.currentVersion + 1))
    }

    @Test func aNewerGuideVersionIsShownToPeopleWhoSawTheOlderOne() {
        #expect(Onboarding.shouldShow(seenVersion: Onboarding.currentVersion - 1))
    }

    @Test func pagesStopAtBothEnds() {
        #expect(Onboarding.page(0, step: -1) == 0)
        #expect(Onboarding.page(0, step: 1) == 1)
        #expect(Onboarding.page(Onboarding.pageCount - 1, step: 1) == Onboarding.pageCount - 1)
        #expect(Onboarding.page(3, step: -1) == 2)
    }
}

/// The launch decision against real `UserDefaults`, which is the part that
/// decides whether someone ever sees the guide.
@Suite struct OnboardingLaunchTests {
    private func freshDefaults() -> UserDefaults {
        let name = "OnboardingLaunchTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aTrulyFreshInstallShowsTheGuideExactlyOnce() {
        let defaults = freshDefaults()
        #expect(defaults.object(forKey: Onboarding.seenVersionKey) == nil)
        #expect(Onboarding.consumeFirstShow(in: defaults))
        #expect(!Onboarding.consumeFirstShow(in: defaults))
        #expect(defaults.integer(forKey: Onboarding.seenVersionKey) == Onboarding.currentVersion)
    }

    @Test func anUpgradeFromAnOlderGuideShowsItOnceMore() {
        let defaults = freshDefaults()
        defaults.set(Onboarding.currentVersion - 1, forKey: Onboarding.seenVersionKey)
        #expect(Onboarding.consumeFirstShow(in: defaults))
        #expect(!Onboarding.consumeFirstShow(in: defaults))
    }

    @Test func anInstallThatPredatesTheGuideShowsItToo() {
        // 0.1.x never wrote the key; the settings blob is what proves the app
        // had been used. The guide must not be skipped just because settings exist.
        let defaults = freshDefaults()
        defaults.set(Data("{}".utf8), forKey: "com.orris.inkstone.settings")
        #expect(Onboarding.consumeFirstShow(in: defaults))
    }

    @Test func aCurrentInstallIsLeftAlone() {
        let defaults = freshDefaults()
        defaults.set(Onboarding.currentVersion, forKey: Onboarding.seenVersionKey)
        #expect(!Onboarding.consumeFirstShow(in: defaults))
    }
}

@Suite struct LanguageResolutionTests {
    @Test(arguments: [
        (["zh-Hant-TW"], AppLanguage.traditionalChinese),
        (["zh-TW"], .traditionalChinese),
        (["zh-HK"], .traditionalChinese),
        (["zh-Hant-HK"], .traditionalChinese),
        (["zh-MO"], .traditionalChinese),
        (["zh-Hans-CN"], .simplifiedChinese),
        (["zh-CN"], .simplifiedChinese),
        (["zh-SG"], .simplifiedChinese),
        (["zh"], .simplifiedChinese),
        (["en-AU"], .english),
        (["fr-FR"], .english),
        ([], .english),
        // First supported entry wins, as the bundle does it.
        (["fr-FR", "zh-Hant-TW", "en"], .traditionalChinese),
        (["ja-JP", "en-US", "zh-Hans-CN"], .english),
    ])
    func resolvesTheSystemList(preferred: [String], expected: AppLanguage) {
        #expect(AppLanguage.resolving(preferred: preferred) == expected)
    }

    @Test func neverResolvesToSystem() {
        for list in [["x"], [], ["zh"], ["en"]] {
            #expect(AppLanguage.resolving(preferred: list) != .system)
        }
    }

    @Test func localizedFallsBackToEnglishWithoutALprojBundle() {
        // Under `swift test` there is no .lproj for any language, so the lookup
        // must degrade to the key itself rather than return something empty.
        Localization.use(.traditionalChinese)
        defer { Localization.use(.system) }
        #expect(localized("Stopped.") == "Stopped.")
    }
}
