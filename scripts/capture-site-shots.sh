#!/bin/bash
set -euo pipefail

# Captures the website's screenshots, one PNG per state, then writes the WebP
# variants and the size manifest that site/build.py reads.
#
# What it can and cannot reach, and why — this is the constraint the whole
# script is shaped around:
#
#   An app that is not frontmost has no key window, so it has no first
#   responder. Menu key-equivalents still arrive (AppKit dispatches those before
#   the responder chain), but typing, pasting and clicking a control do not.
#   That means every state below is reached one of two ways: the launch hook,
#   which opens a named note, or a menu shortcut. Anything needing a click —
#   framing the canvas, opening a Settings tab — has to be shot by hand.
#
#   Captures go by window ID with `-o`, which drops the drop shadow, so the PNG
#   is exactly the window at 2x and nothing has to be cropped afterwards.
#
# Usage: ./scripts/capture-site-shots.sh [output-dir]

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/site/assets/shots}"
APP="${INKSTONE_APP:-$ROOT/.build-demo/Build/Products/Debug/Inkstone.app}"
BIN="$APP/Contents/MacOS/Inkstone"
VAULT="${INKSTONE_VAULT:-$ROOT/assets/demo-vault}"
KEYS="python3 $ROOT/scripts/send-keys.py"
WIN="python3 $ROOT/scripts/inkstone-window.py"
# The widths the page actually requests, from the `sizes` attribute build.py
# writes. Generating a 2400px variant nobody asks for is bytes on a CDN and a
# line in the manifest that never matches a media query.
VARIANTS=(640 960 1280)

[ -x "$BIN" ] || { echo "error: $BIN not found — see record-demo.sh for the build line" >&2; exit 1; }
command -v cwebp >/dev/null || { echo "error: cwebp not installed (brew install webp)" >&2; exit 1; }
mkdir -p "$OUT"

quit_app() { pkill -f "Inkstone.app/Contents/MacOS/Inkstone" 2>/dev/null || true; sleep 1; }
trap 'quit_app; rm -f /tmp/inkstone-test-vault' EXIT

caffeinate -d -u -w $$ &

launch() {  # launch <note-file-in-vault>
  quit_app
  echo "$VAULT|$1" > /tmp/inkstone-test-vault
  "$BIN" >/tmp/inkstone-run.log 2>&1 &
  sleep 7
}

shoot() {   # shoot <name>
  read -r WID _ _ WW WH <<< "$($WIN)"
  screencapture -x -o -l"$WID" "$OUT/$1.png"
  echo "    $1.png  ($(sips -g pixelWidth "$OUT/$1.png" | tail -1 | tr -d ' pixelWidth:')px wide)"
}

echo "==> live preview"
launch "Typography Notes.md"
shoot live-preview

echo "==> backlinks"
launch "The Measure.md"
shoot backlinks

echo "==> graph"
$KEYS key 5 cmd shift     # ⌘⇧G
sleep 3
shoot graph

echo "==> quick switcher"
launch "Home.md"
$KEYS key 31 cmd          # ⌘O
sleep 2
shoot quickswitcher

quit_app

# ---- WebP + manifest ------------------------------------------------------
# The manifest carries intrinsic size and the variant widths. build.py reads it
# rather than measuring, so the site can be built on a machine with no image
# tools at all — and so a re-shoot updates every width/height by rebuilding
# instead of by editing eight content files.
: > "$OUT/manifest.txt"
for png in "$OUT"/*.png; do
  name="$(basename "$png" .png)"
  w=$(sips -g pixelWidth "$png" | tail -1 | tr -dc 0-9)
  h=$(sips -g pixelHeight "$png" | tail -1 | tr -dc 0-9)
  cwebp -quiet -q 82 "$png" -o "$OUT/$name.webp"
  line="$name.webp $w $h"
  for v in "${VARIANTS[@]}"; do
    [ "$v" -lt "$w" ] || continue
    magick "$png" -resize "${v}x" -strip "$OUT/$name-$v.png"
    cwebp -quiet -q 82 "$OUT/$name-$v.png" -o "$OUT/$name-$v.webp"
    rm -f "$OUT/$name-$v.png"
    line="$line $v"
  done
  echo "$line" >> "$OUT/manifest.txt"
  # The full-size PNG is a build input, not something a visitor is served.
  rm -f "$png"
done

echo
cat "$OUT/manifest.txt"
