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
- [ ] Remaining UI defects below triaged and fixed
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

## Phase 5 — remaining UI defects (not yet fixed)

Found while walking the panes. Ordered by how much they hurt.

1. **Graph View renders blank.** Opening it from the View menu gives an empty
   pane and the inspector drops to "Nothing selected". The graph *logic* is unit
   tested, so this is a view-layer problem, not the simulation.
2. **Raw frontmatter fills the top of every note.** `---` / `tags:` / `aliases:`
   / `---` are shown as literal text, duplicating the inspector's Properties
   panel and pushing the actual note below the fold.
3. **Two menus both named "View"** in the menu bar — SwiftUI's built-in one plus
   `CommandMenu("View")`. Should merge into the standard menu via `CommandGroup`.
4. **No readable line length.** Body text runs the full width of the editor pane;
   on a wide window lines get far too long to read comfortably.
5. **GFM task lists don't render.** `- [ ] a task` stays literal in live preview.
6. Reading mode still silently falls back to live preview (HANDOFF §7).

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
- Attachments/images/video + per-file-type sync filters remain **not started** —
  requested twice, still the largest untouched piece of the original brief.
