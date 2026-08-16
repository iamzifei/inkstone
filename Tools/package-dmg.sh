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

if $install_app; then
  echo "==> Installing to /Applications"
  rm -rf /Applications/Inkstone.app
  ditto "$APP" /Applications/Inkstone.app
fi

echo
echo "Disk image: $(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")  ($(du -h "$DMG" | cut -f1))"
