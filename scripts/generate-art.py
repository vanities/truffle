#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["requests", "pillow", "numpy"]
# ///
"""Truffle's generated art, with OpenAI's image API (gpt-image-2, Adam's pick).

Auth: OPENAI_API_KEY (Adam's, per his instruction 2026-10-30), from the environment, then `.env`
in this repo, then ../game/.env where the art pipeline keeps it. Nothing secret is printed.

    uv run --script scripts/generate-art.py icons            # icon concepts → build/art/icon-*.png
    uv run --script scripts/generate-art.py icon-set CONCEPT [--name AppIcon-Note]  # light/dark/tinted icon set
    uv run --script scripts/generate-art.py mixes [KEY ...]  # mix artwork into Mix-*.imageset
    uv run --script scripts/generate-art.py props [KEY ...]  # transparent seasonal props into Prop-*.imageset
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
import numpy as np
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
    "stPatricks": "A cheerful little shamrock wearing big headphones and a tiny green top hat, dancing a jig on top of a pot of gold coins, a small rainbow arcing behind it. Emerald and kelly green, shiny gold and soft cream.",
    "fourthOfJuly": "A happy hot dog in a bun wearing star-shaped sunglasses and headphones, waving a sparkler, with red, white and blue fireworks bursting in the night sky behind it. Deep navy blue, bright red, white and a little gold.",
    "nightDrive": "A tiny cute car with glowing headlights driving down an empty neon highway toward a big moon under a starry sky. Synthwave purple, magenta and electric blue.",
    "lastYear": "A smiling flip calendar flipping its pages backwards with a nostalgic little sparkle, a faded polaroid photo tucked into it. Warm sepia, dusty rose and plum.",
    "favorites": "A proud gold star wearing headphones standing on a small trophy pedestal, sparkles all around. Gold, warm orange and deep purple.",
}


# Small figures the seasonal backdrop draws on top of the cards and across the sky. Each is
# (size, max output side in px, silhouette?, prompt). gpt-image-2 has no transparent background, so props
# are drawn on a flat key color and keyed out; silhouettes come out as one white shape the app tints.
PROP_KEY = "a perfectly flat, solid, uniform pure magenta (#FF00FF) background"
SILHOUETTE_KEY = "a perfectly flat, solid, uniform pure white background"
PROP_STYLE = (
    f"A single small decorative object for a music app's seasonal theme, alone on {PROP_KEY}, with a generous empty "
    "margin around it. Cute flat vector illustration with bold simple shapes, soft gradients and gentle highlights, "
    "rich saturated color, a thin darker outline, in a playful cartoon style. No magenta or pink anywhere on the "
    "object. No ground, no cast shadow, no scenery, no frame. Absolutely no text, letters, numbers or words anywhere."
)
SILHOUETTE_STYLE = (
    f"One solid flat pure black silhouette with crisp clean edges and no interior detail, on {SILHOUETTE_KEY}, "
    "with a generous empty margin around it. No moon, no stars, no ground, no scenery, no frame. Absolutely no "
    "text, letters, numbers or words anywhere."
)
PROPS = {
    "pumpkin": ("1024x1024", 300, False,
                "A plump round orange pumpkin with deep ribs, a short curly green stem, a curling vine tendril and one "
                "small green leaf, seen from the front, sitting upright as if resting on a shelf."),
    "gourd": ("1024x1024", 300, False,
              "A small squat cream-white pumpkin with soft pale green ribs and a stubby brown stem, seen from the front, "
              "sitting upright as if resting on a shelf."),
    "jackOLantern": ("1024x1024", 300, False,
                     "A cute carved jack-o'-lantern pumpkin with a friendly toothy grin and triangle eyes glowing warm "
                     "yellow-orange from the candle inside, a short curly green stem, seen from the front, sitting upright "
                     "as if resting on a shelf."),
    "sleigh": ("1536x1024", 900, True,
               "Santa Claus in his sleigh pulled by a team of six reindeer flying to the right through the air, seen from "
               "the side: the classic Christmas Eve silhouette. The reindeer run in a graceful rising line, two by two, "
               "legs mid-gallop, antlers up, reins to the sleigh; Santa waves, his sack of toys behind him. Wide and "
               "short, the whole team in one row."),
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


def generate(prompt: str, key: str, quality: str, label: str, size: str = "1024x1024") -> Image.Image:
    started = time.monotonic()
    body = {"model": MODEL, "prompt": prompt, "n": 1, "size": size, "quality": quality}
    response = requests.post(API_URL, timeout=300, headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
                             json=body)
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


def cmd_icon_set(key: str, concept: str, name: str = "AppIcon") -> None:
    folder = ASSETS / f"{name}.appiconset"
    folder.mkdir(parents=True, exist_ok=True)
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
    if name == "AppIcon":
        light_image.resize((512, 512), Image.LANCZOS).save(ASSETS / "Mark.imageset" / "Mark.png")
    # Settings shows each icon; an app icon set can't be loaded as an image, so keep a small copy.
    preview = ASSETS / f"IconPreview-{concept}.imageset"
    preview.mkdir(parents=True, exist_ok=True)
    light_image.resize((180, 180), Image.LANCZOS).save(preview / "icon.png")
    (preview / "Contents.json").write_text(json.dumps(
        {"images": [{"filename": "icon.png", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}}, indent=2))
    print(f"[art] {name} written from concept {concept}")


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


def chroma_key(image: Image.Image, solid: float = 120, clear: float = 36) -> Image.Image:
    """Keys out the flat background the prop was drawn on. The key color is read from the border, and
    edge pixels are unmixed from it, so there's no colored fringe once the app scales the prop down."""
    rgb = np.asarray(image.convert("RGB")).astype(np.float32)
    border = np.concatenate([rgb[:6].reshape(-1, 3), rgb[-6:].reshape(-1, 3), rgb[:, :6].reshape(-1, 3), rgb[:, -6:].reshape(-1, 3)])
    key = np.median(border, axis=0)
    distance = np.linalg.norm(rgb - key, axis=2)
    alpha = np.clip((distance - clear) / (solid - clear), 0, 1)
    a = alpha[..., None]
    color = np.clip((rgb - (1 - a) * key) / np.maximum(a, 1e-3), 0, 255)
    out = np.dstack([color, alpha * 255]).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def cmd_props(key: str, keys: list[str]) -> None:
    def make(name: str) -> tuple[str, Image.Image]:
        size, _, silhouette, prompt = PROPS[name]
        style = SILHOUETTE_STYLE if silhouette else PROP_STYLE
        return name, generate(f"{style} {prompt}", key, "high", f"prop {name}", size=size)

    OUT.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=4) as pool:
        for name, raw in pool.map(make, keys):
            _, longest, silhouette, _ = PROPS[name]
            raw.save(OUT / f"prop-{name}-raw.png")
            image = chroma_key(raw)
            if silhouette:
                # One white shape; the app tints it (template rendering).
                white = Image.new("RGBA", image.size, (255, 255, 255, 0))
                white.putalpha(image.getchannel("A"))
                image = white
            box = image.getchannel("A").point(lambda a: 255 if a > 10 else 0).getbbox()
            if box:
                pad = max(4, int(max(box[2] - box[0], box[3] - box[1]) * 0.02))
                image = image.crop((max(0, box[0] - pad), max(0, box[1] - pad),
                                    min(image.width, box[2] + pad), min(image.height, box[3] + pad)))
            scale = min(1.0, longest / max(image.size))
            image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
            folder = ASSETS / f"Prop-{name}.imageset"
            folder.mkdir(parents=True, exist_ok=True)
            image.save(folder / f"{name}.png", optimize=True)
            contents: dict = {"images": [{"filename": f"{name}.png", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}}
            if silhouette:
                contents["properties"] = {"template-rendering-intent": "template"}
            (folder / "Contents.json").write_text(json.dumps(contents, indent=2))
            print(f"[art] prop {name}: {image.width}x{image.height} (raw render in {OUT})", flush=True)
    print(f"[art] {len(keys)} props in the asset catalog")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    icons = sub.add_parser("icons")
    icons.add_argument("concepts", nargs="*", default=list(ICON_CONCEPTS))
    icon_set = sub.add_parser("icon-set")
    icon_set.add_argument("concept", choices=list(ICON_CONCEPTS))
    icon_set.add_argument("--name", default="AppIcon")
    mixes = sub.add_parser("mixes")
    mixes.add_argument("keys", nargs="*", default=list(MIXES))
    props = sub.add_parser("props")
    props.add_argument("keys", nargs="*", default=list(PROPS), help=", ".join(PROPS))
    args = parser.parse_args()
    if args.command == "props" and (unknown := set(args.keys) - set(PROPS)):
        parser.error(f"unknown prop(s) {', '.join(sorted(unknown))}; one of: {', '.join(PROPS)}")
    key = api_key()
    print(f"[art] {MODEL}, OPENAI_API_KEY", flush=True)
    if args.command == "icons":
        cmd_icons(key, args.concepts)
    elif args.command == "icon-set":
        cmd_icon_set(key, args.concept, args.name)
    elif args.command == "props":
        cmd_props(key, args.keys)
    else:
        cmd_mixes(key, args.keys)


if __name__ == "__main__":
    main()
