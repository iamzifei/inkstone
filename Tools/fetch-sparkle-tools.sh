#!/bin/bash
#
# Fetches Sparkle's command-line tools into .sparkle-tools/, which the release
# script uses to sign a DMG and write the appcast.
#
# The framework itself comes through SwiftPM (see project.yml) — this is only the
# tooling, which SwiftPM does not put anywhere reachable. Downloading a pinned
# tarball rather than digging through DerivedData means the release script works
# on a clean checkout and cannot pick up a different Sparkle version than the one
# the app links against.
#
# The download is pinned by version and checked against a SHA-256, so a truncated
# or substituted archive fails here rather than signing a release with a tool
# nobody vetted. Re-running is cheap: it exits immediately if the tools are
# already present at the pinned version.
#
#     Tools/fetch-sparkle-tools.sh
set -euo pipefail

# Must match the `from:` version of the Sparkle package in project.yml. A signing
# tool from a different major version can write an appcast the framework in the
# app will not accept.
SPARKLE_VERSION="2.9.6"
SPARKLE_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/.sparkle-tools"
STAMP="$DEST/.version"

if [ -x "$DEST/sign_update" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$SPARKLE_VERSION" ]; then
  echo "Sparkle tools $SPARKLE_VERSION already present."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
echo "==> Downloading Sparkle $SPARKLE_VERSION tools"
curl -fsSL "$URL" -o "$TMP/sparkle.tar.xz"

ACTUAL="$(shasum -a 256 "$TMP/sparkle.tar.xz" | awk '{print $1}')"
if [ "$ACTUAL" != "$SPARKLE_SHA256" ]; then
  echo "error: checksum mismatch for Sparkle $SPARKLE_VERSION" >&2
  echo "  expected $SPARKLE_SHA256" >&2
  echo "  actual   $ACTUAL" >&2
  echo "If the release was legitimately re-cut, update SPARKLE_SHA256 here." >&2
  exit 1
fi

tar -xf "$TMP/sparkle.tar.xz" -C "$TMP"
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$TMP/bin/generate_keys" "$TMP/bin/sign_update" "$TMP/bin/generate_appcast" "$DEST/"
echo "$SPARKLE_VERSION" > "$STAMP"

echo "==> Sparkle tools in $DEST"
ls "$DEST"
