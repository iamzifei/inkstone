#!/bin/bash
set -euo pipefail
# Raw App Store captures for one language, on three devices:
#
#   iPhone 6.9" (1320x2868), iPad 13" (2064x2752), and iPhone Duo — the inner
#   screen, open and half-open (App Store Connect's APP_IPHONE_DUO slot).
#
#   scripts/capture-store-shots.sh en|zh-Hans|zh-Hant
#
# The app runs in that language (-AppleLanguages) on that language's demo
# vault, opened through the DEBUG hook; every state is reached through
# DemoDirector commands, so nothing is tapped. The status bar reads 9:41.
# make-store-shots.py composes the captions afterwards.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LANG_CODE="${1:?en, zh-Hans or zh-Hant}"
BUNDLE="com.orris.inkstone"
PHONE="${INKSTONE_PHONE:-iPhone 17 Pro Max}"
PAD="${INKSTONE_PAD:-iPad Pro 13-inch (M5)}"
DUO="${INKSTONE_DUO:-Inkstone Duo}"
APP="$ROOT/.build-sim/Build/Products/Debug-iphonesimulator/Inkstone.app"
HUB=/Users/james/.nvm/versions/node/v22.14.0/bin/agent-desktop

case "$LANG_CODE" in
  en)      SRC=demo-vault;         NAME="Notes";   LOCALE=en_AU
           HOME_N="Home.md"; TYPO="Typography Notes.md"; MEASURE="The Measure.md"; SEARCH="typography"
           PROJECT="Projects/Inkstone.md"; CALLOUT="Notes/Files as Truth.md"; READING="Reading/Bringhurst.md" ;;
  zh-Hans) SRC=demo-vault-zh;      NAME="我的笔记"; LOCALE=zh_CN
           HOME_N="首页.md"; TYPO="排版笔记.md"; MEASURE="行长.md"; SEARCH="排版"
           PROJECT="项目/Inkstone.md"; CALLOUT="笔记/文件即真相.md"; READING="阅读/布林赫斯特.md" ;;
  zh-Hant) SRC=demo-vault-zh-Hant; NAME="我的筆記"; LOCALE=zh_TW
           HOME_N="首頁.md"; TYPO="排版筆記.md"; MEASURE="行長.md"; SEARCH="排版"
           PROJECT="專案/Inkstone.md"; CALLOUT="筆記/檔案即真相.md"; READING="閱讀/布林赫斯特.md" ;;
  *) echo "unknown language $LANG_CODE" >&2; exit 1 ;;
esac
OUT="$ROOT/assets/ios-shots/$LANG_CODE"
WORK="$(mktemp -d -t inkstone-shots)"
VAULT="$WORK/$NAME"
cp -R "$ROOT/assets/$SRC" "$VAULT"
CMD="$WORK/commands.txt"
mkdir -p "$OUT/iphone" "$OUT/ipad" "$OUT/duo"

dims() { sips -g pixelWidth -g pixelHeight "$1" | tail -2 | awk '{printf "%s ", $2}'; }

prepare() {  # prepare <device>
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b >/dev/null 2>&1
  xcrun simctl status_bar "$1" override --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
  xcrun simctl install "$1" "$APP"
  xcrun simctl spawn "$1" defaults write com.apple.Preferences DidShowContinuousPathIntroduction -bool true
}

launch() {  # launch <device>   (fresh process, command file emptied)
  xcrun simctl terminate "$1" "$BUNDLE" 2>/dev/null || true
  sleep 1
  : > "$CMD"
  SIMCTL_CHILD_INKSTONE_OPEN_VAULT="$VAULT" SIMCTL_CHILD_INKSTONE_DEMO_COMMANDS="$CMD" \
    xcrun simctl launch "$1" "$BUNDLE" -AppleLanguages "($LANG_CODE)" -AppleLocale "$LOCALE" >/dev/null
  sleep 7
}

say() { echo "$1" >> "$CMD"; sleep "${2:-3}"; }

snap() {  # snap <device> <file> [display-uuid]
  if [ -n "${3:-}" ]; then
    xcrun simctl io "$1" screenshot --display="$3" "$2" >/dev/null 2>&1
  else
    xcrun simctl io "$1" screenshot "$2" >/dev/null 2>&1
  fi
  echo "    $(basename "$2")  $(dims "$2")"
}

# ------------------------------------------------------------------ iPhone
prepare "$PHONE"
echo "==> iPhone 6.9\" ($LANG_CODE)"
launch "$PHONE";                         snap "$PHONE" "$OUT/iphone/01-library.png"
launch "$PHONE"; say "open $HOME_N";     snap "$PHONE" "$OUT/iphone/02-live-preview.png"
launch "$PHONE"; say "open $TYPO";       snap "$PHONE" "$OUT/iphone/03-typography.png"
launch "$PHONE"; say "open $MEASURE";    snap "$PHONE" "$OUT/iphone/04-measure.png"
launch "$PHONE"; say "graph" 6;          snap "$PHONE" "$OUT/iphone/05-graph.png"
launch "$PHONE"; say "switcher $SEARCH"; snap "$PHONE" "$OUT/iphone/06-search.png"
launch "$PHONE"; say "open $HOME_N"; say "palette"; snap "$PHONE" "$OUT/iphone/07-palette.png"
xcrun simctl terminate "$PHONE" "$BUNDLE" 2>/dev/null || true

# -------------------------------------------------------------------- iPad
prepare "$PAD"
echo "==> iPad 13\" ($LANG_CODE)"
launch "$PAD"; say "open $HOME_N";   snap "$PAD" "$OUT/ipad/01-live-preview.png"
launch "$PAD"; say "open $TYPO";     snap "$PAD" "$OUT/ipad/02-typography.png"
launch "$PAD"; say "open $MEASURE"; say "inspector on"; snap "$PAD" "$OUT/ipad/03-measure.png"
launch "$PAD"; say "open $PROJECT" 5; snap "$PAD" "$OUT/ipad/04-project.png"
launch "$PAD"; say "open $CALLOUT";  snap "$PAD" "$OUT/ipad/05-callout.png"
launch "$PAD"; say "open $READING"; say "mode reading"; snap "$PAD" "$OUT/ipad/06-reading.png"
say "mode live" 1
xcrun simctl terminate "$PAD" "$BUNDLE" 2>/dev/null || true

# --------------------------------------------------------------------- Duo
hub() {  # press a Device Hub posture button
  local ref
  ref=$("$HUB" snapshot --app DeviceHub -i 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
def walk(n):
    if n.get('name')==sys.argv[1] and n.get('role')=='button': print(n['ref_id']); sys.exit()
    for c in n.get('children',[]): walk(c)
walk(d['data']['tree'])" "$1")
  "$HUB" click "$ref" >/dev/null 2>&1
  sleep 3
}
inner() { xcrun simctl io "$DUO" enumerate | awk '/UUID/{u=$2} /Default width/{w=$3} /Default height/{if (w"x"$3=="2007x2853") print u}'; }
prepare "$DUO"
# Device Hub drives the hinge; it has to be running.
open -g /Applications/Xcode.app/Contents/Applications/DeviceHub.app; sleep 4
echo "==> iPhone Duo, inner screen ($LANG_CODE)"
hub "Open"
launch "$DUO"; say "open $HOME_N";   snap "$DUO" "$OUT/duo/01-open.png" "$(inner)"
launch "$DUO"; say "open $TYPO"; hub "Partially Open"; snap "$DUO" "$OUT/duo/02-half-open.png" "$(inner)"
hub "Open"
launch "$DUO"; say "graph" 6;        snap "$DUO" "$OUT/duo/03-graph.png" "$(inner)"
xcrun simctl terminate "$DUO" "$BUNDLE" 2>/dev/null || true

rm -rf "$WORK"
echo
echo "==> raw screenshots in $OUT"
