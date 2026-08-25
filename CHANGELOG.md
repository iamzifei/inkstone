# Changelog

Notable changes, newest first. Versions follow the ones Sparkle serves from
[appcast.xml](https://inkslab.app/appcast.xml).

The working notes behind each change — what was reported, what it actually
turned out to be — are in [`docs/plans/`](docs/plans), one file per piece of
work. This file is the summary; those are the reasoning.

## 0.1.3 — 2026-08-25

Four things the 2026-08-25 audit found, done.

### Search no longer waits for the disk

- **Search runs off the main thread, and only after you stop typing.** It used to
  run synchronously on every keystroke and read every note in the vault: on
  8,852 notes a query matching nothing cost **783 ms of frozen window**, and
  every prefix of a real query matches nothing while you type it.
- **And it is genuinely faster.** Reading the vault in parallel batches, and
  sorting the note order once when the index is built rather than on every
  search: a query matching nothing **778 ms → 115 ms**, a query matching plenty
  **257 ms → 21 ms**.
- The quick switcher (⌘O) is off the main thread too — it was 100 ms per
  keystroke.

### Reading mode is a reading mode

Its only effect used to be `isEditable = false`; it rendered identically to live
preview. Now the Markdown syntax is **removed** rather than hidden, so:

- headings, quotes and frontmatter lose their markers instead of dimming them;
- a bullet is a bullet, a task is ☐ or ☑, a link reads as what it shows;
- **copying a paragraph gives prose.** In live preview the syntax characters are
  still in the document at 0.01pt, so a copy hands back `**bold**`.

It renders into its own view, never into the editor's storage — that storage is
the file on disk.

### Six settings that were switches wired to nothing

Every one now does what it says, and each has tests:

- **Auto-close brackets** and **Continue lists on Return** ran unconditionally;
  turning them off did nothing at all.
- **Tab size** and **Indent with tabs** were read by nothing. Tab and Shift-Tab
  now indent, including a whole selection, keeping blank lines blank.
- **New link format** and **Shortest path links** were read by nothing. An
  inserted link now honours both — and a short name is used only when it is
  unambiguous, because a bare `[[Plan]]` with two Plans in the vault is a link
  that silently points at the wrong file.
- **Show line numbers** was a field with no control at all. It has both.

### Faster

- `outgoing(from:)` filtered every edge in the vault on every call — and the
  inspector calls it once per note opened. It is a dictionary now, like
  `backlinks` always was.

## 0.1.2 — 2026-08-25

### Graph view

- **The graph no longer hangs the app.** One layout frame of an 8,844-note vault
  measured **3,993 ms** in a release build, on the main thread, inside the
  drawing closure. It is now **5.2 ms**, off the main actor: flat slot-indexed
  arrays instead of a dictionary keyed by node ID, and a Barnes–Hut quadtree
  instead of comparing every node with every other.
- **No node runs away from the graph any more.** Repulsion had no floor, so a
  close enough pair pushed each other at the velocity clamp for the whole run —
  a dozen nodes ended up 14,000 units out from a graph whose 99th percentile was
  1,685, and "fit on screen" framed the stragglers.
- **Nodes are named after their file**, not after the first `#` heading in it.
  Two notes sharing a heading used to draw as two identically-named circles.
- **Opening the graph from a note shows that note's graph** — what links to it
  and what it links to, with a depth of 1–5. ⌥⌘G, or the Scope switch, gives the
  whole vault.
- **An Obsidian-shaped settings panel**: Filters (search, tags, attachments,
  existing files only, orphans), colour Groups, Display (arrows, text fade, node
  size, link thickness), and Forces (centre, repel, link, link distance), with
  Obsidian's ranges and default readings.
- Drag a node, scroll to zoom, hover to name one dot in a field of them.

### Editor

- **Reveal in sidebar** (⌥⌘R, or the button beside the mode picker) expands the
  file tree down to the note you are reading and scrolls to it. After following
  links for a while you know what you are reading and not where it lives.
- **Frontmatter is shown as a properties table** at the top of the note, in file
  order. It used to be concealed outright, and the
  `showFrontmatterAsProperties` setting — on by default, with a toggle in
  Settings — was read by nothing at all.
- **Frontmatter that cannot be parsed is no longer hidden.** A header written
  with full-width colons is not YAML, and a dozen lines of the author's own text
  simply vanished from the preview. Content the app cannot render is content it
  shows.
- **File paths written in prose are links.** `06-选题装配/选题池.md` in a
  sentence now opens that note, if that note exists. Paths that do not resolve
  stay plain text.
- **The selection is one continuous band per line.** AppKit draws it as a
  per-glyph-run background, and in a live-preview layout — where syntax markers
  are 0.01pt and every block has its own line height — that arrived as a row of
  disconnected bars at half a dozen different heights.
- **Tooltips on every icon-only button**: the main toolbar, the canvas toolbar,
  the graph controls, and the three editor modes. Reading mode's says what it
  actually does — locked, not a separate renderer.

### Performance

- **Opening and closing the sidebar is no longer heavy.** `resetCursorRects`
  scanned the whole document and asked the layout manager for a rect per code
  block — and AppKit calls it on every tracking-area update, which a split-view
  animation issues continuously. On a 198KB note it was **54% of the main
  thread**; it is now **1.6%**, because a cursor rect outside the visible area
  can never be hovered.
- A width change no longer triggers a full re-highlight mid-animation. Opening
  the sidebar moves the text measure ~260pt, crossing the 32pt image-scaling
  bucket eight times; the pass now waits for the width to stop moving.

### Website

- **Every page is linked from the home page.** The sync guide, the privacy
  statement and both landing pages were in the sitemap and in no navigation
  anywhere — reachable only by knowing the URL.
- Two landing pages: [an honest Obsidian
  comparison](https://inkslab.app/obsidian-alternative.html), and [what syncing a
  vault actually costs](https://inkslab.app/obsidian-sync-free.html).
- `llms.txt`, so an assistant reading the site gets the summary rather than the
  marketing.

## 0.1.1 — 2026-08-20

- Background sync on iOS, fixed. It was never that iOS refused to wake the app:
  iOS woke it every time and it crashed on the first line of the handler.
  `BGTaskScheduler.register(using: nil)` runs on a background queue, and
  `MainActor.assumeIsolated` in that handler traps off the main thread.
- `BGContinuedProcessingTask` for the first sync — started in the foreground,
  continuing after you leave the app, with the system showing progress.
- Sync responds to cancellation properly, so an interrupted run resumes instead
  of starting over.

## 0.1.0

First signed, notarised release, distributed through Sparkle.
