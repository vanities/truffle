# /// script
# requires-python = ">=3.11"
# dependencies = ["PyJWT>=2.8", "cryptography>=42", "requests>=2.31"]
# ///
"""Truffle on Apple's side, through the App Store Connect API.

Reads APPSTORE_CONNECT_KEY_ID / _ISSUER_ID / _KEY_FILE from .env.appstore-connect in this repo, or
falls back to Earmark's (the same team key). Paths in the env file are relative to the env file.

  uv run --script scripts/asc.py status       # agreements, the bundle ID, the App Store Connect app
  uv run --script scripts/asc.py register     # register com.vanities.truffle (no-op when it exists)
  uv run --script scripts/asc.py enable-carplay  # CarPlay on the App ID (the team's grant, as Earmark has it)
  uv run --script scripts/asc.py create-app   # the App Store Connect app record, if the API allows it
                                              # (it doesn't: 403 "apps does not allow CREATE", 2026-10-30)
"""
from __future__ import annotations

import argparse
import logging
import sys
import time
from pathlib import Path

import jwt
import requests

API = "https://api.appstoreconnect.apple.com"
ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "com.vanities.truffle"
APP_NAME = "Truffle: Music Player for Plex"
SKU = "truffle"

log = logging.getLogger("asc")


def load_env() -> tuple[dict[str, str], Path]:
    for candidate in (ROOT / ".env.appstore-connect", ROOT.parent / "earmark" / ".env.appstore-connect"):
        if candidate.exists():
            env = {}
            for line in candidate.read_text().splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, value = line.partition("=")
                    env[key.strip()] = value.strip()
            return env, candidate
    sys.exit("no .env.appstore-connect here or in ../earmark")


class ASC:
    def __init__(self) -> None:
        env, source = load_env()
        key_path = Path(env["APPSTORE_CONNECT_KEY_FILE"])
        if not key_path.is_absolute():
            key_path = source.parent / key_path
        now = int(time.time())
        self.token = jwt.encode(
            {"iss": env["APPSTORE_CONNECT_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
            key_path.read_text(), algorithm="ES256", headers={"kid": env["APPSTORE_CONNECT_KEY_ID"], "typ": "JWT"},
        )
        log.info("[asc] key from %s", source.relative_to(ROOT.parent))

    def call(self, method: str, path: str, params: dict | None = None, body: dict | None = None) -> tuple[int, dict]:
        started = time.monotonic()
        response = requests.request(method, f"{API}{path}", params=params, json=body, timeout=30,
                                    headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"})
        log.info("[asc] %s %s → %d in %.0fms", method, path, response.status_code, (time.monotonic() - started) * 1000)
        try:
            return response.status_code, response.json()
        except ValueError:
            return response.status_code, {}


def explain(payload: dict) -> str:
    return "; ".join(f"{e.get('code')}: {e.get('detail') or e.get('title')}" for e in payload.get("errors", []))


def bundle(asc: ASC) -> dict | None:
    status, payload = asc.call("GET", "/v1/bundleIds", {"filter[identifier]": BUNDLE_ID})
    if status != 200:
        sys.exit(f"bundle IDs: {status} {explain(payload)}")
    return next((b for b in payload.get("data", []) if b["attributes"]["identifier"] == BUNDLE_ID), None)


def cmd_status(asc: ASC) -> None:
    found = bundle(asc)
    print(f"bundle ID {BUNDLE_ID}: {'registered (' + found['id'] + ')' if found else 'not registered'}")
    status, payload = asc.call("GET", "/v1/apps", {"filter[bundleId]": BUNDLE_ID})
    if status != 200:
        sys.exit(f"apps: {status} {explain(payload)}")
    apps = payload.get("data", [])
    print(f"App Store Connect app: {apps[0]['attributes']['name'] + ' (' + apps[0]['id'] + ')' if apps else 'none yet'}")


def cmd_register(asc: ASC) -> None:
    if (found := bundle(asc)) is not None:
        print(f"already registered: {found['id']}")
        return
    status, payload = asc.call("POST", "/v1/bundleIds", body={"data": {"type": "bundleIds", "attributes": {
        "identifier": BUNDLE_ID, "name": "Truffle", "platform": "IOS"}}})
    if status != 201:
        sys.exit(f"register: {status} {explain(payload)}")
    print(f"registered {BUNDLE_ID}: {payload['data']['id']}")


def cmd_enable_carplay(asc: ASC) -> None:
    """Apple grants CarPlay audio to the team, but each App ID still needs the capability turned on, or
    automatic signing says "Entitlement com.apple.developer.carplay-audio not found"."""
    found = bundle(asc)
    if found is None:
        sys.exit("register the bundle ID first")
    status, caps = asc.call("GET", f"/v1/bundleIds/{found['id']}/bundleIdCapabilities")
    if any(c["attributes"].get("capabilityType") == "CARPLAY_PLAYABLE_CONTENT" for c in caps.get("data", [])):
        print("CarPlay already on")
        return
    status, payload = asc.call("POST", "/v1/bundleIdCapabilities", body={"data": {
        "type": "bundleIdCapabilities", "attributes": {"capabilityType": "CARPLAY_PLAYABLE_CONTENT"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": found["id"]}}},
    }})
    if status != 201:
        sys.exit(f"enable CarPlay: {status} {explain(payload)}")
    print("CarPlay on for " + BUNDLE_ID)


def cmd_create_app(asc: ASC) -> None:
    found = bundle(asc)
    if found is None:
        sys.exit("register the bundle ID first")
    status, payload = asc.call("GET", "/v1/apps", {"filter[bundleId]": BUNDLE_ID})
    if status == 200 and payload.get("data"):
        print(f"app already exists: {payload['data'][0]['id']}")
        return
    status, payload = asc.call("POST", "/v1/apps", body={"data": {
        "type": "apps",
        "attributes": {"name": APP_NAME, "sku": SKU, "primaryLocale": "en-US", "bundleId": BUNDLE_ID},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": found["id"]}}},
    }})
    if status != 201:
        sys.exit(f"create app: {status} {explain(payload)}")
    print(f"created app {payload['data']['id']}: {APP_NAME}")


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stderr)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["status", "register", "enable-carplay", "create-app"])
    args = parser.parse_args()
    asc = ASC()
    {"status": cmd_status, "register": cmd_register, "enable-carplay": cmd_enable_carplay,
     "create-app": cmd_create_app}[args.command](asc)


if __name__ == "__main__":
    main()
