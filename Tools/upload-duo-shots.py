#!/usr/bin/env python3
"""Upload the iPhone Duo screenshots to App Store Connect.

    Tools/upload-duo-shots.py <app-store-version-id> [--confirm]

fastlane picks a screenshot's slot from its pixel size and does not know the
iPhone Duo's inner screen, so these go up through the App Store Connect API
directly: for each language in assets/store-shots/<lang>/duo, the version's
localization gets an APP_IPHONE_DUO screenshot set whose images are replaced
by these, in file-name order. Run it after fastlane — which creates the
zh-Hans / zh-Hant localizations, and whose overwrite_screenshots would delete
this set if it ran afterwards. Needs PyJWT and cryptography (pip).

Uses the same API key as the rest of the release tooling. Without --confirm it
only prints what it would do.
"""
from __future__ import annotations

import hashlib
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import jwt  # PyJWT

ROOT = Path(__file__).resolve().parent.parent
KEY_PATH = Path.home() / ".private_keys" / "AuthKey_UYGG95M882.p8"
KEY_ID = "UYGG95M882"
ISSUER = "ea36e3b8-3c0a-4a03-819f-24061a386eb4"
API = "https://api.appstoreconnect.apple.com"
LOCALES = {"en": "en-US", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant"}
SLOT = "APP_IPHONE_DUO"


def token() -> str:
    now = int(time.time())
    return jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                      KEY_PATH.read_text(), algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})


def call(method: str, path: str, body: dict | None = None) -> dict:
    request = urllib.request.Request(
        API + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        sys.exit(f"{method} {path}: HTTP {error.code}\n{error.read().decode()[:2000]}")


def upload(set_id: str, file: Path) -> str:
    data = file.read_bytes()
    reserved = call("POST", "/v1/appScreenshots", {"data": {
        "type": "appScreenshots",
        "attributes": {"fileName": file.name, "fileSize": len(data)},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})
    shot = reserved["data"]
    for op in shot["attributes"]["uploadOperations"]:
        part = data[op["offset"]: op["offset"] + op["length"]]
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
        urllib.request.urlopen(urllib.request.Request(op["url"], data=part, method=op["method"], headers=headers))
    call("PATCH", f"/v1/appScreenshots/{shot['id']}", {"data": {
        "type": "appScreenshots", "id": shot["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    return shot["id"]


def wait_until_processed(ids: list[str]) -> None:
    pending = set(ids)
    for _ in range(60):
        for shot_id in list(pending):
            state = call("GET", f"/v1/appScreenshots/{shot_id}")["data"]["attributes"]["assetDeliveryState"]
            if state["state"] == "COMPLETE":
                pending.discard(shot_id)
            elif state["state"] == "FAILED":
                sys.exit(f"screenshot {shot_id} rejected: {state.get('errors')}")
        if not pending:
            return
        time.sleep(5)
    sys.exit(f"still processing after 5 minutes: {sorted(pending)}")


def main() -> int:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    version_id, confirm = sys.argv[1], "--confirm" in sys.argv
    localizations = call("GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")["data"]
    by_locale = {loc["attributes"]["locale"]: loc["id"] for loc in localizations}
    for lang, locale in LOCALES.items():
        files = sorted((ROOT / "assets" / "store-shots" / lang / "duo").glob("*.png"))
        if not files:
            continue
        if locale not in by_locale:
            sys.exit(f"{locale}: no localization on this version yet — run fastlane first")
        loc_id = by_locale[locale]
        sets = call("GET", f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets")["data"]
        existing = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == SLOT), None)
        print(f"{locale}: {len(files)} Duo screenshots" + (" (replacing the current set)" if existing else ""))
        if not confirm:
            continue
        old_ids: list[str] = []
        if existing:
            set_id = existing["id"]
            old_ids = [old["id"] for old in
                       call("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots?limit=200")["data"]]
        else:
            set_id = call("POST", "/v1/appScreenshotSets", {"data": {
                "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": SLOT},
                "relationships": {"appStoreVersionLocalization": {
                    "data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}})["data"]["id"]
        # New ones first, old ones removed only once the new ones are in: a
        # failure part-way leaves the old set, not an empty one.
        ids = [upload(set_id, f) for f in files]
        wait_until_processed(ids)
        for old in old_ids:
            call("DELETE", f"/v1/appScreenshots/{old}")
        print(f"  uploaded and processed: {', '.join(f.name for f in files)}")
    if not confirm:
        print("dry run — pass --confirm to upload")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
