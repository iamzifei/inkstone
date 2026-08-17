#!/bin/bash
#
# Builds Inkstone for a real iPhone or iPad and installs it.
#
#     Tools/install-ios.sh            # first connected device
#     Tools/install-ios.sh "James iPhone 15 Pro"
#
# The device must be connected and unlocked — over USB, or over Wi-Fi if it has
# been paired for wireless development in Xcode. Both of James's devices are
# already registered on the developer account, so no portal step is involved.

set -euo pipefail

cd "$(dirname "$0")/.."

KEY_PATH="$HOME/.private_keys/AuthKey_UYGG95M882.p8"
KEY_ID="UYGG95M882"
ISSUER_ID="ea36e3b8-3c0a-4a03-819f-24061a386eb4"
BUILD=".build-device"
APP="$BUILD/Build/Products/Debug-iphoneos/Inkstone.app"

wanted="${1:-}"

# --- Find a device -----------------------------------------------------------
xcrun devicectl list devices --json-output /tmp/inkstone-devices.json >/dev/null 2>&1

device=$(python3 - "$wanted" <<'PY'
import json, sys
wanted = sys.argv[1]
try:
    devices = json.load(open("/tmp/inkstone-devices.json"))["result"]["devices"]
except Exception:
    sys.exit(0)
for d in devices:
    name = d.get("deviceProperties", {}).get("name", "")
    model = d.get("hardwareProperties", {}).get("marketingName", "")
    state = d.get("connectionProperties", {}).get("tunnelState", "")
    if "iPhone" not in model and "iPad" not in model:
        continue
    if wanted and wanted != name:
        continue
    # "connected" covers both USB and a live wireless tunnel.
    if state == "connected":
        print(d["hardwareProperties"]["udid"])
        break
PY
)

if [[ -z "$device" ]]; then
  echo "No connected iPhone or iPad." >&2
  echo "Connect one by cable (or over Wi-Fi if paired), unlock it, and re-run." >&2
  echo >&2
  echo "Visible devices:" >&2
  xcrun devicectl list devices 2>/dev/null | sed -n '1,10p' >&2
  exit 1
fi

echo "==> Device $device"

# --- Build -------------------------------------------------------------------
# `generic/platform=iOS` rather than the specific device: it builds the same
# slice and does not fail when the device drops off Wi-Fi mid-build.
echo "==> Building"
xcodebuild -project Inkstone.xcodeproj -scheme Inkstone -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath "$BUILD" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  build | grep -E '^\*\* BUILD|error:'
# A pipeline reports grep's status, so a failed build whose output contains
# "error:" would otherwise look like success and install a stale app.
[[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "Build failed." >&2; exit 1; }

# --- Install -----------------------------------------------------------------
echo "==> Installing"
xcrun devicectl device install app --device "$device" "$APP"

echo
echo "Installed. On first launch the device may ask you to trust the developer:"
echo "  Settings → General → VPN & Device Management → Apple Development"
