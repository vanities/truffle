#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["requests", "pillow"]
# ///
"""Truffle's generated art, with OpenAI's image API (gpt-image-2, Adam's pick).

Auth: OPENAI_API_KEY (Adam's, per his instruction 2026-10-30), from the environment, then `.env`
in this repo, then ../game/.env where the art pipeline keeps it. Nothing secret is printed.

    uv run --script scripts/generate-art.py icons            # icon concepts → build/art/icon-*.png
    uv run --script scripts/generate-art.py icon-set CONCEPT # AppIcon, -Dark, -Tinted into the asset catalog
    uv run --script scripts/generate-art.py mixes [KEY ...]  # mix artwork into Mix-*.imageset
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import requests
from PIL import Image, ImageEnhance, ImageOps

REPO = Path(__file__).resolve().parent.parent
ASSETS = REPO / "Truffle/Resources/Assets.xcassets"
OUT = REPO / "build/art"
API_URL = "https://api.openai.com/v1/images/generations"
MODEL = "gpt-image-2"

# The family look Earmark and Mango set: one bold flat charcoal glyph on a vivid two-colour gradient.
ICON_BASE = (
    "App icon for iOS, square, 1024x1024, no text, no letters, no words anywhere. "
    "A single bold flat vector glyph centred in the frame, filling about 68% of it, with a "
    "soft subtle drop shadow beneath it. Flat modern iconography, generous even margins, "
    "crisp clean edges, perfectly centred, no gloss, no 3D render, no photorealism, no "
    "rounded-rectangle frame or border drawn inside the image. The background is a smooth "
    "two-colour diagonal gradient, completely plain with no pattern or texture."
)

ICON_CONCEPTS = {
    # Earmark wears headphones; so does its sibling. Cute at 60 px if the shapes stay bold.
    "headphones": (
        "The glyph is a round chocolate truffle candy, a plump ball with a little swirl of "
        "chocolate on top, wearing a pair of big over-ear headphones across its top. One "
        "bold solid silhouette, the headphones clearly readable."
    ),
    "note": (
        "The glyph is a round chocolate truffle candy seen from the side, a plump ball sitting "
        "in a fluted paper cup, with its swirl of chocolate on top curling up into a musical "
        "eighth note. One bold solid silhouette."
    ),
    "record": (
        "The glyph is a round chocolate truffle candy drawn as a vinyl record seen from above: "
        "a solid disc with a few concentric groove rings cut out of it and a small center "
        "label, topped with a playful chocolate drizzle swirl. One bold solid silhouette."
    ),
}

LIGHT = ("very dark charcoal, almost black",
         "warm dusky plum purple in the top-left to vivid sunset pink-orange in the bottom-right")
DARK = ("warm glowing sunset pink-orange", "very dark plum-black in the top-left to near-black in the bottom-right")

MIX_STYLE = (
    "Square illustration for a music app's mix cover. Playful, cute and a little silly, flat "
    "vector illustration with bold simple shapes and soft gradients, rich saturated color, one "
    "clear character or subject in the middle of the frame, plenty of breathing room near the "
    "bottom edge. Absolutely no text, letters, numbers or words anywhere."
)

MIXES = {
    "halloween": "A cute little jack-o'-lantern wearing big headphones and bobbing its head to music, under a huge full moon with a few cartoon bats. Deep purple night sky, pumpkin orange glow.",
    "fall": "A cheerful squirrel wearing headphones, sitting in a pile of maple leaves and holding an acorn like a microphone. Warm amber, rust and golden yellow.",
    "winter": "A happy snowman whose earmuffs are actually headphones, eyes closed and grooving, gentle snowfall. Icy blues and soft white.",
    "spring": "A fuzzy bumblebee wearing tiny headphones, dancing on top of a blooming pink flower. Pastel pink, fresh green and sunny yellow.",
    "summer": "A popsicle wearing sunglasses, lounging on a pool float shaped like a vinyl record in sparkling water. Teal, aqua and sunny yellow.",
    "thanksgiving": "A plump happy cartoon turkey wearing headphones, dancing next to a pumpkin pie and a little pile of autumn leaves. Warm browns, harvest orange and cream.",
    "christmas": "A gingerbread cookie person playing a tiny keyboard next to a glowing little tree with string lights. Cozy red, pine green and warm gold.",
    "newYear": "A disco ball wearing a party hat, surrounded by confetti and little fireworks. Midnight navy, gold and silver sparkle.",
    "valentines": "Two cassette tapes in love with heart eyes, little hearts floating up between them. Pink, red and soft cream.",
    "nightDrive": "A tiny cute car with glowing headlights driving down an empty neon highway toward a big moon under a starry sky. Synthwave purple, magenta and electric blue.",
    "lastYear": "A smiling flip calendar flipping its pages backwards with a nostalgic little sparkle, a faded polaroid photo tucked into it. Warm sepia, dusty rose and plum.",
    "favorites": "A proud gold star wearing headphones standing on a small trophy pedestal, sparkles all around. Gold, warm orange and deep purple.",
}


def load_env(path: Path) -> None:
    if not path.is_file():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip().removeprefix("export ").lstrip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def api_key() -> str:
    for candidate in (REPO / ".env", REPO.parent / "game" / ".env"):
        load_env(candidate)
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        sys.exit("No OPENAI_API_KEY in the environment, ./.env or ../game/.env")
    return key


def generate(prompt: str, key: str, quality: str, label: str) -> Image.Image:
    started = time.monotonic()
    response = requests.post(API_URL, timeout=300, headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
                             json={"model": MODEL, "prompt": prompt, "n": 1, "size": "1024x1024", "quality": quality})
    if not response.ok:
        sys.exit(f"[art] {label}: HTTP {response.status_code} {response.text[:400]}")
    data = response.json()["data"][0]
    raw = base64.b64decode(data["b64_json"]) if data.get("b64_json") else requests.get(data["url"], timeout=120).content
    print(f"[art] {label}: {len(raw) // 1024} KB in {time.monotonic() - started:.1f}s", flush=True)
    return Image.open(io.BytesIO(raw)).convert("RGB")


def icon_prompt(concept: str, glyph: str, background: str) -> str:
    return f"{ICON_BASE} {ICON_CONCEPTS[concept]} The glyph is {glyph}. The background gradient runs from {background}."


def cmd_icons(key: str, concepts: list[str]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=3) as pool:
        images = pool.map(lambda c: (c, generate(icon_prompt(c, *LIGHT), key, "high", f"icon {c}")), concepts)
        for concept, image in images:
            image.save(OUT / f"icon-{concept}.png")
    print(f"[art] icon concepts in {OUT}")


def cmd_icon_set(key: str, concept: str) -> None:
    folder = ASSETS / "AppIcon.appiconset"
    light = OUT / f"icon-{concept}.png"
    light_image = Image.open(light).convert("RGB") if light.exists() else generate(icon_prompt(concept, *LIGHT), key, "high", "icon light")
    dark_image = generate(icon_prompt(concept, *DARK), key, "high", "icon dark")
    light_image.resize((1024, 1024), Image.LANCZOS).save(folder / "AppIcon.png")
    dark_image.resize((1024, 1024), Image.LANCZOS).save(folder / "AppIcon-Dark.png")
    # Tinted: iOS colors a grayscale icon itself; the dark render, desaturated and lifted, reads best.
    tinted = ImageEnhance.Contrast(ImageOps.grayscale(dark_image)).enhance(1.35).convert("RGB")
    tinted.resize((1024, 1024), Image.LANCZOS).save(folder / "AppIcon-Tinted.png")
    (folder / "Contents.json").write_text(json.dumps({
        "images": [
            {"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "AppIcon-Dark.png",
             "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": "AppIcon-Tinted.png",
             "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        ],
        "info": {"author": "xcode", "version": 1},
    }, indent=2))
    mark = ASSETS / "Mark.imageset"
    light_image.resize((512, 512), Image.LANCZOS).save(mark / "Mark.png")
    print(f"[art] icon set written from concept {concept}")


def cmd_mixes(key: str, keys: list[str]) -> None:
    def make(name: str) -> tuple[str, Image.Image]:
        return name, generate(f"{MIX_STYLE} {MIXES[name]}", key, "medium", f"mix {name}")

    with ThreadPoolExecutor(max_workers=4) as pool:
        for name, image in pool.map(make, keys):
            folder = ASSETS / f"Mix-{name}.imageset"
            folder.mkdir(parents=True, exist_ok=True)
            # 768 px covers a 196 pt card at 3x; JPEG keeps the app small.
            image.resize((768, 768), Image.LANCZOS).save(folder / "art.jpg", quality=86, optimize=True)
            (folder / "Contents.json").write_text(json.dumps(
                {"images": [{"filename": "art.jpg", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}}, indent=2))
    print(f"[art] {len(keys)} mix covers in the asset catalog")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    icons = sub.add_parser("icons")
    icons.add_argument("concepts", nargs="*", default=list(ICON_CONCEPTS))
    icon_set = sub.add_parser("icon-set")
    icon_set.add_argument("concept", choices=list(ICON_CONCEPTS))
    mixes = sub.add_parser("mixes")
    mixes.add_argument("keys", nargs="*", default=list(MIXES))
    args = parser.parse_args()
    key = api_key()
    print(f"[art] {MODEL}, OPENAI_API_KEY", flush=True)
    if args.command == "icons":
        cmd_icons(key, args.concepts)
    elif args.command == "icon-set":
        cmd_icon_set(key, args.concept)
    else:
        cmd_mixes(key, args.keys)


if __name__ == "__main__":
    main()
