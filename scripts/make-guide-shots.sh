#!/bin/bash
# Renders the welcome guide's screenshots from the real views and refreshes the
# asset catalog. No screen capture, no window on screen, no synthetic input.
#
#     scripts/make-guide-shots.sh
#
# Needs a Debug build. It re-signs a copy of it ad hoc with no entitlements,
# because the sandboxed app cannot read the repository or write the PNGs.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcodebuild -project Inkstone.xcodeproj -scheme Inkstone -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$WORK/dd" build | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'
cp -R "$WORK/dd/Build/Products/Debug/Inkstone.app" "$WORK/Inkstone.app"
codesign --force --deep --sign - "$WORK/Inkstone.app" >/dev/null 2>&1

INKSTONE_GUIDE_SHOTS="$WORK/raw" INKSTONE_GUIDE_SHOTS_ASSETS="$PWD/assets" \
  "$WORK/Inkstone.app/Contents/MacOS/Inkstone"
python3 scripts/make-guide-shots.py "$WORK/raw"
