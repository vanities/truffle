# /// script
# requires-python = ">=3.11"
# dependencies = ["PyJWT>=2.8", "cryptography>=42", "requests>=2.31"]
# ///
"""Fill in the App Store listing for Truffle via the App Store Connect API.

Idempotent: safe to re-run. Reads credentials like scripts/testflight.py.

  uv run --script scripts/appstore.py setup                 # categories, age rating, rights, URLs, version + copy, price, review info
  uv run --script scripts/appstore.py screenshots DIR       # upload marketing/iphone (6.9" iPhone) or marketing/ipad (13" iPad)
  uv run --script scripts/appstore.py attach-build [N]      # bind a processed TestFlight build (default: newest) to the version
  uv run --script scripts/appstore.py status                # print what App Store Connect has
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import sys
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("tf", ROOT / "testflight.py")
tf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tf)  # type: ignore[union-attr]

VERSION = "1.0.0"
LOCALE = "en-US"
SITE = "https://am2.biz/truffle"

COPY = {
    "subtitle": "Plex music, made for the car",
    "promotionalText": "Shuffle All that's actually random, a CarPlay screen with only the good buttons, and mixes that know what month it is. Plex music, but sweeter.",
    "description": """Plex music, but sweeter.

Truffle is a music player for your Plex server, made for the car. Sign in with Plex and your whole library is right there: no syncing, no uploading, no catalog to rent.

EVERY SONG. NO FAVORITES.
Shuffle All plays your library in a truly random order, every song once before any song twice. Not your ratings, not your play counts, not what's popular. Just luck.

ONLY THE GOOD BUTTONS
CarPlay gets a big Shuffle All, your likes, the season's mixes and your playlists. Now Playing adds one button: the heart.

MIXES THAT KNOW WHAT MONTH IT IS
Halloween, Thanksgiving, the holidays, New Year, Valentine's and every season, made from your library's own moods. Plus This Time Last Year, and your favorites from seasons past.

YOUR FLACS, AS THEY ARE
Truffle plays your files straight from your server, at even volume. Leave home Wi-Fi and it hops to your server's public address without missing a beat.

DRESSED UP FOR THE SEASON
Colors, falling leaves and an app icon that change with the seasons.

ALL THE USUAL GOOD STUFF
Playlists, likes, artists, albums, search, a queue you can reorder, AirPlay, and lock screen and steering-wheel controls.

Needs a Plex account and a Plex Media Server with music. Free and open source. No ads, no tracking, no rating nags.
Source code: github.com/vanities/truffle""",
    "keywords": "carplay,shuffle,random,flac,lossless,playlist,mixes,seasonal,halloween,christmas,server,nas",
    "whatsNew": "",
    "copyright": "2026 AM2 LLC",
    "supportUrl": f"{SITE}/support",
    "marketingUrl": SITE,
    "privacyPolicyUrl": f"{SITE}/privacy",
}
assert len(COPY["subtitle"]) <= 30 and len(COPY["keywords"]) <= 100 and len(COPY["promotionalText"]) <= 170

PRIMARY_CATEGORY, SECONDARY_CATEGORY = "MUSIC", "ENTERTAINMENT"

AGE_RATING = {
    # Content descriptors: NONE / INFREQUENT_OR_MILD / FREQUENT_OR_INTENSE
    "alcoholTobaccoOrDrugUseOrReferences": "NONE",
    "contests": "NONE",
    "gamblingSimulated": "NONE",
    "gunsOrOtherWeapons": "NONE",
    "healthOrWellnessTopics": False,
    "horrorOrFearThemes": "NONE",
    "matureOrSuggestiveThemes": "NONE",
    "medicalOrTreatmentInformation": "NONE",
    "profanityOrCrudeHumor": "NONE",
    "sexualContentGraphicAndNudity": "NONE",
    "sexualContentOrNudity": "NONE",
    "violenceCartoonOrFantasy": "NONE",
    "violenceRealistic": "NONE",
    "violenceRealisticProlongedGraphicOrSadistic": "NONE",
    # Capabilities: booleans
    "advertising": False,
    "gambling": False,
    "lootBox": False,
    "messagingAndChat": False,
    "parentalControls": False,
    "socialMedia": False,
    "socialMediaAgeRestricted": False,
    "unrestrictedWebAccess": False,
    "userGeneratedContent": False,
    "ageAssurance": False,
    "ageRatingOverride": "NONE",
    "koreaAgeRatingOverride": "NONE",
}

REVIEW_NOTES = """Truffle is a music player for Plex Media Server. Signing in uses Plex's own PIN sign-in on plex.tv (the app never sees a password), and the app then plays music from the user's own Plex server.

To test: sign in with a Plex account that has a Plex Media Server with a music library. Shuffle All on Home starts playback; the season's mixes, Library, Search and the player work from there. Playback continues in the background and from the lock screen and CarPlay, which is why audio is declared in UIBackgroundModes.

The app has no developer-operated backend and collects no data."""

# The App Review contact is the same person for every AM2 LLC app: copied from Earmark's live
# listing at run time, so it isn't written into this public repo.
CONTACT_SOURCE_BUNDLE = "com.vanities.earmark"


class Store(tf.ASC):
    def patch_ok(self, path: str, body: dict) -> dict:
        response = requests.patch(f"{tf.API}{path}", headers=self._headers(), json=body, timeout=30)
        return response.json() if response.ok and response.text else {"_status": response.status_code, "_text": response.text}

    def post_ok(self, path: str, body: dict) -> dict:
        response = requests.post(f"{tf.API}{path}", headers=self._headers(), json=body, timeout=30)
        return response.json() if response.ok and response.text else {"_status": response.status_code, "_text": response.text}


def report(label: str, result: dict) -> None:
    if "_status" in result:
        print(f"  ✗ {label}: {result['_status']} {result['_text'][:240]}")
    else:
        print(f"  ✓ {label}")


def editable_version(asc: Store, app_id: str, create: bool) -> dict | None:
    versions = asc.get(f"/v1/apps/{app_id}/appStoreVersions", {"filter[platform]": "IOS", "limit": 10, "fields[appStoreVersions]": "versionString,appStoreState,appVersionState,releaseType"})["data"]
    editable_states = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "WAITING_FOR_REVIEW", "INVALID_BINARY"}
    for version in versions:
        state = version["attributes"].get("appVersionState") or version["attributes"].get("appStoreState")
        if state in editable_states:
            return version
    if not create:
        return None
    created = asc.post("/v1/appStoreVersions", {"data": {"type": "appStoreVersions", "attributes": {"platform": "IOS", "versionString": VERSION, "releaseType": "MANUAL"}, "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
    print(f"  ✓ created version {VERSION} (manual release)")
    return created["data"]


def version_localization(asc: Store, version_id: str) -> dict:
    locs = asc.get(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations", {"fields[appStoreVersionLocalizations]": "locale"})["data"]
    for loc in locs:
        if loc["attributes"]["locale"] == LOCALE:
            return loc
    return asc.post("/v1/appStoreVersionLocalizations", {"data": {"type": "appStoreVersionLocalizations", "attributes": {"locale": LOCALE}, "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}})["data"]


def contact_from_sibling(asc: Store) -> dict:
    apps = asc.get("/v1/apps", {"filter[bundleId]": CONTACT_SOURCE_BUNDLE})["data"]
    versions = asc.get(f"/v1/apps/{apps[0]['id']}/appStoreVersions", {"filter[platform]": "IOS", "limit": 1})["data"] if apps else []
    detail = asc.get(f"/v1/appStoreVersions/{versions[0]['id']}/appStoreReviewDetail").get("data") if versions else None
    fields = ("contactFirstName", "contactLastName", "contactEmail", "contactPhone")
    return {k: v for k, v in (detail or {}).get("attributes", {}).items() if k in fields and v}


def set_review_details(asc: Store, version_id: str, phone: str | None) -> None:
    detail = asc.get(f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail").get("data")
    review_attrs = {**contact_from_sibling(asc), "demoAccountRequired": False, "notes": REVIEW_NOTES}
    if phone:
        review_attrs["contactPhone"] = phone
    if detail:
        report("review contact + notes", asc.patch_ok(f"/v1/appStoreReviewDetails/{detail['id']}", {"data": {"type": "appStoreReviewDetails", "id": detail["id"], "attributes": review_attrs}}))
    else:
        report("review contact + notes", asc.post_ok("/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": review_attrs, "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}}))


def cmd_setup(asc: Store, phone: str | None) -> None:
    app = asc.app() or sys.exit("no app record")
    app_id = app["id"]
    print(f"{app['attributes']['name']} ({app_id})")

    report("content rights: no third-party content", asc.patch_ok(f"/v1/apps/{app_id}", {"data": {"type": "apps", "id": app_id, "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}}))

    infos = asc.get(f"/v1/apps/{app_id}/appInfos", {"fields[appInfos]": "appStoreState,state"})["data"]
    info = next((i for i in infos if (i["attributes"].get("state") or i["attributes"].get("appStoreState")) not in ("READY_FOR_SALE", "READY_FOR_DISTRIBUTION")), infos[0])
    report(f"categories: {PRIMARY_CATEGORY} / {SECONDARY_CATEGORY}", asc.patch_ok(f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
        "primaryCategory": {"data": {"type": "appCategories", "id": PRIMARY_CATEGORY}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": SECONDARY_CATEGORY}},
    }}}))

    rating = asc.get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration").get("data")
    if rating:
        report("age rating: 4+ (nothing to declare)", asc.patch_ok(f"/v1/ageRatingDeclarations/{rating['id']}", {"data": {"type": "ageRatingDeclarations", "id": rating["id"], "attributes": AGE_RATING}}))

    for loc in asc.get(f"/v1/appInfos/{info['id']}/appInfoLocalizations", {"fields[appInfoLocalizations]": "locale"})["data"]:
        report(f"app info {loc['attributes']['locale']}: subtitle + privacy URL", asc.patch_ok(f"/v1/appInfoLocalizations/{loc['id']}", {"data": {"type": "appInfoLocalizations", "id": loc["id"], "attributes": {"subtitle": COPY["subtitle"], "privacyPolicyUrl": COPY["privacyPolicyUrl"]}}}))

    version = editable_version(asc, app_id, create=True)
    if version:
        loc = version_localization(asc, version["id"])
        attrs = {k: COPY[k] for k in ("description", "keywords", "promotionalText", "whatsNew", "supportUrl", "marketingUrl")}
        result = asc.patch_ok(f"/v1/appStoreVersionLocalizations/{loc['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": attrs}})
        if "_status" in result and "whatsNew" in result["_text"]:
            attrs.pop("whatsNew")  # not editable on an app's first version
            result = asc.patch_ok(f"/v1/appStoreVersionLocalizations/{loc['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": attrs}})
        report(f"version {version['attributes']['versionString']} copy (description, keywords, URLs)", result)
        report(f"version {VERSION}: manual release, copyright", asc.patch_ok(f"/v1/appStoreVersions/{version['id']}", {"data": {"type": "appStoreVersions", "id": version["id"], "attributes": {"versionString": VERSION, "releaseType": "MANUAL", "copyright": COPY["copyright"]}}}))

        set_review_details(asc, version["id"], phone)

    # Price: free, USA as base territory.
    if asc.get(f"/v1/apps/{app_id}/appPriceSchedule").get("data"):
        print("  = price schedule already set")
        return
    points = asc.get(f"/v1/apps/{app_id}/appPricePoints", {"filter[territory]": "USA", "fields[appPricePoints]": "customerPrice,proceeds", "limit": 200})["data"]
    free = next((p for p in points if float(p["attributes"]["customerPrice"]) == 0.0), None)
    if free:
        result = asc.post_ok("/v1/appPriceSchedules", {
            "data": {"type": "appPriceSchedules", "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}},
                "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                "manualPrices": {"data": [{"type": "appPrices", "id": "${price-free}"}]},
            }},
            "included": [{"type": "appPrices", "id": "${price-free}", "attributes": {"startDate": None}, "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}],
        })
        report("price: Free (all territories)", result)
    else:
        print("  ✗ price: could not find the free price point")

    print("\nStill manual in App Store Connect: App Privacy → 'Data Not Collected' (Get Started → No → Publish),")
    print("and the review contact phone number under Version → App Review Information.")


# Folder name under marketing/ → App Store Connect slot. 1320x2868 goes in the 6.9" slot, 2064x2752 in the 13" one.
DISPLAY_TYPES = {"iphone": "APP_IPHONE_67", "ipad": "APP_IPAD_PRO_3GEN_129"}


def cmd_screenshots(asc: Store, directory: Path) -> None:
    display_type = DISPLAY_TYPES.get(directory.resolve().name) or sys.exit(f"expected a folder named one of {sorted(DISPLAY_TYPES)}")
    app = asc.app() or sys.exit("no app record")
    version = editable_version(asc, app["id"], create=False) or sys.exit("no editable version; run setup first")
    loc = version_localization(asc, version["id"])
    sets = asc.get(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets", {"fields[appScreenshotSets]": "screenshotDisplayType"})["data"]
    shot_set = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == display_type), None)
    if not shot_set:
        shot_set = asc.post("/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": display_type}, "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]
        print(f"created screenshot set {display_type}")
    existing = asc.get(f"/v1/appScreenshotSets/{shot_set['id']}/appScreenshots", {"fields[appScreenshots]": "fileName,assetDeliveryState", "limit": 20})["data"]
    existing_names = {e["attributes"]["fileName"] for e in existing}
    files = sorted(p for p in directory.iterdir() if p.suffix.lower() == ".png")
    for path in files[:10]:
        if path.name in existing_names:
            print(f"  = {path.name} already uploaded")
            continue
        data = path.read_bytes()
        reservation = asc.post("/v1/appScreenshots", {"data": {"type": "appScreenshots", "attributes": {"fileName": path.name, "fileSize": len(data)}, "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": shot_set["id"]}}}}})["data"]
        for op in reservation["attributes"]["uploadOperations"]:
            chunk = data[op["offset"]: op["offset"] + op["length"]]
            headers = {h["name"]: h["value"] for h in op["requestHeaders"]}
            response = requests.request(op["method"], op["url"], headers=headers, data=chunk, timeout=120)
            response.raise_for_status()
        asc.patch(f"/v1/appScreenshots/{reservation['id']}", {"data": {"type": "appScreenshots", "id": reservation["id"], "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
        print(f"  ✓ uploaded {path.name} ({len(data) // 1024} KB)")


def cmd_attach_build(asc: Store, build_number: str | None) -> None:
    app = asc.app() or sys.exit("no app record")
    version = editable_version(asc, app["id"], create=False) or sys.exit("no editable version; run setup first")
    builds = asc.builds(app["id"], limit=25)
    target = next((b for b in builds if (build_number is None or b["attributes"]["version"] == build_number) and b["attributes"]["processingState"] == "VALID"), None) or sys.exit("no processed build found")
    asc.patch(f"/v1/appStoreVersions/{version['id']}/relationships/build", {"data": {"type": "builds", "id": target["id"]}})
    print(f"  ✓ attached build {target['attributes']['version']} to version {version['attributes']['versionString']}")


def cmd_status(asc: Store) -> None:
    app = asc.app() or sys.exit("no app record")
    print(f"{app['attributes']['name']} ({app['attributes']['bundleId']}) rights={app['attributes'].get('contentRightsDeclaration')}")
    for info in asc.get(f"/v1/apps/{app['id']}/appInfos", {"fields[appInfos]": "state,appStoreState,primaryCategory,secondaryCategory", "include": "primaryCategory,secondaryCategory"})["data"]:
        rel = info.get("relationships", {})
        primary = (rel.get("primaryCategory", {}).get("data") or {}).get("id")
        secondary = (rel.get("secondaryCategory", {}).get("data") or {}).get("id")
        print(f"  appInfo state={info['attributes'].get('state') or info['attributes'].get('appStoreState')} categories={primary}/{secondary}")
        for loc in asc.get(f"/v1/appInfos/{info['id']}/appInfoLocalizations", {"fields[appInfoLocalizations]": "locale,name,subtitle,privacyPolicyUrl"})["data"]:
            a = loc["attributes"]; print(f"    {a['locale']}: name={a.get('name')!r} subtitle={a.get('subtitle')!r} privacy={a.get('privacyPolicyUrl')}")
    for version in asc.get(f"/v1/apps/{app['id']}/appStoreVersions", {"filter[platform]": "IOS", "limit": 5, "fields[appStoreVersions]": "versionString,appVersionState,releaseType,build", "include": "build", "fields[builds]": "version"})["data"]:
        a = version["attributes"]
        build_id = (version.get("relationships", {}).get("build", {}).get("data") or {}).get("id")
        build = asc.get(f"/v1/builds/{build_id}", {"fields[builds]": "version"})["data"]["attributes"]["version"] if build_id else None
        detail = asc.get(f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail", {"fields[appStoreReviewDetails]": "contactPhone"}).get("data")
        print(f"  version {a['versionString']} state={a.get('appVersionState')} release={a.get('releaseType')} build={build or 'none'} reviewContact={'set' if detail and detail['attributes'].get('contactPhone') else 'missing phone'}")
        for loc in asc.get(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations", {"fields[appStoreVersionLocalizations]": "locale,keywords,supportUrl,marketingUrl"})["data"]:
            a = loc["attributes"]; print(f"    {a['locale']}: keywords={a.get('keywords')!r} support={a.get('supportUrl')} marketing={a.get('marketingUrl')}")
            sets = asc.get(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets", {"fields[appScreenshotSets]": "screenshotDisplayType"})["data"]
            for shot_set in sets:
                shots = asc.get(f"/v1/appScreenshotSets/{shot_set['id']}/appScreenshots", {"fields[appScreenshots]": "fileName,assetDeliveryState", "limit": 20})["data"]
                states = [s["attributes"]["assetDeliveryState"]["state"] for s in shots]
                print(f"    screenshots {shot_set['attributes']['screenshotDisplayType']}: {len(shots)} ({', '.join(sorted(set(states)))})")


def cmd_submit(asc: Store, dry_run: bool) -> None:
    """Submit the editable version via reviewSubmissions: find/create → add item → submitted=true."""
    app = asc.app() or sys.exit("no app record")
    version = editable_version(asc, app["id"], create=False) or sys.exit("no editable version")
    attached = (asc.get(f"/v1/appStoreVersions/{version['id']}", {"fields[appStoreVersions]": "versionString", "include": "build", "fields[builds]": "version"}).get("included") or [{}])[0].get("attributes", {}).get("version")
    print(f"version {version['attributes']['versionString']} build {attached or 'NONE'}")
    if not attached:
        sys.exit("no build attached; run attach-build first")
    if dry_run:
        print("dry run: not submitting"); return
    existing = asc.get(f"/v1/apps/{app['id']}/reviewSubmissions", {"filter[platform]": "IOS", "filter[state]": "READY_FOR_REVIEW"})["data"]
    if existing:
        submission = existing[0]
        print(f"  reusing submission {submission['id']}")
    else:
        submission = asc.post("/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"}, "relationships": {"app": {"data": {"type": "apps", "id": app["id"]}}}}})["data"]
        print(f"  ✓ created submission {submission['id']}")
    items = asc.get(f"/v1/reviewSubmissions/{submission['id']}/items", {"limit": 10}).get("data", [])
    if not items:
        asc.post("/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission["id"]}},
            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}},
        }}})
        print(f"  ✓ added version {version['attributes']['versionString']} to the submission")
    result = asc.patch_ok(f"/v1/reviewSubmissions/{submission['id']}", {"data": {"type": "reviewSubmissions", "id": submission["id"], "attributes": {"submitted": True}}})
    report("submitted for review", result)


def cmd_submission_status(asc: Store) -> None:
    app = asc.app() or sys.exit("no app record")
    for submission in asc.get(f"/v1/apps/{app['id']}/reviewSubmissions", {"filter[platform]": "IOS", "fields[reviewSubmissions]": "state,submittedDate", "limit": 5})["data"]:
        a = submission["attributes"]
        print(f"  submission {submission['id'][:8]}… state={a['state']} submitted={str(a.get('submittedDate'))[:19]}")
        for item in asc.get(f"/v1/reviewSubmissions/{submission['id']}/items", {"fields[reviewSubmissionItems]": "state", "limit": 10}).get("data", []):
            print(f"    item state={item['attributes']['state']}")
    for version in asc.get(f"/v1/apps/{app['id']}/appStoreVersions", {"filter[platform]": "IOS", "limit": 3, "fields[appStoreVersions]": "versionString,appVersionState"})["data"]:
        print(f"  version {version['attributes']['versionString']}: {version['attributes'].get('appVersionState')}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    setup = sub.add_parser("setup"); setup.add_argument("--phone", help="App Review contact phone, e.g. '+1 555 555 5555'")
    review = sub.add_parser("review"); review.add_argument("--phone", required=True)
    shots = sub.add_parser("screenshots"); shots.add_argument("directory")
    attach = sub.add_parser("attach-build"); attach.add_argument("build", nargs="?")
    sub.add_parser("status")
    submit = sub.add_parser("submit"); submit.add_argument("--dry-run", action="store_true")
    sub.add_parser("submission-status")
    args = parser.parse_args()
    asc = Store(tf.load_env())
    match args.command:
        case "setup": cmd_setup(asc, args.phone)
        case "review":
            app = asc.app() or sys.exit("no app record")
            version = editable_version(asc, app["id"], create=False) or sys.exit("no editable version")
            set_review_details(asc, version["id"], args.phone)
        case "screenshots": cmd_screenshots(asc, Path(args.directory))
        case "attach-build": cmd_attach_build(asc, args.build)
        case "status": cmd_status(asc)
        case "submit": cmd_submit(asc, args.dry_run)
        case "submission-status": cmd_submission_status(asc)


if __name__ == "__main__":
    main()
