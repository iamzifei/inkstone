#!/bin/bash
#
# Builds a signed App Store IPA at .build-ios-release/export/Inkstone.ipa, which
# is what fastlane's `release` lane uploads.
#
#     Tools/package-ios.sh
#
# Two things worth knowing before reading further:
#
#   * The **archive** is signed for development and that is normal. Xcode
#     re-signs during `-exportArchive` with an Apple Distribution certificate,
#     which `-allowProvisioningUpdates` mints from the same App Store Connect API
#     key the macOS pipeline notarises with. The check at the end is on the
#     exported IPA, not the archive.
#   * iOS gets **its own entitlements file**. The macOS one carries App Sandbox
#     keys and Sparkle's `temporary-exception.mach-lookup`, and temporary
#     exceptions are rejected by App Store validation. project.yml selects per
#     SDK; this script does not have to do anything about it, but that is why
#     the two files exist.
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="K9YT36SP4B"
KEY_PATH="$HOME/.private_keys/AuthKey_UYGG95M882.p8"
KEY_ID="UYGG95M882"
ISSUER_ID="ea36e3b8-3c0a-4a03-819f-24061a386eb4"
BUILD=".build-ios-release"

[[ -f "$KEY_PATH" ]] || { echo "Missing API key: $KEY_PATH" >&2; exit 1; }

command -v xcodegen >/dev/null && xcodegen generate >/dev/null

rm -rf "$BUILD"
mkdir -p "$BUILD"

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$KEY_PATH"
      -authenticationKeyID "$KEY_ID"
      -authenticationKeyIssuerID "$ISSUER_ID")

echo "==> Archiving for iOS"
xcodebuild -project Inkstone.xcodeproj -scheme Inkstone -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$BUILD/Inkstone.xcarchive" \
  "${AUTH[@]}" archive | grep -E '^\*\* ARCHIVE|error:'
# A pipeline reports the last command's status, so `xcodebuild | grep` looks
# successful whenever grep matches — including when what it matched was the
# error that failed the build.
[[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "Archive failed." >&2; exit 1; }

cat > "$BUILD/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
EOF

echo "==> Exporting for the App Store"
xcodebuild -exportArchive -archivePath "$BUILD/Inkstone.xcarchive" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist" \
  -exportPath "$BUILD/export" "${AUTH[@]}" | grep -E 'EXPORT SUCCEEDED|error:'
[[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "Export failed." >&2; exit 1; }

IPA="$BUILD/export/Inkstone.ipa"
[[ -f "$IPA" ]] || { echo "No IPA produced." >&2; exit 1; }

# --- Verify what actually got signed ---------------------------------------
# Not decoration. An IPA signed for development uploads and is then rejected
# minutes later by email; these three facts are what separate the two, and
# reading them here costs a second.
echo "==> Verifying the exported IPA"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q "$IPA" -d "$WORK"
APP="$WORK/Payload/Inkstone.app"

AUTHORITY="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority/ {print $2; exit}')"
ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - -)"
GTA="$(echo "$ENTS" | grep -A1 'get-task-allow' | tail -1 | tr -d ' \t')"
ICLOUD_ENV="$(echo "$ENTS" | grep -A1 'icloud-container-environment' | tail -1 | sed 's/<[^>]*>//g' | tr -d ' \t')"

printf "    signed by            %s\n" "$AUTHORITY"
printf "    get-task-allow       %s\n" "$GTA"
printf "    iCloud environment   %s\n" "$ICLOUD_ENV"

[[ "$AUTHORITY" == *"Apple Distribution"* ]] || {
  echo "Not signed for distribution — App Store upload would be rejected." >&2; exit 1; }
[[ "$GTA" == "<false/>" ]] || {
  echo "get-task-allow is not false — this is a development build." >&2; exit 1; }
[[ "$ICLOUD_ENV" == "Production" ]] || {
  echo "iCloud container is '$ICLOUD_ENV', not Production." >&2; exit 1; }
# The macOS-only entitlements must not have followed the app across.
if echo "$ENTS" | grep -q "temporary-exception"; then
  echo "A temporary-exception entitlement is present; the App Store rejects those." >&2
  exit 1
fi

# Two checks that exist because App Store upload found them and this script did
# not — and upload failure arrives minutes later, by email, after everything
# looks like it worked:
#
#   90474  no orientations declared. Not optional once the app ships for iPad:
#          multitasking requires all four.
#   90717  the large app icon contains an alpha channel. iOS masks corners
#          itself, so the marketing icon must be a fully opaque square.
ORIENT="$(/usr/libexec/PlistBuddy -c "Print :UISupportedInterfaceOrientations" "$APP/Info.plist" 2>/dev/null | grep -c UIInterfaceOrientation || true)"
IPAD_ORIENT="$(/usr/libexec/PlistBuddy -c "Print :UISupportedInterfaceOrientations~ipad" "$APP/Info.plist" 2>/dev/null | grep -c UIInterfaceOrientation || true)"
FAMILIES="$(/usr/libexec/PlistBuddy -c "Print :UIDeviceFamily" "$APP/Info.plist" 2>/dev/null | grep -c 2 || true)"
printf "    orientations         iphone=%s ipad=%s\n" "$ORIENT" "$IPAD_ORIENT"
[[ "$ORIENT" -ge 1 ]] || { echo "No UISupportedInterfaceOrientations — upload fails with 90474." >&2; exit 1; }
if [[ "$FAMILIES" -ge 1 && "$IPAD_ORIENT" -lt 4 ]]; then
  echo "Ships for iPad but declares $IPAD_ORIENT iPad orientations; multitasking needs 4." >&2
  exit 1
fi

# Checked at the source, not in the bundle: the 1024 marketing icon is compiled
# into Assets.car and is not a loose file, so inspecting $APP/AppIcon*.png reads
# the small icons and always passes. This reads the file the catalog points at.
SOURCE_ICON="App/Resources/Assets.xcassets/AppIcon.appiconset/icon-ios-light.png"
if [[ -f "$SOURCE_ICON" ]]; then
  A="$(magick identify -format '%A' "$SOURCE_ICON")"
  printf "    marketing icon alpha %s\n" "$A"
  [[ "$A" == "Undefined" || "$A" == "False" ]] || {
    echo "$SOURCE_ICON has an alpha channel — upload fails with 90717." >&2
    echo "Regenerate with Tools/generate-app-icon.py, which flattens the light one." >&2
    exit 1; }
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist")"
BUILD_NO="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Info.plist")"
echo
echo "IPA: $IPA  ($VERSION build $BUILD_NO, $(du -h "$IPA" | cut -f1))"
echo "Next: fastlane ship        # first time, asks for a 2FA code"
echo "      fastlane release     # afterwards, no human needed"
