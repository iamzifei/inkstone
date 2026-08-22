#!/usr/bin/env python3
"""Set the App Store listing fields that `asc` does not cover, via the API.

    Tools/asc_listing.py <app-id> [--version 0.1.1]

This exists because five things turned out to need the raw API, each discovered
by trying the obvious thing first and reading the error:

  * **The app name is not on the app.** It lives on an `appInfoLocalization`,
    and `asc apps info edit` has no `--name`. Worth knowing: creating the app
    with `asc apps create` silently auto-renames when the name is taken, so
    "Inkstone" became "Inkstone - inkstone" and had to be corrected here.
  * **The version string must match the build.** App creation makes a default
    `1.0`; an IPA at 0.1.1 will not attach to it.
  * **`asc metadata pull` returns only `app-info` for a fresh app**, because the
    version localization does not exist yet. It has to be created, not pushed.
  * **`whatsNew` cannot be set on a first version** — the API returns
    STATE_ERROR, which is correct: there is nothing for it to be new against.
  * **The age rating declaration requires every attribute**, not the non-null
    ones. Sending a partial set returns "you must provide a value for
    'gunsOrOtherWeapons'" one field at a time.

Everything here is idempotent: run it twice and the second run is a no-op.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

import jwt

KEY_ID = "UYGG95M882"
ISSUER = "ea36e3b8-3c0a-4a03-819f-24061a386eb4"
KEY_PATH = pathlib.Path.home() / ".private_keys" / f"AuthKey_{KEY_ID}.p8"
META = pathlib.Path(__file__).resolve().parent.parent / "fastlane" / "metadata" / "en-US"

# Every attribute the age rating declaration demands. Frequencies take "NONE",
# the rest take false. This is a text editor: no ads, no gambling, no chat, and
# no user-generated content from anyone but the person typing.
FREQUENCIES = [
    "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated",
    "gunsOrOtherWeapons", "horrorOrFearThemes", "matureOrSuggestiveThemes",
    "medicalOrTreatmentInformation", "profanityOrCrudeHumor",
    "sexualContentGraphicAndNudity", "sexualContentOrNudity",
    "violenceCartoonOrFantasy", "violenceRealisticProlongedGraphicOrSadistic",
    "violenceRealistic",
]
BOOLEANS = [
    "gambling", "unrestrictedWebAccess", "userGeneratedContent", "messagingAndChat",
    "socialMedia", "parentalControls", "advertising", "healthOrWellnessTopics",
    "lootBox", "ageAssurance", "socialMediaAgeRestricted",
]


def token() -> str:
    return jwt.encode(
        {"iss": ISSUER, "iat": int(time.time()), "exp": int(time.time()) + 900,
         "aud": "appstoreconnect-v1"},
        KEY_PATH.read_text(), algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"})


def call(method: str, path: str, body=None):
    url = path if path.startswith("http") else "https://api.appstoreconnect.apple.com" + path
    request = urllib.request.Request(
        url, data=json.dumps(body).encode() if body is not None else None, method=method,
        headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read() or b"{}")


def read(name: str) -> str:
    return (META / name).read_text(encoding="utf-8").strip()


def explain(status: int, payload: dict, label: str) -> bool:
    if status < 400:
        print(f"  ok    {label}")
        return True
    for error in payload.get("errors", [])[:3]:
        print(f"  FAIL  {label}: {error.get('code')} | {(error.get('detail') or '')[:150]}")
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("app_id")
    parser.add_argument("--version", default="0.1.1")
    args = parser.parse_args()

    status, data = call("GET", f"/v1/apps/{args.app_id}/appInfos")
    app_info = next(i for i in data["data"]
                    if i["attributes"].get("appStoreState") == "PREPARE_FOR_SUBMISSION")
    app_info_id = app_info["id"]

    # --- name, subtitle, privacy policy -----------------------------------
    status, data = call("GET", f"/v1/appInfos/{app_info_id}/appInfoLocalizations")
    localization = next(l for l in data["data"] if l["attributes"]["locale"] == "en-US")
    explain(*call("PATCH", f"/v1/appInfoLocalizations/{localization['id']}",
                  {"data": {"type": "appInfoLocalizations", "id": localization["id"],
                            "attributes": {"name": read("name.txt"),
                                           "subtitle": read("subtitle.txt"),
                                           "privacyPolicyUrl": read("privacy_url.txt")}}}),
            "name / subtitle / privacy URL")

    # --- categories --------------------------------------------------------
    explain(*call("PATCH", f"/v1/appInfos/{app_info_id}",
                  {"data": {"type": "appInfos", "id": app_info_id, "relationships": {
                      "primaryCategory": {"data": {"type": "appCategories", "id": "PRODUCTIVITY"}},
                      "secondaryCategory": {"data": {"type": "appCategories", "id": "UTILITIES"}}}}}),
            "categories")

    # --- content rights ----------------------------------------------------
    explain(*call("PATCH", f"/v1/apps/{args.app_id}",
                  {"data": {"type": "apps", "id": args.app_id,
                            "attributes": {"contentRightsDeclaration":
                                           "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}}),
            "content rights")

    # --- age rating --------------------------------------------------------
    status, data = call("GET", f"/v1/appInfos/{app_info_id}?include=ageRatingDeclaration")
    declaration = next(i for i in data.get("included", [])
                       if i["type"] == "ageRatingDeclarations")
    attributes = {k: "NONE" for k in FREQUENCIES} | {k: False for k in BOOLEANS}
    explain(*call("PATCH", f"/v1/ageRatingDeclarations/{declaration['id']}",
                  {"data": {"type": "ageRatingDeclarations", "id": declaration["id"],
                            "attributes": attributes}}),
            f"age rating ({len(attributes)} attributes)")

    # --- version string and listing copy -----------------------------------
    status, data = call("GET", f"/v1/apps/{args.app_id}/appStoreVersions")
    version = next((v for v in data["data"]
                    if v["attributes"].get("appStoreState") == "PREPARE_FOR_SUBMISSION"), None)
    if version is None:
        print("  FAIL  no editable App Store version")
        return 1
    if version["attributes"]["versionString"] != args.version:
        # App creation makes a default 1.0. A build at another version will not
        # attach to it, and the mismatch is not reported until the attach fails.
        explain(*call("PATCH", f"/v1/appStoreVersions/{version['id']}",
                      {"data": {"type": "appStoreVersions", "id": version["id"],
                                "attributes": {"versionString": args.version}}}),
                f"version string -> {args.version}")

    copy = {"description": read("description.txt"),
            "keywords": read("keywords.txt"),
            "promotionalText": read("promotional_text.txt"),
            "marketingUrl": read("marketing_url.txt"),
            "supportUrl": read("support_url.txt")}
    # whatsNew is deliberately absent. On a first version the API rejects it
    # with STATE_ERROR, and it is right to: there is no previous version.

    status, data = call("GET", f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")
    existing = {l["attributes"]["locale"]: l["id"] for l in data.get("data", [])}
    if "en-US" in existing:
        explain(*call("PATCH", f"/v1/appStoreVersionLocalizations/{existing['en-US']}",
                      {"data": {"type": "appStoreVersionLocalizations",
                                "id": existing["en-US"], "attributes": copy}}),
                "listing copy")
    else:
        explain(*call("POST", "/v1/appStoreVersionLocalizations",
                      {"data": {"type": "appStoreVersionLocalizations",
                                "attributes": copy | {"locale": "en-US"},
                                "relationships": {"appStoreVersion": {
                                    "data": {"type": "appStoreVersions", "id": version["id"]}}}}}),
                "listing copy (created)")

    print(f"\nversion localization id: {existing.get('en-US', '(new)')}")
    print("screenshots go up with:  asc screenshots upload --version-localization <id> …")
    return 0


if __name__ == "__main__":
    sys.exit(main())
