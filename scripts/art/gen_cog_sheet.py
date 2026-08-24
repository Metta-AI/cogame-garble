#!/usr/bin/env python3
"""Generates the Garble cog sheet with nano-banana (Gemini image generation).

One render, five cogs in a row — one radio kit per seat — on a flat chroma
backdrop, written to scripts/art/source/cogs_sheet.png. The kits are what
makes a seat readable on the board at 48 px with every label hidden: a whip
antenna, a dish, a headset-and-key, a crank set, and rabbit ears.

    GEMINI_API_KEY=... python3 scripts/art/gen_cog_sheet.py

The key is only ever the `x-goog-api-key` header; it is never printed, never
written to a file and never a URL parameter. `scripts/art/split_cog_sheet.py`
turns the sheet into the five `data/cog_<colour>_front.png` sprites, which are
committed — CI does not regenerate art.
"""

import base64
import json
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
REFERENCE = os.path.join(HERE, "source", "cog_reference.png")
OUT = os.path.join(HERE, "source", "cogs_sheet.png")
ENDPOINT = (
    "https://generativelanguage.googleapis.com/v1beta/models/"
    "gemini-2.5-flash-image:generateContent"
)

PROMPT = """Using this robot character ("cog") as the exact character design
reference, draw FIVE of these cogs side by side in one single horizontal row,
evenly spaced, all the same size, full body, front-facing, feet on the same
baseline, same clean cartoon rendering and same line weight as the reference.
Leave a WIDE empty vertical band of pure background between every pair of
neighbouring cogs — at least a third of a cog's width — and make each cog,
including everything it carries or wears, fit entirely inside its own column.
Nothing may touch, overlap or reach into a neighbour's column.

Background: perfectly flat, solid, uniform pure bright green (#00FF00). No
shadows, no drop shadows, no contact shadows, no gradients, no floor, no
ground plane, no vignette — the background will be chroma-keyed out and must
be one single colour edge to edge. Nothing green touches or overlaps any cog.

Each cog is a radio operator on a noisy trading floor and carries ONE big,
unmistakable piece of radio kit, so the five read apart instantly at small
size:

1. LEFT — RED (#E0523A) plating: a single tall straight whip antenna rising
   from the top of its head, and a chunky black handheld microphone held up
   to its screen face.
2. SECOND — BLUE (#3F7CC4) plating: a large white parabolic satellite dish
   mounted on its right shoulder, angled forward.
3. MIDDLE — GREEN (#2ECC71) plating: oversized padded headphones over the
   head and a small brass telegraph morse key held flat in both hands.
4. FOURTH — YELLOW (#DDC531) plating: a boxy field radio strapped across its
   chest with a big round tuning dial and a side hand crank.
5. RIGHT — VIOLET (#A86FD6) plating: twin V-shaped rabbit-ear antennae on its
   head and a stubby violet walkie-talkie clipped to its chest.

No text, no letters, no numbers, no labels, no speech bubbles, no logos."""


def main() -> int:
    key = os.environ.get("GEMINI_API_KEY", "").strip()
    if not key:
        print("GEMINI_API_KEY is not set", file=sys.stderr)
        return 2
    with open(REFERENCE, "rb") as handle:
        reference = base64.b64encode(handle.read()).decode()
    body = {
        "contents": [{"parts": [
            {"inline_data": {"mime_type": "image/png", "data": reference}},
            {"text": PROMPT},
        ]}],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={"x-goog-api-key": key, "content-type": "application/json"},
    )
    try:
        response = json.load(urllib.request.urlopen(request, timeout=180))
    except urllib.error.HTTPError as error:
        print("gemini HTTP", error.code, error.read()[:600].decode("utf-8",
              "replace"), file=sys.stderr)
        return 1
    parts = response["candidates"][0]["content"]["parts"]
    image = next(p for p in parts if "inlineData" in p)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as handle:
        handle.write(base64.b64decode(image["inlineData"]["data"]))
    print("wrote", os.path.relpath(OUT, REPO))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
