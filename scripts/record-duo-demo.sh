#!/bin/bash
set -euo pipefail
# Records the iPhone Duo demo on the "Inkstone Duo" simulator (iOS 27.2):
# folded → unfolded → half-open as a book → half-open upright.
#
# The app is driven by DemoDirector (debug builds: a command file it polls),
# the hinge by Device Hub's Closed / Partially Open / Open / Rotate buttons
# through agent-desktop. Raw takes land in assets/footage-duo/; encode with
# scripts/encode-duo-demo.sh.
#
# Needs: a Debug build in .build-sim, Device Hub open, agent-desktop.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="Inkstone Duo"
OUT="$ROOT/assets/footage-duo"
WORK="${TMPDIR:-/tmp}/inkstone-duo-demo"
AD="${AGENT_DESKTOP:-agent-desktop}"
APP="$ROOT/.build-sim/Build/Products/Debug-iphonesimulator/Inkstone.app"

mkdir -p "$OUT"; rm -rf "$WORK"; mkdir -p "$WORK"
cp -R "$ROOT/assets/demo-vault" "$WORK/Demo"
CMD="$WORK/commands.txt"; : > "$CMD"
say() { echo "$1" >> "$CMD"; }

hub() {  # press a Device Hub button by name
  local ref
  ref=$("$AD" snapshot --app DeviceHub -i 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
def walk(n):
    if n.get('name')==sys.argv[1] and n.get('role')=='button': print(n['ref_id']); sys.exit()
    for c in n.get('children',[]): walk(c)
walk(d['data']['tree'])" "$1")
  [ -n "$ref" ] || { echo "Device Hub button not found: $1" >&2; exit 1; }
  "$AD" click "$ref" >/dev/null
}

display() {  # UUID of the display with the given size, e.g. 1398x2034
  xcrun simctl io "$SIM" enumerate | awk -v want="$1" '/UUID/{u=$2} /Default width/{w=$3} /Default height/{if (w"x"$3==want) print u}'
}

record_start() { xcrun simctl io "$SIM" recordVideo --display="$1" --codec=h264 --force "$2" 2>/dev/null & REC=$!; sleep 1.2; }
# Stops after a tail: simctl starts writing about a second late, and the last
# action needs time on screen.
record_stop()  { sleep 1.5; kill -INT "$REC"; wait "$REC" 2>/dev/null || true; }

OUTER=$(display 1398x2034); INNER=$(display 2007x2853)
echo "outer=$OUTER inner=$INNER"

xcrun simctl status_bar "$SIM" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 || true
xcrun simctl install "$SIM" "$APP"
hub "Closed"; sleep 2
xcrun simctl terminate "$SIM" com.orris.inkstone 2>/dev/null || true
SIMCTL_CHILD_INKSTONE_OPEN_VAULT="$WORK/Demo" SIMCTL_CHILD_INKSTONE_DEMO_COMMANDS="$CMD" \
  xcrun simctl launch "$SIM" com.orris.inkstone >/dev/null
sleep 6

# 1. Folded: the list, then a note.
record_start "$OUTER" "$OUT/01-folded.mov"
sleep 1.5; say "open Home.md"; sleep 4
record_stop

# 2. Unfolded: the same note, now with the sidebar; follow a link.
hub "Open"; sleep 2
record_start "$INNER" "$OUT/02-unfolded.mov"
sleep 2.5; say "follow Typography Notes"; sleep 3.5
record_stop

# 3. Half-open like a book: note on the left page, inspector on the right.
record_start "$INNER" "$OUT/03-book.mov"
sleep 1.5; hub "Partially Open"; sleep 3.5; say "follow The Measure"; sleep 3
record_stop

# 4. Half-open upright: note above the crease, inspector below.
hub "Rotate Right"; sleep 2.5
record_start "$INNER" "$OUT/04-upright.mov"
sleep 2; say "follow Typography Notes"; sleep 3
record_stop

# Leave the simulator as found.
hub "Rotate Right"; sleep 0.5; hub "Rotate Right"; sleep 0.5; hub "Rotate Right"; sleep 0.5
hub "Open"
xcrun simctl status_bar "$SIM" clear || true
ls -lh "$OUT"
