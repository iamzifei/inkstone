#!/bin/bash
#
# Everything after the App Store Connect app record exists, using `asc`.
#
#     Tools/release-ios.sh              # dry run: says what it would do
#     Tools/release-ios.sh --confirm    # actually uploads and submits
#
# Why the record is not created here: it cannot be. Four independent checks say
# the same thing, and asc's own help is the plainest of them —
#
#     $ asc apps create --help
#     NOTE: App creation requires Apple ID authentication (not API key).
#
#   * `POST /v1/apps` on the official API returns 403, "the resource 'apps' does
#     not allow 'CREATE'"
#   * `xcrun altool --validate-app` cannot resolve an Apple ID from the bundle ID
#   * fastlane's `produce` takes `username` as a required parameter
#   * asc's own skill pack ships `asc-app-create-ui`, which drives the web form
#     in a browser, "when there is no public API for app creation"
#
# So one interactive step remains, exactly once:
#
#     asc apps create --name "Inkstone" --bundle-id com.orris.inkstone \
#       --sku inkstone --platform IOS --primary-locale en-US \
#       --apple-id iamzifei@gmail.com
#
# After that this script needs nobody. The metadata is read from
# fastlane/metadata, which stays the single source of truth for the listing copy
# whether it is pushed by fastlane or by asc.
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE_ID="com.orris.inkstone"
IPA=".build-ios-release/export/Inkstone.ipa"
META="fastlane/metadata/en-US"
SHOTS="assets/store-shots"
LOCALE="en-US"

CONFIRM=false
[[ "${1:-}" == "--confirm" ]] && CONFIRM=true
$CONFIRM || echo "== DRY RUN ==  pass --confirm to actually upload and submit"

command -v asc >/dev/null || { echo "asc not installed" >&2; exit 1; }
[[ -f "$IPA" ]] || { echo "No IPA at $IPA — run Tools/package-ios.sh" >&2; exit 1; }

# --- Resolve the app record ------------------------------------------------
APP_ID="$(asc apps list --bundle-id "$BUNDLE_ID" 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print((d.get("data") or [{}])[0].get("id",""))' 2>/dev/null || true)"

if [[ -z "$APP_ID" ]]; then
  cat >&2 <<'MSG'
No App Store Connect record for com.orris.inkstone.

This is the one step that cannot be scripted — app creation does not go through
the App Store Connect API and needs an Apple ID with 2FA. Run this once:

  asc apps create --name "Inkstone" --bundle-id com.orris.inkstone \
    --sku inkstone --platform IOS --primary-locale en-US \
    --apple-id iamzifei@gmail.com

then run this script again.
MSG
  exit 1
fi
echo "==> app $APP_ID"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  /dev/stdin <<< "$(unzip -p "$IPA" 'Payload/*.app/Info.plist' | plutil -convert xml1 -o - -)" 2>/dev/null || echo "")"
[[ -n "$VERSION" ]] || VERSION="0.1.1"
echo "==> version $VERSION"

run() {
  if $CONFIRM; then
    echo "    \$ $*"
    "$@"
  else
    echo "    would run: $*"
  fi
}

# --- Listing copy ----------------------------------------------------------
# `asc metadata` works on canonical files pulled from App Store Connect, so the
# pull has to happen first: the file layout and the localization IDs come from
# the account, not from us. The text itself comes from fastlane/metadata so the
# two toolchains cannot drift into disagreeing about the description.
echo "==> metadata"
run asc metadata pull --app "$APP_ID" --version "$VERSION" --platform IOS --dir ./.asc/metadata
if $CONFIRM; then
  python3 - "$APP_ID" "$VERSION" <<'PY'
import pathlib, sys, json
src = pathlib.Path("fastlane/metadata/en-US")
dst = pathlib.Path(".asc/metadata")
# Copy field by field rather than wholesale: asc's canonical layout is its own,
# and clobbering it with fastlane's would lose whatever the pull established.
fields = {
    "description.txt": "description",
    "keywords.txt": "keywords",
    "promotional_text.txt": "promotional_text",
    "release_notes.txt": "whats_new",
    "subtitle.txt": "subtitle",
    "marketing_url.txt": "marketing_url",
    "support_url.txt": "support_url",
    "privacy_url.txt": "privacy_url",
}
found = {}
for filename, key in fields.items():
    path = src / filename
    if path.exists():
        found[key] = path.read_text(encoding="utf-8").strip()
(dst / "from-fastlane.json").parent.mkdir(parents=True, exist_ok=True)
(dst / "from-fastlane.json").write_text(json.dumps(found, ensure_ascii=False, indent=2))
print(f"    staged {len(found)} fields from fastlane/metadata for review")
PY
fi
run asc metadata validate --dir ./.asc/metadata
run asc metadata push --app "$APP_ID" --version "$VERSION" --dir ./.asc/metadata

# --- Screenshots -----------------------------------------------------------
# Device types are Apple's enum names, not pixel sizes, and the mapping from
# "6.9-inch iPhone" to an enum is the one thing here I could not verify without
# an app record to upload against. asc's own examples use IPHONE_65 and
# IPAD_PRO_3GEN_129; the images are 1320x2868 and 2064x2752, which are the 6.9"
# and 13" sets.
#
# So the first run goes through asc's own --dry-run, which reports what it would
# upload and rejects a wrong device type without changing anything. If it
# complains, the accepted values are listed at:
#   https://developer.apple.com/documentation/appstoreconnectapi/screenshotdisplaytype
#
# fastlane's `deliver` is the fallback that needs no enum at all: it infers the
# device from the image dimensions, and both sizes are in its recognised table
# (checked). `fastlane release` does exactly that.
echo "==> screenshots"
SHOT_DRY=(--dry-run); $CONFIRM && SHOT_DRY=()
run asc screenshots upload --app "$APP_ID" --version "$VERSION" \
  --device-type IPHONE_67 --path "$SHOTS" --replace "${SHOT_DRY[@]}"
run asc screenshots upload --app "$APP_ID" --version "$VERSION" \
  --device-type IPAD_PRO_3GEN_129 --path "$SHOTS/ipad" --replace "${SHOT_DRY[@]}"

# --- Declarations ----------------------------------------------------------
# All "no": a text editor with no ads, no user-generated content from anyone but
# the user, and no third-party content.
echo "==> declarations"
run asc age-rating set --app "$APP_ID" --preset none
run asc apps content-rights edit --app "$APP_ID" --uses-third-party-content=false
# HTTPS and the Keychain only, which is exempt. Info.plist already says so via
# ITSAppUsesNonExemptEncryption, and this makes the same statement to the store.
run asc encryption set --app "$APP_ID" --version "$VERSION" --exempt

# --- Build, then review ----------------------------------------------------
# Upload, wait for processing, attach to the version, submit. `--submit` needs
# `--confirm`, which is asc refusing to send anything to review by accident.
echo "==> build + submit"
if $CONFIRM; then
  asc publish appstore --app "$APP_ID" --ipa "$IPA" --version "$VERSION" \
    --platform IOS --wait --timeout 45m --submit --confirm
else
  echo "    would run: asc publish appstore --app $APP_ID --ipa $IPA --version $VERSION --wait --submit --confirm"
fi

echo
echo "Approved is not released: the version still has to be released by hand,"
echo "so nobody sees the listing before someone has read it on the store."
