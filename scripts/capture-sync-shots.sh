#!/bin/bash
# Captures the screenshots the sync guide uses.
#
#   scripts/capture-sync-shots.sh [output-dir]
#
# Everything shown is invented. The app runs against `INKSTONE_DEMO_DEFAULTS`, a
# throwaway UserDefaults suite, so the repository, branch, vault list and token
# state on screen are the ones seeded below and cannot be whoever is running
# this. That is isolation by construction — safer than blanking fields after the
# fact, which only removes what someone remembered to look at.
#
# The vault is a copy of assets/demo-vault, so no real notes appear either.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Kept apart from assets/shots, which capture-site-shots.sh owns along with the
# manifest build.py reads. These are illustrations for one page, not marketing
# shots with responsive variants.
OUT="${1:-$ROOT/site/assets/guide}"
# The sandboxed build cannot open a vault anywhere but the file picker, and a
# picker is a separate process that cannot be scripted — so the harness build
# turns the sandbox off, exactly as record-demo.sh does. Never shipped.
APP="${INKSTONE_APP:-$ROOT/.build-demo/Build/Products/Debug/Inkstone.app}"
BIN="$APP/Contents/MacOS/Inkstone"
WIN="python3 $ROOT/scripts/inkstone-window.py"
SUITE="com.orris.inkstone.shots"

[ -x "$BIN" ] || { echo "error: $BIN not found. Build it with:
  xcodebuild -project Inkstone.xcodeproj -scheme Inkstone -destination 'platform=macOS' \\
    -configuration Debug -derivedDataPath .build-demo \\
    CODE_SIGN_ENTITLEMENTS=App/Resources/Inkstone-Dev.entitlements build" >&2; exit 1; }
mkdir -p "$OUT"

# Staged inside the project rather than in $TMPDIR: the app is sandboxed, and a
# folder under /var/folders is not reachable from inside it — the vault silently
# fails to open and the capture is of an empty window.
STAGE="$ROOT/.build-shots"
mkdir -p "$STAGE"
quit_app() { pkill -f "Inkstone.app/Contents/MacOS/Inkstone" 2>/dev/null || true; sleep 1; }
cleanup() {
  quit_app
  defaults delete "$SUITE" 2>/dev/null || true
  rm -rf "$STAGE" /tmp/inkstone-test-vault
}
trap cleanup EXIT

caffeinate -d -u -w $$ &

# One vault per shot, each a fresh copy so a `.git` folder or a conflict file
# added for one picture cannot leak into the next.
stage_vault() {   # stage_vault <name>
  local dir="$STAGE/$1"
  rm -rf "$dir"
  cp -R "$ROOT/assets/demo-vault" "$dir"
  echo "$dir"
}

launch() {        # launch <vault-dir> [settings-pane]
  quit_app
  defaults delete "$SUITE" 2>/dev/null || true
  echo "$1" > /tmp/inkstone-test-vault
  INKSTONE_DEMO_DEFAULTS="$SUITE" \
  INKSTONE_DEMO_SYNC="you/notes@main" \
  INKSTONE_OPEN_SETTINGS="${2:-}" \
    "$BIN" >/tmp/inkstone-shots.log 2>&1 &
  sleep 7
  # The Settings scene has no window until something opens it. A menu
  # key-equivalent is dispatched before the responder chain, so it arrives even
  # though the app is not frontmost — which is the only reason this is
  # scriptable at all.
  if [ -n "${2:-}" ]; then
    python3 "$ROOT/scripts/send-keys.py" key 43 cmd   # ⌘,
    sleep 3
  fi
}

shoot() {         # shoot <name> [window-title]
  local args=()
  [ -n "${2:-}" ] && args=(--title "$2")
  # `${args[@]+...}` because macOS ships bash 3.2, where expanding an empty
  # array under `set -u` is an error rather than nothing — and the failure
  # surfaces as an empty window id, which reads as "no window" instead of "bad
  # shell".
  read -r WID _ _ _ _ <<< "$($WIN ${args[@]+"${args[@]}"})"
  screencapture -x -o -l"$WID" "$OUT/$1.png"
  echo "    $1.png"
}

echo "==> sync settings, GitHub configured"
V="$(stage_vault settings)"
launch "$V" sync
shoot sync-settings Sync

echo "==> the git working copy notice"
V="$(stage_vault gitvault)"
git -C "$V" init -q
launch "$V" sync
shoot sync-git-guard Sync

echo "==> conflict copies in the file list"
V="$(stage_vault conflicts)"
printf '# The Measure\n\nGitHub had a different version of this note.\n' \
  > "$V/The Measure (conflict 2026-08-23 1420).md"
printf '# Ideas\n\nGitHub had a different version of this note.\n' \
  > "$V/Ideas (conflict 2026-08-23 1420).md"
launch "$V"
shoot sync-conflict-copies
# The point of this picture is two filenames in the sidebar, and the rest of the
# window is an empty editor. Cropped at 2x, so the numbers are device pixels.
python3 "$ROOT/scripts/crop-png.py" "$OUT/sync-conflict-copies.png" 0 0 620 880

quit_app

# WebP alongside each PNG: these are large flat screenshots and the saving is
# most of the file. The PNG stays as the fallback the page names second.
if command -v cwebp >/dev/null; then
  for png in "$OUT"/sync-*.png; do
    cwebp -quiet -q 82 "$png" -o "${png%.png}.webp"
    echo "    $(basename "${png%.png}.webp")"
  done
else
  echo "note: cwebp not installed, PNGs only (brew install webp)" >&2
fi

echo "==> done: $OUT"
