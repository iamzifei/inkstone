#!/bin/bash
set -euo pipefail
# Turns the raw takes from record-duo-demo.sh into the site's iPhone Duo film:
#   site/assets/video/duo.mp4 / duo.webm / duo-poster.webp
#
# The simulator records at a variable frame rate and stops writing when the
# screen stops changing, so a take ends at its last change. Each segment is
# trimmed at the front and held on its last frame (tpad) for the time a reader
# needs, then fitted onto one 1600x1000 canvas — folded and upright takes are
# portrait, unfolded and book takes landscape — and joined with dissolves.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="$ROOT/assets/footage-duo"
WORK="$IN/.work"
OUT="$ROOT/site/assets/video"
W=1600; H=1000; FPS=30; XFADE=0.5
BG="0xF1EFE8"      # the site's code-block paper, so portrait takes sit on paper
mkdir -p "$WORK" "$OUT"

#        take          start  hold
SEGS=(  "01-folded     0.0    1.5"
        "02-unfolded   1.8    2.5"
        "03-book       0.0    2.0"
        "04-upright    1.4    2.5" )

NORM=()
for row in "${SEGS[@]}"; do
  read -r name start hold <<<"$row"
  src="$IN/$name.mov"; dst="$WORK/$name.mp4"
  echo "==> $name (from ${start}s, hold ${hold}s)"
  # ffmpeg applies the recording's rotation metadata itself; fps before tpad
  # turns the variable-rate take into frames tpad can clone.
  # Trimmed after fps, not with -ss: a take can hold one frame for seconds,
  # and seeking into it lands past the only frame there is.
  ffmpeg -v error -y -i "$src" \
    -vf "fps=$FPS,trim=start=$start,setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration=$hold,scale=w=$W-80:h=$H-80:force_original_aspect_ratio=decrease:flags=lanczos,pad=$W:$H:(ow-iw)/2:(oh-ih)/2:color=$BG,format=yuv420p" \
    -an -c:v libx264 -crf 16 -preset veryfast "$dst"
  NORM+=("$dst")
done

duration() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
filter=""; label="0:v"; acc=$(duration "${NORM[0]}"); inputs=()
for f in "${NORM[@]}"; do inputs+=(-i "$f"); done
for i in $(seq 1 $((${#NORM[@]} - 1))); do
  offset=$(python3 -c "print(f'{max(0.0, $acc - $XFADE):.3f}')")
  filter+="[$label][$i:v]xfade=transition=fade:duration=$XFADE:offset=$offset[v$i];"
  label="v$i"
  acc=$(python3 -c "print(f'{$acc - $XFADE + $(duration "${NORM[$i]}"):.3f}')")
done
ffmpeg -v error -y "${inputs[@]}" -filter_complex "${filter%;}" -map "[$label]" \
  -an -c:v libx264 -crf 16 -preset veryfast "$WORK/joined.mp4"

ffmpeg -v error -y -i "$WORK/joined.mp4" -an -c:v libx264 -profile:v high -crf 26 -preset slow \
  -pix_fmt yuv420p -movflags +faststart "$OUT/duo.mp4"
ffmpeg -v error -y -i "$WORK/joined.mp4" -an -c:v libvpx-vp9 -pix_fmt yuv420p -crf 42 -b:v 0 -row-mt 1 \
  -deadline good -cpu-used 2 "$OUT/duo.webm"
ffmpeg -v error -y -ss 1.0 -i "$WORK/joined.mp4" -vframes 1 "$WORK/poster.png"
cwebp -quiet -q 82 "$WORK/poster.png" -o "$OUT/duo-poster.webp"
ls -lh "$OUT"/duo*; echo "duration: $(duration "$OUT/duo.mp4")s"
