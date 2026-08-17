# Replacing the regex scanner with cmark-gfm — 2026-08-17

Assessment, not a commitment. The question behind it: the Markdown rendering
keeps producing small problems, so is the approach wrong?

## The answer, short

The **drawing** approach is right and there is no alternative to it. The
**scanning** approach is where the small problems come from, and there is a
better one already sitting in the dependency list unused.

## What is there now

| Piece | Size | What it does |
|---|---|---|
| `SyntaxScanner` | 488 lines | ~30 `NSRegularExpression` patterns over the raw text |
| `MarkdownHighlighter` | 1275 lines | Turns tokens into attributes |
| `EditorRenderer` | ~420 lines | Paints what attributes cannot express |

`swift-markdown` — Apple's wrapper around cmark-gfm — is declared as a
dependency of InkstoneCore and **imported nowhere**. `import Markdown` appears 0
times in the project. The comment above it in `Package.swift` claims it "gives
us GitHub Flavored Markdown for free"; none of that was ever collected.

## Why not switch the whole thing to a library

There is no native live-preview Markdown editor library, for any platform:

| Product | How it renders |
|---|---|
| Obsidian | CodeMirror 6 — web, in Electron |
| Typora | Own engine — web |
| Bear, iA Writer, Ulysses | All hand-written, native |
| MarkdownUI | Renders to SwiftUI views; **not editable** |
| Down | One-shot conversion to `NSAttributedString`; no live preview |

Live preview requires the source text and its rendering to occupy one editable
buffer. Natively that means TextKit, and nothing exists on top of TextKit that
does Markdown. Every native app in this category wrote its own — the drawing
layer here is not an unusual choice, it is the only one.

The real alternative is WKWebView + CodeMirror 6, which is abandoning "native
app" as a premise: memory, launch time, input methods, gestures and
accessibility all regress.

## What is worth changing

Replace the regex scan with a cmark-gfm parse. Keep the highlighter and the
renderer.

Measured on the real parser (2026-08-17):

```
Heading          L1:1–L1:25
  Emphasis       L1:15–L1:25        ← nesting, with ranges
Table            L8:1–L10:10
  Head → Cell    L8:2–L8:5          ← a table is structure, not pipes
  Body → Row → Cell
ListItem.checkbox = .unchecked      ← task state directly
CodeBlock        L12:1–L14:4
```

Line/column ranges for every node, correct nesting, and **tables as Head / Body
/ Row / Cell**. That last one matters beyond correctness: real column layout is
possible from a structure and is not possible from a regex that matches pipes.
The current table alignment works by measuring cells and padding them with
kerning, which cannot survive a cell containing an image, a wide inline formula,
or a link whose display text differs from its source.

The bugs fixed this week are all of one kind, and all of them are bugs a parser
does not have:

  - `fenceLines` deduced the closing ``` from the block's last character and
    missed it when the pattern took the trailing newline
  - `---` was matched but never rendered
  - Block margins were applied per line because the scanner reports a block as
    one flat range with no interior structure
  - Table columns aligned by measured kerning rather than by layout

## What cmark cannot do

Verified against the parser, not assumed. These land inside a single `Text`
node and still need scanning by hand:

  - `$maths$` and `$$maths$$`
  - `==highlight==`
  - `[[wikilink]]` and `![[embed]]`
  - `#tag`
  - `[^footnote]`
  - Obsidian callouts (`> [!note]`)

So the regexes do not disappear; they shrink to the Obsidian-specific layer and
run over text ranges the parser has already isolated — which is where they are
reliable, since they no longer have to reason about whether they are inside a
code fence or a table cell.

## Cost

Rough, and the honest uncertainty is in the second row.

| Step | Estimate | Confidence |
|---|---|---|
| Parse and map nodes to `NSRange` | 1 session | Ranges are line/column; converting needs a line-index and care around CJK, since a "column" is not a UTF-16 offset |
| Port ~30 token kinds to node kinds | 2–3 sessions | **Least certain.** Each kind has behaviour the tests do not cover |
| Keep the Obsidian layer as regexes over parsed text | 1 session | Mostly deletion |
| Reconcile with live preview's caret-line reveal | ? | Unknown. The current design reveals source per token range; nodes nest, so "the token under the caret" becomes ambiguous |
| Performance check | 0.5 session | Parsing is O(n) but happens on every keystroke; the current scan is 0.1ms on a small note and was 517ms on a 223KB one before the IndexSet fix |

**Not a one-sitting change.** The safe shape is incremental: parse alongside the
regexes, migrate one token kind at a time behind a flag, compare the two on real
notes, and delete each regex only once its node produces identical attributes.

## Recommendation

Worth doing, not urgently. The current renderer works and its remaining faults
are findable and fixable one at a time — this week showed that. But every one of
them was a boundary case a parser would not have, and the table layout ceiling
is real and will not lift without structure.

Do it when the iOS work is finished and there is a session's worth of quiet, not
between bug reports.

## Open question

Live preview's "reveal the source on the caret's line" is defined per token. In
an AST, a caret inside `**bold**` inside a list item inside a blockquote is
inside three nodes. Which one reveals? This needs deciding before the migration,
not during it.
