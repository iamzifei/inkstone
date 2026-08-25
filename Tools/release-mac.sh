#!/bin/bash
#
# Publishes an already-packaged Inkstone build as a GitHub release.
#
#     Tools/release-mac.sh [--notes <file>]
#
# Run Tools/package-dmg.sh first; this uploads what it produced.
#
# This exists because of a bug that shipped and stayed shipped for four
# releases. The website's download button points at
#
#     .../releases/latest/download/Inkstone.dmg
#
# which GitHub resolves only if the latest release has an asset named *exactly*
# Inkstone.dmg. The packaging script names its output Inkstone-<version>.dmg,
# because the appcast needs to tell versions apart. Nothing reconciled the two:
# releases were being cut by hand, and "also upload a copy under the stable
# name" lived only in whoever's head was doing it. It was a 404 from 0.1.2 to
# 0.1.5.
#
# So the reconciliation is here, in the step that cannot be skipped, rather
# than in a checklist. Every release gets both names for the same file:
#
#   Inkstone-<version>.dmg  — what the appcast links, one per version, forever
#   Inkstone.dmg            — what the website links, always the newest
#
# site/tests/test_site.py::ExternalLinks fetches the second one for real, so if
# this ever drifts again the site tests fail rather than the download.

set -euo pipefail

cd "$(dirname "$0")/.."

BUILD=".build-release"
notes_file=""
[[ "${1:-}" == "--notes" ]] && notes_file="${2:?--notes needs a file}"

APP="$BUILD/export/Inkstone.app"
[[ -d "$APP" ]] || { echo "No packaged app. Run Tools/package-dmg.sh first." >&2; exit 1; }

VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
DMG="$BUILD/Inkstone-$VERSION.dmg"
TAG="v$VERSION"

[[ -f "$DMG" ]] || { echo "Missing $DMG. Run Tools/package-dmg.sh first." >&2; exit 1; }

# The stable-named copy the website links to. A copy rather than a rename: the
# appcast entry for this version must keep pointing at the versioned name after
# the next release moves the stable one on.
STABLE="$BUILD/Inkstone.dmg"
cp "$DMG" "$STABLE"

echo "==> Releasing $TAG"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" "$STABLE" --clobber
else
  args=(--title "Inkstone ${VERSION}")
  if [[ -n "$notes_file" ]]; then args+=(--notes-file "$notes_file"); else args+=(--generate-notes); fi
  gh release create "$TAG" "$DMG" "$STABLE" "${args[@]}"
fi

# --- Verify, because this is exactly the step that failed silently -----------
# `gh release upload` succeeding says the asset is in the release. It does not
# say the URL the website uses resolves — which depends on this release also
# being the *latest* one, and on the name matching to the character.
echo "==> Checking the URL the website actually links"
URL="https://github.com/iamzifei/inkstone/releases/latest/download/Inkstone.dmg"
for attempt in 1 2 3 4 5; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 30 "$URL" || echo 000)
  [[ "$code" == "200" ]] && { echo "    $URL → 200"; exit 0; }
  echo "    attempt $attempt: $code (GitHub's CDN caches the previous 404 briefly)"
  sleep 10
done
echo "$URL still returns $code. The website's download button is broken." >&2
exit 1
