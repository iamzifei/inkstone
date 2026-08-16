# Inkstone — UI/UX, theming, and app icon

Started 2026-08-16 (Sydney). Continues the 2026-08-15 build session recorded in
`/Users/james/Dev/inkstone/HANDOFF.md`.

## Goal

James's asks, in the order he gave them:

1. Look at the UI — nobody had ever seen it.
2. UI/UX work; adapt correctly to system dark/light; colours and contrast correct.
3. Change the theme colour.
4. An app icon that follows macOS design conventions.

## Acceptance criteria

- [x] The app runs and every pane has been seen and screenshotted
- [x] `.system` appearance actually follows macOS, in both directions
- [x] Every built-in theme clears WCAG AA in both appearances, asserted by a test
- [x] Accent colour changed to cinnabar and used consistently
- [x] App icon present in `Assets.car` at every declared size, legible at 16px
- [x] Remaining UI defects triaged and fixed (Phase 5)
- [x] Markdown tables render (Phase 6)
- [x] Attachments: images, media, import, per-type sync filters (Phase 7)
- [x] Desktop feature-complete against the original brief (Phases 8–10)
- [ ] iOS run (never executed — carried over from HANDOFF §3)

## Phase 1 — crash and first sight ✅

The HANDOFF's blocking bug (§4, `SIGABRT` in `RB::Device` when the vault UI
appeared) **did not reproduce**. Opened the vault UI repeatedly on this machine
with two live displays; no crash, no crash report.

Honest scope of that result: this is a *different machine* (M5 Pro, two attached
displays) from the one that crashed, so two variables changed at once — the
display configuration **and** the hardware/OS install. It is consistent with the
"headless/screen-shared display" hypothesis and it unblocks all UI work, but it
does not prove the original diagnosis. If it recurs on the original machine with
a real display attached, the hypothesis is wrong.

## Phase 2 — dark/light correctness ✅

**Root cause found.** `InkstoneApp` read `@Environment(\.colorScheme)` inside the
`App` struct. That environment is not attached to a rendered window, so it always
reported `.light` and never updated. Every `.system` user got the light palette
even with macOS in dark mode — which is exactly what the first screenshots showed.

Fix: `StyledRoot` (`App/Support/ThemeBridge.swift`) resolves the palette inside
the view hierarchy, where `\.colorScheme` is truthful, and injects `\.style`.
Applied to both the main window and the Settings scene.

Verified by flipping the system appearance with the app running: it follows both
ways.

## Phase 3 — colour and contrast ✅

Accent changed from warm brown `#7A5C3E` to **cinnabar `#C0453B`** (light) /
`#E0685C` (dark) — 朱砂, the red of a seal pressed on paper.

Added `ContrastTests`, which asserts WCAG 2.1 AA for every foreground/background
pair that actually occurs on screen, in both appearances, for every built-in
theme. It immediately caught three failures in the pre-existing **Slate** theme
(faint text 2.83:1, unresolved links 2.15:1 and 2.83:1 against their real
backgrounds); those are fixed. Test count 26 → 29, all passing.

## Phase 4 — app icon ✅

`Tools/generate-app-icon.py` composites `Tools/icon-artwork.png` into every slot.
It clips to a superellipse (the macOS 26 shape), re-centres on the content
bounding box, and downsamples all sizes from one master.

Three hand-drawn attempts were discarded first — a top-down slab kept reading as
a monitor, and a centred crescent read as a moon. The shipped artwork is an
inkstone disc with a crescent ink pool and a plain cinnabar seal. The seal is
deliberately **blank**: generated seal script came out as garbled pseudo-Chinese,
which a Chinese reader spots instantly.

`xcrun assetutil --info` now reports 11 `AppIcon` entries; previously the
`Assets.car` contained only `AccentColor` (HANDOFF §7).

## Phase 5 — UI defects ✅

All fixed and verified on screen.

1. **Graph view rendered blank.** Two causes, both about how a `Canvas` observes
   state. SwiftUI records a `@State` property as a dependency of `body` only if
   `body` reads it; `simulation` was read exclusively inside the draw closure,
   which runs at render time, so the view never re-evaluated once the simulation
   was built and the closure kept the `nil` it captured first. Diagnostics
   showed `rebuild()` reporting 18 nodes against 303 consecutive draws seeing
   nil. It is now read during body evaluation and passed in as a value. The
   `TimelineView` also ignored its context, so frames were not distinct.
   `LocalGraphThumbnail` had the same latent bug and got the same fix.
2. **Raw frontmatter** is concealed in live preview, restored in source mode and
   when the caret moves onto it.
3. **Duplicate "View" menu** merged into the system menu with
   `CommandGroup(after: .toolbar)`.
4. **Readable line length never applied.** The setting and the centring code
   both existed; the inset was simply only recomputed when the *style* changed,
   so it kept whatever it calculated on first layout — usually at zero width.
   Now recomputed on scroll-view frame changes. (This one was listed as "no
   readable line length" earlier, which was wrong: the feature was there and
   broken, not missing.)
5. **Task lists** now colour their marker and strike through completed items.
6. Reading mode still falls back to live preview — unchanged, still open.

## Phase 6 — Markdown tables ✅

Tables were never scanned at all. `SyntaxScanner` now emits `.table`,
`.tableHeaderRow` and `.tableDelimiterRow`; the block is deliberately not masked
so inline syntax inside cells still works.

Columns are aligned by **kerning the last character of each cell**, not by
rewriting the file — the same rendering-only approach as the CJK spacing. Widths
are *measured* rather than derived from character counts: the first attempt
assumed one Han character equals two Latin ones, which is wrong because a
monospaced Latin font has no CJK glyphs and the fallback family's advance is not
exactly double. That draft was visibly ragged; measuring fixed it.

## Phase 7 — Attachments ✅

The largest untouched piece of the original brief.

- `AttachmentKind`, `AttachmentIndex` and `SyncFilePolicy` in
  `InkstoneCore/Vault/Attachments.swift`, with 14 tests.
- Images embedded as `![[file.png]]` render inline. **Not** with
  `NSTextAttachment`: TextKit 1 only draws attachments for the U+FFFC character,
  and inserting one would add bytes the user never typed. The markup is
  concealed, line height is raised to reserve space, and the text view paints
  the image itself — flipping the CTM, since text views use flipped coordinates
  and the picture otherwise renders upside down.
- Drop or paste a file and it is copied into the attachment folder with the
  embed markup inserted. Verified end to end: a pasted image landed as
  `Attachments/Pasted image.png` with `![[Attachments/Pasted image.png]]`
  inserted at the caret.
- Settings gained a **File types to sync** section: images, audio, PDFs, video,
  other files, plus a size ceiling. Notes and canvases always sync.

⚠️ **Scope note, stated plainly:** the sync *filter* is implemented, but there is
still no sync engine to filter. iCloud is entitlement-blocked (HANDOFF §6) and
GitHub sync is not started. The policy is honest configuration waiting for a
consumer, not working sync.

## Latent issue found along the way

`SettingsData` is decoded with `try?`, and Swift's synthesised decoding treats a
missing key as an error even when the property has a default. So **any** newly
added settings field silently resets every preference the user has. The sync
policy is stored as an optional to dodge this, and `SettingsCompatibilityTests`
pins the behaviour — but the underlying fragility applies to the next field
anyone adds. Worth a proper `decodeIfPresent` pass on all ~30 fields.

### One unreproduced observation — do not treat as a known bug yet

After a UI session, `Samples/Inkstone Demo/Map.canvas` came back rewritten, and a
sorted-key comparison against `HEAD` reported the content as **not** semantically
identical. The file was reverted before the difference was analysed, and it has
not reproduced since: opening the vault leaves the canvas byte-identical, and so
did a later attempt to open the canvas itself.

n=1, artifact destroyed, cause unknown. It matters because a canvas that mutates
on open would be data loss in an app whose whole premise is that the files on
disk are the source of truth. Worth a deliberate test — open a canvas, move a
node, undo, close — before trusting canvas round-tripping in the UI. The
round-trip *unit* test passes, so any bug is in the view layer, not the model.

## HUMAN QUEUE

- **Decide whether the icon is final.** It is generated, committed, and shipping
  in the build; say the word and it changes. Artwork:
  `/Users/james/Dev/inkstone/Tools/icon-artwork.png`
- **iCloud container** still has to be created in the developer portal before the
  entitlement can be uncommented (HANDOFF §6). Blocks iCloud sync.
- Attachments and per-type sync filters are **done** (Phase 7), but real sync
  still needs the iCloud container created in the developer portal, or GitHub
  sync built.


## Phase 8 — block-level live preview ✅

`TokenKind` had `.blockquote` and `.listMarker` cases the scanner never emitted,
so every `-` and `>` showed raw. Both are scanned now, and the renderer does the
rest: hanging indents, drawn bullets, a rule down the left of quotes, concealed
`> [!type]` callout scaffolding, hidden ``` fences, real checkboxes for tasks,
and inline-code chips.

Two of these could not be done by substituting characters, because that would
edit the note. The marker is concealed and the shape — bullet, checkbox, chip —
is painted into the space it left.

The chips also could not use `.backgroundColor`: that attribute fills the entire
line fragment, and at a 1.75 line-height multiple the fill towers over the text.
They are drawn from the font's own metrics and positioned from the baseline.

## Phase 9 — panes that frame their content ✅

Opening a canvas showed one corner of one card. `fitToContent()` set `pan` to the
negated content centre, putting that centre at the *origin* — the top-left of the
view — and it had no viewport size to centre against. The graph was centred but
its force layout is far smaller than the viewport, so the vault sat in a knot in
the middle. Both now fit their content, and both gained a fit button.

Reading mode is genuinely read-only now; previously it hid the syntax but left
the document editable, so the picker offered a mode that did not exist.

## Phase 10 — GitHub sync ✅

The other half of "sync via iCloud or GitHub". iCloud is still blocked on the
container entitlement, so GitHub is the path that needs nothing created first.

- Local files are identified by their **git blob SHA**, which is exactly what
  the GitHub API reports, so both sides are named by the same hash and "did this
  change?" needs no timestamps and no clock agreement. Verified against
  `git hash-object`.
- `SyncPlanner` is pure and three-way: local, remote, and the state at the last
  clean sync. Two-way syncing cannot distinguish "I edited this" from "they
  deleted it" — that is how sync tools eat notes. Every combination is tested.
- **Conflicts never overwrite.** The remote copy lands beside the local one as
  `Note (conflict <time>).md` and is reported in the UI.
- The file-type policy from Phase 7 is finally applied.
- The token is in the Keychain, not `SettingsData` (a plain JSON blob in
  UserDefaults). Sync is manual by design.
- The client is tested against a stubbed `URLProtocol`. That caught a real bug:
  paths were percent-encoded *before* `URL.appending(path:)`, which escapes the
  `%` again — "Product Ideas.md" would have been written as
  "Product%2520Ideas.md".

⚠️ **Not yet run against a real repository.** Doing so needs James's own token,
and writing to his GitHub is not something to do unasked. Everything up to the
network boundary is tested; the round trip is not.

## Desktop status against the original brief

| Requirement | State |
| --- | --- |
| Vaults, multi-vault | ✅ |
| Sync — GitHub | ✅ built, untested against a live repo |
| Sync — iCloud | ⛔ blocked on the container entitlement |
| Markdown + GFM, tables | ✅ |
| Themes, fonts, separate code font | ✅ |
| Knowledge base, tags | ✅ |
| Internal + external links | ✅ |
| Graph view | ✅ |
| Canvas (JSON Canvas 1.0) | ✅ |
| Calendar / daily notes | ✅ |
| en / 简体 / 繁體 | ✅ |
| CJK-Latin typography | ✅ |
| Attachments, images, media, previews | ✅ |
| Per-file-type sync filters | ✅ |
| App icon | ✅ |
| Math / Mermaid / PDF embeds | ❌ not in the original brief; would need a new dependency |
| iOS | ❌ never run — next phase |


## iCloud container — DONE 2026-08-16

**Resolved.** Kept below for the record; nothing here is outstanding.

Inkstone's iCloud code is written and handles the container being absent, so the
app degrades cleanly today. What is missing is the container itself: it must
exist in the developer portal before Xcode can mint a provisioning profile for
it. Enabling the entitlement first makes *every* local build fail to sign, which
is why the keys sit commented in `App/Resources/Inkstone.entitlements`.

Facts needed:

  - Team:         Orris Technology — K9YT36SP4B
  - Bundle ID:    com.orris.inkstone
  - Container ID: iCloud.com.orris.inkstone   (exactly this, "iCloud." prefix included)

### Easiest route — let Xcode create it

1. `open /Users/james/Dev/inkstone/Inkstone.xcodeproj`
2. Select the **Inkstone** project in the navigator, then the **Inkstone**
   target, then the **Signing & Capabilities** tab.
3. Check Team reads *Orris Technology*.
4. Click **+ Capability**, search *iCloud*, double-click it.
5. Tick **iCloud Documents**.
6. Under Containers click **+**, enter `iCloud.com.orris.inkstone`, confirm.
7. Wait for the spinner to settle. Xcode registers the container in the portal
   and refreshes the profile.

Xcode's edits to the `.xcodeproj` are thrown away by the next `xcodegen
generate` — that is fine and expected. **The container it registered in the
portal is what matters, and that persists.**

### If Xcode refuses

Some accounts will not let Xcode register containers. Then do it by hand:

1. developer.apple.com/account → **Certificates, Identifiers & Profiles**
2. **Identifiers** → change the dropdown at the top right from *App IDs* to
   **iCloud Containers** → **+**
3. Description `Inkstone`, Identifier `iCloud.com.orris.inkstone` → Continue →
   Register
4. Back to **Identifiers** → *App IDs* → `com.orris.inkstone` → tick **iCloud**
   → **Configure** → select the container just made → Save

### Then

Tell me, and I re-enable these three keys in `Inkstone.entitlements`:

    com.apple.developer.ubiquity-container-identifiers
    com.apple.developer.icloud-container-identifiers
    com.apple.developer.icloud-services   (CloudDocuments)

and verify the app signs, launches, and that "Create Vault in iCloud Drive"
produces a working vault instead of its current alert.


### How the iCloud container was actually set up

The portal steps above were never needed. What blocked it was not the container
but **an unregistered device**: with an iCloud entitlement, a macOS build needs a
real Mac App Development profile, and a profile must contain a registered
device. The error only ever said "no profiles were found", which points at the
wrong thing.

Done with the App Store Connect API (key `UYGG95M882`, Admin):

1. Verified the account first, read-only — `com.orris.inkstone` exists as bundle
   ID `52S6ATX4NV`, team `K9YT36SP4B`. Never write to a developer account before
   confirming it is the right one.
2. `POST /v1/devices` registered this Mac (`00006050-001468EA1131401C`).
3. The ICLOUD capability was *already* enabled on the app ID, so nothing to add.
4. Built with `-allowProvisioningUpdates` plus `-authenticationKeyPath/-ID/
   -IssuerID`. Xcode's own account was not visible to `xcodebuild` ("No
   Accounts"), and the API key sidesteps that entirely.

Verified end to end:

  - The profile carries `iCloud.com.orris.inkstone` and team `K9YT36SP4B`.
  - The signed app's entitlements carry the container.
  - At runtime the container resolves and its Documents folder is writable:
    `INKSTONE_ICLOUD_CHECK=1 …/Inkstone` prints AVAILABLE.
  - **Ordinary builds still work with no extra flags**, both the sandboxed and
    the unsandboxed dev variant, so day-to-day iteration is unchanged.


## iCloud sync, actually working — 2026-08-16

The container being reachable was only half of it. iCloud Drive evicts files it
considers unused, leaving a hidden placeholder `.Note.md.icloud` in place of the
note. The scanner used `.skipsHiddenFiles`, so an evicted note disappeared from
the sidebar entirely — indistinguishable, to a user, from sync having lost it.

Fixed in three places, in `ICloudFiles` plus its two call sites:

  - The scanner filters hidden entries itself and lists a placeholder under the
    name the file will have once downloaded, so the note stays visible.
  - Opening a vault requests every evicted file back, off the main thread.
  - Opening an evicted note waits up to 2s for its bytes. Without this it opens
    blank and the empty buffer overwrites the real note on the next save — a
    display bug becoming data loss.

Both syncs now have a switch. iCloud defaults on and governs only keeping files
present; the app cannot opt out of iCloud moving the folder, and the UI says so
rather than implying more control than exists. GitHub defaults off.

## Signed distribution — 2026-08-16

`Tools/package-dmg.sh [--install]` produces a notarised DMG; `spctl` returns
"accepted, source=Notarized Developer ID". Two traps, both recorded in the
script:

  - Automatic signing cannot mint a **Developer ID** profile with this API key
    ("Cloud signing permission error"), though it mints Development profiles
    fine. The profile was created once via `POST /v1/profiles` with
    `profileType: MAC_APP_DIRECT`. The certificate type is
    `DEVELOPER_ID_APPLICATION_G2` — filtering for `DEVELOPER_ID_APPLICATION`
    returns an empty list, which reads as "no certificate" and is not.
  - Notarise and staple the **app** before building the DMG, then notarise and
    staple the DMG. Stapling only the DMG leaves a dragged-out copy ticketless,
    so it must reach Apple to validate and fails offline.

Verified: Release build launches, does not crash, and quits cleanly.
