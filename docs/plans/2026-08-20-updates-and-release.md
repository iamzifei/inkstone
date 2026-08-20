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

## HUMAN QUEUE

1. 🔴 **One command, one 2FA code.** In the repository:

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
