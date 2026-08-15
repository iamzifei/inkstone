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
