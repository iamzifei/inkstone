#!/usr/bin/env python3
"""
Builds Inkstone's app icon from `Tools/icon-artwork.png` into every slot declared
by AppIcon.appiconset/Contents.json.

    python3 Tools/generate-app-icon.py

The artwork is an inkstone (砚) with a cinnabar seal (朱印) on warm paper. This
script does the parts that have to be exact and repeatable rather than eyeballed:

  - Clips to a full-bleed superellipse ("squircle"), the macOS 26 / iOS icon
    shape. A plain rounded rectangle reads subtly wrong next to system icons, and
    macOS no longer wants the old free-form silhouette with baked-in margins.
  - Re-centres the artwork on its content bounding box and scales it to a fixed
    fraction of the canvas, so the optical margin matches other app icons instead
    of inheriting whatever margin the source render happened to have.
  - Downsamples every size from one master with LANCZOS, so the 16px and 32px
    slots stay consistent with the 1024 instead of drifting.

Regenerate whenever the artwork or the accent colour changes. Cinnabar #C0453B is
the app's accent colour; icon and UI share it (see Theme.inkstone).
"""

from __future__ import annotations

import json
import pathlib

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
ARTWORK = ROOT / "Tools/icon-artwork.png"
ICONSET = ROOT / "App/Resources/Assets.xcassets/AppIcon.appiconset"

BASE = 1024
SUPERSAMPLE = 4
S = BASE * SUPERSAMPLE

# Fraction of the icon width the artwork's content should span. Apple's own icons
# sit around 0.78–0.82 once the squircle is full bleed; below that the icon looks
# timid in the Dock, above it the corners get crowded.
CONTENT_SCALE = 0.80

# How far a pixel must differ from the paper background to count as content.
# High enough to ignore the render's soft contact shadow, which would otherwise
# drag the bounding box down and to the right and push the art off centre.
CONTENT_THRESHOLD = 20


def squircle_mask(size: int, exponent: float = 5.0) -> Image.Image:
    """
    Apple's icon outline is a continuous-curvature superellipse.
    |x|^n + |y|^n <= 1 with n≈5 is a close, cheap approximation.
    """
    axis = np.linspace(-1.0, 1.0, size)
    x, y = np.meshgrid(axis, axis)
    distance = np.abs(x) ** exponent + np.abs(y) ** exponent

    # Feather across roughly one final-resolution pixel so the edge stays smooth
    # after downsampling rather than aliasing.
    edge = 2.0 * SUPERSAMPLE / size
    alpha = np.clip((1.0 - distance) / edge + 0.5, 0.0, 1.0)
    return Image.fromarray((alpha * 255).astype(np.uint8), mode="L")


def background_colour(art: Image.Image) -> tuple:
    """The paper tone, taken from the corners the artwork leaves empty."""
    pixels = np.asarray(art.convert("RGB"))
    corners = np.concatenate(
        [
            pixels[:24, :24].reshape(-1, 3),
            pixels[:24, -24:].reshape(-1, 3),
            pixels[-24:, :24].reshape(-1, 3),
            pixels[-24:, -24:].reshape(-1, 3),
        ]
    )
    return tuple(int(v) for v in np.median(corners, axis=0))


def content_box(art: Image.Image, paper: tuple) -> tuple:
    """Bounding box of everything that is not paper, as a centred square."""
    pixels = np.asarray(art.convert("RGB")).astype(np.int16)
    difference = np.abs(pixels - np.array(paper, dtype=np.int16)).max(axis=2)
    rows = np.where(difference.max(axis=1) > CONTENT_THRESHOLD)[0]
    columns = np.where(difference.max(axis=0) > CONTENT_THRESHOLD)[0]
    if len(rows) == 0 or len(columns) == 0:
        return (0, 0, art.width, art.height)

    top, bottom = int(rows[0]), int(rows[-1]) + 1
    left, right = int(columns[0]), int(columns[-1]) + 1

    # Square it off around the content's centre so scaling cannot distort the art.
    side = max(bottom - top, right - left)
    centre_x = (left + right) // 2
    centre_y = (top + bottom) // 2
    half = side // 2
    return (centre_x - half, centre_y - half, centre_x + half, centre_y + half)


def render() -> Image.Image:
    art = Image.open(ARTWORK).convert("RGB")
    paper = background_colour(art)

    # Crop to content, padding with paper if the square runs past the source edge.
    box = content_box(art, paper)
    side = box[2] - box[0]
    content = Image.new("RGB", (side, side), paper)
    content.paste(art.crop(box), (max(0, -box[0]), max(0, -box[1])))

    target = int(S * CONTENT_SCALE)
    content = content.resize((target, target), Image.LANCZOS)

    canvas = Image.new("RGB", (S, S), paper)
    offset = (S - target) // 2
    canvas.paste(content, (offset, offset))

    canvas = canvas.convert("RGBA")
    canvas.putalpha(squircle_mask(S))
    return canvas.resize((BASE, BASE), Image.LANCZOS)


def write_slots(master: Image.Image) -> None:
    manifest_path = ICONSET / "Contents.json"
    manifest = json.loads(manifest_path.read_text())

    for entry in manifest.get("images", []):
        side = float(entry["size"].split("x")[0])
        scale = int(entry.get("scale", "1x").rstrip("x"))
        pixels = int(round(side * scale))
        name = f"icon-{pixels}.png"

        master.resize((pixels, pixels), Image.LANCZOS).save(ICONSET / name)
        entry["filename"] = name

    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")


def main() -> None:
    master = render()
    write_slots(master)
    print(f"wrote icon slots to {ICONSET}")


if __name__ == "__main__":
    main()
