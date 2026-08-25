# Graph view: stop it hanging, then bring it up to Obsidian's

**Status:** done 2026-08-25. Tooltips confirmed working by James.

## What was reported

Three things, on a Mac, against the 8,844-note vault at `~/Dev/詹有才`:

1. Toolbar buttons are icons with nothing telling you what they do.
2. Opening the graph makes the app stop responding.
3. The graph shows headings out of the files rather than the notes themselves.

Then, on seeing the first fix: match Obsidian's graph — its design, its
performance, and its settings panel (Filters / Groups / Display / Forces).

## What each one actually was

### 2 — the hang

`GraphSimulation.step` compared every node with every other. It also kept its
bodies in a `[String: Body]` dictionary and re-sorted each node's neighbour list
**by string** on every frame, to keep the force accumulation order stable.

Measured on this machine, release build, one frame:

| nodes | before | after |
| --- | --- | --- |
| 500 | 14.8 ms | 0.2 ms |
| 2,000 | 202.7 ms | 1.0 ms |
| 8,844 | **3,992.9 ms** | 5.2 ms |

And it ran **on the main thread inside the `Canvas` draw closure**, so the four
seconds were four seconds of an unresponsive window, repeated every frame.

Fixed by three separate changes:

- flat arrays indexed by slot instead of a dictionary keyed by node ID, which
  removes the string hashing and makes the sort unnecessary (insertion order is
  already deterministic);
- a Barnes–Hut quadtree for repulsion, O(n log n) instead of all-pairs;
- the layout moved off the main actor entirely — `GraphPane.settle()` steps in a
  detached task and publishes each finished frame back as state.

### 2b — the runaway nodes, found while checking the fix

With the hang gone the graph drew, and about a dozen nodes were 14,000 units out
from a graph whose 99th percentile was 1,685. "Fit on screen" then framed the
stragglers and squashed the real graph into a speck.

Repulsion goes as 1/d³ and had no floor above a hundredth of a unit, so a close
enough pair pushed each other at the 60-unit velocity clamp — and kept doing it,
in the same direction, every frame, for the whole run. Two fixes: a
`minimumSeparation` of 8 units (about two node radii) below which the force stops
growing, and a starting cloud drawn from the full 64-bit PRNG output rather than
a 10,000 × 10,000 lattice of angles and radii.

Real vault, after: p50 1046, p99 1677, max 1687 — one clean disc.

### 3 — the labels

`GraphData.build` labelled note nodes with `note.title`, which falls back to the
first `# heading` in the file. So `选题装配模板.md` was drawn as "选题装配：标题",
`解答型口播稿模板.md` as "选题：", and `README.md` and `AGENTS.md` — which share a
first heading — became two circles with the same name. Now the file name.

### 1 — the tooltips

`.help()` on every toolbar button, and on the canvas toolbar and graph controls,
which are all icon-only too.

**Confirmed working** by James on the installed build. Worth recording why it
could not be confirmed from here: `.help()` on a toolbar button does not surface
as `AXHelp` — and neither does macOS's own "Hide Sidebar" item, so an absent
`AXHelp` says nothing about whether a tooltip appears. Do not read that signal
as a failure again.

## Phase 3 — Obsidian parity

Obsidian's panel, from the screenshot supplied:

| Section | Controls |
| --- | --- |
| Filters | Search files…, Tags, Attachments, Existing files only, Orphans |
| Groups | New group — a search query and a colour per group |
| Display | Arrows, Text fade threshold, Node size, Link thickness, Animate |
| Forces | Centre force 0.52, Repel force 10.00, Link force 1.00, Link distance 250 |

Force sliders keep Obsidian's ranges and default readings, mapped onto the
simulation's own parameters so the defaults reproduce the layout that already
works.

### Acceptance

- [x] One frame of the 8,844-node vault costs single-digit milliseconds, release
- [x] The layout never leaves a node an order of magnitude outside the rest
- [x] Node labels are file names
- [x] Nothing expensive runs on the main actor
- [x] The panel above, in full, with the settings persisted
- [x] Drag a node; scroll to zoom
- [x] Compared side by side against Obsidian on the same vault

### What the side-by-side showed

Obsidian's own graph, on this vault, from its saved `.obsidian/graph.json`:
`showTags: false`, `showOrphans: true`, `centerStrength: 0.519`, `repelStrength:
10`, `linkStrength: 1`, `linkDistance: 250`. Inkstone's defaults now read the
same, and `showTags` was flipped to off to match.

Two things came out of looking at the two side by side:

- **Link distance was being scaled to a quarter**, so the default 250 behaved
  like 60 and the linked part of the vault collapsed into a knot in the middle of
  the orphans instead of spreading out among them. Now one layout unit per unit
  on the dial.
- **Nodes are drawn in the body text colour**, as Obsidian does it, not in the
  accent. Several thousand accent-coloured dots is a wall of one loud colour and
  leaves the colour groups nothing to stand out against.

### What Obsidian is actually built on

It is worth saying plainly, because the request was to refer to its
implementation: **Obsidian is not open source.** Only its API type definitions
are. What the shipped bundle does show, read out of
`/Applications/Obsidian.app/Contents/Resources/obsidian.asar`:

- **PIXI.js 7.2.4 (legacy)** — the graph is drawn on the GPU through WebGL.
- **CodeMirror** — the editor, 607 string hits.
- **No d3-force.** `forceSimulation`, `alphaDecay` and `velocityDecay` do not
  appear at all, so the layout is their own and not readable from here.

So the graph's shape was matched by reading its settings file and its rendering,
not its source. The one structural difference that remains is the renderer:
Obsidian draws on the GPU, this draws on the CPU through SwiftUI `Canvas`. That
is what the profile-led work below is standing in for, and it is where to go next
if a much larger vault ever needs it.

### Where the drawing time went

`sample` on the main thread while the 9,350-node graph settled, release build:

| | before | after |
| --- | --- | --- |
| `GraphPane.draw` | 3,306 / 4,555 samples (73%) | 181 / 4,989 (4%) |
| `drawLabels` | 1,970 (43%) | 112 (2%) |
| `CTLineCreateWithAttributedString` | 1,345 (30%) | 79 (2%) |

Three changes, each aimed at what the profile actually said:

- labels are not drawn at all while a large graph is still settling — the names
  are sliding around too fast to read, and shaping them was the single most
  expensive thing on the main thread;
- the label cap came down from 400 to 250, with padding so two labels that clear
  each other by a hair still read as two;
- nodes below 2.5 points of radius are drawn as rectangles. A circle is four
  bezier curves and a square is four lines, and at the zoom that fits a large
  vault *every* node is that small.

Panning a settled graph was not measured: the synthetic drag never reached the
window, and the numbers above are for the settle only.

## Phase 4 — the graph follows the note you are reading

Reported after phase 3: with a note open, the graph should show *that note's*
neighbourhood, not nine thousand dots.

`TabContent.graph` now carries an optional focus, so a local graph and the vault
graph are separate tabs rather than one view with a mode. Opening the graph from
the toolbar or ⇧⌘G focuses on whatever is open; ⌥⌘G, or the Scope switch in the
panel, gives the whole vault. Depth is 1–5, as Obsidian's local graph has it, and
the focused note is drawn in the accent colour so the eye finds it first.

`GraphData.local` grew the full filter set — it was honouring only
`includeUnresolved`, so tags, attachments and the search box did nothing in a
local graph. One exception, deliberate: **the focused note is kept whatever the
search says.** A local graph of a note that filtered itself out is an empty box
with no explanation of why.

Two smaller things that came out of looking at it running:

- the panel ran underneath the zoom controls in the opposite corner, leaving them
  visible but unclickable;
- switching scope opens a different tab, so a pane-local "is the panel open" flag
  closed the panel every time — it is `@AppStorage` now, which is also what
  Obsidian does with the `close` key in its `graph.json`.

## HUMAN QUEUE

- Look at the graph beside Obsidian's on the same vault and say what still differs.
- Obsidian was left with a Graph view tab open on the 詹有才 vault, from driving
  it for the comparison. Nothing in the vault was touched.
