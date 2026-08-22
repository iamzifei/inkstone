#!/bin/bash
set -uo pipefail

# Records the raw footage for the website's hero video: one .mov per segment,
# each a scripted pass through one part of the app. Segments are separate so a
# take that goes wrong costs one segment rather than the whole minute, and so
# encode-demo.sh can reorder or drop one without a re-shoot.
#
# Six things here are not obvious, and each of them cost a bad take:
#
#   * The app is launched by running its binary, not with `open -a`.
#     LaunchServices does not forward the shell's environment, and the vault hook
#     needs it.
#   * The vault hook is inside `#if DEBUG`, so this records a **Debug** build.
#     That is a real difference and the caption on the site must not claim a
#     speed this footage cannot support.
#   * Input goes through scripts/send-keys.py, which posts to Inkstone's pid.
#     cliclick and System Events both deliver to whatever is frontmost, which is
#     useless here: the rig runs while another window covers the app, and on a
#     locked screen nothing can be brought to the front at all.
#   * Capture goes by window ID. `screencapture -R x,y,w,h` photographs whatever
#     is at those coordinates and still exits 0, so a window that failed to open
#     yields a perfectly valid film of somebody's desktop. inkstone-window.py
#     refuses to return an ID for a window that is not really on screen.
#   * The display sleeps, and a sleeping display records black. `caffeinate`
#     runs for the whole session — the first attempt at this produced a 156 KB
#     PNG of pure black and looked like a capture-permission problem.
#   * `screencapture -v` starts a beat after launch and only emits frames when
#     something changes, so every segment opens with a lead-in and a trailing
#     hold is shorter on disk than it was in real time. The sleeps below are
#     padded for that.
#
# Usage: ./scripts/record-demo.sh [output-dir]

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/assets/footage}"
APP="${INKSTONE_APP:-$ROOT/.build-demo/Build/Products/Debug/Inkstone.app}"
BIN="$APP/Contents/MacOS/Inkstone"
VAULT="${INKSTONE_VAULT:-$ROOT/assets/demo-vault}"
KEYS="python3 $ROOT/scripts/send-keys.py"
WIN="python3 $ROOT/scripts/inkstone-window.py"

[ -x "$BIN" ] || { echo "error: $BIN not found. Build it with:
  xcodebuild -project Inkstone.xcodeproj -scheme Inkstone -destination 'platform=macOS' \\
    -configuration Debug -derivedDataPath .build-demo \\
    CODE_SIGN_ENTITLEMENTS=App/Resources/Inkstone-Dev.entitlements build" >&2; exit 1; }
[ -d "$VAULT" ] || { echo "error: vault not found: $VAULT" >&2; exit 1; }
mkdir -p "$OUT"

# The scratch note segment 2 types into. Removed on the way out so the vault is
# the same before and after — a demo vault that grows an Untitled.md every run
# would eventually show one in a screenshot.
SCRATCH="$VAULT/Untitled.md"

cleanup() {
  pkill -f "screencapture -v" 2>/dev/null
  osascript -e 'quit app "Inkstone"' >/dev/null 2>&1
  pkill -f "Inkstone.app/Contents/MacOS/Inkstone" 2>/dev/null
  rm -f /tmp/inkstone-test-vault "$SCRATCH"
}
trap cleanup EXIT

# ------------------------------------------------------------------- launch

cleanup
sleep 1
caffeinate -d -u -w $$ &
echo "$VAULT|Home.md" > /tmp/inkstone-test-vault
"$BIN" >/tmp/inkstone-run.log 2>&1 &
sleep 6

read -r WID WX WY WW WH <<< "$($WIN)" || { echo "error: no Inkstone window — did it launch? see /tmp/inkstone-run.log" >&2; exit 1; }
echo "==> window $WID  ${WW}x${WH} at ${WX},${WY}"

# ------------------------------------------------------------------- helpers

REC_PID=""
# `-V` is the stop, not a safety limit. screencapture ignores SIGINT when it is
# not attached to a terminal, so an earlier version that recorded with -V 90 and
# killed the process produced five 90-second takes that all had to be trimmed by
# hand. Here each segment is given exactly the length its choreography needs and
# the recorder is waited on.
start() {   # start <name> <seconds>
  echo "==> $1 (${2}s)"
  rm -f "$OUT/$1.mov"
  screencapture -v -l"$WID" -V "$2" "$OUT/$1.mov" >/dev/null 2>&1 &
  REC_PID=$!
  sleep 1.8          # the lead-in; frames before this are usually missing
}
stop() {
  wait $REC_PID 2>/dev/null
  sleep 0.6          # screencapture finalises the container after it stops
}

# Typing, pasting and clicking all need a first responder, and an app that is
# not frontmost has no key window and therefore has none. Menu key-equivalents
# still arrive, which is why the rest of this script works regardless. This
# decides whether the two segments that need real input can run at all.
can_focus() {
  osascript -e 'tell application "Inkstone" to activate' >/dev/null 2>&1
  sleep 1
  [ "$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)" = "Inkstone" ]
}

K_RETURN=36; K_G=5; K_O=31; K_N=45; K_E=14

# Clicks need a first responder, which needs a key window, which needs the app
# to be frontmost. Menu key-equivalents arrive either way — that asymmetry is
# what decides which takes can run.
if can_focus; then FOCUS=yes; else FOCUS=no; fi
echo "==> app can be brought frontmost: $FOCUS"
[ "$FOCUS" = yes ] || cat >&2 <<'NOTE'
!! The app cannot be brought frontmost, so it has no key window and no first
!! responder: typing, pasting and clicking all go nowhere. Segments 04 (canvas)
!! and 05 (typing) are being skipped, and 02 will open the switcher without a
!! query in it. Unlock the Mac, leave no app in full screen, and run this again.
NOTE

# Sidebar row centres, in screen points, measured from a capture at this window
# size. Rows are pitched 23pt apart from Attachments at 122pt.
SIDEBAR_X=60
MAP_Y=345
# Anywhere in the body of an empty note. ⌘N opens the note but leaves the caret
# outside the text view, so the first take typed thirty characters into nothing.
EDITOR_X=900
EDITOR_Y=400

click() { cliclick -w 40 "c:$1,$2"; }

# --------------------------------------------------------------- 1. the vault
# Home, with the sidebar, the note and the inspector all on screen at once. This
# is the frame that says what kind of app this is, so it opens the film.
start 01-vault 6
sleep 1.3
$KEYS scroll -3
stop

# ------------------------------------------------------- 2. the quick switcher
start 02-switcher 9
$KEYS key $K_O cmd
sleep 1.4
if [ "$FOCUS" = yes ]; then $KEYS text 'measure' --delay 0.11; sleep 1.4; fi
$KEYS key $K_RETURN
stop

# ----------------------------------------------------------------- 3. graph
start 03-graph 6
$KEYS key $K_G cmd shift
stop

# ---------------------------------------------------------------- 4. canvas
# Opened by clicking the sidebar rather than through the switcher. Two reasons:
# the fuzzy switcher ranks "The Elements of Typographic Style" above "Map" for
# the query "Map", and a canvas opened programmatically never runs its
# fit-to-content, so it comes up as a few specks in the corner.
if [ "$FOCUS" = yes ]; then
start 04-canvas 7
click $SIDEBAR_X $MAP_Y
stop
fi

# --------------------------------------------------------- 5. mixed typing
# The claim the site makes loudest, made in the product instead of in CSS.
# Deliberately last: it creates Untitled.md, and anything recorded after it has
# a stray note in the sidebar and a stray node in the graph.
if [ "$FOCUS" = yes ]; then
start 05-typing 14
$KEYS key $K_N cmd
sleep 1.2
click $EDITOR_X $EDITOR_Y
sleep 0.6
$KEYS text '# 一行里的两种文字' --delay 0.08
sleep 0.4
$KEYS key $K_RETURN; $KEYS key $K_RETURN
sleep 0.3
$KEYS text '中英文混排 typography 的难处不在字体，在 spacing。' --delay 0.07
stop
fi

echo "==> footage:"
ls -la "$OUT"/*.mov
