# Auto-update, macOS release, and the iOS App Store attempt

Started 2026-08-20 (Sydney), after the website went live at inkslab.app.

## What was asked

1. Sparkle auto-update for the macOS app
2. Package and release it
3. Fix the nav primary button — **done**, see below
4. iOS packaging and a download
5. iOS screenshots, and publish to the App Store
6. Put the iOS download link on the site once it is live

## The gate, stated up front

**The App Store Connect API cannot create an app record.** Probed directly:

    POST /v1/apps → 403
    "The resource 'apps' does not allow 'CREATE'.
     Allowed operations are: GET_COLLECTION, GET_INSTANCE, UPDATE"

There is no `com.orris.inkstone` app in the account (six others are). The bundle
ID itself **is** registered (`com.orris.inkstone`, UNIVERSAL), so that half is
done — but the record has to be created by a human at
<https://appstoreconnect.apple.com>. Everything downstream depends on it:

- uploading a build (TestFlight or App Store) needs the record
- filling metadata needs the record
- submitting for review needs the record, and **review then takes days**

So items 5 and 6 **cannot complete today no matter how much effort goes in**.
What can be done is to have everything waiting at the door: a signed App Store
archive, screenshots at the exact required sizes, and the metadata written.

A second thing worth saying plainly: **an iOS app cannot be downloaded from a
website.** There is no side-load path. "iOS download" on inkslab.app can only
ever mean an App Store link, or a TestFlight public link as an interim — and
TestFlight needs the same app record.

## Status

| # | Item | State |
|---|---|---|
| 3 | Nav primary button | ✅ **Fixed.** `.nav-links > a` is (0,1,1) and `.btn` is (0,1,0), so the hover-underline's `padding-block-end: 2px` was overwriting the button's 11.52px bottom padding while the top kept it — the label sat below centre in a box 9px taller at the top, plus a stray 1px transparent border. Scoped the rule with `:not(.btn)` and made `.btn` an `inline-flex` centred box so it cannot drift again. Measured after: 11.52/11.52, border 0. |
| 1 | Sparkle auto-update | ✅ **Shipped and verified end to end** — see below. |
| 2 | macOS release | ✅ **v0.1.1 live.** 0.1.0 was published and withdrawn; it could not launch. |
| 4 | iOS archive | ✅ App Store IPA built and signed with Apple Distribution: `get-task-allow=false`, iCloud environment Production, TestFlight enabled. |
| 5a | iOS screenshots | ✅ Six iPhone 6.9" (1320×2868) and three iPad 13" (2064×2752), at Apple's exact sizes. `scripts/capture-ios-shots.sh` reproduces them. |
| 5b | App Store submission | 🟡 **automated end to end; needs one 2FA code.** `fastlane create_app` creates the record, `fastlane release` uploads binary + metadata + screenshots and submits. `fastlane check` runs read-only today and confirms the key authenticates. |
| 6 | iOS link on the site | 🔴 blocked on 5b |

## 0.1.0 shipped broken, and why nothing caught it

Worth writing down because the lesson is about the pipeline, not the bug.

Adding Sparkle gave the app a framework to load. One target serves macOS and
iOS, so it got only the iOS runpath, `@executable_path/Frameworks`. On macOS the
executable lives one directory deeper, so dyld looked in
`Contents/MacOS/Frameworks`, found nothing, and aborted before any of the app's
own code ran:

    Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle

**Every gate passed on that build.** The archive succeeded. The signature was
valid. `codesign --deep --strict` was happy. Apple notarised it twice — app and
disk image. `stapler validate` agreed. Gatekeeper accepted it. It was published
to GitHub and the site's button pointed at it.

None of those checks load a dylib, so none of them could notice that the app
could not start. The fix is therefore two things:

1. `LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]` = `@executable_path/../Frameworks`.
2. `Tools/package-dmg.sh` now **launches the app it just built**, holds it eight
   seconds, and fails the release if it exits or if dyld writes a loader
   complaint. It is the only check in the pipeline that would have caught this.

0.1.0 was deleted rather than left in the releases list, tag included. A release
that cannot launch has no users to protect and is a trap for anyone who finds it.

## The updater, verified rather than assumed

Sandboxed Sparkle needs three things that only work together, and none of which
fails loudly on its own: `SUEnableInstallerLauncherService`, the two
`-spks`/`-spki` mach-lookup exceptions, and the network-client entitlement the
app already had. Rather than assume, the whole path was exercised against a local
feed advertising a higher version and pointing at the real signed DMG:

- the menu item is present and enabled (so `canCheckForUpdates` was true)
- `SULastCheckTime` was written after a check against the live feed
- Sparkle offered the update — "Inkstone 9.9.9 is now available—you have 0.1.1"
- it downloaded, validated the EdDSA signature, installed through the XPC
  service and relaunched the app
- **and the bundle was still validly signed and Gatekeeper-accepted afterwards**

## The App Store gate, confirmed twice

Independently, from two directions:

    POST /v1/apps  →  403
      "The resource 'apps' does not allow 'CREATE'."

    xcrun altool --validate-app  →
      "Cannot determine the Apple ID from Bundle ID 'com.orris.inkstone'"

The bundle ID is registered; the app record is not.

**Correction to what this file said earlier.** It claimed there was "no scripted
way around it". That is true of the *official* API and false in general.
fastlane's `produce` drives the same private endpoints the App Store Connect
website uses, authenticated with an Apple ID session rather than an API key, and
it can create the record. What it cannot do is skip the 2FA code — which is why
`username` is a required parameter of that action and no API key substitutes for
it. The cached Apple session in `~/.app-store` is from 2026-02-07 and returns
401, so it has to be a fresh login.

Everything downstream of that one code is now automated, in `fastlane/`.

## iOS background sync

Added after the release work. The auto-sync was a `Task` with a sleep loop —
fine on macOS, useless on iOS, where the app is suspended seconds after leaving
the screen.

| Mechanism | For |
| --- | --- |
| `BGAppRefreshTask` | the app is not running at all |
| `BGProcessingTask` | more to move than a refresh window allows |
| `beginBackgroundTask` | a sync already in flight when the user leaves |

**The bug it uncovered.** `openLastVault()` ran from `.onAppear`, which never
fires when iOS wakes an app for a background task — no scene is rendered. The
handler would have found no vault, synced nothing, and reported success. It now
lives on `Workspace` as `openMostRecentVaultIfNeeded()`.

**Verified on an iPhone 15 Pro**, because the Simulator has no scheduler at all:
registration ok for both identifiers, submission ok for both, and the scheduler
held two pending requests. The handler body was then executed directly and
reported exactly why it declined to start — a sync was already running.

**A measurement worth keeping:** that sync took **over 90 seconds** on a real
vault. An app-refresh window is roughly 30. So refresh runs will frequently
expire and the processing task is what actually completes the work. Both are
scheduled deliberately for that reason.

**A correction.** The first version of the comment in `BackgroundSync.swift` said
the engine "records what it has done as it goes". It does not — `SyncState` is
written once, at the end of a successful run. An interrupted run therefore leaves
state untouched; the next run re-derives its plan from the real local and remote
file lists and at worst re-uploads identical content. Survivable, but not what
was originally claimed.

**Not used: `BGContinuedProcessingTask`** (new in iOS 26). It fits "tap Sync,
then leave the app", with a progress display — a different feature from
unattended periodic sync, and it must be submitted while foregrounded. Worth
adding later.

⚠️ **For App Review:** declaring `UIBackgroundModes` invites the question of
whether they are used. They are, by the two task identifiers above. If the
listing is rejected on that point, the answer is: GitHub vault sync while the
app is not in the foreground.

## An iOS app cannot be downloaded from a website

Worth being plain about, since item 4 asked for "packaging and a download". There
is no side-load path on iOS. The IPA is real and signed, but the only ways a
person can install it are TestFlight or the App Store, and both need the app
record. Until then the site says nothing about iOS rather than linking somewhere
that does not work.

## What is already in place

- `Tools/package-dmg.sh` — signed + notarised + stapled DMG, app first then DMG.
  Uses the App Store Connect API key at `~/.private_keys/AuthKey_UYGG95M882.p8`.
- Certificates: `Developer ID Application: Orris Technology Pty Ltd (K9YT36SP4B)`
  for the DMG, `Apple Development: Zifei Gong` for devices. An **Apple
  Distribution** certificate does not exist yet; Xcode can mint one with
  `-allowProvisioningUpdates` and the same API key.
- The three sibling apps all ship Sparkle already. Candela vendors the framework
  because it builds with bare `swiftc`; Inkstone has XcodeGen and SwiftPM, so it
  takes the dependency properly instead.

## Store listing images

`scripts/make-store-shots.py` composes the marketing screenshots from the raw
device captures: caption, subtitle, framed device, paper ground and the cinnabar
hairline. Six iPhone, three iPad, at exactly 1320×2868 and 2064×2752, asserted
per file. Rendered through headless Chrome so the captions are set in the real
Source Serif and Source Han — the second slide is about mixed-script setting, and
approximating it would have the listing arguing against itself.

`assets/ios-shots/` stays the raw captures; `assets/store-shots/` is what gets
uploaded.

## Two toolchains, one source of truth

Both are wired, deliberately:

- `Tools/release-ios.sh` — the `asc` path that was asked for. Dry run by default.
- `fastlane release` — the fallback, and the safer one for screenshots: it infers
  the device from image dimensions instead of needing Apple's display-type enum.

The listing copy lives once, in `fastlane/metadata/en-US`, and the asc script
reads from there so the two cannot drift.

**Marked unverified rather than asserted:** which display-type enum accepts a
1320×2868 image. It cannot be checked without a record to upload against, so the
screenshot step runs through asc's own `--dry-run` first.

## iOS submission — where it actually stands

App record `6803462651`, version 0.1.1, build 3 uploaded and attached.

| Done | |
| --- | --- |
| App record | `asc apps create` (2FA, done by James) |
| Name | **Inkstone Notes** — "Inkstone" is taken by another account, confirmed by a 409 `DUPLICATE.DIFFERENT_ACCOUNT`. asc's `--auto-rename` had silently produced "Inkstone - inkstone". |
| Build | 0.1.1 build 3, uploaded and attached |
| Screenshots | 6 iPhone (`APP_IPHONE_67`) + 6 iPad (`APP_IPAD_PRO_3GEN_129`), all COMPLETE |
| Listing copy | description, keywords, promotional text, three URLs |
| Categories | Productivity / Utilities |
| Age rating | 16 frequency attributes NONE, 11 booleans false |
| Content rights | no third-party content |
| Availability | 175 territories, plus new ones automatically |
| Pricing | free |
| Copyright | 2026 Orris Technology Pty Ltd |
| Review contact | name, email, phone, notes; `demoAccountRequired` set false |

**Blocked on one thing: App Privacy.** `asc review items-add` refuses the version
with "You must have published answers to your app's data usages", and the API
cannot supply them — all four endpoints 404 with "does not exist":

    /v1/appDataUsages · /v1/appDataUsageCategories
    /v1/appDataUsageDataProtections · /v1/apps/{id}/appDataUsagesPublishState

This matches fastlane's own documentation for the same task: *"Because the
underlying functionality does not utilize the official App Store Connect API,
App Store Connect API Keys are not supported for this specific task."* It is the
same class of gap as app creation — Apple ID auth only.

Two ways through, both needing James once:

1. `asc web auth login --apple-id iamzifei@gmail.com`, then
   `asc web privacy pull/apply/publish` (experimental, but scripted)
2. App Store Connect → App Privacy → Get Started → **No, we do not collect data
   from this app** → Publish. Four clicks, because the app genuinely collects
   nothing.

After either, submission is `asc review items-add --submission <id> --item-type
appStoreVersions --item-id <version>` then `asc review submissions-submit --id
<id> --confirm`. Submission `15181670-2a08-48f8-9ff7-03ee40dde74a` is already
created and waiting.

## Two upload failures worth remembering

The first upload was **rejected**, with two errors no local check had caught:

    90474  no UISupportedInterfaceOrientations. Not optional once the app ships
           for iPad — multitasking requires all four.
    90717  the 1024 marketing icon contained an alpha channel.

Both are now asserted in `Tools/package-ios.sh`. The icon check reads the
asset-catalog **source**, not the built bundle: the marketing icon is compiled
into `Assets.car` and is not a loose file, so a check against
`$APP/AppIcon*.png` inspects the small icons and passes every time.

## HUMAN QUEUE

1. 🔴 **One command, one 2FA code.** Either works:

       asc apps create --name "Inkstone" --bundle-id com.orris.inkstone \
         --sku inkstone --platform IOS --primary-locale en-US \
         --apple-id iamzifei@gmail.com

   then `Tools/release-ios.sh --confirm`. Or the fastlane path:

       fastlane create_app

   It asks for the Apple ID password for `iamzifei@gmail.com` and a verification
   code, then creates the record. The session is cached in `~/.app-store` for
   about a month, so later releases need nothing.

   Doing it by hand in the web UI works too — Apps → + → New App, iOS, name
   **Inkstone**, English (U.S.), bundle `com.orris.inkstone`, SKU `inkstone` —
   and `fastlane release` picks up from there either way.
2. 🟡 Decide whether the interim iOS link on the site is **TestFlight public** or
   nothing until App Store approval.
3. 🟡 The LICENSE and `main`-branch items from the website plan are still open.
