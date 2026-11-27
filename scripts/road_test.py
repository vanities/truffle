#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# ///
"""A drive in the simulator: an album streams as if on cellular while the connection changes under it.

    scripts/road_test.py "0:5g 45:3g 75:dead 165:5g 200:end" --save-ahead YES --out build/road/on
    scripts/road_test.py "0:3g 180:end" --save-ahead NO --out build/road/3g-off

The timeline is seconds after launch and what the connection becomes (scripts/demo_server.py's
/demo/network: 5g, lte, 3g, edge, dead, wifi, or a rate in kbps such as 2000). The app runs `-TruffleScene road`: the first album from its
first song, Next after `--next` seconds. Songs are FLAC the size of a CD rip (about 900 kbps), played muted.

It prints, and saves under --out: the car log (one line per silence), the seconds of silence it adds up to,
the player's own log lines for the cache and the buffering rules, and a screenshot before each change (the
scrubber shows where the song's clock stood; it only advances while sound is playing).

Needs a simulator that is not the signed-in "Truffle" one (default: "Truffle Player"), a debug build in
build/DerivedData, and ./demo-library.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
APP = REPO / "build/DerivedData/Build/Products/Debug-iphonesimulator/Truffle.app"
BUNDLE = "com.vanities.truffle"
SERVER = "http://127.0.0.1:32499"


def say(text: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {text}", flush=True)


def run(*args: str, check: bool = True) -> str:
    return subprocess.run(args, check=check, capture_output=True, text=True).stdout.strip()


def simulator(name: str) -> str:
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "-j"))["devices"]
    found = [d["udid"] for runtime in devices.values() for d in runtime if d["name"] == name and d.get("isAvailable")]
    if not found:
        sys.exit(f"no simulator named {name!r}")
    return found[0]


def network(profile: str) -> None:
    # A bare number is a rate in kbps.
    query = f"kbps={profile}" if profile.isdigit() else f"profile={profile}"
    with urllib.request.urlopen(f"{SERVER}/demo/network?{query}", timeout=5) as response:
        say(f"network → {json.load(response)['network']}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("timeline", help='"0:5g 45:3g 75:dead 165:5g 200:end"')
    parser.add_argument("--save-ahead", choices=["YES", "NO"], default="YES", help="Save Ahead on Cellular")
    parser.add_argument("--next", type=int, default=40, help="seconds into the album before Next")
    parser.add_argument("--flac", default="cd", help="cd: the size of a CD rip, about 900 kbps (default); 1: the small ones, about 335 kbps")
    parser.add_argument("--sim", default="Truffle Player")
    parser.add_argument("--out", type=Path, default=REPO / "build/road/run")
    args = parser.parse_args()

    steps = [(int(at), what) for at, what in (step.split(":") for step in args.timeline.split())]
    if steps[0][0] != 0 or steps[-1][1] != "end":
        sys.exit("the timeline starts at 0 and ends with <seconds>:end")
    if not APP.exists():
        sys.exit(f"no debug build at {APP}; run `make build`")
    args.out.mkdir(parents=True, exist_ok=True)
    udid = simulator(args.sim)

    server_log = (args.out / "server.log").open("w")
    server = subprocess.Popen([str(REPO / "scripts/demo_server.py")], env={**os.environ, "DEMO_FLAC": args.flac},
                              stdout=server_log, stderr=subprocess.STDOUT)
    stream = None
    try:
        for _ in range(40):
            try:
                urllib.request.urlopen(f"{SERVER}/identity", timeout=1).close()
                break
            except OSError:
                time.sleep(0.5)
        else:
            sys.exit("the demo server didn't come up; see server.log")

        run("xcrun", "simctl", "boot", udid, check=False)
        run("xcrun", "simctl", "bootstatus", udid)
        # Uninstalled first: a download still running from the last drive would land in this one.
        run("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)
        run("xcrun", "simctl", "uninstall", udid, BUNDLE, check=False)
        run("xcrun", "simctl", "install", udid, str(APP))
        # A fresh install asks for Siri and, on a holiday, says the icon changed; both sit over the screenshots.
        run("xcrun", "simctl", "privacy", udid, "grant", "siri", BUNDLE, check=False)
        data = Path(run("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data"))
        support = data / "Library/Application Support/Truffle"
        # A clean phone: nothing saved, no queue to resume (a resumed queue starts saving before Play).
        subprocess.run(["/bin/rm", "-rf", str(data / "Library/Caches/Songs"), str(support / "car-log.json"), str(support / "player.json")])

        stream = subprocess.Popen(["xcrun", "simctl", "spawn", udid, "log", "stream", "--level", "info", "--style", "compact",
                                   "--predicate", f'subsystem == "{BUNDLE}"'], stdout=(args.out / "app.log").open("w"),
                                  stderr=subprocess.DEVNULL)
        time.sleep(1)
        network(steps[0][1])
        started = time.monotonic()
        run("xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE, "-demo.active", "NO",
            "-TruffleServerURL", SERVER, "-TruffleServerToken", "demo", "-TruffleMute", "YES", "-TruffleCellular", "YES",
            "-settings.saveOnCellular", args.save_ahead, "-settings.dataSaver", "NO", "-settings.seasonalIcon", "NO", "-TruffleScene", "road",
            "-TruffleSteps", str(args.next))
        say(f"launched on {args.sim}: as if on cellular, Save Ahead on Cellular {args.save_ahead}, Next at {args.next} s")

        for at, what in steps[1:]:
            time.sleep(max(0, at - (time.monotonic() - started)))
            shot = args.out / f"at-{at:03d}s-before-{what}.png"
            run("xcrun", "simctl", "io", udid, "screenshot", str(shot), check=False)
            if what != "end":
                network(what)
        time.sleep(1)
    finally:
        if stream:
            stream.send_signal(signal.SIGINT)
        server.terminate()
        server_log.close()

    run("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)
    report(args.out, support)


def report(out: Path, support: Path) -> None:
    lines = (out / "app.log").read_text(errors="replace").splitlines()
    keep = re.compile(r"\[cache\]|\[buffer\]|\[debug\] road|\[carlog\]|preloaded|\[player\] (play|pause|next|stalled)")
    picked = [re.sub(r"^\S+ (\S+)\s+\S+\s+\S+\s+", r"\1 ", line)[:220] for line in lines if keep.search(line)]
    (out / "app-picked.log").write_text("\n".join(picked) + "\n")
    saved = sum("[cache] saved" in line for line in lines)
    from_phone = sum("plays from the phone" in line for line in lines)

    log_file = support / "car-log.json"
    entries = [entry["text"] for entry in json.loads(log_file.read_text())] if log_file.exists() else []
    (out / "car-log.txt").write_text("\n".join(entries) + "\n")
    # A "so far" line is the same silence as the line that ends it.
    silent = sum(float(m.group(1)) for text in entries if (m := re.match(r"Silent ([\d.]+) s (?!so far)", text)))

    print()
    print(f"songs saved to the phone: {saved}; songs readied from the phone: {from_phone}")
    print(f"silence the car log wrote down: {silent:.1f} s in {sum(text.startswith('Silent') and 'so far' not in text for text in entries)} stretch(es)")
    print("car log:")
    for text in entries or ["(empty: nothing went silent)"]:
        print(f"  {text}")
    print(f"logs and screenshots: {out}")


if __name__ == "__main__":
    main()
