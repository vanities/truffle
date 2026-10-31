#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# ///
"""A stand-in Plex Media Server for the simulator and screenshots.

Serves the invented library in scripts/demo-catalog.json the way PMS 1.43 answers the requests
Truffle makes: the MediaContainer shapes, the filters (`album.mood=`, `userRating>=`, `viewedAt>=`, `title=`),
paging, the sorts Truffle asks for, the photo resizer, history, ratings, playlists (made, renamed,
described, given a cover, songs added, removed and moved), audio with byte ranges, and Data Saver's
HLS transcode (start, the session's playlist and segment, stop).

    make demo-library            # covers (Swift) and audio (ffmpeg) into ./demo-library
    scripts/demo_server.py       # http://127.0.0.1:32499
    xcrun simctl launch <udid> com.vanities.truffle -TruffleServerURL http://127.0.0.1:32499
"""

import datetime as dt
import json
import logging
import os
import random
import re
import subprocess
import sys
import threading
import time
import unicodedata
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qsl, unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "scripts" / "demo-catalog.json"
LIBRARY = ROOT / "demo-library"
PORT = int(os.environ.get("DEMO_PORT", "32499"))
SECTION = "1"
STAMP = 1_780_000_000

log = logging.getLogger("demo")

# Chord progressions (Hz) and lengths for the generated songs; each song uses one of these.
PROGRESSIONS = [
    ([[220, 261.6, 329.6], [174.6, 220, 261.6], [261.6, 329.6, 392], [196, 246.9, 293.7]], 151),
    ([[196, 246.9, 293.7], [164.8, 196, 246.9], [130.8, 164.8, 196], [146.8, 185, 220]], 185),
    ([[233.1, 293.7, 349.2], [155.6, 196, 233.1], [174.6, 220, 261.6], [116.5, 146.8, 174.6]], 222),
    ([[146.8, 174.6, 220], [233.1, 293.7, 349.2], [130.8, 164.8, 196], [220, 277.2, 329.6]], 204),
    ([[164.8, 207.7, 246.9], [220, 277.2, 329.6], [185, 220, 277.2], [123.5, 155.6, 185]], 168),
    ([[261.6, 329.6, 392], [220, 261.6, 329.6], [174.6, 220, 261.6], [196, 246.9, 293.7]], 239),
]


def slug(text: str) -> str:
    folded = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return "-".join(part for part in re.split(r"[^a-z0-9]+", folded) if part)


def make_audio() -> None:
    """Soft chord pads with ffmpeg, one file per progression, made once. Data Saver's HLS gets a copy with the
    moov atom up front (audio/hls): AVPlayer reads a segment from its start, and ffmpeg writes moov last."""
    folder = LIBRARY / "audio"
    (folder / "hls").mkdir(parents=True, exist_ok=True)
    for index, (chords, seconds) in enumerate(PROGRESSIONS):
        target = folder / f"song-{index}.m4a"
        if not target.exists():
            make_song(target, chords, seconds)
        segment = folder / "hls" / target.name
        if not segment.exists():
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(target), "-c", "copy", "-movflags", "+faststart",
                            str(segment)], check=True)
            log.info("[audio] made hls/%s", segment.name)


def make_song(target: Path, chords: list[list[float]], seconds: int) -> None:
    def note(n: int) -> str:
        freq = (f"if(lt(mod(t,16),4),{chords[0][n]},if(lt(mod(t,16),8),{chords[1][n]},"
                f"if(lt(mod(t,16),12),{chords[2][n]},{chords[3][n]})))")
        return f"sin(2*PI*{freq}*t)"
    envelope = "(1-exp(-mod(t,4)*5))*(0.55+0.45*exp(-mod(t,4)*0.6))"
    pad = f"0.16*({note(0)}+{note(1)}+{note(2)})*{envelope}"
    started = time.monotonic()
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", f"aevalsrc=exprs='{pad}':s=44100:d={seconds}",
                    "-af", "afade=t=in:d=2,afade=t=out:st=" + str(seconds - 3) + ":d=3,aecho=0.8:0.7:300:0.25",
                    "-ac", "2", "-c:a", "aac", "-b:a", "96k", str(target)], check=True)
    log.info("[audio] made %s (%ds) in %.1fs", target.name, seconds, time.monotonic() - started)


class Library:
    def __init__(self) -> None:
        catalog = json.loads(CATALOG.read_text())
        rng = random.Random(42)
        self.lock = threading.Lock()
        self.moods: dict[str, str] = {}
        self.artists, self.albums, self.tracks = [], [], []
        self.playlists: list[dict] = []
        # Data Saver's transcode sessions: session -> the song's ratingKey, until the app stops it.
        self.transcodes: dict[str, str] = {}
        album_index = 0
        for artist_index, artist in enumerate(catalog["artists"]):
            artist_id = str(1000 + artist_index)
            self.artists.append({"ratingKey": artist_id, "key": f"/library/metadata/{artist_id}/children", "type": "artist",
                                 "title": artist["name"], "titleSort": artist["name"].removeprefix("The "),
                                 "thumb": f"/library/metadata/{artist_id}/thumb/{STAMP}", "childCount": len(artist["albums"]),
                                 "_portrait": f"artists/{slug(artist['name'])}.jpg"})
            for album in artist["albums"]:
                album_id = str(2000 + album_index)
                album_index += 1
                for mood in album["moods"]:
                    self.moods.setdefault(mood, str(5000 + len(self.moods)))
                added = STAMP + album["year"] * 1000 + rng.randint(0, 900)
                record = {"ratingKey": album_id, "key": f"/library/metadata/{album_id}/children", "type": "album",
                          "title": album["title"], "parentTitle": artist["name"], "parentRatingKey": artist_id,
                          "year": album["year"], "thumb": f"/library/metadata/{album_id}/thumb/{STAMP}",
                          "leafCount": len(album["tracks"]), "addedAt": added, "Mood": [{"tag": m} for m in album["moods"]],
                          "_cover": f"covers/{slug(album['title'])}.jpg", "_moods": album["moods"]}
                self.albums.append(record)
                album_loudness = rng.uniform(-15.5, -8.5)
                for number, title in enumerate(album["tracks"], start=1):
                    track_id = str(3000 + len(self.tracks))
                    song = rng.randrange(len(PROGRESSIONS))
                    loudness = album_loudness + rng.uniform(-2.5, 1.5)
                    self.tracks.append({
                        "ratingKey": track_id, "key": f"/library/metadata/{track_id}", "type": "track", "title": title,
                        "grandparentTitle": artist["name"], "grandparentRatingKey": artist_id,
                        "parentTitle": album["title"], "parentRatingKey": album_id, "parentYear": album["year"],
                        "index": number, "parentIndex": 1, "duration": PROGRESSIONS[song][1] * 1000,
                        "parentThumb": record["thumb"], "grandparentThumb": f"/library/metadata/{artist_id}/thumb/{STAMP}",
                        "addedAt": added, "_song": song, "_album": record,
                        "_loudness": round(loudness, 2), "_gain": round(-24.5 - loudness, 2), "_albumGain": round(-24.5 - album_loudness, 2),
                    })
        # Every seventh song is loved, like a lived-in library.
        for track in self.tracks[::7]:
            track["userRating"] = 10.0
            track["lastRatedAt"] = STAMP + rng.randint(0, 10_000_000)
        self.by_id = {item["ratingKey"]: item for item in self.artists + self.albums + self.tracks}
        self.history = self._make_history(rng)
        by_title = {track["title"]: track for track in self.tracks}
        # Playlist slots get their own ids (PMS's playlistItemID), which removing and moving go by.
        self.next_item_id = 1
        self.playlists.append({"ratingKey": "900", "title": "All Music", "smart": True, "_entries": None,
                               "addedAt": STAMP - 60 * 86_400, "updatedAt": STAMP - 60 * 86_400})
        for offset, playlist in enumerate(catalog["playlists"]):
            ids = [by_title[name]["ratingKey"] for name in playlist["pick"] if name in by_title]
            self.playlists.append({"ratingKey": str(901 + offset), "title": playlist["title"], "smart": False,
                                   "_entries": self.make_entries(ids), "_summary": playlist.get("summary"),
                                   "_poster": playlist.get("poster"), "addedAt": STAMP - 60 * 86_400,
                                   "updatedAt": STAMP - offset * 9 * 86_400})

    def _make_history(self, rng: random.Random) -> list[dict]:
        """Listening sessions from March 2024 up to now, in this machine's time zone: the drive in, lunch, the
        drive home and evenings on weekdays, lazier weekends. A few songs or most of an album at a time, each
        song played mostly in the seasons its album's moods suit. Tracks get viewCount and lastViewedAt from it,
        as PMS reports them."""
        seasons = {"Autumnal": [9, 10, 11], "Spooky": [10], "Eerie": [10, 11], "Nostalgic": [9, 10, 11],
                   "Wintry": [12, 1, 2], "Cold": [12, 1, 2], "Ethereal": [12, 1, 2], "Summery": [6, 7, 8],
                   "Carefree": [6, 7, 8], "Springlike": [3, 4, 5], "Pastoral": [3, 4, 5], "Romantic": [2]}

        def suits(track: dict, month: int) -> bool:
            months = {m for mood in track["_album"]["_moods"] for m in seasons.get(mood, [])}
            return not months or month in months

        albums: dict[str, list[dict]] = {}
        for track in self.tracks:
            albums.setdefault(track["parentRatingKey"], []).append(track)
        # (hour, chance of a session starting around then)
        weekday = [(7.6, 0.4), (12.3, 0.12), (17.4, 0.35), (21.0, 0.3)]
        weekend = [(10.8, 0.35), (15.0, 0.3), (20.5, 0.3)]
        now = dt.datetime.now()
        day = dt.date(2024, 3, 1)
        plays = []
        while day <= now.date():
            for hour, chance in weekend if day.weekday() >= 5 else weekday:
                if rng.random() >= chance:
                    continue
                if rng.random() < 0.3:
                    album = rng.choice([songs for songs in albums.values() if suits(songs[0], day.month)])
                    session = album[:rng.randint(3, len(album))]
                else:
                    session = []
                    for _ in range(rng.randint(2, 5)):
                        for _attempt in range(12):
                            track = rng.choice(self.tracks)
                            if suits(track, day.month):
                                break
                        session.append(track)
                moment = dt.datetime.combine(day, dt.time()) + dt.timedelta(hours=hour + rng.uniform(-1.0, 1.0))
                for track in session:
                    moment += dt.timedelta(milliseconds=track["duration"])
                    if moment > now:
                        break
                    plays.append({"ratingKey": track["ratingKey"], "key": track["key"], "type": "track", "title": track["title"],
                                  "librarySectionID": SECTION, "viewedAt": int(moment.timestamp()), "accountID": 1, "deviceID": 7})
            day += dt.timedelta(days=1)
        for play in plays:
            track = self.by_id[play["ratingKey"]]
            track["viewCount"] = track.get("viewCount", 0) + 1
            track["lastViewedAt"] = max(track.get("lastViewedAt", 0), play["viewedAt"])
            # Albums too: Home's Recently Played sorts them by it.
            track["_album"]["lastViewedAt"] = max(track["_album"].get("lastViewedAt", 0), play["viewedAt"])
            # And artists, which Artists sorts by (Recently Played, Most Played).
            artist = self.by_id[track["grandparentRatingKey"]]
            artist["viewCount"] = artist.get("viewCount", 0) + 1
            artist["lastViewedAt"] = max(artist.get("lastViewedAt", 0), play["viewedAt"])
        return sorted(plays, key=lambda play: play["viewedAt"])

    def make_entries(self, track_ids: list[str]) -> list[tuple[int, str]]:
        entries = []
        for track_id in track_ids:
            entries.append((self.next_item_id, track_id))
            self.next_item_id += 1
        return entries

    def playlist(self, playlist_id: str) -> dict | None:
        return next((p for p in self.playlists if p["ratingKey"] == playlist_id), None)

    @staticmethod
    def touch(playlist: dict) -> None:
        playlist["updatedAt"] = int(time.time())

    # MARK: shapes

    def public(self, item: dict, detailed: bool = False) -> dict:
        out = {key: value for key, value in item.items() if not key.startswith("_")}
        if item.get("type") == "track":
            stream = {"streamType": 2, "codec": "aac", "selected": True}
            if detailed:
                stream.update({"loudness": str(item["_loudness"]), "gain": str(item["_gain"]), "albumGain": str(item["_albumGain"]),
                               "peak": "0.98"})
            part = {"key": f"/library/parts/{item['ratingKey']}/{STAMP}/file.m4a", "container": "mp4", "duration": item["duration"]}
            if detailed:
                part["Stream"] = [stream]
            out["Media"] = [{"container": "mp4", "audioCodec": "aac", "bitrate": 96, "Part": [part]}]
        return out

    def playlist_entries(self, playlist: dict) -> list[tuple[int, dict]]:
        """(playlistItemID, track) per slot; the smart "All Music" numbers every song in order."""
        entries = playlist["_entries"]
        if entries is None:
            return list(enumerate(self.tracks, start=1))
        return [(item_id, self.by_id[track_id]) for item_id, track_id in entries if track_id in self.by_id]

    def playlist_items(self, playlist: dict) -> list[dict]:
        return [track for _, track in self.playlist_entries(playlist)]

    def playlist_public(self, playlist: dict) -> dict:
        items = self.playlist_items(playlist)
        public = {"ratingKey": playlist["ratingKey"], "key": f"/playlists/{playlist['ratingKey']}/items", "type": "playlist",
                  "title": playlist["title"], "smart": playlist["smart"], "playlistType": "audio", "leafCount": len(items),
                  "duration": sum(t["duration"] for t in items), "composite": f"/playlists/{playlist['ratingKey']}/composite/{STAMP}",
                  "addedAt": playlist["addedAt"], "updatedAt": playlist["updatedAt"]}
        if playlist.get("_summary"):
            public["summary"] = playlist["_summary"]
        if playlist.get("_poster") or playlist.get("_poster_bytes"):
            # A new upload gets a new stamp, like PMS, so cached art doesn't stick around.
            public["thumb"] = f"/library/metadata/{playlist['ratingKey']}/thumb/{playlist.get('_poster_stamp', STAMP)}"
        return public


LIB: Library


def container(items: list | None = None, total: int | None = None, directories: list | None = None, **extra) -> dict:
    body = dict(extra)
    if items is not None:
        body["Metadata"] = items
        body["size"] = len(items)
    if directories is not None:
        body["Directory"] = directories
        body["size"] = len(directories)
    if total is not None:
        body["totalSize"] = total
    return {"MediaContainer": body}


def artist_sort(item: dict) -> str:
    name = item.get("grandparentTitle", "") if item.get("type") == "track" else item.get("parentTitle", "")
    return name.removeprefix("The ").lower()


def album_sort(item: dict) -> str:
    return (item.get("parentTitle", "") if item.get("type") == "track" else item.get("title", "")).lower()


def multivariant_playlist(session: str) -> str:
    """What PMS answers start.m3u8 with: one AAC variant, in a folder named for the session."""
    return ("#EXTM3U\n#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=182000,CODECS=\"mp4a.40.2\"\n"
            f"session/{session}/base/index.m3u8\n")


def media_playlist(seconds: int) -> str:
    """The whole song as one segment: the demo .m4a (moov first), which AVPlayer plays as a segment, where PMS
    cuts AAC into ten-second pieces."""
    return (f"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:{seconds + 1}\n#EXT-X-MEDIA-SEQUENCE:0\n"
            f"#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:{seconds}.000,\n00000.m4a\n#EXT-X-ENDLIST\n")


def page(items: list, query: dict) -> tuple[list, int]:
    start = int(query.get("X-Plex-Container-Start", 0))
    size = query.get("X-Plex-Container-Size")
    chosen = items[start:] if size is None else items[start:start + int(size)]
    return chosen, len(items)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        log.debug("[http] " + fmt, *args)

    def send_json(self, payload: dict, status: int = 200) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_text(self, text: str, content_type: str) -> None:
        data = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_empty(self, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def send_bytes(self, data: bytes, content_type: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_art(self, item_id: str) -> None:
        """An uploaded playlist cover, a bundled playlist poster, or an album cover or artist portrait."""
        playlist = LIB.playlist(item_id)
        if playlist and playlist.get("_poster_bytes"):
            return self.send_bytes(playlist["_poster_bytes"], "image/jpeg")
        if playlist and playlist.get("_poster"):
            return self.send_file(LIBRARY / playlist["_poster"], "image/jpeg")
        item = LIB.by_id.get(item_id)
        relative = item and (item.get("_cover") or item.get("_portrait"))
        return self.send_file(LIBRARY / relative, "image/jpeg") if relative else self.send_empty(404)

    def send_file(self, path: Path, content_type: str) -> None:
        if not path.exists():
            self.send_empty(404)
            return
        size = path.stat().st_size
        start, end = 0, size - 1
        ranged = self.headers.get("Range")
        if ranged and (match := re.match(r"bytes=(\d*)-(\d*)", ranged)):
            if match.group(1):
                start = int(match.group(1))
                end = int(match.group(2)) if match.group(2) else size - 1
            else:
                start = size - int(match.group(2))
            end = min(end, size - 1)
        length = end - start + 1
        self.send_response(206 if ranged else 200)
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if ranged:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with path.open("rb") as handle:
            handle.seek(start)
            remaining = length
            while remaining > 0:
                chunk = handle.read(min(65536, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                remaining -= len(chunk)

    def do_GET(self) -> None:
        self.route("GET")

    def do_PUT(self) -> None:
        self.route("PUT")

    def do_POST(self) -> None:
        self.route("POST")

    def do_DELETE(self) -> None:
        self.route("DELETE")

    def route(self, method: str) -> None:
        started = time.monotonic()
        parts = urlsplit(self.path)
        path = unquote(parts.path)
        query = dict(parse_qsl(parts.query, keep_blank_values=True))
        query.pop("X-Plex-Token", None)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length > 0 else b""
        try:
            self.dispatch(method, path, query, body)
        except Exception:  # noqa: BLE001 - a demo server should log and answer, not die
            log.exception("[demo] %s %s failed", method, path)
            self.send_empty(500)
        log.info("[demo] %s %s %s%s in %.0fms", method, path, ",".join(sorted(query)), f" +{len(body)}B" if body else "",
                 (time.monotonic() - started) * 1000)

    def dispatch(self, method: str, path: str, query: dict, body: bytes = b"") -> None:
        lib = LIB
        if path == "/identity":
            return self.send_json(container(machineIdentifier="demo", version="1.43.5.demo"))
        if path == "/library/sections":
            return self.send_json(container(directories=[{"key": SECTION, "type": "artist", "title": "Music",
                                                          "agent": "tv.plex.agents.music"}]))
        if (match := re.fullmatch(r"/library/sections/\d+/mood", path)):
            moods = [{"key": key, "title": name, "fastKey": f"/library/sections/{SECTION}/all?mood={key}"}
                     for name, key in sorted(lib.moods.items())]
            return self.send_json(container(directories=moods))
        if re.fullmatch(r"/library/sections/\d+/all", path):
            return self.send_json(self.library_all(query))
        if (match := re.fullmatch(r"/library/metadata/(\d+)/thumb/\d+", path)):
            return self.send_art(match.group(1))
        if (match := re.fullmatch(r"/library/metadata/(\d+)/posters", path)) and method == "POST":
            # A custom cover: the JPEG is the whole body, as Truffle and scripts/plex_mix.py send it.
            playlist = lib.playlist(match.group(1))
            if not playlist:
                return self.send_empty(404)
            if not body:
                return self.send_empty(400)
            with lib.lock:
                playlist["_poster_bytes"] = body
                playlist["_poster_stamp"] = max(int(time.time()), playlist.get("_poster_stamp", 0) + 1)
                lib.touch(playlist)
            return self.send_empty(200)
        if (match := re.fullmatch(r"/library/metadata/(\d+)", path)) and method == "PUT":
            # The locked summary Truffle and plex_mix.py set on a playlist's metadata item.
            playlist = lib.playlist(match.group(1))
            if playlist and "summary.value" in query:
                with lib.lock:
                    playlist["_summary"] = query["summary.value"]
                    lib.touch(playlist)
            return self.send_empty(200)
        if (match := re.fullmatch(r"/library/metadata/(\d+)/children", path)):
            item = lib.by_id.get(match.group(1))
            if item and item["type"] == "artist":
                kids = [lib.public(a) for a in lib.albums if a["parentRatingKey"] == item["ratingKey"]]
            else:
                kids = [lib.public(t) for t in lib.tracks if t["parentRatingKey"] == match.group(1)]
            return self.send_json(container(kids, total=len(kids)))
        if (match := re.fullmatch(r"/library/metadata/(\d+)/allLeaves", path)):
            kids = [lib.public(t) for t in lib.tracks if t["grandparentRatingKey"] == match.group(1)]
            chosen, total = page(kids, query)
            return self.send_json(container(chosen, total=total))
        if (match := re.fullmatch(r"/library/metadata/([\d,]+)", path)):
            items = [lib.public(lib.by_id[i], detailed=True) for i in match.group(1).split(",") if i in lib.by_id]
            return self.send_json(container(items))
        if path == "/photo/:/transcode":
            thumb = query.get("url", "")
            if (match := re.fullmatch(r"/playlists/(\d+)/composite/\d+", thumb)):
                playlist = next((p for p in lib.playlists if p["ratingKey"] == match.group(1)), None)
                items = lib.playlist_items(playlist) if playlist else []
                cover = items[0]["_album"]["_cover"] if items else None
                return self.send_file(LIBRARY / cover, "image/jpeg") if cover else self.send_empty(404)
            if (match := re.fullmatch(r"/library/metadata/(\d+)/thumb/\d+", thumb)):
                return self.send_art(match.group(1))
            return self.send_empty(404)
        if (match := re.fullmatch(r"/library/parts/(\d+)/\d+/file\.m4a", path)):
            track = lib.by_id.get(match.group(1))
            return self.send_file(LIBRARY / "audio" / f"song-{track['_song']}.m4a", "audio/mp4") if track else self.send_empty(404)
        if path == "/music/:/transcode/universal/start.m3u8":
            # Like PMS 1.43 without the HLS music profile: "No conversion profile found for protocol hls", a 400.
            # DEMO_TRANSCODE_FAILS=1 turns every transcode down, to watch Data Saver fall back.
            failing = bool(os.environ.get("DEMO_TRANSCODE_FAILS"))
            if failing or "protocol=hls" not in query.get("X-Plex-Client-Profile-Extra", ""):
                log.info("[transcode] turned down (%s)", "DEMO_TRANSCODE_FAILS" if failing else "no hls profile")
                return self.send_empty(400)
            match = re.fullmatch(r"/library/metadata/(\d+)", query.get("path", ""))
            session = query.get("session", "")
            if not match or not session or match.group(1) not in lib.by_id:
                return self.send_empty(400)
            with lib.lock:
                lib.transcodes[session] = match.group(1)
            log.info("[transcode] %s started for %s at %s kbps", session[:8], lib.by_id[match.group(1)]["title"],
                     query.get("musicBitrate"))
            return self.send_text(multivariant_playlist(session), "application/vnd.apple.mpegurl")
        if (match := re.fullmatch(r"/music/:/transcode/universal/session/([^/]+)/base/(index\.m3u8|00000\.m4a)", path)):
            track = lib.by_id.get(lib.transcodes.get(match.group(1), ""))
            if not track:
                return self.send_empty(404)
            if match.group(2) == "index.m3u8":
                return self.send_text(media_playlist(PROGRESSIONS[track["_song"]][1]), "application/vnd.apple.mpegurl")
            return self.send_file(LIBRARY / "audio" / "hls" / f"song-{track['_song']}.m4a", "audio/mp4")
        if path == "/video/:/transcode/universal/stop":
            session = query.get("session", "")
            with lib.lock:
                known = lib.transcodes.pop(session, None) is not None
            log.info("[transcode] %s stopped (known=%s)", session[:8], known)
            return self.send_empty(200)
        if path == "/playlists" and method == "GET":
            return self.send_json(container([lib.playlist_public(p) for p in lib.playlists]))
        if path == "/playlists" and method == "POST":
            ids = re.findall(r"\d+", query.get("uri", "").split("/library/metadata/")[-1])
            now = int(time.time())
            with lib.lock:
                playlist = {"ratingKey": str(950 + len(lib.playlists)), "title": query.get("title", "Playlist"), "smart": False,
                            "_entries": lib.make_entries(ids), "addedAt": now, "updatedAt": now}
                lib.playlists.append(playlist)
            return self.send_json(container([lib.playlist_public(playlist)]))
        if (match := re.fullmatch(r"/playlists/(\d+)", path)):
            playlist = lib.playlist(match.group(1))
            if not playlist:
                return self.send_empty(404)
            if method == "PUT":
                with lib.lock:
                    if "title" in query:
                        playlist["title"] = query["title"]
                    if "summary" in query:
                        playlist["_summary"] = query["summary"]
                    lib.touch(playlist)
            return self.send_json(container([lib.playlist_public(playlist)]))
        if (match := re.fullmatch(r"/playlists/(\d+)/items/(\d+)/move", path)) and method == "PUT":
            playlist = lib.playlist(match.group(1))
            if not playlist or playlist["_entries"] is None:
                return self.send_empty(404)
            item_id, after = int(match.group(2)), query.get("after")
            with lib.lock:
                entries = playlist["_entries"]
                moving = next((e for e in entries if e[0] == item_id), None)
                if moving is None or (after and not any(e[0] == int(after) for e in entries if e[0] != item_id)):
                    return self.send_empty(404)
                entries.remove(moving)
                # Right after `after`, or first without one.
                position = next(i + 1 for i, e in enumerate(entries) if e[0] == int(after)) if after else 0
                entries.insert(position, moving)
                lib.touch(playlist)
            return self.send_json(container([lib.playlist_public(playlist)]))
        if (match := re.fullmatch(r"/playlists/(\d+)/items/(\d+)", path)) and method == "DELETE":
            playlist = lib.playlist(match.group(1))
            if not playlist or playlist["_entries"] is None:
                return self.send_empty(404)
            with lib.lock:
                kept = [e for e in playlist["_entries"] if e[0] != int(match.group(2))]
                if len(kept) == len(playlist["_entries"]):
                    return self.send_empty(404)
                playlist["_entries"] = kept
                lib.touch(playlist)
            return self.send_json(container([lib.playlist_public(playlist)]))
        if (match := re.fullmatch(r"/playlists/(\d+)/items", path)):
            playlist = lib.playlist(match.group(1))
            if not playlist:
                return self.send_empty(404)
            if method == "PUT":
                ids = re.findall(r"\d+", query.get("uri", "").split("/library/metadata/")[-1])
                with lib.lock:
                    playlist["_entries"] = (playlist["_entries"] or []) + lib.make_entries(ids)
                    lib.touch(playlist)
                return self.send_json(container([lib.playlist_public(playlist)]))
            items = [dict(lib.public(t), playlistItemID=item_id) for item_id, t in lib.playlist_entries(playlist)]
            chosen, total = page(items, query)
            return self.send_json(container(chosen, total=total))
        if path == "/hubs/search":
            text = query.get("query", "").lower()
            limit = int(query.get("limit", 10))
            hubs = [
                {"type": "artist", "Metadata": [lib.public(a) for a in lib.artists if text in a["title"].lower()][:limit]},
                {"type": "album", "Metadata": [lib.public(a) for a in lib.albums if text in a["title"].lower()][:limit]},
                {"type": "track", "Metadata": [lib.public(t) for t in lib.tracks if text in t["title"].lower()][:limit]},
            ]
            return self.send_json({"MediaContainer": {"size": len(hubs), "Hub": hubs}})
        if path == "/status/sessions/history/all":
            plays = list(lib.history)
            if "viewedAt>" in query:
                plays = [p for p in plays if p["viewedAt"] >= int(query["viewedAt>"])]
            if "viewedAt<" in query:
                plays = [p for p in plays if p["viewedAt"] <= int(query["viewedAt<"])]
            if query.get("sort", "").endswith(":desc"):
                plays.reverse()
            chosen, total = page(plays, query)
            return self.send_json(container(chosen, total=total))
        if path == "/:/rate":
            track = lib.by_id.get(query.get("key", ""))
            if track:
                rating = float(query.get("rating", -1))
                with lib.lock:
                    if rating < 0:
                        track.pop("userRating", None)
                    else:
                        track["userRating"] = rating
                        track["lastRatedAt"] = int(time.time())
            return self.send_empty(200)
        if path == "/:/timeline":
            log.info("[timeline] %s %s at %ss", query.get("state"), lib.by_id.get(query.get("ratingKey", ""), {}).get("title"),
                     int(query.get("time", 0)) // 1000)
            return self.send_empty(200)
        return self.send_empty(404)

    def library_all(self, query: dict) -> dict:
        lib = LIB
        kind = query.get("type", "10")
        items = {"8": lib.artists, "9": lib.albums, "10": lib.tracks}.get(kind, lib.tracks)
        if "album.mood" in query:
            wanted = set(query["album.mood"].split(","))
            names = {name for name, key in lib.moods.items() if key in wanted}
            items = [t for t in items if names & set(t["_album"]["_moods"])]
        if "mood" in query:
            wanted = set(query["mood"].split(","))
            names = {name for name, key in lib.moods.items() if key in wanted}
            items = [i for i in items if names & set(i.get("_moods", []))]
        if "userRating>" in query:
            floor = float(query["userRating>"])
            items = [i for i in items if i.get("userRating", 0) >= floor]
        if "title" in query:
            # PMS reads a plain string filter as "contains", without case.
            needle = query["title"].lower()
            items = [i for i in items if needle in i["title"].lower()]
        sort = query.get("sort", "")
        field, _, direction = sort.partition(":")
        descending = direction == "desc"
        if sort == "random":
            items = random.sample(items, len(items))
        elif field in ("addedAt", "lastRatedAt", "lastViewedAt", "viewCount"):
            items = sorted(items, key=lambda i: i.get(field, 0), reverse=descending)
        elif field == "titleSort":
            items = sorted(items, key=lambda i: i.get("titleSort", i["title"]).lower(), reverse=descending)
        elif field == "artist.titleSort":
            # PMS's "Album Artist" order; within an artist, albums then track numbers.
            items = sorted(items, key=lambda i: (artist_sort(i), album_sort(i), i.get("index", 0)), reverse=descending)
        elif field == "album.titleSort":
            items = sorted(items, key=lambda i: (album_sort(i), i.get("index", 0)), reverse=descending)
        elif sort == "id":
            items = sorted(items, key=lambda i: int(i["ratingKey"]))
        chosen, total = page(items, query)
        return container([lib.public(i) for i in chosen], total=total)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S", stream=sys.stderr)
    if not (LIBRARY / "covers").exists():
        sys.exit("No demo-library/covers yet. Run: make demo-library")
    make_audio()
    global LIB
    LIB = Library()
    log.info("[demo] %d artists, %d albums, %d songs, %d plays, %d moods on :%d", len(LIB.artists), len(LIB.albums),
             len(LIB.tracks), len(LIB.history), len(LIB.moods), PORT)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
