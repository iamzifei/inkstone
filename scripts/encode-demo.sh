#!/bin/bash
set -euo pipefail

# Turns the raw segments from record-demo.sh into the two files the hero plays,
# plus a poster frame.
#
#   assets/footage/*.mov      raw, ~2.7 MB/s, 120 fps, one per segment
#   site/assets/video/hero.mp4    H.264, what Safari plays
#   site/assets/video/hero.webm   VP9, smaller, what Chrome and Firefox play
#   site/assets/video/poster.webp the first frame, shown until the video decodes
#
# The crop is measured per segment, not hardcoded. `screencapture -v` ignores
# `-o`, so every frame carries the window's drop shadow — and the shadow is not
# a constant: an active window casts a bigger one, so the same 3600x2260 window
# sits inside a 3736x2396 frame when it is behind something and a 3824x2484 one
# when it is in front. A fixed crop is right for exactly the take it was
# measured on, which is how a re-shoot ends up with a sliver of desktop down one
# edge. scripts/measure-window-crop.py reads it off the frame instead.
#
# 1440x904 keeps the window's real 1800x1130 proportion exactly (both are
# 3600:2260 scaled), so nothing in the picture is stretched and the hero's
# reserved box matches the file to the pixel.
#
# Usage: ./scripts/encode-demo.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FOOTAGE="$ROOT/assets/footage"
WORK="$ROOT/assets/footage/.work"
OUT="$ROOT/site/assets/video"

SIZE="1440:904"
FPS=30
XFADE=0.45          # long enough to read as a dissolve, short enough not to wait

mkdir -p "$WORK" "$OUT"
shopt -s nullglob
SEGMENTS=("$FOOTAGE"/[0-9][0-9]-*.mov)
[ ${#SEGMENTS[@]} -gt 0 ] || { echo "error: no segments in $FOOTAGE — run record-demo.sh" >&2; exit 1; }

# ---- 1. normalise each segment ------------------------------------------
# Constant frame rate before anything else. screencapture writes a variable-rate
# 120 fps file whose timestamps xfade cannot line up; feeding those straight into
# the filter graph produces a transition that lands at the wrong moment on some
# clips and not at all on others.
NORM=()
for src in "${SEGMENTS[@]}"; do
  name="$(basename "$src" .mov)"
  dst="$WORK/$name.mp4"
  crop="$(python3 "$ROOT/scripts/measure-window-crop.py" "$src")"
  echo "==> normalising $name  (crop $crop)"
  ffmpeg -v error -y -i "$src" \
    -vf "crop=$crop,scale=$SIZE:flags=lanczos,fps=$FPS,format=yuv420p" \
    -an -c:v libx264 -crf 16 -preset veryfast "$dst"
  NORM+=("$dst")
done

duration() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }

# ---- 2. chain them with dissolves ----------------------------------------
# Each xfade offset is "everything so far, minus the overlaps already spent".
# Getting that wrong is the classic way to end up with a video that is correct
# for two clips and jumps for the rest.
if [ ${#NORM[@]} -eq 1 ]; then
  cp "${NORM[0]}" "$WORK/joined.mp4"
else
  filter=""; label="0:v"; acc=$(duration "${NORM[0]}")
  inputs=()
  for f in "${NORM[@]}"; do inputs+=(-i "$f"); done
  for i in $(seq 1 $((${#NORM[@]} - 1))); do
    offset=$(python3 -c "print(f'{max(0.0, $acc - $XFADE):.3f}')")
    out="v$i"
    filter+="[$label][$i:v]xfade=transition=fade:duration=$XFADE:offset=$offset[$out];"
    label="$out"
    acc=$(python3 -c "print(f'{$acc - $XFADE + $(duration "${NORM[$i]}"):.3f}')")
  done
  filter="${filter%;}"
  echo "==> joining ${#NORM[@]} segments"
  ffmpeg -v error -y "${inputs[@]}" -filter_complex "$filter" -map "[$label]" \
    -an -c:v libx264 -crf 16 -preset veryfast "$WORK/joined.mp4"
fi

# ---- 3. the two published encodes ----------------------------------------
# `-movflags +faststart` moves the index to the front. Without it the browser
# downloads the whole file before it can show a single frame, which on a hero
# video is the difference between "plays immediately" and "plays eventually".
echo "==> H.264"
ffmpeg -v error -y -i "$WORK/joined.mp4" \
  -an -c:v libx264 -profile:v high -crf 26 -preset slow -pix_fmt yuv420p \
  -movflags +faststart "$OUT/hero.mp4"

echo "==> VP9"
ffmpeg -v error -y -i "$WORK/joined.mp4" \
  -an -c:v libvpx-vp9 -crf 42 -b:v 0 -row-mt 1 -deadline good -cpu-used 2 \
  "$OUT/hero.webm"

# ---- 4. poster -----------------------------------------------------------
# Taken a second in rather than at zero: the first frames of a segment are the
# lead-in, and a poster of a half-drawn window is worse than no poster.
echo "==> poster"
ffmpeg -v error -y -ss 1.0 -i "$WORK/joined.mp4" -vframes 1 "$WORK/poster.png"
cwebp -quiet -q 82 "$WORK/poster.png" -o "$OUT/poster.webp"

echo
ls -lh "$OUT"
echo
echo "duration: $(duration "$OUT/hero.mp4")s"
