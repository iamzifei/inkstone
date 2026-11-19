# Changelog

Notable changes, newest first. Versions follow the ones Sparkle serves from
[appcast.xml](https://inkslab.app/appcast.xml).

The working notes behind each change — what was reported, what it actually
turned out to be — are in [`docs/plans/`](docs/plans), one file per piece of
work. This file is the summary; those are the reasoning.

## 0.5.1 — 2026-11-20

### Faster
- Opening a long note on the Mac blocks the interface a quarter as long as before (measured:
  2.5 s → 0.6 s over twelve opens of a 60 KB note), and less on iPhone and iPad too.
- Notes with pictures open without freezing: images decode in the background while a
  placeholder of the right size holds their place (measured: a note with twelve large photos
  went from a ~1.1 s freeze to under 0.07 s, on Mac and iPhone).
- Switching notes does less work: each note is styled once when it opens, not three times.

### New on iPhone and iPad
- Share files from any app — Files, Mail, Photos and others — straight into your knowledge
  base; they land in the inbox and are filed like anything dropped in.

### Fixed
- Settings › Knowledge Base opens at the top instead of scrolled down to the rules editor.

## 0.5.0 — 2026-11-19

Inkstone is now an AI knowledge base, made for people who have never heard
the word "vault". Plan and reasoning: `docs/plans/20261119-ai-knowledge-base-0.5.0.md`.

- **Create a knowledge base in three steps** — a name and a place (iCloud
  Drive, a folder, or a folder you already have). The skeleton (inbox,
  projects, areas, resources, media, outputs, private, review, archive,
  system), the organizing rules and three entry files are made for you, in
  the interface language. A folder you already have keeps every file where
  it is.
- **Drop anything in.** Drag onto the window (Mac, iPad), Add Files…, or
  share links and text from other apps. The first time: copy or move, with
  "always do this"; copy is the default, and a move removes the original
  only after a complete, identical copy.
- **It files itself.** Privacy words first (to the private folder), then your
  rules, a project named in the file, media by type and month, then Apple's on-device model (or your
  own model, off by default) — renamed by date and topic, Markdown notes
  given their source and date without a word of text changing. Exact copies
  go to to-delete; look-alikes and anything unsure wait for you. Rounds of
  more than 20 files or with duplicates wait for your yes.
- **Nothing is lost.** Nothing is ever deleted. Every step is logged before
  it is taken, and every round can be undone — without overwriting
  anything changed since.
- **AGENTS.md, README.md and SOURCE_OF_TRUTH.md**, written and kept up to
  date, so any AI assistant knows what is where. Only the part between
  Inkstone's markers is rewritten.
- **Settings › Knowledge Base**: organizing, the AI engine, what dropping
  does, and the organizing rules as plain text (the vault's own file), with
  "Restore Default Policy" and a check that never overwrites an edit made on
  another device.
- **Only Inkstone's own knowledge bases are organized** (made or adopted,
  with their rules file). A vault from another app is opened as it is.
- HTML comments (`<!-- … -->`) are hidden when reading and folded in live
  preview, like `%%comments%%`.
- The iOS share extension ships (links and text to Inkstone).

Notes for 0.3.0 and 0.4.0 are on the GitHub releases page.

## 0.2.2 — 2026-11-18

- **The welcome guide's screenshots match the guide's language.** Each of the six
  pages now has an English, 简体中文 and 繁體中文 screenshot, and they swap as soon
  as the language picker changes. They are not captures: `GuideShots` draws the
  app's real views (`RootView`, the quick switcher, `SettingsView`) offscreen with
  the in-app language forced, against a demo vault, so the sidebar, inspector,
  graph labels and canvas cards are in that language. `scripts/make-guide-shots.sh`
  reproduces them. About 770 KB for all 18.
- **Chinese demo vaults** (`assets/demo-vault-zh`, `assets/demo-vault-zh-Hant`)
  with Chinese file names, folders, tags and notes, for those renders.
- **A canvas opened while its window was still settling no longer stays framed for
  the wrong size.** The automatic fit is redone when the pane is resized, as long
  as nobody has panned or zoomed. (Found while rendering the canvas page: it came
  out tiny in a corner.)

## 0.2.1 — 2026-11-18

- **The welcome guide now opens in front on first launch.** It was being opened
  from the main window's first appearance and could end up behind it. It is now
  brought forward and made key explicitly. Everyone sees it once more with this
  version (guide version 2), including people who dismissed or missed 0.2.0's.
  Verified for a brand-new install (no preferences, no vault — the guide comes
  first, then the folder chooser behind it), a second launch (not shown again) and
  an upgrade from guide version 1.
- **A language picker on the guide's first page.** English / 简体中文 / 繁體中文,
  pre-selected from the system's preferred languages (`zh-Hant`, `zh-TW`, `zh-HK`
  and `zh-MO` give 繁體中文, any other Chinese gives 简体中文, anything else
  English). Choosing one re-renders the guide at once and sets the app's own
  language setting, the same one as Settings › Language, so the whole app follows.
- **Errors, status lines and the app's own menu titles follow that setting too.**
  They used to answer in the system language whatever the picker said, because
  `String(localized:)` asks the main bundle. They now look the string up in the
  chosen language (`localized(_:)`). Menus and items that macOS supplies itself
  (File, Edit, About, Close…) still follow the system language.

## 0.2.0 — 2026-11-18

### A welcome guide, and the interface in three languages

- **First-run welcome guide (macOS).** Six pages, each with a screenshot of the
  app: choosing the notes folder, `[[wikilinks]]` and backlinks, the quick
  switcher (⌘O), the graph, the canvas, and sync / settings. It opens once, and
  people updating from 0.1.x see it once too — the "seen" flag is a version
  number (`onboardingSeenVersion`), so a later guide with new pages can be shown
  again by bumping one constant. Reopen it any time from **Help › Show Welcome
  Guide**; Esc closes it, ← → turn the pages.
- **The guide is English, 简体中文 and 繁體中文**, and follows the language chosen
  in Settings rather than only the system language.
- **Every interface string now has all three languages.** About 270 strings —
  most of Settings › Sync, the assistant, version history, bookmarks and the
  sidebar menus, and the iCloud messages — had no Chinese at all and showed in
  English. GitHub and sync errors, sync progress, and the assistant's provider
  errors are translated too; they used to be plain English strings that could not
  be.
- A sync error that names a count ("would delete 8882 of …") still prints the
  bare number rather than "8,882".

## 0.1.5 — 2026-08-26

- **Tables in reading mode are drawn with rules.** A real `NSTextTable` on macOS;
  on iOS, tab stops placed by measuring each cell. Not box-drawing characters —
  a CJK glyph in a monospaced font is 1.61× the width of an ASCII one rather than
  2×, because the font has no CJK and the fallback is not a multiple of its
  advance, so a table padded by counting characters lines up in a string and not
  on screen.

## 0.1.4 — 2026-08-26

### Reading mode renders everything

- **Pictures, Mermaid diagrams and formulas are drawn**, not left as text. The
  editor cannot use `NSTextAttachment` — its storage is the file on disk and
  TextKit would need a U+FFFC character inserted into it — but reading mode's
  storage belongs to nobody, so the attachment character is free. Each one falls
  back to text: a picture that will not load leaves the file's name, a formula
  that will not parse leaves its LaTeX in the warning colour.
- **Tables are laid out in columns** instead of showing their pipes, with CJK
  counted as two columns wide so the alignment actually holds.
- **Nothing is lost any more.** Frontmatter used to be deleted whole — including
  a header written with full-width colons, which YAML reads as a scalar rather
  than a mapping, so a dozen lines of the author's own text vanished. A
  `%%comment%%` used to delete its entire line, prose either side included. Both
  fixed, and `losesNoContent` is now a property test: every run of letters,
  digits or CJK in the source must survive into the output.
- Callout markers, `$$` fences and a table's `| --- |` row are removed rather
  than passed through as text.

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
