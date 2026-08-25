# Frontmatter you can see, and a selection that is one shape

**Status:** done 2026-08-25.

## What was reported

On the Mac, against a real vault:

1. A note's metadata — its YAML frontmatter — is not previewed at all.
2. The Markdown styling and **the selection** still are not good enough.
3. The three mode icons above the editor have no tooltips, and nobody can tell
   what the third one does.

Asked what specifically was wrong with the selection, the answer was
**"不连续／有豁口"** — discontinuous, full of gaps — and, asked which part of the
Markdown styling to fix first, **"选中的样式"**. So the styling complaint and the
selection complaint are one complaint.

## 1 — the frontmatter

`MarkdownHighlighter` concealed the whole frontmatter token outright, on the
grounds that "the properties are already presented by the inspector". That is
only true while the inspector happens to be open, so a note's tags, aliases and
status were invisible the rest of the time — and `showFrontmatterAsProperties`,
a setting that is **on by default and has a toggle in Settings**, was read by
nothing whatsoever.

It is now a properties table at the top of the note, as in Obsidian: keys on the
left, values on the right, list values as chips, a rule underneath, and the note
below that. Editing still reveals the raw YAML, the same as any other syntax the
caret is sitting in.

Drawn by hand rather than as an `NSTextAttachment`, for the reason the inline
images already document: TextKit 1 only makes an attachment glyph for U+FFFC, and
the text storage here *is* the file — it must not gain characters the author did
not type. So the source is collapsed, its height reserved on the first line, and
`EditorRenderer` paints into the gap.

**Row order comes from the file, not the dictionary.** `Frontmatter.properties`
is a `[String: PropertyValue]`, and Swift seeds its hashing per process, so
reading `keys` would have rearranged someone's own properties table on every
launch. `NotePropertyOrder` reads the order back out of the YAML; it lives in the
core, with tests, rather than in the view that draws it.

## 2 — the selection

AppKit's selection is a *text attribute background*: `NSLayoutManager` fills one
rect per glyph run, using that run's own metrics. In an ordinary text view that
is invisible. In this one it is not — live preview collapses syntax markers to a
0.01pt clear font, gives whole lines a 0.01pt line height, and gives code blocks
and headings each their own line height. The result, in the screenshot that came
back: pink bars at half a dozen different heights, stopping and starting down the
page, with blank-looking full-width stripes between them.

Now drawn by `EditorRenderer.drawSelection`, from
`enumerateEnclosingRects(forGlyphRange:withinSelectedGlyphRange:in:)` — which
answers the question actually being asked, "what area does this selection cover",
per **line fragment** instead of per run. One continuous rounded band per visual
line. Bands under 3pt tall are skipped, because a collapsed line carries no text
anyone can see and a hairline stripe across the page reads as a fault.

Two things that had to come with it, because AppKit is no longer doing them:

- the view repaints itself on selection change, on becoming and resigning first
  responder, and on the window's key state changing;
- an **inactive** selection is still drawn, in a muted colour. Losing the
  selection entirely when you switch apps is not what the platform does.

macOS only: UIKit gives no way to suppress its own selection drawing, so iOS
keeps the system one rather than drawing two.

## 3 — the mode picker

A segmented `Picker` shows one tooltip for the whole control, so it is three
plain buttons that look like a picker, each with its own `.help`. And the third
icon was unreadable because the feature behind it barely existed: **reading
mode's only effect was `isEditable = false`.** Its tooltip now says exactly that
— "the same as live preview but locked, so nothing is changed by a stray
keystroke" — rather than implying a renderer that is not there. A real reading
renderer is still on the roadmap.

## What Obsidian could and could not be copied from

Asked to refer to Obsidian's implementation: **it is not open source**, so there
is nothing to read. What its shipped bundle does show is CodeMirror 6 and
PIXI.js. CodeMirror *is* open source, and the transferable idea is real: its
live preview replaces a range with a **widget decoration**. Collapsing the
frontmatter and reserving height for something drawn in its place is the same
idea; only the mechanics differ, because TextKit is not CodeMirror.

## Round two — what the screenshots showed

### The selection was still wrong, in the opposite direction

`enumerateEnclosingRects` returns the *full line fragment*, and this editor puts
16pt of paragraph spacing and a 1.6 line-height multiple into every one. So the
first fix traded a row of disconnected bars for one solid slab of colour with the
text floating inside it. It now enumerates line fragments and uses each one's
**used rect** — the part the glyphs actually occupy — with the horizontal extent
from `boundingRect(forGlyphRange:)`, extended to the line end only where the
selection carries on past it. Per-line bands, gaps between paragraphs.

### Frontmatter that is not YAML was being hidden

The note that showed this has a header written with **full-width colons**
(`编号：N19`). YAML reads that as one long scalar, not a mapping, so
`Frontmatter.properties` came back empty, `PropertiesBlock` returned nil, and the
old code fell through to concealing the whole block: a dozen lines of the
author's own text, gone from the preview, with nothing to say why.

Now the only thing that concealment path does is *render the source*. Three cases
share it — the caret is in the block, the setting is off, or it will not parse —
and the rule behind all three is one line: **content this cannot render is
content it shows.**

### File paths in prose were not links

Notes that keep an index refer to other files by path constantly, usually inside
backticks because that is how a path is written. Markdown has no syntax for it,
so none of them were clickable — the path had to be read, remembered, and typed
into the switcher.

`VaultPathDetector` (in the core, with tests) finds path-shaped runs;
`Workspace.resolveVaultPath` decides. Two deliberate constraints:

- **Only paths that resolve are linked.** A link that goes nowhere is worse than
  no link, and prose is full of `v3.2`, `1966.` and `example.com` — offering
  every one of those as a file would turn a paragraph into a field of false
  links.
- **Resolution is stricter than an embed's.** `AttachmentIndex` falls back to
  matching a unique *basename* anywhere in the vault, which is right for
  `![[diagram.png]]` — the author named a file, not a place. Someone who wrote
  `06-选题装配/选题池.md` meant that file, and quietly linking to a same-named
  file in another folder would be worse than not linking.

Answered from the in-memory indexes rather than the file system, because it runs
on every highlight pass; the detector has a linearity test for the same reason.

## HUMAN QUEUE

- Select across a heading, a code block and a paragraph and say whether it looks
  right now. Both rounds were proved with a temporarily forced selection and a
  screenshot, then the hook removed — the automation cannot hold focus on the
  window long enough to make a real one.
