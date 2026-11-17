# Welcome guide and complete localisation (0.2.0)

Asked 2026-11-18: every Mac app gets a first-run guide with screenshots, and every
app's UI and guide must cover at least English, 简体中文 and 繁體中文.

## What shipped

- `App/Views/OnboardingView.swift` — a SwiftUI `Window` scene, six pages, opened
  once per `Onboarding.currentVersion` and from Help › Show Welcome Guide. The
  existing `WelcomeView` (the "no vault open" screen) is untouched: it is the
  chooser, the guide explains what comes after.
- `Packages/InkstoneCore/.../Onboarding/Onboarding.swift` + `OnboardingTests` —
  the show-once rule and page stepping, testable without a window.
- Six screenshots in `Assets.xcassets` (`Guide*`), cropped from
  `site/assets/shots/*.webp` (the 3600px originals), 16:10, ~280 KB in total. They
  were captured from the demo vault, so no real notes appear. Nothing was
  captured from the live screen. No screenshot of the folder chooser exists, so
  page 1 shows the sidebar with the vault menu instead.

## The localisation gap

The catalog looked complete — all 184 entries had en / zh-Hans / zh-Hant — but it
only listed strings someone had once added by hand. Extracting what the compiler
actually sees (`SWIFT_EMIT_LOC_STRINGS`, the `.stringsdata` files from a build)
found **253 more** in the app target, and 49 in `InkstoneCore`, which Xcode does
not extract at all. Method, so it can be repeated:

    # app target: build, then collect keys from the build's *.stringsdata
    # package: swift build -Xswiftc -emit-localized-strings \
    #            -Xswiftc -emit-localized-strings-path -Xswiftc <dir>   (clean build)
    # compare both key sets with App/Resources/Localizable.xcstrings

Also: `GitHubError`, `SyncError` and the sync progress messages were plain
`String`s, so they could not be translated; they are `String(localized:)` now.
Counts inside `SyncError` stay `String`-interpolated so they print as "8882",
which `SyncBranchSafetyTests` pins.

## Known limits

- `String(localized:)` follows the *system* language; only SwiftUI `Text` follows
  the in-app language picker. Errors and status lines therefore ignore the picker.
  That was already true of the assistant's errors.
- The Help-menu item and the window title are localised by the system language for
  the same reason.
- Plain-`String` text that never passes through a localisation call is invisible to
  the compiler's extraction; the grep for `errorDescription` / `LocalizedError`
  found only the three enums above.
- iOS shares the string catalog and benefits, but gets no guide.
