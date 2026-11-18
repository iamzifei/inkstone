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

## 0.2.1 follow-up

- **Opening in front.** `FrontmostWindow` (an `NSViewRepresentable` in the guide)
  activates the app and orders its window front, immediately and again after 0.5s.
  Guide version bumped to 2 so 0.2.0 users see it again.
- **Checked against a real process**, not just unit tests: an ad-hoc-signed,
  unsandboxed copy of the Debug build (its defaults live in
  `~/Library/Preferences`, separate from the real app's sandbox container), driven
  only through System Events window and menu names. Fresh: guide window first and
  app frontmost. Second launch: no guide. Seen version 1: guide shown, flag becomes 2.
  System `zh-Hant-TW`: window title 歡迎使用 Inkstone. System English with in-app
  zh-Hans: title, Help item and the app's own File/View items in Simplified Chinese.
- **Picker.** `AppLanguage.resolving(preferred:)` picks the pre-selection;
  `Localization` / `localized(_:)` resolve non-SwiftUI strings against the chosen
  `.lproj`. `AppSettings` keeps `Localization` in step with the setting.
- `ImageRenderer` draws the segmented picker as a yellow "prohibited" box, so the
  debug dump renders through `NSHostingView` instead.

## 0.2.2 — localised screenshots

- `App/Support/GuideShots.swift` (DEBUG, macOS): for each language, copies a demo
  vault to a temp folder, opens it in a `Workspace` backed by a throwaway defaults
  suite with the language forced, and draws the real views through `NSHostingView`.
  Run by `scripts/make-guide-shots.sh`, which also crops (`make-guide-shots.py`)
  into `Guide<Page>-<lang>` image sets. No screen capture, no input events, nothing
  from the real vault or preferences.
- **What it took to make real views render offscreen:** the window must be ordered
  in (SwiftUI does not start `.task` work for views in a window that was never
  shown — the graph layout and the quick switcher list stayed empty until it was),
  parked at (-40000, -40000) so no display shows it; the vault copy's path must be
  the `realpath` (`/private/var/…`), because the index is keyed by it and Foundation's
  `resolvingSymlinksInPath` strips `/private`, leaving the inspector on "Nothing
  selected"; `NSWindow.isReleasedWhenClosed` must be false or the process dies in
  an autorelease pool; `ImageRenderer` cannot draw AppKit-backed controls.
- A canvas rendered tiny in a corner: its automatic fit ran for a viewport still
  being sized. `CanvasPane` now re-fits on resize while the view is untouched.
- The sync page crops below the Settings tab strip: a `TabView` drawn outside a
  real window loses its icons and the selected label.
- The graph's notes are drawn in the body-text colour (a deliberate design choice
  in `GraphPane`), so the graph shot has black nodes, unlike the 0.1.x website shot.
- `OnboardingScreenshotTests` fails if any page lacks an image in any language.
  Missing image sets otherwise render as an empty box with no error.

## Known limits

- Items macOS supplies (File, Edit, About, Close, the system menus) follow the
  system language; only the app's own items follow the picker.
- A live language change updating already-open menus is the same mechanism as the
  initial one (App.body re-evaluates) but was only checked at launch, not by clicking.
- The screenshots show the app as the renderer draws it: no window title bar or
  traffic lights, and a Settings pane without its tab strip.
- Plain-`String` text that never passes through a localisation call is invisible to
  the compiler's extraction.
- iOS shares the string catalog but gets no guide.
