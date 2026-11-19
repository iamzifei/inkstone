#!/bin/bash
set -euo pipefail
# Mac knowledge-base screens for the website, as real window captures (the
# system's own title bar, corners and shadow), for one language:
#
#   scripts/capture-mac-kb-shots.sh en|zh-Hans|zh-Hant
#
# Uses an unsigned DEBUG build (no sandbox, so DemoDirector can read its
# command file; for local captures only, never shipped):
#   xcodebuild … -configuration Debug -destination 'platform=macOS' \
#     -derivedDataPath .build-mac-shots CODE_SIGNING_ALLOWED=NO build
# The knowledge base is the scratch one (~/Library/Application Support/
# ScratchKnowledgeBase, recreated each launch); settings are an isolated
# defaults suite. Windows are captured by id, so nothing needs to be in front.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LANG_CODE="${1:?en, zh-Hans or zh-Hant}"
APP="$ROOT/.build-mac-shots/Build/Products/Debug/Inkstone.app"
[ -d "$APP" ] || { echo "Build the unsigned Mac app first (.build-mac-shots)." >&2; exit 1; }
OUT="${INKSTONE_SHOTS_OUT:-$ROOT/assets/site-shots}/$LANG_CODE/mac"
CMD="$(mktemp -t inkstone-mac-cmd)"
mkdir -p "$OUT"

winid() {  # the Inkstone window whose title matches $1 (default: the main window)
  python3 - "$1" <<'PY'
import sys, Quartz
want = sys.argv[1]
wins = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
best = None
for w in wins:
    if w.get('kCGWindowOwnerName') != 'Inkstone' or w.get('kCGWindowLayer', 0) != 0: continue
    b = w['kCGWindowBounds']
    if b['Width'] < 300 or b['Height'] < 200: continue
    name = w.get('kCGWindowName') or ''
    if want == 'other':                      # a window that isn't the main one (Settings)
        if name == 'Inkstone': continue
    elif want and want not in name: continue
    area = b['Width'] * b['Height']
    if best is None or area > best[0]: best = (area, w['kCGWindowNumber'])
print(best[1] if best else '')
PY
}
launch() {
  pkill -f "$APP/Contents/MacOS/Inkstone" 2>/dev/null || true
  sleep 1
  : > "$CMD"
  open -n --env INKSTONE_DEMO_DEFAULTS=com.orris.inkstone.shots --env INKSTONE_SCRATCH_KB=seed \
    --env INKSTONE_DEMO_COMMANDS="$CMD" --env INKSTONE_APPEARANCE=light "$@" "$APP" \
    --args -AppleLanguages "($LANG_CODE)"
  sleep 10
  echo "window 1280 800" >> "$CMD"; sleep 2
}
say() { echo "$1" >> "$CMD"; sleep "${2:-3}"; }
snap() {  # snap <file> [window-title]
  local id; id="$(winid "${2:-}")"
  [ -n "$id" ] || { echo "no window for ${2:-main}" >&2; exit 1; }
  screencapture -x -l "$id" "$1"
  echo "    $(basename "$1")  $(sips -g pixelWidth -g pixelHeight "$1" | tail -2 | awk '{printf "%s ", $2}')"
}

echo "==> Mac ($LANG_CODE)"
if [ "${INKSTONE_ONLY:-}" = settings ]; then   # just the Settings window
  launch --env INKSTONE_OPEN_SETTINGS=knowledgeBase; say kb-card-off 12; say kb-confirm 3; say settings 5
  snap "$OUT/k5-settings.png" other
  pkill -f "$APP/Contents/MacOS/Inkstone" 2>/dev/null || true; rm -f "$CMD"; exit 0
fi
launch; say kb-card-off 12;                  snap "$OUT/k1-plan.png"
        say kb-confirm 4;                    snap "$OUT/k2-organized.png"
launch; say kb-card-off 12; say kb-confirm 4; say "open AGENTS.md" 4; snap "$OUT/k3-agents.png"
launch; say kb-card-off 12; say kb-confirm 4; say kb-drop 3; snap "$OUT/k4-drop.png"
launch --env INKSTONE_OPEN_SETTINGS=knowledgeBase; say kb-card-off 12; say kb-confirm 3; say settings 4
        snap "$OUT/k5-settings.png" other
launch; say kb-card-off 4; say welcome 3;    snap "$OUT/k6-welcome.png"
pkill -f "$APP/Contents/MacOS/Inkstone" 2>/dev/null || true
rm -f "$CMD"
echo "==> Mac window captures in $OUT"
