#!/bin/bash
set -euo pipefail
# Raw App Store captures of the knowledge-base screens, for one language:
#
#   scripts/capture-kb-shots.sh en|zh-Hans|zh-Hant
#
# Each scene launches a fresh knowledge base made the way the first-run guide
# makes one (the DEBUG hook INKSTONE_SCRATCH_KB=seed, which also drops sample
# files in its inbox) and reaches its state through DemoDirector commands —
# nothing is tapped. Lands next to the editor shots in assets/ios-shots/<lang>/.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LANG_CODE="${1:?en, zh-Hans or zh-Hant}"
BUNDLE="com.orris.inkstone"
PHONE="${INKSTONE_PHONE:-iPhone 17 Pro Max}"
PAD="${INKSTONE_PAD:-iPad Pro 13-inch (M5)}"
APP="$ROOT/.build-sim/Build/Products/Debug-iphonesimulator/Inkstone.app"
case "$LANG_CODE" in
  en) LOCALE=en_AU ;; zh-Hans) LOCALE=zh_CN ;; zh-Hant) LOCALE=zh_TW ;;
  *) echo "unknown language $LANG_CODE" >&2; exit 1 ;;
esac
[ -d "$APP" ] || { echo "Build the simulator app first (.build-sim)." >&2; exit 1; }
# INKSTONE_SHOTS_OUT: somewhere else (the website's captures); INKSTONE_ONLY_PHONE=1 skips the iPad.
OUT="${INKSTONE_SHOTS_OUT:-$ROOT/assets/ios-shots}/$LANG_CODE"
CMD="$(mktemp -t inkstone-kb-cmd)"
mkdir -p "$OUT/iphone" "$OUT/ipad"

prepare() {
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b >/dev/null 2>&1
  xcrun simctl status_bar "$1" override --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
  # Fresh install: no vaults from earlier runs in the welcome screen's list.
  xcrun simctl uninstall "$1" "$BUNDLE" 2>/dev/null || true
  xcrun simctl install "$1" "$APP"
}
launch() {  # launch <device> [extra env assignments…]
  local dev="$1"; shift
  xcrun simctl terminate "$dev" "$BUNDLE" 2>/dev/null || true
  sleep 1
  : > "$CMD"
  env SIMCTL_CHILD_INKSTONE_SCRATCH_KB=seed SIMCTL_CHILD_INKSTONE_DEMO_COMMANDS="$CMD" "$@" \
    xcrun simctl launch "$dev" "$BUNDLE" -AppleLanguages "($LANG_CODE)" -AppleLocale "$LOCALE" >/dev/null
  sleep 9
}
say() { echo "$1" >> "$CMD"; sleep "${2:-3}"; }
snap() { xcrun simctl io "$1" screenshot "$2" >/dev/null 2>&1 || { echo "screenshot failed: $2" >&2; exit 1; }; echo "    $(basename "$2")"; }

DEVICES=("$PHONE"); [ -n "${INKSTONE_ONLY_PHONE:-}" ] || DEVICES+=("$PAD")
for DEV in "${DEVICES[@]}"; do
  prepare "$DEV"
  if [ "$DEV" = "$PHONE" ]; then D=iphone; else D=ipad; fi
  echo "==> $D ($LANG_CODE)"
  launch "$DEV"; say kb-card-off 4;            snap "$DEV" "$OUT/$D/k1-plan.png"
                 say kb-confirm 3;             snap "$DEV" "$OUT/$D/k2-organized.png"
  launch "$DEV"; say kb-card-off 3; say kb-confirm 3; say "open AGENTS.md" 4; snap "$DEV" "$OUT/$D/k3-agents.png"
  launch "$DEV"; say kb-card-off 2; say kb-drop 3; snap "$DEV" "$OUT/$D/k4-drop.png"
  launch "$DEV" SIMCTL_CHILD_INKSTONE_OPEN_SETTINGS=knowledgeBase; say kb-card-off 3; snap "$DEV" "$OUT/$D/k5-settings.png"
  launch "$DEV"; say kb-card-off 2; say welcome 3; snap "$DEV" "$OUT/$D/k6-welcome.png"
  xcrun simctl terminate "$DEV" "$BUNDLE" 2>/dev/null || true
done
rm -f "$CMD"
echo "==> raw knowledge-base screenshots in $OUT"
