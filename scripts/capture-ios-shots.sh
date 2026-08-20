#!/bin/bash
set -euo pipefail

# Captures the App Store screenshots from the simulators, at exactly the sizes
# Apple requires — 1320x2868 for the 6.9" iPhone and 2064x2752 for the 13" iPad.
# `simctl io screenshot` returns the device's native framebuffer, so nothing is
# ever resized or padded, which is what usually gets a screenshot rejected.
#
# Two things about driving it, both of which the macOS capture rig learned first:
#
#   * Most states are reached without touching the UI at all. The DEBUG-only
#     launch hook seeds a throwaway vault inside the app container and opens a
#     named note, so a screenshot of any note is a relaunch rather than a tap.
#     On iOS that hook is the *only* way to see the editor from a script — the
#     note list is a navigation stack and nothing is on screen until something is
#     tapped.
#   * The two states that do need a tap — the graph and search — are tapped with
#     cliclick against the Simulator's own window, because simctl has no tap
#     command. `simctl boot` runs headless, so Simulator.app has to be opened
#     first or there is no window to click.
#
# Usage: ./scripts/capture-ios-shots.sh [output-dir]

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/assets/ios-shots}"
VAULT="$ROOT/assets/demo-vault"
BUNDLE="com.orris.inkstone"
PHONE="${INKSTONE_PHONE:-iPhone 17 Pro Max}"   # 6.9", the size Apple asks for
PAD="${INKSTONE_PAD:-iPad Pro 13-inch (M5)}"   # 13", required because the app ships for iPad
APP="$ROOT/.build-sim/Build/Products/Debug-iphonesimulator/Inkstone.app"

command -v cliclick >/dev/null || { echo "error: cliclick not installed" >&2; exit 1; }
mkdir -p "$OUT" "$OUT/ipad"

build_for() {
  echo "==> Building for $1"
  # Debug, because the vault hook that makes this scriptable is `#if DEBUG`.
  xcodebuild -project "$ROOT/Inkstone.xcodeproj" -scheme Inkstone -configuration Debug \
    -destination "platform=iOS Simulator,name=$1" -derivedDataPath "$ROOT/.build-sim" \
    build 2>&1 | grep -E '^\*\* BUILD|error:'
}

seed() {  # seed <device>
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b >/dev/null 2>&1
  xcrun simctl install "$1" "$APP"
  # First launch creates the container and the scratch vault; only then is there
  # somewhere to copy the richer demo vault into.
  SIMCTL_CHILD_INKSTONE_SCRATCH_VAULT=1 xcrun simctl launch "$1" "$BUNDLE" >/dev/null 2>&1
  sleep 7
  local container
  container="$(xcrun simctl get_app_container "$1" "$BUNDLE" data)"
  # Home.md is excluded because the hook rewrites it on every launch, and its
  # version is a better live-preview subject anyway: a CJK heading, mixed
  # setting, tasks, a quote, a table, inline maths and a fence.
  rsync -a --exclude 'Home.md' "$VAULT/" "$container/Library/Application Support/ScratchVault/"
}

shoot() {  # shoot <device> <output-path> [note]
  xcrun simctl terminate "$1" "$BUNDLE" 2>/dev/null || true
  sleep 1
  if [ -n "${3:-}" ]; then
    SIMCTL_CHILD_INKSTONE_SCRATCH_VAULT=1 SIMCTL_CHILD_INKSTONE_OPEN_NOTE="$3" \
      xcrun simctl launch "$1" "$BUNDLE" >/dev/null 2>&1
  else
    SIMCTL_CHILD_INKSTONE_SCRATCH_VAULT=1 xcrun simctl launch "$1" "$BUNDLE" >/dev/null 2>&1
  fi
  sleep 7
  xcrun simctl io "$1" screenshot "$2" >/dev/null 2>&1
  echo "    $(basename "$2")  $(sips -g pixelWidth -g pixelHeight "$2" | tail -2 | tr -d ' \n')"
}

# ------------------------------------------------------------------- iPhone
build_for "$PHONE"
seed "$PHONE"
echo "==> iPhone 6.9\""
shoot "$PHONE" "$OUT/01-library.png"
shoot "$PHONE" "$OUT/02-live-preview.png" "Home.md"
shoot "$PHONE" "$OUT/03-typography.png"   "Typography Notes.md"
shoot "$PHONE" "$OUT/04-measure.png"      "The Measure.md"

# The graph and search need real taps. The device is 1320x2868 px = 440x956 pt at
# 3x, shown at 100% inside the Simulator window: horizontally centred, and below
# the title bar. The toolbar icons were measured off a screenshot at device px
# (683, 251) for search and (771, 251) for the graph, which is (228, 84) and
# (257, 84) in points.
open -a Simulator; sleep 5
read -r WX WY < <(python3 -c "
import Quartz
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly|Quartz.kCGWindowListExcludeDesktopElements, Quartz.kCGNullWindowID) or []:
    if 'Simulator' in str(w.get('kCGWindowOwnerName','')) and w.get('kCGWindowName') == '$PHONE':
        b = w['kCGWindowBounds']; print(int(b['X']) + 27, int(b['Y']) + 63); break
")
if [ -n "${WX:-}" ]; then
  echo "==> taps against the Simulator window at ${WX},${WY}"
  osascript -e 'tell application "Simulator" to activate' >/dev/null 2>&1; sleep 1.5
  cliclick -w 40 "c:$((WX + 257)),$((WY + 84))"; sleep 4
  xcrun simctl io "$PHONE" screenshot "$OUT/05-graph.png" >/dev/null 2>&1
  echo "    05-graph.png  $(sips -g pixelWidth -g pixelHeight "$OUT/05-graph.png" | tail -2 | tr -d ' \n')"
  cliclick -w 40 "c:$((WX + 228)),$((WY + 84))"; sleep 3
  cliclick -w 30 t:"typography"; sleep 3
  xcrun simctl io "$PHONE" screenshot "$OUT/06-search.png" >/dev/null 2>&1
  echo "    06-search.png $(sips -g pixelWidth -g pixelHeight "$OUT/06-search.png" | tail -2 | tr -d ' \n')"
else
  echo "!! Simulator window for '$PHONE' not found — skipping the graph and search shots" >&2
fi

# --------------------------------------------------------------------- iPad
build_for "$PAD"
seed "$PAD"
echo "==> iPad 13\""
shoot "$PAD" "$OUT/ipad/01-live-preview.png" "Home.md"
shoot "$PAD" "$OUT/ipad/02-typography.png"   "Typography Notes.md"
shoot "$PAD" "$OUT/ipad/03-measure.png"      "The Measure.md"

xcrun simctl terminate "$PHONE" "$BUNDLE" 2>/dev/null || true
xcrun simctl terminate "$PAD" "$BUNDLE" 2>/dev/null || true
echo
echo "==> screenshots in $OUT"
