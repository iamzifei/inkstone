# What is fake, what is slow, and what needs doing

**Audited 2026-08-25**, macOS and iOS, against the 8,852-note vault at
`~/Dev/詹有才`. Every figure below is a measurement from a release build, not an
estimate. Nothing here is a guess about what *might* be slow.

There are **no `TODO`, `FIXME` or `HACK` markers anywhere in the codebase** — so
none of what follows was labelled. It was found by comparing declared surface
against actual readers.

---

## 1 — Settings that do nothing

Found by listing all 53 `SettingsData` properties and checking which have no
reader outside `AppSettings.swift` and `SettingsView.swift`. **Six have a visible
control in Settings that is wired to nothing**, and one is a field with no
control at all.

| Setting | Control | What actually happens |
| --- | --- | --- |
| `autoPairBrackets` | "Auto-close brackets and quotes" | The behaviour exists and is **unconditional**. Turning it off changes nothing. |
| `smartLists` | "Continue lists on Return" | Same — `listContinuation` runs whatever the switch says. |
| `indentWithTabs` | toggle | Nothing reads it. |
| `tabSize` | "Tab size: n" stepper | Nothing reads it. |
| `useShortestPathLinks` | toggle | Nothing reads it. New links are always written one way. |
| `newLinkFormat` | wikilink / markdown picker | Nothing reads it. |
| `showLineNumbers` | *(no control)* | Dead field. |

This is the same class of defect as `showFrontmatterAsProperties`, which was on
by default, had a toggle, and was read by nothing until 2026-08-25.

**Severity: high for trust, low for effort.** A switch that lies is worse than a
missing feature. Each is either a few lines to honour or a few lines to remove;
the two indentation ones and the two link-format ones are real features that were
never finished.

**Not dead, checked and cleared:** `themeID` is read inside `AppSettings.swift`
itself (`availableThemes.first { $0.id == data.themeID }`), which the first pass
flagged as a false positive.

---

## 2 — Search freezes the app, and it is the worst thing in it

`SearchPane.runSearch()` is called from `.onChange(of: workspace.searchQuery)` —
**every keystroke** — and calls `SearchEngine.fullText` **synchronously on the
main actor**. That function reads every note in the vault off disk.

Measured, release build, 8,852 notes:

| query | time | why |
| --- | --- | --- |
| `zzzznotfound` | **783 ms** | matches nothing, so it reads all 8,852 files |
| `认知` | **268 ms** | stops at the 200-hit limit |
| `a` | 1 ms | hits the limit almost immediately |

The 200-hit early exit is what saves the common case. It does not save the case
that matters: **while you are typing the first characters of a real query, every
prefix matches nothing**, so a five-character search costs several seconds of a
frozen window.

The quick switcher (⌘O) has the same shape without the disk reads:
**`quickSwitch` is 100 ms per keystroke**, also on the main actor. Typing is
noticeably behind.

**There is no debounce anywhere in either path.**

Fix: move both off the main actor, debounce by ~150 ms, and cancel the in-flight
search when the query changes. The search itself does not need to get faster —
it needs to stop being in the way.

---

## 3 — Reading mode is not a mode

`EditorMode.reading` has exactly one effect in the whole codebase:

```swift
textView.isEditable = mode != .reading
```

Plus turning off the spell checker. It renders identically to live preview. The
tooltip written on 2026-08-25 now says so honestly rather than implying a
renderer, but the README still lists it as "⚠️ falls back to live preview" and
the mode picker still offers three buttons where there are two and a half.

swift-markdown already parses every note into an AST that nothing renders. That
AST is the reading renderer, unbuilt.

---

## 4 — What silently does nothing on iOS

| Feature | On iOS |
| --- | --- |
| **Footnote jump** | Tapping `[^1]` finds its destination and then does nothing — the scroll is inside `#if os(macOS)`. A silent no-op. |
| Split view | Absent by design, and documented. |
| Custom selection drawing | macOS only by design — UIKit gives no way to suppress its own, and two selections is worse than one. |
| Reveal in sidebar | Hidden at compact width as of this audit; it shipped visible on iPhone, where there is no sidebar on screen to reveal into. |

---

## 5 — Costs that are fine now and will not stay fine

| | now | shape |
| --- | --- | --- |
| `IndexSnapshot.outgoing(from:)` | 0.15 ms/call at 1,004 edges | filters **every** edge, O(E) per call, called per note opened. A vault with heavy linking makes this the inspector's cost. `incoming` is a dictionary and does not have the problem. |
| `notes(taggedWith:)` | fine | filters all notes per call |
| Full reindex | 690 ms, 8,852 notes | off the main actor, cancels the previous run. Correct. |
| Path auto-linking scan | ~1 ms/screenful release | linear, tested |

`outgoing` wants the same treatment `incoming` already has: build it once into a
dictionary when the snapshot is assembled.

---

## 6 — Smaller things

- **Three `print()` calls ship in release builds** — `InkstoneApp.swift:618`
  (`[demo] seeded sync binding`), `BackgroundSync.swift:240` and `:323`. Should
  be `Logger`, or `#if DEBUG`.
- **One `try!`** — `MarkdownEditorView.swift:1187`, a regex literal. It cannot
  fail with a constant pattern, but it is the one force-unwrap in the app and a
  `static let` built once with a fallback costs nothing.
- **iCloud entitlement still deferred.** Honest in the README; the container has
  never been created, so `createICloudVault()` shows an alert.
- **No plugin API**, no Android, no Publish equivalent. All three are stated
  plainly on the website's comparison page; none is a hidden gap.

---

## What I would do, in order

1. **Debounce and de-block search and the quick switcher.** It is the only thing
   here that makes the app feel broken, and it costs the least to fix.
2. **Honour or remove the six dead settings.** A lying switch is a trust problem,
   and `autoPairBrackets`/`smartLists` are one line each to honour.
3. **Build the reading renderer** on the AST that is already parsed, or drop the
   third mode.
4. **Make `outgoing(from:)` a dictionary** before a vault appears that needs it.
5. Footnote jump on iOS; the three `print`s; the `try!`.

## What happened to all this

Items 1–5 were done on 2026-08-25 and shipped in 0.1.3 — the search, the six
settings (all honoured, none removed), the reading renderer and the `outgoing`
dictionary. Written up in
[`2026-08-26-audit-followup.md`](2026-08-26-audit-followup.md).

**Still open, all of it from §6:**

| | where |
| --- | --- |
| Three `print()` calls ship in release | `InkstoneApp.swift:618`, `BackgroundSync.swift:240` and `:323` |
| One `try!` | `MarkdownEditorView.swift:1286` |
| Footnote jump does nothing on iOS | `MarkdownEditorView.swift:358` — the scroll is inside `#if os(macOS)` |

None of them is user-visible except the last, and none was in the batch that was
asked for. Together they are a few minutes' work.

## HUMAN QUEUE

- The three above: worth doing, not worth a release of their own. They can ride
  along with whatever ships next.
