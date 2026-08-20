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
| 1 | Sparkle auto-update | ⬜ |
| 2 | macOS release | ⬜ |
| 4 | iOS archive | ⬜ |
| 5a | iOS screenshots | ⬜ |
| 5b | App Store submission | 🔴 blocked on the app record |
| 6 | iOS link on the site | 🔴 blocked on 5b |

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

1. 🔴 **Create the Inkstone app record** at appstoreconnect.apple.com → Apps → +
   → New App. Platform iOS, name **Inkstone**, primary language English (U.S.),
   bundle ID `com.orris.inkstone`, SKU `inkstone`. That is the whole manual step;
   everything after it is scripted.
2. 🟡 Decide whether the interim iOS link on the site is **TestFlight public** or
   nothing until App Store approval.
3. 🟡 The LICENSE and `main`-branch items from the website plan are still open.
