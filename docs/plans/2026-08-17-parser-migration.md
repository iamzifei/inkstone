# Migrating the scanner to cmark-gfm — implementation plan

Started 2026-08-17. Follows the assessment in
`/Users/james/Dev/inkstone/docs/plans/2026-08-17-markdown-parser.md`, which
concluded the migration is worth doing. This file is the *how*, and is the
progress record — check items off here rather than re-scanning the repo.

Scope: **macOS desktop first.** The engine lives in `InkstoneCore`, which is
platform-agnostic, so iOS inherits it for free; but only the macOS editor gets
looked at and verified this pass.

---

## The shape of the change, in one sentence

`SyntaxScanner.scan(_:) -> [SyntaxToken]` stays exactly as it is as an interface,
and only its *implementation* is replaced — so the highlighter (1275 lines) and
the renderer (~420 lines) are not touched at all.

There are exactly three production callers:

| Caller | File |
|---|---|
| `MarkdownHighlighter` | `App/Views/Editor/MarkdownHighlighter.swift:23` |
| `LinkRewriter` | `Packages/InkstoneCore/Sources/InkstoneCore/Index/LinkRewriter.swift:22` |
| `Note` | `Packages/InkstoneCore/Sources/InkstoneCore/Markdown/Note.swift:49` |

Keeping the token stream as the contract is what makes this safe: the two
engines can run side by side over the same corpus and be diffed token for token.

---

## The open question, answered

> *Live preview's "reveal the source on the caret's line" is defined per token.
> In an AST, a caret inside `**bold**` inside a list item inside a blockquote is
> inside three nodes. Which one reveals?*

**All three, and that is already the behaviour today.** The question only looks
hard if the AST replaces the token stream. It does not — the AST *produces* the
token stream, and each node emits its own flat token with its own range.
`MarkdownHighlighter.apply` computes `isBeingEdited` per token by intersecting
the caret's paragraph with that token's range, so three nested nodes yield three
tokens that each independently decide to reveal. That is what happens now when
`**bold**` sits inside a quoted list item, and nothing about it changes.

No decision was needed. The question was an artefact of assuming a bigger
rewrite than the one being done.

---

## What was measured, not assumed (2026-08-17)

Probe: `Packages/InkstoneCore/Tests/InkstoneCoreTests/ProbeTests.swift`
(temporary — delete when this plan closes).

### 1. A cmark "column" is a **UTF-8 byte offset**, 1-based

Parsing `中文abc **粗体** tail`:

```
Text   @1:1-1:11   "中文abc "     ← 10 columns; "中文abc " is 10 UTF-8 bytes, 6 characters, 6 UTF-16 units
Strong @1:11-1:21  "**粗体**"     ← 10 columns = 2+3+3+2 bytes
```

Line total: 25 UTF-8 bytes, 17 UTF-16 units. So the conversion is
**UTF-8 byte offset → UTF-16 offset**, not character counting. This is the
"care around CJK" the assessment flagged; it is now a known quantity rather
than a risk.

### 2. The parse is at parity; the whole scan is not

The first measurement compared **cmark's parse alone** against the full legacy
scan and looked like parity. That was not a like-for-like comparison, and the
early conclusion drawn from it — "the performance concern dissolves" — was
wrong. The full engine, measured end to end in release on the 55 KB benchmark:

| Phase | Release |
|---|---|
| `SourceMap` build | 0.13 ms |
| cmark parse | 6.5 ms |
| AST walk + token emission | ~6.5 ms |
| Obsidian regexes | 2.5 ms |
| sort | 0.2 ms |
| **total, parser engine** | **~16–19 ms**, now **15.0 ms** after the visitor refactor below |
| **total, legacy engine** | **~6.5 ms** |

So it is **2.3× the scanner it replaces** after the refactor, not parity. Roughly
45% of what remains is cmark itself, which is C we do not control.

Two things were tried and measured rather than assumed:

  - `SourceMap` originally probed the text through `NSString.character(at:)`
    per character: **1.72 ms → 0.13 ms** after copying the text into a flat
    `[UInt16]` buffer once. Kept.
  - The suspicion that `map.text as String` at each call site was bridging and
    copying the whole document hundreds of times: **no measurable difference.**
    Swift's bridge back to a natively-originated string is O(1). Hypothesis
    tested, rejected, and the change kept only because it reads better.

The walk originally used an eight-case `as?` chain per node — a runtime
conformance lookup each time, measured at 1.7 ms of the 6.5 ms walk. It was
deferred until correctness was settled, then replaced with swift-markdown's
`MarkupVisitor`, where each node's own `accept` dispatches statically. That took
the 55 KB scan from **18.1 ms to 15.0 ms** — more than the 1.7 ms predicted,
because removing the recursion also removed the `inout` state passing and the
`markup as? InlineMarkup` test on every node. Verified behaviour-preserving by
the full suite *and* by re-running the attribute-level dumps: identical to the
legacy engine and identical to the pre-refactor parser output, line for line.

**Benchmark only in release, and only end to end.** Debug numbers are ~3× off,
and they are off *asymmetrically*: the legacy engine is almost entirely
`NSRegularExpression`, a precompiled system framework our build settings cannot
touch, so debug barely slows it (6.5 → 7.4 ms) while it slows the parser engine
by nearly 3× (16 → 45 ms). Neither the absolute numbers nor the ratio between
them survives a change of configuration.

### 3. Obsidian syntax is invisible to cmark, exactly as predicted

`[[wikilink]]`, `![[embed.png]]`, `#tag`, `==high==`, `$x^2$`, `[^1]` all land
inside a single `Text` node. `> [!note] Callout` parses as
`BlockQuote → Paragraph → Text "[!note] Callout"`. So the Obsidian layer keeps
its regexes — but now runs over `Text` node ranges the parser has already
isolated, so it can no longer misfire inside a code fence or a table cell.

---

## Files

```
Packages/InkstoneCore/Sources/InkstoneCore/Markdown/
  SyntaxScanner.swift      TokenKind / SyntaxToken / WikiLink — the contract. Unchanged.
                           `scan` routes to whichever engine is selected.
  SourceMap.swift          NEW. (line, UTF-8 column) → UTF-16 NSRange.
  DocumentScanner.swift    NEW. swift-markdown AST → block + GFM inline tokens.
  ObsidianSyntax.swift     NEW. The surviving regexes, scoped to given ranges.
  LegacyScanner.swift      The current 488-line regex scanner, moved, kept for diffing.
```

**Frontmatter is handled before parsing**, not by cmark: `---\n…\n---` parses as
a thematic break plus a setext heading and would corrupt everything after it.
The frontmatter range is detected first, emitted as its own token, and the
parse runs on the remainder with a constant **line offset** added to every
source position. Columns are unaffected, so this is exact.

---

## Stages

- [x] **0. Probe.** Column units, parse cost, what cmark can and cannot see.
- [x] **1. `SourceMap`.** UTF-8 column → UTF-16 offset, ASCII fast path.
      10 tests, including round-trips against the real parser on CJK and emoji.
- [x] **2. Block tokens from the AST.**
- [x] **3. GFM inline tokens from the AST.**
- [x] **4. Obsidian layer over prose regions.**
- [x] **5. Differential harness.** `EngineDiffTests`, 11 tests.
- [x] **6. Default flipped to `.parser`.** 159 tests green in debug *and*
      release.
- [x] **7. Looked at the macOS app.** See below.
- [ ] **8. Delete `ProbeTests`** — done. **`LegacyScanner` deliberately kept**;
      see "Decisions" below.

## What the differential harness found

Both engines over the sample vault and 23 constructed documents. After the port,
the token streams are **identical** except for the differences listed here, each
of which is pinned by its own test so a reversion fails as loudly as an
unexplained diff would.

The parser is right and the old scanner was wrong:

| Difference | Why it happened |
|---|---|
| **A heading, list item or quote containing `` `code` `` was dropped entirely** | The old scanner masked inline code *before* looking for block constructs, then skipped any match touching the mask. `### Three with \`code\`` rendered as body text. A whole class of bugs, not one. |
| `_underscore_` emphasis was never found | The old pattern matched `*` only. |
| Setext headings (`Title` over `=====`) were never found | The old heading pattern is ATX-only; the `---` form was rendered as a horizontal rule. |
| A GFM table without outer pipes was never found | The old pattern required them, because without parsing it could not tell a table from prose containing a `|`. |
| `#tag` inside an **indented** code block was indexed as a tag | The old scanner had no pattern for indented code at all. |
| `a * b \`c * d\` e` matched as emphasis across the code span | The old inline patterns did not know where code spans were. |

Deliberate changes where the parser disagrees with the old behaviour:

| Difference | Verdict |
|---|---|
| `\t- item` with no list above it is an **indented code block**, not a list at nesting level 1 | CommonMark. The old regex matched the bullet anywhere. Only bites for a malformed orphan item; a tab-indented item *under* a list still nests, which is the case that occurs in real vaults. Two existing tests were rewritten to use a parent item, with the reason recorded in them. |
| Obsidian task states | cmark reports only GFM's `[ ]` and `[x]`. `[/]`, `[-]`, `[✓]` are read from the text instead, so Obsidian's extended states keep working. |
| `[^id]: …` footnote definitions | cmark consumes them as CommonMark **link reference definitions** — `[^why]: Because.` is a valid one — and then resolves `[^why]` elsewhere into a shortcut reference *link*. Both halves are special-cased back. This was found by the diff, not by reasoning. |
| Table token range | cmark ends the node on the last cell's pipe; the old regex took the trailing newline. Matched to the old bound rather than tidied, because that is the one that has been looked at on screen. |

## Stage 7 — what was actually verified in the app

Not "it builds". A debug-only `INKSTONE_SCANNER=legacy` hook was added to
`MarkdownHighlighter` so the two engines can be compared through the
**highlighter**, on the attributes that reach the screen, rather than only on
the token stream. Using the existing headless dump hooks on a document
containing every construct:

  - `INKSTONE_INDENT_DUMP` — paragraph indents, head indents, kerning:
    **byte-identical** between engines, line for line.
  - `INKSTONE_CONCEAL_DUMP` — which marker lines collapse and to what height:
    **byte-identical**.
  - `INKSTONE_CHECKBOX_DUMP` — checkbox state across all three caret positions:
    **byte-identical**.
  - `INKSTONE_CARET_DUMP` — laid out through a real `NSLayoutManager`. The only
    difference in the whole document is the h1, which the old engine sized at
    18.8pt (body) because its title contained a code span, and the new engine
    sizes at 36pt. Every following line is offset by exactly 55.4pt and nothing
    else changes. The legacy bug, confirmed at layout level.

Then the app itself, run against a scratch vault and screenshotted: headings
with rules, collapsed frontmatter, bold/italic/underscore-italic/strikethrough/
highlight, inline and display maths, wikilinks, embeds, real checkboxes with the
done item struck through, nested bullets at 22/44/66pt, ordered list hanging
indent, blockquote rules and nesting, a callout with its `[!warning]` collapsed,
a table drawn as one panel with columns aligned and the delimiter row collapsed,
a fenced block whose `#nottag [[notlink]]` is correctly *not* highlighted, a
thematic break, a raised footnote marker, and CJK-Latin spacing.

## Decisions

**`LegacyScanner` stays.** The plan said delete it. It is 488 lines of code
unreachable from the app — but it is the oracle `EngineDiffTests` compares
against, and that harness is the only thing that would catch a silent
regression in a construct nobody has a unit test for. Delete it after a release
cycle in real use, not before.

**The open question about caret reveal needed no answer** — see above. It was an
artefact of assuming the AST would replace the token stream.

## Acceptance

1. ✅ `swift test` green — 159 tests, debug and release.
2. ✅ Differential harness reports zero unexplained token differences; all 10
   explained ones are pinned by tests.
3. ✅ **Met, after the visitor refactor.** 55 KB scans in **15.0 ms** in release
   (the criterion was < 16 ms), against 6.5 ms for the scanner it replaced. It
   was 18–19 ms before the refactor. What the criterion was standing in for —
   typing latency — is separately and much more decisively better than before
   the port; see "Follow-up" below.
4. ✅ macOS app verified by screenshot and by attribute-level diff, not by
   inference.

## Follow-up, same day: the keystroke path

The port left one acceptance criterion unmet — 55 KB scanning in 16–19 ms rather
than under 16 — and the plan said the real fix was not to make the scan faster
but to stop scanning the whole document on every keystroke. Looking at the
editor rather than the engine showed it was worse than that:

  - `textDidChange` ran a full pass, **and** `textViewDidChangeSelection` ran
    another. Typing one character did the whole thing twice.
  - Every arrow key, every click, every drag-selection ran a full pass — in
    source and reading mode too, where the caret changes nothing at all.
  - Scrolling, resizing the window, and a Mermaid diagram finishing each ran a
    full scan of unchanged text.

Two changes, neither of them architectural:

1. **`CachingScanner`** (`Packages/InkstoneCore/Sources/InkstoneCore/Editor/CachingScanner.swift`)
   — remembers the last document and its tokens. Anything that re-highlights
   text that did not change now costs nothing to scan.
2. **`CaretLineTracker`** (`Packages/InkstoneCore/Sources/InkstoneCore/Editor/CaretLineTracker.swift`)
   — live preview's only dependency on the selection is *which line* the caret
   is on, so a selection change that stays on one line skips the pass entirely.

Both live in `InkstoneCore` rather than in the editor coordinator specifically so
they can be tested: the coordinator is `@MainActor`, wrapped around a platform
text view, and has no test target. 13 tests between them, including the ones that
matter — that the cache never returns another document's tokens, and that moving
the caret to a *new* line is never skipped.

### Measured in the running app, not inferred

Same workload both times — 10 keystrokes then 10 arrow keys on a 56 KB note,
driven through System Events, debug build, with `INKSTONE_NO_SCAN_CACHE` and
`INKSTONE_NO_SELECTION_GUARD` reproducing the old behaviour in the same binary:

| | before | after |
|---|---|---|
| highlight passes | 31 | 21 |
| full document scans | 31 | **10** |
| total main-thread highlight time | 1548 ms | **624 ms** |
| **median pass** | **53.2 ms** | **5.5 ms** |

The median is the one that is typing latency, and it is ~10× better in debug —
where the parser engine is at its worst. Two passes per keystroke remain, because
AppKit posts the selection notification before the text notification and the
caret line legitimately changed length; the second is a cache hit.

Two measurement notes, because both nearly produced a wrong answer:

  - The first A/B compared trials where different numbers of keystrokes had
    actually landed (18 vs 0). The numbers looked like a result. They were not
    comparable at all, and the run was thrown away rather than explained.
  - Synthetic clicks focus the editor only intermittently, so an attempt to
    verify caret reveal through the GUI showed "no reveal" — which looked like a
    regression from the new guard. Running the *same binary* with the guard
    disabled showed exactly the same thing, so the click was at fault, not the
    change. That is why the guard is verified by unit test instead.


## Follow-up: tables render as tables

The assessment's stated payoff for parsing was structure — "**tables as Head /
Body / Row / Cell**… real column layout is possible from a structure and is not
possible from a regex that matches pipes". The port delivered the structure and
then kept drawing tables the old way, so nothing changed on screen: monospaced
code font, the `|` characters left visible, the code-block background, the code
block's copy button. James looked at the render-test document and said,
correctly, that tables were being shown as code blocks — which is what they were
being styled as.

What changed:

  - The `|` characters are concealed like every other piece of syntax, and
    reappear on the row the caret is on.
  - Cells use the body face. They were monospaced only because that was the sole
    way to line columns up while the pipes were on screen; the columns are
    positioned by measured kerning, so the constraint had already gone.
  - `runFont` no longer switches to the code face for runs inside a cell. It had
    to, when a bold word in a cell would otherwise break the column.
  - A new `.inkstoneTableBlock` attribute tells the renderer to paint table
    chrome — a tinted header band, hairlines between rows, and a border —
    instead of a code panel. `.inkstoneBlockFill` stays on the block so the copy
    button and its hit test are untouched.
  - Column widths gain a gutter, since the pipes that used to separate them are
    now invisible and the source's single spaces are not enough.

Two bugs the same document exposed and that were fixed with it:

  - **A GFM table written without outer pipes** (`A | B`) kept its pipes and was
    never aligned: the cell splitter required a leading `|`. Cells are now the
    runs *between* the pipes with the row's own edges standing in for the outer
    ones, which handles both forms.
  - **The cell-width cache was keyed by the string alone.** Harmless while every
    table used the one code font, and wrong the moment the face changed. Now
    keyed by face and size too.

## Follow-up: two things the render test caught after that

**The table bands did not line up with their own text.** The row bands and
separators were drawn from line *fragment* rects. Measured with a dump added for
the purpose rather than reasoned about:

```
fragment= 114.60..149.80 (h 35.20)   used= 124.20..149.80 (h 25.60)   | Feature | State |
fragment= 149.81..175.41 (h 25.60)   used= 149.81..175.41 (h 25.60)   | Tables | works |
fragment= 175.41..210.61 (h 35.20)   used= 175.41..201.01 (h 25.60)   | Alignment | works |
```

A block's outer margin — `paragraphSpacing`, 9.6pt here — lives *inside* the
first and last fragments of the block. So the header band carried 9.6pt of
margin above the header text and the separator sat hard against its underside.
The chrome now comes from the **used** rects, which are the glyphs' own boxes and
contain no margin.

**An image on a line with words was painted over them.** The embed took the whole
line's height and was drawn centred in it while the words kept their baseline.
This had been noted in the sample as a "known limitation" — which was the wrong
call: it is a defect, and labelling it did not make it less of one. An embed that
shares its line with text is now drawn as a thumbnail at 1.4× the text size,
using the same reservation trick as an inline formula (collapse the markup, add
the picture's width as kerning, paint into the gap). An embed alone on its line
is still a block image.

## Follow-up: the table bands, third attempt

Two earlier fixes each used a rect that *looked* like the right one, and each was
reported back as still wrong. Measured with a pixel analysis of a screenshot
rather than judged by eye:

| rect used | space above the header text | below |
|---|---|---|
| line **fragment** | carries the block's 9.6pt outer margin | — |
| line **used** rect | 18px | 5px |
| **baseline ± font ascender/descender** | 15px | 15px |

The line fragment carries the block's outer margin inside its first and last
rows. The used rect drops that but is still the *line box*, and with an explicit
`maximumLineHeight` TextKit puts all the leading above the text and sits the
glyphs on the bottom edge. Only the baseline plus the font's own ascender and
descender says where the glyphs actually are.

Body rows measure 16px above and 14px below, the 2px being the descender: the
band is centred on the font's em box rather than on the visible ink, so rows do
not jitter depending on whether their text happens to contain a `g`.

**The copy button follows the same rectangle.** James asked for this before it
was broken. `copyButtonRect` now consults `tableGeometry` too, which matters
twice over: it is the drawing position *and* the hit test, so a button drawn in
one place and hit-tested in another would be visible and dead.

*Not verified: that the copy button can be clicked.* Synthetic clicks do not
reach the text view's mouse handling in this harness — a code block's button,
whose geometry this change did not touch, fails identically. Drawing and hit test
call the same function, so they cannot disagree, but that is a structural
argument rather than a test.

## Follow-up: the outline jumps

The sidebar already had an outline pane listing the open note's headings. It was
not clickable, which made it a list of headings rather than a table of contents.

Each row is now a button. The route from the sidebar to the editor is a
`Workspace.RevealTarget` — url, range, and a token that makes a repeated request
for the same heading distinct — which `NoteEditorPane` passes down and the
platform coordinator consumes in `updateNSView`/`updateUIView`. The range is
clamped to the current text, because the ranges come from the index and a note
with unsaved edits can hand back one past the end.

No explicit re-highlight afterwards: moving the caret posts a selection change,
and `CaretLineTracker` decides from there whether a pass is needed. On iOS the
caret is placed without `becomeFirstResponder()`, so jumping to a section does
not throw the keyboard up over it.

## Follow-up: tables — spacing, overflow, and measuring what is drawn

Three problems, reported together against a real note rather than the sample.

**Rows were cramped.** The table used the body line-height multiple, and CJK
glyphs are taller than the Latin ascender box the bands are centred on, so text
nearly touched the separators. Table rows now use `lineHeightMultiple * 1.25`.

**Text escaped the box.** Rows were `.byClipping`, which does two bad things at
once: `tailIndent` has no effect without line breaking, so a row ran to the
*container* edge — which is outside the border, since the panel is inset from it
— and everything past that point was simply lost. Rows now wrap by character
(`.byCharWrapping`; a Chinese row has no spaces to break on). A wrapped row is
still one row: `tableGeometry` groups line fragments by source line, so a
separator is never drawn through the middle of one.

An attempt to prevent wrapping by refusing to align when the table was too wide
was tried and reverted: the columns of a table that needed one wrapped row
collapsed into a run of words separated by single spaces, which was worse than
the problem. The gutter is still dropped when the table is over budget, which
wraps less without losing the alignment.

**Columns drifted on rows with inline formatting.** Cell widths were measured
from the raw characters in one font. A cell containing `**bold**` therefore
measured too narrow where the bold draws wide, *and* too wide where the `**`
collapses to nothing — so every cell after it in that row was pushed out of its
column. Since this pass runs last, after every font and concealment is applied,
the cell can be measured from the storage instead: `attributedSubstring(from:)`
is literally what TextKit will lay out.

That is dearer than measuring a plain string — 55ms a pass on a synthetic
document of 200 tables — so a cell that is a single run of the body face still
takes the old cached path, and only cells that actually differ pay for it: 47ms
on the same document, 0.8ms on a real note.

### Two things that turned out not to be bugs

Both were reported or observed, and both would have led to a "fix" to working
code:

  - **Pipes visible on one row of a table.** That row had the caret on it, and
    revealing source on the caret's line is the rule every other construct
    follows. Confirmed by rendering the same document with no caret: no pipes.
  - **A stray copy button beside a heading, and a missing table**, in the
    offscreen dump. The dump's text container was a fixed 900pt tall, so the last
    block was never laid out. Both vanished when the container was made tall
    enough. The harness was wrong, not the app — the second time this session
    that the harness has been the thing at fault.

## Follow-up: the copy button had no feedback, and the outline was hidden

**The copy button gave nothing back.** No cursor change, no hover state, no
confirmation — three separate reasons to read it as a picture rather than a
control, and no way to tell whether a press had done anything. It now has all
three: a pointing-hand cursor, a darker ground and stronger stroke under the
pointer, and a tick in the accent colour for 1.1s after a copy. Hover state lives
on the text view rather than in the text's attributes: neither is a property of
the text, and putting them in the storage would mean a document-wide
re-highlight every time the pointer crossed a corner.

**The outline was in the left sidebar's fifth tab, and James looked for it in the
inspector.** That is the more reasonable place: the inspector is the panel that
answers "what is in the note I am looking at" — properties, tags, backlinks,
outgoing links — and an outline is the same kind of thing, where the sidebar's
other tabs are vault-level. It is now in both.

### On verifying this

The three button states were rendered **offscreen**, through the same drawing
code, into PNGs via a debug hook. That is not a stylistic choice:

Earlier attempts to verify by driving the pointer failed repeatedly and then
failed badly. Synthetic clicks — first `System Events`, then real `CGEvent`s —
never reached the text view's mouse handling, and a control experiment on a code
block's button (geometry untouched) failed identically, which is what showed the
harness was at fault rather than the change. Then a screenshot revealed why: the
frontmost window was no longer Inkstone. **The clicks had been landing in
whatever the user had in front, on their own machine.** One went into a page of
their energy account.

The rule that follows: do not drive the pointer on a machine someone is using.
Offscreen rendering through the same code answers the same question, and a debug
hook that renders to a file can be run a hundred times without touching anything.

That hook also caught itself out once — `NSImage.lockFocus` is unflipped where
`NSTextView` is flipped, so the first dump drew the tick upside down. The tick
was correct all along; the harness was not. Worth stating, because "the image
looks wrong" was one step away from a fix to code that had nothing wrong with it.

## Follow-up: two heading regressions the render test caught

Both were introduced by the port, both invisible until a document used the
syntax, and both are in `MarkdownHighlighter`, not the parser:

  - **Setext headings** (`Title` over `=====`) drew their underline as part of
    the title, at title size — a row of giant equals signs under every such
    heading. The old scanner never recognised setext at all, so this was new.
    Recorded in the diff harness as a "known cosmetic difference to revisit" and
    then not revisited; the render test is what made it visible.
  - **Closed ATX headings** (`### Title ###`) left the trailing hashes behind as
    body text, because cmark reports them outside the heading node.

## Follow-up: two gaps the render test found and reported, then closed

Both were surfaced by the sample document, written down as findings rather than
fixed at the time, and left in the report as "observations, not fixed". Closing
them is what "continue" meant.

**`![[photo.png|300]]` was parsed and then discarded.** `WikiLink` has carried
the hint since the scanner was first written — the doc comment on `alias` even
says "for embeds this doubles as a size hint" — and the highlighter loaded every
embed at the full measure regardless. The parsing now lives in
`WikiLink.embedSize`, where it is tested, and the distinction that makes it
delicate is the point of those tests: the same pipe means *display text* on an
ordinary wikilink, so `![[Meeting|notes]]` must not be read as a zero-wide embed.
Sizes are capped at the measure, `300x200` is honoured as an exact box rather
than a width with a derived height, and the picture is resized to match — the
cache buckets by 32pt and never scales up, so it answers "no wider than" rather
than "this wide".

**Obsidian's extended task states all drew as finished.** `[/]` in progress,
`[-]` cancelled, `[>]` deferred, `[<]` scheduled, `[?]`, `[!]`, `[*]` — every
non-blank state rendered as a ticked box with its text struck through, which is
the one distinction a task list exists to make. The `.inkstoneCheckbox`
attribute now carries the state *character* rather than a Bool; `contentRange`
was already exactly that character, so nothing in the token contract changed.
Done and cancelled read as finished; everything else keeps its text unstruck,
because an item in progress is still work.

While fixing the first: the offscreen dump could not show images at all, because
the benchmark hook never set `resolveAttachment` and every embed resolved to
nothing. It now resolves against the benchmarked file's own folder.

## Follow-up: code blocks got the table's geometry

A code block's panel was still drawn from the line fragments, so it inherited the
same fault the table had — the block's outer margin sits inside the first
fragment and almost nothing sits inside the last, which put the opening line
further from the edge than the closing one. Its text was inset 8pt where a table
cell is inset 12, so a code block and a table next to each other started their
text in different places.

Both now come from `blockRows`, the ink measurement the table fix introduced,
with a fixed 10pt of padding. Measured on screen: 9.5pt above the first line,
9.0pt below the last. Horizontal inset is the same constant the table uses.

`copyButtonRect` follows the code panel too. That is the same trap as before and
worth stating twice: the function is both the drawing position *and* the hit
test, so a panel moved without it produces a button drawn in one place and
clickable in another.

## What is still left

**Typing latency is now dominated by attribute application, not scanning.** A
5.5 ms median pass on a 56 KB note in debug is comfortable; the remaining scan
still happens on the main thread once per keystroke, and on a much larger note
that would still be felt. If it ever needs to go further, the options are
unchanged: scan on a background actor, or reparse only the block the caret is
in. Neither is needed yet, and neither should be done speculatively.

Smaller, still available:

  - The second pass per keystroke could be eliminated by having the selection
    callback defer to `textDidChange` when the text has changed. Worth ~2 ms in
    release; not taken, because the guard would then depend on the ordering of
    two AppKit notifications, and stale attributes are a worse failure than a
    redundant pass.
  - ~~The `MarkupVisitor` refactor~~ — done, and worth 3.1 ms rather than the
    1.7 ms predicted.

## iOS

The engine lives in `InkstoneCore`, so iOS inherited it with no iOS-specific
work, and the `CaretLineTracker` guard was wired into the UIKit coordinator at
the same time as the AppKit one. Verified on an iPhone 17 Pro simulator
(iOS 26.3) rather than assumed: the same construct-heavy documents render
identically to macOS — heading containing a code span (the legacy bug, fixed),
underscore emphasis, checkboxes with the done item struck through, nested
bullets, ordered list, blockquote nesting, inline and display maths, highlight,
raised footnote marker, CJK-Latin spacing, callout, table drawn as one panel with
columns aligned and the delimiter row collapsed, a fenced block whose
`#nottag [[notlink]]` is correctly not highlighted, thematic break, block
identifier, and footnote definition.

## HUMAN QUEUE

Nothing. Stage 7 was completed on this machine — screen capture works and the
`RenderBox` crash in `HANDOFF.md` §4 did not reproduce.
