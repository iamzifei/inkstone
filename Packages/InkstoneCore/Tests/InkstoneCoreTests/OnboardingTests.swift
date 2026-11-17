import Testing
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
