# Two remaining items: real table layout, and HTML — 2026-08-17

> **Outcome: T1 and H2 built the same day.** T2 and H3 remain unstarted and
> unblocked. The options below are kept as written, including the reasoning that
> turned out to need correcting — see "What the phone changed" at the end.

Options, not a commitment. Written after the cmark-gfm migration closed, for the
two things left on its "what is still left" list. Both were called out there as
being a different size from everything else, and both turn out to be the *same*
decision asked twice.

## The decision behind both

Inkstone has one load-bearing invariant: **the text storage is the file**. Every
feature is either

  1. **styled in place** — the source stays on screen and gains attributes, with
     the syntax characters collapsed to 0.01pt; or
  2. **concealed and replaced** — the source is hidden, height or width is
     reserved, and something else is drawn into the gap.

Both already exist. (2) is not exotic here: inline images, Mermaid diagrams,
typeset formulas and `[TOC]` all work that way, and `MermaidRenderer` already
solves the hard parts of the WebKit variant (offscreen windows, snapshot timing,
dark mode).

So the question for tables and for HTML is not "is it possible". It is **which
constructs have earned the move from (1) to (2)**, given what (2) costs: text
inside a replaced block is no longer selectable, clickable or editable unless
each of those is rebuilt by hand.

---

## Tables

### Where it stands

Cells are positioned by adding `.kern` to the last character of each cell so the
next one starts at the column's x. Pipes are concealed. A row too wide for the
measure wraps by character rather than being clipped. Widths are measured from
the storage, so bold and concealed markers are accounted for.

That is as far as (1) goes, and it is genuinely good inside the measure. Three
things it cannot do:

  - **Wrap inside a cell.** A paragraph is one flow; a wrapped row continues at
    the paragraph indent, across the full width, not within its column.
  - **Shrink a column.** Widths are max-content. There is no way to give a long
    description column less room and let it wrap.
  - **Vary height per cell** — an image or a display formula in a cell.

And one thing it *should* already do and does not:

  - **`|:--:|` alignment is parsed by cmark and never read.** `Table.alignments`
    is referenced in a comment and nowhere else, so the sample's "left, centre,
    right" table renders entirely left-aligned.

### T1 — Finish the in-place version

Alignment, and better behaviour when the table does not fit.

Alignment is cheap and falls out of the existing mechanism: the padding that
makes a column line up is currently added *after* a cell. Add it **before** the
cell instead and the cell is right-aligned; split it and the cell is centred. No
new drawing, no new attribute — the same kerning, applied at the other end.

Fitting is harder but bounded: when the aligned width exceeds the measure,
distribute the shortfall across columns by their content rather than dropping
the gutter wholesale, so the widest column gives up the most.

  - **Effort:** about half a session.
  - **Risk:** low. Everything stays editable, selectable and clickable.
  - **Ceiling:** unchanged. Still no wrapping inside a cell.

### T2 — Draw the table

Conceal the table's source, lay each cell out in its own container, and draw the
grid. This is mechanism (2), and it is what "real column layout" means.

  - `TableLayout` in the app layer: source + alignments + measure + style →
    column widths (min-content/max-content, the CSS algorithm), row heights,
    per-cell attributed strings and their rects. Cached by those inputs; a table
    changes far less often than the document is highlighted.
  - The highlighter conceals the table's lines and reserves the computed height,
    exactly as `inlineImage` does for a picture.
  - `EditorRenderer` draws the cells and the chrome from the cached layout.

**The editing story is what makes this viable.** Obsidian solves it with a real
editable table widget; we do not have to, because live preview already reveals
source on the caret's line. Extend that to the block: caret anywhere inside the
table → fall back to the current in-place rendering, which is exactly what T1
improves. **T1 is not throwaway work if T2 happens — it becomes T2's editing
view.**

What T2 costs beyond the layout itself:

  - **Clicks.** A `[[wikilink]]` or `#tag` inside a drawn cell stops being
    clickable unless the cell rects are kept and mapped back to source ranges.
    Doable — the layout knows both — but it is real work, and forgetting it is
    the kind of regression that gets noticed a week later.
  - **Selection.** Dragging across a drawn table selects concealed source, so
    the selection highlight will be wrong. Obsidian has the same problem and
    answers it with the widget. We would answer it by revealing source, which is
    the caret rule again — but a *drag* that starts outside the table is not a
    caret landing inside it, and that case needs deciding.
  - **Cost per pass.** Layout cached, drawing not. Needs measuring on a document
    of many tables before it ships, the same way the scan was.

  - **Effort:** 2–3 sessions, and the second one is the click/selection work
    rather than the layout.
  - **Risk:** medium. The layout is self-contained and testable; the interaction
    is where it can go wrong quietly.

### Recommendation

**T1 now, T2 only if a real note needs it.** Alignment being silently dropped is
a defect, not a limitation, and it is half a session away. The wrapping ceiling
has a workaround every Markdown author already knows — shorter cells — and T2's
cost is mostly in the parts that are not the table.

If T2 is wanted, it should be scoped as its own piece of work with the click and
selection behaviour decided **before** the layout is written, not after.

---

## HTML

### Where it stands

`InlineHTML` and `HTMLBlock` are handled nowhere. cmark reports both, the walk
has no case for either, and their text falls through as prose — so `<b>bold</b>`
is on screen as five extra characters, and a `<div>` block is three lines of
source.

### H1 — Leave it

Defensible. HTML in a Markdown note is usually one of three things: `<br>`,
`<div align="center">`, or an `<img>` that a wikilink embed already covers.

### H2 — Conceal the tags of a whitelist, style the content

cmark gives `InlineHTML` nodes **with their ranges**, so this needs no regex and
cannot misfire inside code. Emit a token per tag, pair opener with closer in the
highlighter, conceal both, and apply the attribute the tag maps to:

| tag | attribute |
|---|---|
| `<b>` `<strong>` | bold |
| `<i>` `<em>` | italic |
| `<u>` | underline |
| `<s>` `<del>` | strikethrough |
| `<mark>` | highlight |
| `<code>` | code face |
| `<sub>` `<sup>` | baseline offset |

Anything not in the table stays as source — the same floor-does-not-move rule
the entity table uses. Nesting works, because each tag conceals itself and the
attributes accumulate.

  - **Effort:** half to one session.
  - **Risk:** low. No WebKit, no new drawing mechanism, and an unpaired tag
    simply styles nothing.
  - **Does not cover:** `<br>` (cannot insert a line break without changing the
    buffer), attributes such as `style=`, and block HTML.

### H3 — Render block HTML through WebKit

`HTMLBlock` → snapshot → conceal → reserve height, reusing `MermaidRenderer`'s
pipeline, which has already paid for the offscreen-window and snapshot-timing
problems.

  - **Effort:** about a session.
  - **Risk:** medium, and mostly not technical. It puts WebKit on the path of
    ordinary notes rather than just diagrams: memory per block, async first
    paint, a second theme to keep in sync, and a sandbox surface. The
    `HANDOFF.md` RenderBox crash is a reminder that pulling more of the system's
    rendering stack into the editor has a tail.

### H4 — Render HTML properly

No. That is a browser.

### Recommendation

**H2, and stop there.** It covers what people actually type, costs little, and
carries no WebKit. Block HTML stays as source, which is honest — it is showing
you exactly what is in your file.

---

## If both were done

T1 + H2 is roughly one session and closes both items at the level that matches
how the constructs are actually used. T2 and H3 are each a separate piece of work
with their own decisions to make first, and neither is blocking anything.

## What the phone changed

James's answer to the open question was the useful part: wide tables are not
common, **but the phone is half the width**. So the question was measured rather
than argued — the same documents rendered at 370pt, which is what an iPhone 17
Pro gives after insets.

The result was not what either of us assumed. **Ordinary tables fit on a phone.**
All four in the sample render at 370pt with their columns intact. What does not
fit is a table of four prose columns — and there, the thing making it *worse* was
the alignment padding itself, which ate the width the rows needed and turned each
into three lines.

That reframed T1's fit rule from a tidy-up into the main point:

> **When no arrangement can fit, stop aligning.** The test is the widest row's
> *natural* width — what it takes with no padding at all. If even that exceeds
> the measure, columns cannot line up however the padding is distributed.

This is the third version of that rule. The first kept alignment always and let
rows wrap; the second dropped it whenever the *aligned* width was over, which
fired on tables that merely needed one wrapped row and collapsed their columns
for nothing. Testing the natural width tells those two situations apart, and the
evidence is two renders of the same table at 700pt: the old rule wrapped all five
rows, the new one wraps only the row that is genuinely too long — ten lines
against six.

**Dropping the alignment on its own was not enough, and shipping it that way was
a mistake.** With no padding, cells ran together separated by a single space and
the header read as a run of words — James's report was that the table "no longer
shows columns", which is exactly right. Losing the *columns* is a fair trade for
a table that cannot have them; losing the visible *cell boundaries* is not, and
the two are separate things.

So an unaligned table now gets a fixed gap at every boundary — a constant, unlike
the alignment padding, so it cannot grow a row by the widest cell in every
column — and a **hairline is drawn wherever a cell-separating pipe was
concealed**. That rule is drawn in both modes: aligned, the rules line up into
real column separators; unaligned, they still say where one cell ends and the
next begins. Clipped to the pipe's own line fragment, so a wrapped row's
boundaries do not draw through the line above them.

Rows also wrap by *word* rather than by character now. Chinese still breaks
between characters — standard line breaking gives an opportunity at every one —
while character wrapping had split `1621` across two lines.

**It also removed most of the case for T2.** In-cell wrapping was wanted mainly
so a table would survive a narrow measure. A phone-width table that fits keeps
its columns, and one that cannot fit now reads as a list of records with its rows
still delimited. T2 would make that case prettier; it is no longer the difference
between usable and not.

## What was built

**T1** — `|:---|:---:|---:|` alignment, which cmark parsed and nothing read, and
the fit rule above. Alignment falls out of the existing kerning: the padding that
makes a column line up moves to the *front* of a cell for right alignment and
splits for centre. Verified by measuring ink extents rather than by eye — the
three body rows of a right-aligned column end within one pixel of each other, at
370pt as well as 700.

**H2** — inline HTML from cmark's `InlineHTML` nodes, so no regex and no chance
of firing inside code. `b`, `strong`, `i`, `em`, `u`, `s`, `del`, `strike`,
`mark`, `code`, `sub`, `sup`.

Two things it got wrong first, both worth keeping written down:

  - The tags were collapsed in the token loop and the span attributes applied
    after, so an outer `<b>` set a font across the inner `<i>`'s concealed tags
    and gave back the width they had been collapsed out of — visible as blank
    gaps. Attributes first, then collapse.
  - An **unclosed** `<b>` was collapsed too, which deleted it from view while
    styling nothing. Only tags that actually paired are collapsed now. Same rule
    as the unsupported ones: a tag that does nothing must still be visible, or
    the author's text is gone with nothing to show for it.
