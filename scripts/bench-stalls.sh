#!/bin/bash
set -euo pipefail
# Main-thread stall benchmark: scripted actions, measured by MainStallMonitor.
#
#   scripts/bench-stalls.sh ios|mac <out.tsv> [runs=3]
#
# Builds nothing. Expects an optimised DEBUG build (DemoDirector and the
# monitor exist only in DEBUG; -O so the numbers are about the code, not the
# debug build):
#   ios: xcodebuild -scheme Inkstone -configuration Debug \
#          -destination 'generic/platform=iOS Simulator' -derivedDataPath .build-sim-opt \
#          SWIFT_OPTIMIZATION_LEVEL=-O build
#   mac: xcodebuild -scheme Inkstone -configuration Debug -destination 'platform=macOS' \
#          -derivedDataPath .build-mac-opt SWIFT_OPTIMIZATION_LEVEL=-O CODE_SIGNING_ALLOWED=NO build
# The vault is scripts/make-bench-vault.py's, regenerated on every run.
#
# Each segment line in <out.tsv>: label, frames over 16.7 ms, longest stall
# (ms), main-thread time blocked beyond one frame (ms). Lower is better.
# On the Mac the window should be on screen: an occluded window skips drawing,
# which hides part of the cost. The simulator renders regardless.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:?ios or mac}"; OUT="${2:?output tsv}"; RUNS="${3:-3}"
# Absolute: the app writes it, and its working directory is not this one.
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
VAULT="${INKSTONE_BENCH_VAULT:-$HOME/Library/Caches/inkstone-bench-vault}"
# Regenerated every time: typing segments edit it, and runs must start equal.
rm -rf "$VAULT"; python3 "$ROOT/scripts/make-bench-vault.py" "$VAULT" 3000
CMD="$(mktemp -t inkstone-bench-cmd)"
: > "$OUT"
say() { echo "$1" >> "$CMD"; sleep "${2:-0.6}"; }

start() {
  : > "$CMD"
  case "$TARGET" in
    ios)
      local dev="${INKSTONE_BENCH_DEVICE:-iPhone 18 Pro}"
      local app="$ROOT/.build-sim-opt/Build/Products/Debug-iphonesimulator/Inkstone.app"
      xcrun simctl terminate "$dev" com.orris.inkstone 2>/dev/null || true
      xcrun simctl install "$dev" "$app"
      # The simulator app may read host paths but not write them: it writes
      # inside its own container, copied out after each run (collect).
      SIMOUT="$(xcrun simctl get_app_container "$dev" com.orris.inkstone data)/tmp/stalls.tsv"
      rm -f "$SIMOUT"
      env SIMCTL_CHILD_INKSTONE_OPEN_VAULT="$VAULT" SIMCTL_CHILD_INKSTONE_DEMO_COMMANDS="$CMD" \
          SIMCTL_CHILD_INKSTONE_STALL_OUT="$SIMOUT" \
        xcrun simctl launch "$dev" com.orris.inkstone >/dev/null ;;
    mac)
      local app="$ROOT/.build-mac-opt/Build/Products/Debug/Inkstone.app"
      pkill -f "$app/Contents/MacOS/Inkstone" 2>/dev/null || true; sleep 1
      # -g: launched in the background, so it never takes focus from what
      # the person at the Mac is doing.
      open -g -n --env INKSTONE_OPEN_VAULT="$VAULT" --env INKSTONE_DEMO_COMMANDS="$CMD" \
        --env INKSTONE_STALL_OUT="$OUT" --env INKSTONE_DEMO_DEFAULTS=com.orris.inkstone.bench "$app" ;;
  esac
  sleep 25          # open the vault and build the index
}

for run in $(seq 1 "$RUNS"); do
  start
  say "stall-mark idle" 5; say "stall-report" 1

  say "stall-mark switch"
  for i in 1 2 3; do for n in A B C D E F G H; do say "open Switch/$n.md" 0.7; done; done
  sleep 1; say "stall-report" 1

  say "stall-mark long-open"
  for i in 1 2 3; do for n in Long Long-1 Long-2 Long-3; do say "open Long/$n.md" 1.2; done; done
  sleep 1; say "stall-report" 1

  say "open Switch/A.md" 2
  say "stall-mark typing"
  for i in $(seq 1 30); do say "type x" 0.15; done
  sleep 4; say "stall-report" 1          # autosave and the reindex it wakes

  say "stall-mark gallery"
  say "open Images/Gallery.md" 6
  say "stall-report" 1

  if [ "$TARGET" = ios ]; then cat "$SIMOUT" >> "$OUT"; fi
  echo "  run $run done"
done
case "$TARGET" in
  ios) xcrun simctl terminate "${INKSTONE_BENCH_DEVICE:-iPhone 18 Pro}" com.orris.inkstone 2>/dev/null || true ;;
  mac) pkill -f "$ROOT/.build-mac-opt/Build/Products/Debug/Inkstone.app/Contents/MacOS/Inkstone" 2>/dev/null || true ;;
esac
# Median per label across runs.
python3 - "$OUT" <<'PY'
import sys, statistics as st, collections
rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    p = line.split("\t")
    if len(p) == 4: rows[p[0]].append([float(x) for x in p[1:]])
print(f"{'segment':<12}{'frames>16.7ms':>15}{'longest ms':>12}{'blocked ms':>12}   (median of {max(len(v) for v in rows.values())} runs)")
for k, v in rows.items():
    print(f"{k:<12}{st.median(r[0] for r in v):>15.0f}{st.median(r[1] for r in v):>12.1f}{st.median(r[2] for r in v):>12.1f}")
PY
