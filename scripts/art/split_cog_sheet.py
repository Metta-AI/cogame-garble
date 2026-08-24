#!/usr/bin/env python3
"""Splits the nano-banana cog sheet into the five seat sprites.

`scripts/art/source/cogs_sheet.png` is a single Gemini ("nano-banana") render
of the Softmax cog in five radio kits — whip antenna, satellite dish, headset
and morse key, crank field radio, rabbit ears — on a flat green backdrop
(`scripts/art/gen_cog_sheet.py` made it). This script keys the backdrop out
with an edge flood fill, so the green cog's own plating survives while the
backdrop and its drop shadows go; then it splits the row on empty columns,
crops each part to content, pads it to a square and writes 128 px RGBA
sprites:

    python3 scripts/art/split_cog_sheet.py [outdir]

Default outdir is `data`, which is what the game image and the replay-viewer
bundle both serve. The derived PNGs are committed — CI does not regenerate
art.
"""

import os
import sys
from collections import deque

from PIL import Image

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "source",
                  "cogs_sheet.png")
SEATS = [
    "cog_red_front.png",
    "cog_blue_front.png",
    "cog_green_front.png",
    "cog_yellow_front.png",
    "cog_violet_front.png",
]
SIZE = 128
TOL = 70       # colour distance from the backdrop that still counts as backdrop
               # — wide enough to swallow the render's soft drop shadows, which
               # are the backdrop hue a few steps darker
SHADOW_FLOOR = 0.55  # darkest shadow, as a fraction of the backdrop
HUE_SLACK = 12       # per-channel slack when matching the backdrop's ratios
MIN_COLUMN = 10  # opaque pixels a column needs before it counts as occupied;
                 # keying leaves a few-pixel haze that would otherwise bridge
                 # two neighbouring cogs into one run


def key_background(img):
    """Flood-fills the green backdrop (and its shadows) away from the edges."""
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    # Median of the border is robust to the corner smudges the render leaves.
    border = [px[x, y][:3] for x in range(w) for y in (0, h - 1)] + \
        [px[x, y][:3] for y in range(h) for x in (0, w - 1)]
    bg = tuple(sorted(c[i] for c in border)[len(border) // 2] for i in range(3))

    def backdrop(p):
        r, g, b = p[:3]
        if sum((a - c) ** 2 for a, c in zip((r, g, b), bg)) ** 0.5 <= TOL:
            return True
        # The soft drop shadows the render puts under each cog are the
        # backdrop colour scaled down, so they keep its channel ratios
        # exactly; the green cog's plating does not, which is what keeps its
        # body when the shadow under its feet goes.
        if g < 60:
            return False
        k = g / float(bg[1])
        if k < SHADOW_FLOOR or k > 1.25:
            return False
        return abs(r - bg[0] * k) <= HUE_SLACK and \
            abs(b - bg[2] * k) <= HUE_SLACK

    seen = bytearray(w * h)
    queue = deque()
    for x in range(w):
        queue.append((x, 0))
        queue.append((x, h - 1))
    for y in range(h):
        queue.append((0, y))
        queue.append((w - 1, y))
    while queue:
        x, y = queue.popleft()
        if x < 0 or y < 0 or x >= w or y >= h or seen[y * w + x]:
            continue
        seen[y * w + x] = 1
        if not backdrop(px[x, y]):
            continue
        px[x, y] = (0, 0, 0, 0)
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    return img


def split(img):
    alpha = img.getchannel("A")
    w, h = img.size
    columns = [sum(1 for y in range(h) if alpha.getpixel((x, y)) > 24)
               >= MIN_COLUMN for x in range(w)]
    runs, start = [], None
    for x, on in enumerate(columns + [False]):
        if on and start is None:
            start = x
        elif not on and start is not None:
            if x - start > 20:
                runs.append((start, x))
            start = None
    if len(runs) != len(SEATS):
        raise SystemExit("expected %d cogs in the sheet, found %d: %r"
                         % (len(SEATS), len(runs), runs))
    parts = []
    for x0, x1 in runs:
        part = img.crop((x0, 0, x1, h))
        part = part.crop(part.getbbox())
        side = max(part.size)
        square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        square.paste(part, ((side - part.width) // 2, side - part.height))
        parts.append(square.resize((SIZE, SIZE), Image.LANCZOS))
    return parts


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "data"
    os.makedirs(outdir, exist_ok=True)
    for name, sprite in zip(SEATS, split(key_background(Image.open(SRC)))):
        sprite.save(os.path.join(outdir, name))
    print("cog sprites written to", outdir)


if __name__ == "__main__":
    main()
