# Obsidian parity check

Renders sampled notes with **Obsidian's own renderer** and compares element
counts with Inkstone's scanner, note by note. Read-only on both sides.

1. Copy the vault's `.md` files somewhere (never test on the real vault), and
   write the sample list (vault-relative paths, one per line) to
   `<dir>/sample.txt`.
2. Obsidian (open on that vault; the window may be in the background):
   ```
   obsidian vault=<id> eval code="(()=>{const w=require('@electron/remote').getCurrentWebContents();w.setBackgroundThrottling(false);window.__inkCmpDir='<dir>/';return eval(require('fs').readFileSync('scripts/obsidian-parity/obsidian-run.js','utf8'))})()"
   ```
   Background throttling has to be off: a hidden Obsidian window does not
   render (no animation frames). Turn it back on afterwards with
   `setBackgroundThrottling(true)`. Progress: `<dir>/progress.txt`.
   The note is rendered into a detached off-screen element; saving is stubbed.
3. Inkstone:
   ```
   cd Packages/InkstoneCore
   INKSTONE_PARITY_DIR=<vault copy> INKSTONE_PARITY_LIST=<dir>/sample.txt \
   INKSTONE_PARITY_OUT=<dir>/inkstone.jsonl swift test -c release --filter ObsidianParity
   ```
4. `python3 scripts/obsidian-parity/compare.py <dir> [category] [n]`

Counting rules are aligned (a task is also a list item; links, embeds and
images are one bucket). Blockquotes are not compared (Inkstone counts lines).

Last run 2026-11-18, 1,195 notes: see docs/plans/2026-11-18-perf-ux-duo.md.
