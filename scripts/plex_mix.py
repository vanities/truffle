#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["requests", "pillow"]
# ///
"""Seasonal mixes as Plex playlists, for the `seasonal-mix` skill (.claude/skills/seasonal-mix).

Every Plex call runs inside the NAS's `plex` container (`ssh nas`), with the server token read from
Preferences.xml in that shell, so the token never leaves the NAS or reaches a log.

    plex_mix.py themes                                   # the themes and their moods/keywords
    plex_mix.py candidates halloween --year 2026         # candidate songs → build/mixes/halloween-2026.json
    plex_mix.py existing                                 # Truffle mixes already on the server
    plex_mix.py art halloween --year 2026 --prompt "…"   # cover art (gpt-image-2, Adam's OpenAI key)
    plex_mix.py create halloween --year 2026 --ids 1,2,3 --art build/mixes/halloween-2026.png --blurb "…"

A mix is an ordinary Plex playlist titled "<emoji> <Theme> <Year>" whose summary ends with
`truffle-mix:<theme>:<year>`; Truffle finds it by that tag and plays it for the season's card.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import io
import json
import logging
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import quote

import requests
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "build" / "mixes"
SECTION = "3"  # Adam's Music library (Books is 4)
PLEX = "http://127.0.0.1:32400"
PREFS = "/config/Library/Application Support/Plex Media Server/Preferences.xml"

log = logging.getLogger("plex_mix")

# window: (month, day) to (month, day), inclusive, read from every earlier year's play history.
THEMES: dict[str, dict] = {
    "halloween": {"emoji": "🎃", "title": "Halloween", "window": ((10, 1), (10, 31)),
                  "moods": ["Spooky", "Eerie", "Ominous", "Menacing", "Malevolent", "Dark", "Nocturnal"],
                  "keywords": ["halloween", "ghost", "witch", "monster", "haunt", "spook", "skeleton", "zombie", "vampire",
                               "grave", "devil", "creep", "boo", "pumpkin", "night", "moon", "dead", "horror", "spirit"]},
    "fall": {"emoji": "🍂", "title": "Fall", "window": ((9, 1), (11, 30)),
             "moods": ["Autumnal", "Wistful", "Bittersweet", "Nostalgic", "Earthy", "Warm"],
             "keywords": ["autumn", "fall", "leaves", "october", "november", "september", "harvest", "sweater", "rain", "cider"]},
    "thanksgiving": {"emoji": "🦃", "title": "Thanksgiving", "window": ((11, 15), (11, 30)),
                     "moods": ["Warm", "Autumnal", "Earthy", "Nostalgic", "Celebratory", "Reflective"],
                     "keywords": ["thank", "grateful", "home", "family", "harvest", "feast", "together", "kitchen", "table", "pie"]},
    "christmas": {"emoji": "🎄", "title": "Christmas", "window": ((11, 25), (12, 26)),
                  "moods": ["Wintry", "Warm", "Sentimental", "Celebratory", "Cold"],
                  "keywords": ["christmas", "xmas", "santa", "snow", "holiday", "jingle", "bell", "sleigh", "merry", "noel",
                               "december", "mistletoe", "reindeer", "carol", "silent night", "winter"]},
    "winter": {"emoji": "❄️", "title": "Winter", "window": ((12, 1), (2, 28)),
               "moods": ["Wintry", "Cold", "Ethereal", "Somber", "Calm/Peaceful", "Introspective"],
               "keywords": ["winter", "snow", "cold", "ice", "frost", "freeze", "december", "january", "february", "blizzard"]},
    "newyear": {"emoji": "🎆", "title": "New Year", "window": ((12, 27), (1, 2)),
                "moods": ["Celebratory", "Euphoric", "Rousing", "Triumphant", "Exuberant"],
                "keywords": ["new year", "midnight", "party", "celebrate", "countdown", "tonight", "dance", "champagne"]},
    "valentines": {"emoji": "💘", "title": "Valentine's", "window": ((2, 1), (2, 14)),
                   "moods": ["Romantic", "Tender", "Sensual", "Passionate", "Intimate"],
                   "keywords": ["love", "heart", "kiss", "darling", "baby", "valentine", "sweetheart", "forever"]},
    "stpatricks": {"emoji": "☘️", "title": "St. Patrick's", "window": ((3, 1), (3, 17)),
                   "moods": ["Rollicking", "Boisterous", "Rowdy", "Joyous", "Lively", "Celebratory"],
                   "keywords": ["irish", "ireland", "dublin", "galway", "whiskey", "pub", "luck", "green", "shamrock", "rover",
                                "drunken", "sailor", "jig", "reel"]},
    "fourthofjuly": {"emoji": "🎆", "title": "Fourth of July", "window": ((6, 25), (7, 4)),
                     "moods": ["Anthemic", "Rousing", "Triumphant", "Celebratory", "Summery"],
                     "keywords": ["america", "american", "usa", "freedom", "free", "fireworks", "independence", "flag",
                                  "liberty", "born in", "fourth", "july", "stars"]},
    "spring": {"emoji": "🌷", "title": "Spring", "window": ((3, 1), (5, 31)),
               "moods": ["Springlike", "Pastoral", "Uplifting", "Cheerful", "Gentle", "Light"],
               "keywords": ["spring", "flower", "bloom", "garden", "rain", "april", "may", "sunshine", "bird"]},
    "summer": {"emoji": "☀️", "title": "Summer", "window": ((6, 1), (8, 31)),
               "moods": ["Summery", "Carefree", "Exuberant", "Playful", "Celebratory"],
               "keywords": ["summer", "sun", "beach", "july", "august", "heat", "ocean", "surf", "pool", "vacation"]},
}
ALIASES = {"xmas": "christmas", "holidays": "christmas", "holiday": "christmas", "new-year": "newyear", "valentine": "valentines",
           "st-patricks": "stpatricks", "stpats": "stpatricks", "st-pats": "stpatricks", "fourth": "fourthofjuly",
           "july4": "fourthofjuly", "4th": "fourthofjuly", "fourth-of-july": "fourthofjuly"}


# MARK: Plex, through the NAS

def plex(method: str, path: str, body: bytes | None = None, content_type: str = "application/json") -> dict | bytes:
    """One request to the server from inside its container. JSON comes back parsed."""
    script = (
        f'T=$(sed -n \'s/.*PlexOnlineToken="\\([^"]*\\)".*/\\1/p\' "{PREFS}"); '
        'if [ "$3" = "-" ]; then '
        'curl -s -X "$1" -H "X-Plex-Token: $T" -H "Accept: application/json" "$2"; '
        'else '
        'curl -s -X "$1" -H "X-Plex-Token: $T" -H "Accept: application/json" -H "Content-Type: $3" --data-binary @- "$2"; '
        'fi'
    )
    remote = " ".join(["docker exec -i plex sh -c", shlex.quote(script), "sh", shlex.quote(method),
                       shlex.quote(PLEX + path), shlex.quote(content_type if body is not None else "-")])
    started = time.monotonic()
    result = subprocess.run(["ssh", "-o", "ConnectTimeout=8", "nas", remote], input=body, capture_output=True, timeout=180)
    log.info("[plex] %s %s → %dB in %.0fms", method, path.split("?")[0], len(result.stdout), (time.monotonic() - started) * 1000)
    if result.returncode != 0:
        sys.exit(f"[plex] {method} {path.split('?')[0]} failed: {result.stderr.decode()[:300]}")
    try:
        return json.loads(result.stdout) if result.stdout.strip().startswith(b"{") else result.stdout
    except json.JSONDecodeError:
        return result.stdout


def items(payload: dict | bytes) -> list[dict]:
    return payload.get("MediaContainer", {}).get("Metadata", []) if isinstance(payload, dict) else []


def track_row(item: dict) -> dict:
    return {"id": item["ratingKey"], "title": item.get("title", ""), "artist": item.get("originalTitle") or item.get("grandparentTitle", ""),
            "album": item.get("parentTitle", ""), "year": item.get("parentYear") or item.get("year"),
            "seconds": int(item.get("duration", 0) / 1000), "liked": (item.get("userRating") or 0) >= 8}


def machine_identifier() -> str:
    payload = plex("GET", "/identity")
    return payload["MediaContainer"]["machineIdentifier"] if isinstance(payload, dict) else ""


# MARK: Commands

def theme_named(name: str) -> tuple[str, dict]:
    key = ALIASES.get(name.lower(), name.lower())
    if key not in THEMES:
        sys.exit(f"unknown theme {name!r}; one of: {', '.join(THEMES)}")
    return key, THEMES[key]


def windows(theme: dict, before_year: int) -> list[tuple[int, int]]:
    """Unix-time windows for the theme in every year before `before_year`, back to 2015."""
    (m1, d1), (m2, d2) = theme["window"]
    spans = []
    for year in range(before_year - 1, 2014, -1):
        start = dt.datetime(year, m1, d1)
        end_year = year + 1 if (m2, d2) < (m1, d1) else year
        end = dt.datetime(end_year, m2, min(d2, 28 if m2 == 2 else d2), 23, 59, 59)
        spans.append((int(start.timestamp()), int(end.timestamp())))
    return spans


def cmd_candidates(name: str, year: int, per_source: int) -> None:
    key, theme = theme_named(name)
    found: dict[str, dict] = {}

    def add(item: dict, source: str, weight: int = 1) -> None:
        if item.get("type") not in (None, "track") or str(item.get("librarySectionID", SECTION)) != SECTION:
            return
        row = found.setdefault(item["ratingKey"], {**track_row(item), "sources": {}, "plays": 0})
        row["sources"][source] = row["sources"].get(source, 0) + weight

    moods = plex("GET", f"/library/sections/{SECTION}/mood?type=9")
    mood_keys = {d["title"]: d["key"] for d in moods.get("MediaContainer", {}).get("Directory", [])} if isinstance(moods, dict) else {}
    wanted = [mood_keys[m] for m in theme["moods"] if m in mood_keys]
    if wanted:
        for item in items(plex("GET", f"/library/sections/{SECTION}/all?type=10&album.mood={','.join(wanted)}&sort=random"
                                      f"&X-Plex-Container-Start=0&X-Plex-Container-Size={per_source}")):
            add(item, "mood")
    for word in theme["keywords"]:
        payload = plex("GET", f"/hubs/search?query={quote(word)}&sectionId={SECTION}&limit=30")
        for hub in payload.get("MediaContainer", {}).get("Hub", []) if isinstance(payload, dict) else []:
            if hub.get("type") == "track":
                for item in hub.get("Metadata", []):
                    add(item, f"word:{word}")
    plays: dict[str, int] = {}
    for start, end in windows(theme, year):
        for entry in items(plex("GET", f"/status/sessions/history/all?librarySectionID={SECTION}&viewedAt%3E={start}"
                                       f"&viewedAt%3C={end}&X-Plex-Container-Start=0&X-Plex-Container-Size=2000")):
            if entry.get("ratingKey"):
                plays[entry["ratingKey"]] = plays.get(entry["ratingKey"], 0) + 1
    top = sorted(plays, key=plays.get, reverse=True)[:per_source]
    for batch in range(0, len(top), 40):
        for item in items(plex("GET", "/library/metadata/" + ",".join(top[batch:batch + 40]))):
            add(item, "history", plays.get(item["ratingKey"], 1))
    for row_id, count in plays.items():
        if row_id in found:
            found[row_id]["plays"] = count

    OUT.mkdir(parents=True, exist_ok=True)
    rows = sorted(found.values(), key=lambda r: (-len(r["sources"]), -r["plays"], r["artist"]))
    path = OUT / f"{key}-{year}.json"
    path.write_text(json.dumps({"theme": key, "year": year, "candidates": rows}, indent=1, ensure_ascii=False))
    print(f"{len(rows)} candidates for {theme['title']} {year} → {path.relative_to(REPO)}")
    for row in rows:
        why = ",".join(f"{s}" if n == 1 else f"{s}×{n}" for s, n in row["sources"].items())
        print(f"{row['id']}\t{row['artist']} — {row['title']} ({row['album']}, {row['year'] or '?'}) "
              f"{row['seconds'] // 60}:{row['seconds'] % 60:02d}{' ♥' if row['liked'] else ''} [{why}]")


def truffle_mixes() -> list[dict]:
    mixes = []
    for item in items(plex("GET", "/playlists?playlistType=audio")):
        tag = next((part for part in (item.get("summary") or "").split() if part.startswith("truffle-mix:")), None)
        if tag:
            mixes.append({"id": item["ratingKey"], "title": item.get("title"), "songs": item.get("leafCount"), "tag": tag})
    return mixes


def cmd_existing() -> None:
    mixes = truffle_mixes()
    for mix in mixes:
        print(f"{mix['id']}\t{mix['title']}\t{mix['songs']} songs\t{mix['tag']}")
    if not mixes:
        print("no Truffle mixes yet")


def openai_key() -> str:
    for candidate in (REPO / ".env", REPO.parent / "game" / ".env"):
        if candidate.is_file():
            for raw in candidate.read_text().splitlines():
                line = raw.strip().removeprefix("export ")
                if line.startswith("OPENAI_API_KEY="):
                    os.environ.setdefault("OPENAI_API_KEY", line.split("=", 1)[1].strip().strip('"').strip("'"))
    return os.environ.get("OPENAI_API_KEY") or sys.exit("no OPENAI_API_KEY in the environment, ./.env or ../game/.env")


ART_STYLE = ("Square cover art for a seasonal music mix. Playful, cute and a little silly, flat vector illustration with "
             "bold simple shapes and soft gradients, rich saturated color, one clear subject, plenty of breathing room. "
             "Absolutely no text, letters, numbers or words anywhere.")


def cmd_art(name: str, year: int, prompt: str) -> None:
    key, _ = theme_named(name)
    started = time.monotonic()
    response = requests.post("https://api.openai.com/v1/images/generations", timeout=300,
                             headers={"Authorization": f"Bearer {openai_key()}", "Content-Type": "application/json"},
                             json={"model": "gpt-image-2", "prompt": f"{ART_STYLE} {prompt}", "n": 1, "size": "1024x1024",
                                   "quality": "medium"})
    if not response.ok:
        sys.exit(f"[art] HTTP {response.status_code} {response.text[:300]}")
    image = Image.open(io.BytesIO(base64.b64decode(response.json()["data"][0]["b64_json"]))).convert("RGB")
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{key}-{year}.jpg"
    image.save(path, quality=90)
    print(f"[art] {path.relative_to(REPO)} in {time.monotonic() - started:.1f}s")


def cmd_create(name: str, year: int, ids: list[str], art: Path | None, blurb: str) -> None:
    key, theme = theme_named(name)
    title = f"{theme['emoji']} {theme['title']} {year}"
    tag = f"truffle-mix:{key}:{year}"
    uri = f"server://{machine_identifier()}/com.plexapp.plugins.library/library/metadata/{','.join(ids)}"
    existing = next((m for m in truffle_mixes() if m["tag"] == tag), None)
    if existing:
        # Same theme and year: refresh it in place, so Truffle and Plexamp keep one playlist per year.
        playlist_id = existing["id"]
        for item in items(plex("GET", f"/playlists/{playlist_id}/items")):
            plex("DELETE", f"/playlists/{playlist_id}/items/{item['playlistItemID']}")
        plex("PUT", f"/playlists/{playlist_id}/items?uri={quote(uri, safe='')}")
        log.info("[mix] refreshed %s", title)
    else:
        payload = plex("POST", f"/playlists?type=audio&title={quote(title)}&smart=0&uri={quote(uri, safe='')}")
        created = items(payload)
        if not created:
            sys.exit(f"[mix] create failed: {str(payload)[:300]}")
        playlist_id = created[0]["ratingKey"]
        log.info("[mix] created %s (%s)", title, playlist_id)
    summary = f"{blurb} {tag}".strip()
    plex("PUT", f"/library/metadata/{playlist_id}?summary.value={quote(summary)}&summary.locked=1")
    plex("PUT", f"/playlists/{playlist_id}?summary={quote(summary)}")
    if art:
        plex("POST", f"/library/metadata/{playlist_id}/posters", body=art.read_bytes(), content_type="image/jpeg")
    check = items(plex("GET", f"/playlists/{playlist_id}"))
    got = check[0] if check else {}
    print(f"{title}: {got.get('leafCount')} songs, summary tagged={tag in (got.get('summary') or '')}, "
          f"poster={'custom' if got.get('thumb') and 'composite' not in got.get('thumb', '') else got.get('thumb') or 'composite'}")


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stderr)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("themes")
    sub.add_parser("existing")
    candidates = sub.add_parser("candidates")
    candidates.add_argument("theme")
    candidates.add_argument("--year", type=int, default=dt.date.today().year)
    candidates.add_argument("--per-source", type=int, default=150)
    art = sub.add_parser("art")
    art.add_argument("theme")
    art.add_argument("--year", type=int, default=dt.date.today().year)
    art.add_argument("--prompt", required=True)
    create = sub.add_parser("create")
    create.add_argument("theme")
    create.add_argument("--year", type=int, default=dt.date.today().year)
    create.add_argument("--ids", required=True, help="comma-separated ratingKeys, in play order")
    create.add_argument("--art", type=Path)
    create.add_argument("--blurb", default="", help="one short silly line shown with the playlist")
    args = parser.parse_args()
    if args.command == "themes":
        for key, theme in THEMES.items():
            print(f"{theme['emoji']} {key}: moods={', '.join(theme['moods'])}; words={', '.join(theme['keywords'][:6])}…")
    elif args.command == "existing":
        cmd_existing()
    elif args.command == "candidates":
        cmd_candidates(args.theme, args.year, args.per_source)
    elif args.command == "art":
        cmd_art(args.theme, args.year, args.prompt)
    else:
        cmd_create(args.theme, args.year, [i.strip() for i in args.ids.split(",") if i.strip()], args.art, args.blurb)


if __name__ == "__main__":
    main()
