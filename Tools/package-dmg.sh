#!/bin/bash
#
# Builds a signed, notarised Inkstone.dmg that opens on any Mac.
#
#     Tools/package-dmg.sh [--install]
#
# --install also replaces /Applications/Inkstone.app with the result.
#
# Needs the App Store Connect API key below, which stands in for an Xcode
# account: xcodebuild run from a terminal reports "No Accounts" even when Xcode
# itself is signed in, and notarytool would otherwise want an app-specific
# password.
#
# The order matters, and is the part that is easy to get wrong. The app is
# notarised and stapled *before* the DMG is built, then the DMG is notarised and
# stapled in turn. Doing only the DMG leaves the app without a ticket, so a copy
# dragged out of it has to reach Apple to validate — which fails offline.

set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="K9YT36SP4B"
KEY_PATH="$HOME/.private_keys/AuthKey_UYGG95M882.p8"
KEY_ID="UYGG95M882"
ISSUER_ID="ea36e3b8-3c0a-4a03-819f-24061a386eb4"
PROFILE_NAME="Inkstone Developer ID"

BUILD=".build-release"
NOTARY=(--key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER_ID")

install_app=false
[[ "${1:-}" == "--install" ]] && install_app=true

if [[ ! -f "$KEY_PATH" ]]; then
  echo "Missing API key: $KEY_PATH" >&2
  exit 1
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"

# --- Archive ---------------------------------------------------------------
echo "==> Archiving"
xcodebuild -project Inkstone.xcodeproj -scheme Inkstone -configuration Release \
  -destination 'platform=macOS' -archivePath "$BUILD/Inkstone.xcarchive" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  archive | grep -E '^\*\* ARCHIVE|error:'
# A pipeline reports the *last* command's status, so `xcodebuild | grep` looked
# successful whenever grep matched — including when what it matched was the
# compiler error that failed the build. This once shipped a stale binary while
# printing errors nobody read.
[[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "Archive failed." >&2; exit 1; }

# --- Export with Developer ID ----------------------------------------------
# Manual signing, because automatic signing cannot mint a Developer ID profile
# with this key: it fails with "Cloud signing permission error". The profile is
# created once via the App Store Connect API (see docs/plans) and lives in
# ~/Library/MobileDevice/Provisioning Profiles.
cat > "$BUILD/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key><dict>
    <key>com.orris.inkstone</key><string>$PROFILE_NAME</string>
  </dict>
  <key>destination</key><string>export</string>
</dict></plist>
EOF

echo "==> Exporting"
xcodebuild -exportArchive -archivePath "$BUILD/Inkstone.xcarchive" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist" \
  -exportPath "$BUILD/export" | grep -E 'EXPORT SUCCEEDED|error:'
[[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "Export failed." >&2; exit 1; }

APP="$BUILD/export/Inkstone.app"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
DMG="$BUILD/Inkstone-$VERSION.dmg"

# --- Notarise the app ------------------------------------------------------
echo "==> Notarising the app (a few minutes)"
ditto -c -k --keepParent "$APP" "$BUILD/Inkstone.zip"
xcrun notarytool submit "$BUILD/Inkstone.zip" --wait --timeout 30m "${NOTARY[@]}" \
  | tail -3
xcrun stapler staple "$APP"

# --- Build and notarise the DMG --------------------------------------------
echo "==> Building the disk image"
rm -rf "$BUILD/dmg"
mkdir -p "$BUILD/dmg"
cp -R "$APP" "$BUILD/dmg/"
ln -s /Applications "$BUILD/dmg/Applications"
hdiutil create -volname "Inkstone" -srcfolder "$BUILD/dmg" -ov -format UDZO "$DMG" >/dev/null

echo "==> Notarising the disk image"
xcrun notarytool submit "$DMG" --wait --timeout 30m "${NOTARY[@]}" | tail -3
xcrun stapler staple "$DMG"

# --- Verify ----------------------------------------------------------------
# Gatekeeper's own verdict, not ours: this is what a user's Mac will decide.
echo "==> Verifying"
spctl -a -vvv -t install "$APP" 2>&1 | head -3
xcrun stapler validate "$APP"

# Then actually run it. This exists because 0.1.0 shipped broken: adding Sparkle
# gave the app a framework to load, one target serves both platforms, and the
# macOS runpath was missing — so dyld looked in Contents/MacOS/Frameworks,
# found nothing, and the app died at launch with "Library missing".
#
# Every check above passed on that build. The archive succeeded, the signature
# was valid, `codesign --deep --strict` was happy, Apple notarised it twice and
# Gatekeeper accepted it. None of them load a dylib, so none of them noticed
# that the app could not start. The only check that catches this is starting it.
echo "==> Launching it, which is the only check that catches a missing library"
LAUNCH_LOG="$BUILD/launch-check.log"
"$APP/Contents/MacOS/Inkstone" >"$LAUNCH_LOG" 2>&1 &
launch_pid=$!
sleep 8
if ! kill -0 "$launch_pid" 2>/dev/null; then
  echo "The app exited instead of staying up. Output:" >&2
  sed 's/^/    /' "$LAUNCH_LOG" >&2
  exit 1
fi
kill "$launch_pid" 2>/dev/null || true
wait "$launch_pid" 2>/dev/null || true
# dyld writes its complaint to stderr before aborting, so an empty log is part
# of the pass condition rather than merely a nice-to-have.
if grep -qiE "Library not loaded|Symbol not found|image not found" "$LAUNCH_LOG"; then
  echo "The app started but dyld reported a problem:" >&2
  sed 's/^/    /' "$LAUNCH_LOG" >&2
  exit 1
fi
echo "    stayed up for 8s with no loader errors"

if $install_app; then
  echo "==> Installing to /Applications"

  # Quit a running copy first. Replacing the bundle underneath a live process
  # leaves it running the old code with nothing on screen to say so — the app
  # looks updated, behaves like the previous build, and the next bug report is
  # about a version that no longer exists.
  if pgrep -f '/Applications/Inkstone.app' >/dev/null; then
    echo "    quitting the running copy"
    osascript -e 'tell application "Inkstone" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      pgrep -f '/Applications/Inkstone.app' >/dev/null || break
      sleep 0.5
    done
    if pgrep -f '/Applications/Inkstone.app' >/dev/null; then
      echo "Inkstone would not quit — install aborted rather than replacing a running app." >&2
      exit 1
    fi
  fi

  rm -rf /Applications/Inkstone.app
  ditto "$APP" /Applications/Inkstone.app

  # Confirm what is installed is what was just built, by code signature rather
  # than by timestamp: a copy that silently failed would otherwise pass.
  built=$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash/ {print $2; exit}')
  installed=$(codesign -dvvv /Applications/Inkstone.app 2>&1 | awk -F= '/^CDHash/ {print $2; exit}')
  if [[ -z "$installed" || "$built" != "$installed" ]]; then
    echo "Installed app does not match the build ($built vs $installed)." >&2
    exit 1
  fi
  echo "    verified: /Applications/Inkstone.app matches this build"
fi

echo
echo "Disk image: $(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")  ($(du -h "$DMG" | cut -f1))"
