#!/bin/bash
# Every automated check, in one command.
#
#   scripts/test-all.sh
#
# Exits non-zero the moment anything fails, so CI and a person get the same
# answer. Four kinds of check, named because they cover different things and a
# green run should not be read as covering more than it does:
#
#   unit        InkstoneCore — the model layer, in isolation
#   e2e         SyncEngine against a fake GitHub, two vaults, one repository
#   regression  one test per bug actually hit, inside the two suites above
#   site        the built website, plus the help URL the app links to
#   smoke       the built macOS app, driving a real vault on disk
#
# What is NOT covered: anything needing a mouse — the context menus, the Settings
# toggles, the file tree. Those need a UI-test target and a windowing session.
set -euo pipefail

cd "$(dirname "$0")/.."
FAILED=()

step() {
    echo
    echo "── $1 ─────────────────────────────────────────"
}

step "unit, e2e and regression — InkstoneCore"
if (cd Packages/InkstoneCore && swift test); then
    echo "core: pass"
else
    FAILED+=("InkstoneCore")
fi

step "site — build, links, and the app's help URL"
# No `-t .`: site/tests has no __init__.py, so the top-level directory has to
# stay the start directory. And no pipe, so the exit status is unittest's.
if python3 -m unittest discover -s site/tests; then
    echo "site: pass"
else
    FAILED+=("site")
fi

step "build — iOS"
if xcodebuild -project Inkstone.xcodeproj -scheme Inkstone -configuration Debug \
     -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -qE '\*\* BUILD SUCCEEDED'; then
    echo "iOS: pass"
else
    FAILED+=("iOS build")
fi

step "build — macOS"
if xcodebuild -project Inkstone.xcodeproj -scheme Inkstone -configuration Debug \
     -destination 'platform=macOS' build 2>&1 | grep -qE '\*\* BUILD SUCCEEDED'; then
    echo "macOS: pass"
else
    FAILED+=("macOS build")
fi

step "smoke — the built macOS app against a real vault"
APP="$(xcodebuild -project Inkstone.xcodeproj -scheme Inkstone -configuration Debug \
        -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')/Inkstone.app/Contents/MacOS/Inkstone"
if INKSTONE_SMOKE=1 "$APP"; then
    echo "smoke: pass"
else
    FAILED+=("smoke")
fi

echo
if [ ${#FAILED[@]} -eq 0 ]; then
    echo "════ everything green ════"
else
    echo "════ failed: ${FAILED[*]} ════"
    exit 1
fi
