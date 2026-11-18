# Inkstone: performance, UX and iPhone Duo pass (2026-11-18)

Size: **XL** (both platforms, many modules). Work on branch `feat/perf-ux-duo`, one PR per phase, `scripts/test-all.sh` green before each merge. Plan accepted by James before code starts.

## Problem
1. Large vaults feel slow: every autosave rebuilds the whole tree + index (part of it on the main thread); the iPhone editor restyles the whole note on every keystroke.
2. iPhone (compact) UX has gaps: can't create/search from the root list, no inspector (backlinks/properties), 22 pt rows and 8 pt close buttons, no swipe actions.
3. The app doesn't use iPhone Duo's inner screen or its bent posture at all.
4. Mac has a few missing shortcuts and small UX rough edges.

## Evidence (verified 2026-11-18, file:line)
- Autosave → own watcher → `handleExternalChange` → `refreshTree()` (sync `VaultScanner().scan` on the main actor) + `reindex()` (`App/Model/Workspace.swift:385-397`); no own-write filtering anywhere. Audit measured ~690 ms reindex for 8,852 notes.
- iOS `rehighlight()` styles the whole storage (`App/Views/Editor/MarkdownEditorView.swift:1912-1918`); macOS already scopes to the viewport (`:1170-1178`). Release scan of a 55 KB note ≈ 16 ms (`ScannerPerformanceTests.swift:13-16`).
- Other hotspots: embeds read from disk before cache (`MarkdownHighlighter.swift:735`), canvas file cards read files in `body` (`CanvasPane.swift:118`), full image decode on main (`AttachmentImageCache.swift`), sync re-hashes every file each run (`SyncEngine.swift:476-551`), settings JSON re-encoded on every slider tick.
- Duo APIs present in the local SDK (iOS 27.2 SDK, Xcode 27.2): SwiftUI `reservedRegions(kind: .division)` (27.1+), `onHingeChange` → `DeviceHingeContext.hinge` (status closed / partiallyOpen / fullyOpen + angle), `ArrangementView` + `.arrangementViewStyle(...)`, `defaultTabBarPlacement`; UIKit `UIHingeInteraction`, `UIViewReservedRegion`, `UIArrangementViewController`. Simulator device type "iPhone Duo" exists (runtime iOS 27.0 installed; Duo needs 27.1 — see HUMAN QUEUE). Apple guidance (tech talks 111461/111463): layout from size classes + reserved regions, hinge for interaction/effects; inner screen is regular×regular and ignores orientation locks; never use `UIScreen.main`.

## Constraints
- Files on disk stay the only source of truth; Obsidian vault compatibility must not regress; link-rewriting on rename stays.
- Swift 6 strict concurrency stays on. No new third-party dependencies.
- Minimum OS stays macOS 26 / iOS 26. Duo-specific code is behind `if #available(iOS 27.1, *)`; the app must build with the iOS 27.2 SDK and still run on iOS 26.
- Every performance change ships with before/after numbers from a repeatable benchmark (existing `INKSTONE_BENCH` hooks + new XCTest/swift-testing measurements on a generated 10k-note vault).
- No App Store / Sparkle release without James's go.

## Not doing (this pass)
Plugin API, block HTML, sync protocol redesign, new AI features, visual rebrand.

## Phases
**P0 — Guardrails (first PR)**
- CI: add a workflow that runs `swift test` for InkstoneCore + macOS and iOS-simulator builds (today CI runs only the site).
- Benchmarks: generated 10k-note fixture; measure cold index, autosave round-trip (keystroke → file written → UI idle), per-keystroke highlight cost (55 KB note, iOS + macOS), image grid memory. Record baseline table in this file.
- `os_signpost` around scan / index / highlight / sync so Instruments shows them.

**P1 — Performance (biggest wins first)**
1. Ignore the app's own writes (record path+mtime+size at write; watcher skips matches) and make external changes incremental: rescan only the changed directory, re-index only changed files, publish deltas instead of replacing `tree`/`index` wholesale; move `VaultScanner.scan` off the main actor. Replace the ~20 "refreshTree + reindex" call sites with targeted updates.
2. iOS editor: port the macOS viewport-scoped styling; word count debounced/incremental instead of in `body`; one string comparison per keystroke.
3. Embeds and canvas file cards: cache-first, async reads.
4. Images: ImageIO thumbnail decoding off main, NSCache cost = bytes; bound the Mermaid cache.
5. Sync: skip re-hashing files whose size+mtime match the manifest.
6. Settings: debounce persistence; narrow observation so a slider doesn't invalidate the whole app.
Target (acceptance): autosave round-trip on 10k vault < 50 ms main-thread work; iOS keystroke styling for 55 KB note within one 120 Hz frame (< 8 ms) for visible range; no regression in core tests.

**P2 — iPhone (compact) UX** — designed on the canvas first
- Root list gets New note / Quick switcher / Search (`.searchable`) toolbar; inspector (backlinks, outline, properties) as a sheet with detents; rows ≥ 44 pt; swipe actions (pin/bookmark, rename, delete→trash); tab strip close targets ≥ 44 pt.

**P3 — iPhone Duo** — designed on the canvas first; simulator for all states, device for bent/stand
- Folded (outer screen, compact): same as P2 iPhone.
- Unfolded (inner, regular×regular): three-column split (sidebar · list · editor) like iPad; keep selection/scroll/caret across fold ↔ unfold (scene state restoration); no orientation assumptions; no `UIScreen.main`.
- Bent (division region present / hinge partiallyOpen, device flat on a table): `ArrangementView` split along the crease — top half = the note (reading/editing), bottom half = controls: formatting bar, outline/backlinks, quick switcher; nothing interactive or text-critical drawn across the crease.
- Stand (tent / propped up, no dedicated API): treated as a hypothesis — partiallyOpen without an active keyboard → reading-first layout on the facing half (larger type, controls hidden). Ship only if it tests well on device; otherwise falls back to the bent or unfolded layout.
- Hinge transitions animate without losing the caret; hinge updates never trigger re-layout storms (throttle).
- App Store: Duo screenshots (outer 1398×2034, inner 2007×2853).

**P4 — Mac UX**
- Shortcuts for vault search, calendar, source/reading mode, inspector; check menus for parity; small polish found on the canvas pass.

**P5 — Product review**
- Written review (feature gaps vs Obsidian/Bear/Apple Notes, onboarding, sync clarity) with a ranked proposal list in `docs/plans/`. James picks what gets built; nothing in P5 ships without that.

## Interrogation (what could go wrong)
- **Riskiest step: P1.1 incremental index.** A missed delta = stale backlinks/search, which looks like data loss. Mitigation: keep the full rebuild as a periodic/idle consistency check, add property tests that compare incremental vs full rebuild on random edit sequences, keep a debug toggle to force full rebuild.
- Own-write filter could hide a genuine external edit made in the same second → compare content hash, not just mtime.
- Viewport styling on iOS was tried on Mac before and needed care (`2026-08-25-sidebar-animation-performance.md`): risk of unstyled text when scrolling fast → style a screenful either side, as macOS does.
- Duo: simulator may not reproduce stand/bent faithfully; hinge angle granularity is system policy (header says don't depend on it) → use `status` + reserved regions, not raw angles.
- Building with the 27.2 SDK may change iOS 26 behaviour (new SDK linking) → run on an iOS 26 simulator too.
- Rejected: rewriting the editor in TextKit 2 now (too large, separate project); a third-party Markdown parser (dependency rule); rendering the bent mode with two separate scenes (Apple steers to ArrangementView/reserved regions).

## Acceptance
- Baseline vs after table filled for every P1 item; `scripts/test-all.sh` green; new CI green.
- Canvas boards for P2/P3 (and P4 polish) published before their code.
- Simulator screenshots: iPhone, iPad, Duo folded / unfolded / bent; Mac.
- Fresh-context review subagent on each PR (report only).

## HUMAN QUEUE
- Install the iOS 27.1+ simulator runtime in Xcode (Settings → Components) so the Duo simulator can boot — currently only iOS 27.0 is installed. (Or confirm I may download it.)
- On-device test on your iPhone Duo for bent and stand postures (I'll give a short checklist).
- Approve releases (Sparkle / App Store) and pick P5 items.
- App Store Connect items seen today: China mainland security assessment + AIGC declaration (due 2027-01-31); accept the updated Paid Applications agreement.

## Benchmarks (measured)
| What | Before | After | How |
|---|---|---|---|
| Save round-trip on 10k notes (rescan + reindex) | 643 ms (scan 219 main-thread + index 421) | index 192 ms incremental, off main; tree rescan off main and only published if changed (autosave publishes nothing) | `INKSTONE_PERF=1 swift test -c release --filter VaultScalePerformance` |
| `resolve` over 39k links | 178 ms | 65–75 ms | same test, `SCALE resolveOnly` |
| `assemble` | 292 ms | 142–146 ms | same test |
| Per-keystroke styling, 88 KB note | 73 ms (iOS styled whole note) | 20 ms (viewport + ½ screen each side) | `INKSTONE_BENCH` + `INKSTONE_BENCH_WINDOW=6000`, -O build without sandbox (see note) |
| Sync local scan, 10k notes | 477 ms (read + hash every file) | 231 ms (size+mtime+ctime stamps; rest is enumeration + .gitignore) | same test, `SCALE syncScan` (page-cached files; cold disk gains more — unmeasured) |
| Word count | whole note recounted in `body` every keystroke | stored, refreshed 300 ms after typing pauses | — |

Note: the `INKSTONE_BENCH` hook is DEBUG-only and the app is sandboxed, so the benchmark build is Debug with `SWIFT_OPTIMIZATION_LEVEL=-O`, no entitlements, ad-hoc signed (`codesign --force --deep -s -`).
Follow-up found: the remaining ~16 ms per keystroke is the whole-document syntax scan (cache misses on every edit). Incremental scanning is its own project — logged for P1 follow-up, not done in this pass.
Behaviour fix found by the equivalence test: on a vault whose path contains a space, path-style links (`/Folder/note`) fell through to name matching and could resolve to a different note with the same name; they now resolve to the exact path (Obsidian's rule).

## Progress log
- 2026-11-18: plan written after code survey + SDK verification; James approved (all phases, runtime download OK, merge after green + independent review).
- 2026-11-18: P1.1 incremental index + string resolve + background tree refresh; P1.2 iOS viewport styling + debounced word count. 582 core tests green; macOS + iOS builds green. CI caught a reuse-window bug (margin measured from now, not from previous build) → fixed + mutation-verified. `scripts/test-all.sh` green. Draft PR #1.
- 2026-11-18: P1.5 sync hash stamps (586 tests). Duo simulator (iOS 27.2) boots; Device Hub drives Closed / Partially Open / Open; screenshots per display work (`simctl io … screenshot --display=<uuid>`; inner AA1D87E1…, outer 21E0C8A9… on this machine).
