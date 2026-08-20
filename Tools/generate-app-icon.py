#!/usr/bin/env python3
"""
Builds Inkstone's app icon for macOS 26 and iOS 26.

    python3 Tools/generate-app-icon.py

The mark is an inkstone seen from above — a dark disc with a crescent ink pool —
and a cinnabar seal resting on its lower right. Drawn geometrically rather than
rendered: since macOS 26 and iOS 26 unified on one rounded-rectangle silhouette
with Liquid Glass treatment applied by the system, an icon wants flat, confident
shapes that survive the system's own lighting and the tinted appearance. A
photographic render fights that and turns to mud at 16pt.

Outputs three iOS appearances plus the macOS size ladder:

  - light   — ink on warm paper
  - dark    — the same mark on a deep ground, for the dark home screen
  - tinted  — a greyscale mask; iOS recolours it with the user's chosen tint, so
              it must read through luminance alone, with no colour to lean on

Regenerate whenever the accent colour changes. Cinnabar #C0453B is the app's
accent; icon and UI share it (see Theme.inkstone).
"""

from __future__ import annotations

import json
import pathlib

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

BASE = 1024
SUPERSAMPLE = 4
S = BASE * SUPERSAMPLE

ROOT = pathlib.Path(__file__).resolve().parent.parent
ICONSET = ROOT / "App/Resources/Assets.xcassets/AppIcon.appiconset"

# Geometry in the 1024 design space.
DISC = (188, 172, 812, 796)          # the inkstone
# The ink well is the *upper third* of the stone, cut off by a single arc — the
# way a round inkstone's 墨堂 actually looks from above. An earlier draft used a
# thin crescent, which read as an eyebrow and made the whole icon a cartoon face.
POOL_CUT = (60, -300, 940, 470)      # big ellipse; its lower arc slices the disc
SEAL = (556, 556, 856, 856)
SEAL_RADIUS = 54
SEAL_RING_INSET = 78
SEAL_RING_WIDTH = 30


def px(value: float) -> float:
    return value * SUPERSAMPLE


def scaled(box: tuple) -> tuple:
    return tuple(px(v) for v in box)


def squircle_mask(size: int, exponent: float = 5.0) -> Image.Image:
    """
    Apple's icon outline is a continuous-curvature superellipse, not a rounded
    rectangle; |x|^n + |y|^n <= 1 with n≈5 is a close, cheap approximation.
    """
    axis = np.linspace(-1.0, 1.0, size)
    x, y = np.meshgrid(axis, axis)
    distance = np.abs(x) ** exponent + np.abs(y) ** exponent
    edge = 2.0 * SUPERSAMPLE / size
    alpha = np.clip((1.0 - distance) / edge + 0.5, 0.0, 1.0)
    return Image.fromarray((alpha * 255).astype(np.uint8), mode="L")


def vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    ramp = np.linspace(0.0, 1.0, size)[:, None]
    channels = [(top[i] + (bottom[i] - top[i]) * ramp).repeat(size, axis=1) for i in range(3)]
    return Image.fromarray(np.stack(channels, axis=2).astype(np.uint8), mode="RGB")


def mask_from(draw_fn) -> Image.Image:
    mask = Image.new("L", (S, S), 0)
    draw_fn(ImageDraw.Draw(mask))
    return mask


def fill(color: tuple, mask: Image.Image) -> Image.Image:
    layer = Image.new("RGBA", (S, S), color + (255,))
    layer.putalpha(mask)
    return layer


def render(palette: dict) -> Image.Image:
    canvas = vertical_gradient(S, palette["paper_top"], palette["paper_bottom"]).convert("RGBA")

    # --- The stone -------------------------------------------------------
    disc = mask_from(lambda d: d.ellipse(scaled(DISC), fill=255))

    # A soft contact shadow gives the disc weight without any 3D rendering.
    if palette["shadow"]:
        shadow = disc.filter(ImageFilter.GaussianBlur(px(16))).point(lambda v: int(v * 0.28))
        shifted = Image.new("L", (S, S), 0)
        shifted.paste(shadow, (0, int(px(14))))
        layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        layer.putalpha(shifted)
        canvas = Image.alpha_composite(canvas, layer)

    stone = vertical_gradient(S, palette["stone_top"], palette["stone_bottom"]).convert("RGBA")
    stone.putalpha(disc)
    canvas = Image.alpha_composite(canvas, stone)

    # --- Ink pool --------------------------------------------------------
    # A crescent, not a full ellipse. The crescent is what identifies an
    # inkstone; a filled ellipse reads as a screen or a camera lens.
    pool = ImageChops.multiply(
        mask_from(lambda d: d.ellipse(scaled(POOL_CUT), fill=255)),
        disc,
    )
    canvas = Image.alpha_composite(canvas, fill(palette["ink"], pool))

    # --- Cinnabar seal ---------------------------------------------------
    seal_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    seal_draw = ImageDraw.Draw(seal_layer)
    seal_draw.rounded_rectangle(scaled(SEAL), radius=px(SEAL_RADIUS), fill=palette["seal"] + (255,))

    # A carved square ring: legible at 32pt where a real character would blur,
    # and free of the garbled pseudo-Chinese a generated glyph would produce.
    ring = (
        SEAL[0] + SEAL_RING_INSET, SEAL[1] + SEAL_RING_INSET,
        SEAL[2] - SEAL_RING_INSET, SEAL[3] - SEAL_RING_INSET,
    )
    seal_draw.rounded_rectangle(
        scaled(ring), radius=px(14), outline=palette["seal_mark"] + (255,), width=int(px(SEAL_RING_WIDTH))
    )

    if palette["shadow"]:
        seal_shadow = seal_layer.getchannel("A").filter(ImageFilter.GaussianBlur(px(10)))
        seal_shadow = seal_shadow.point(lambda v: int(v * 0.32))
        shifted = Image.new("L", (S, S), 0)
        shifted.paste(seal_shadow, (0, int(px(10))))
        layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        layer.putalpha(shifted)
        canvas = Image.alpha_composite(canvas, layer)

    canvas = Image.alpha_composite(canvas, seal_layer)

    canvas.putalpha(
        Image.composite(canvas.getchannel("A"), Image.new("L", (S, S), 0), squircle_mask(S))
    )
    return canvas.resize((BASE, BASE), Image.LANCZOS)


PALETTES = {
    "light": {
        "paper_top": (250, 246, 236), "paper_bottom": (236, 228, 212),
        "stone_top": (74, 68, 82), "stone_bottom": (38, 34, 46),
        "ink": (13, 11, 17), "seal": (192, 69, 59), "seal_mark": (250, 246, 236),
        "shadow": True,
    },
    "dark": {
        # Deeper ground, lighter stone: on a dark home screen the mark has to
        # separate from the background rather than disappear into it.
        #
        # Measured, not judged by eye. The first attempt at this palette gave the
        # stone a 1.65:1 contrast against its ground — on the home screen the
        # disc simply dissolved, and only a red seal floating in a dark square
        # remained. 4.7:1 at the top of the gradient, 2.6:1 at the bottom where
        # the ink pool takes over anyway.
        "paper_top": (22, 21, 26), "paper_bottom": (12, 11, 15),
        "stone_top": (134, 126, 148), "stone_bottom": (88, 82, 100),
        # The ink pool is the one part that cannot simply be "darker" here. At
        # (16,15,20) it matched the ground to within 1.05:1, so the pool merged
        # with the background and the stone read as a crescent rather than a
        # disc — a different shape from the light icon, not a darker version of
        # it. Lifted until it separates from the ground (1.5:1) while staying
        # clearly darker than the stone (1.7:1).
        "ink": (52, 48, 60), "seal": (224, 104, 92), "seal_mark": (26, 24, 30),
        "shadow": False,
    },
    "tinted": {
        # Greyscale only. iOS recolours this with the user's tint, so every
        # distinction has to survive in luminance alone — a colour that carries a
        # difference here carries nothing once the system flattens it.
        #
        # The seal was the weak point at 1.8:1 against the stone, which put the
        # one piece of the mark that says "seal" on the edge of invisibility.
        # Now 3.5:1.
        "paper_top": (236, 236, 236), "paper_bottom": (236, 236, 236),
        "stone_top": (105, 105, 105), "stone_bottom": (105, 105, 105),
        "ink": (44, 44, 44), "seal": (205, 205, 205), "seal_mark": (72, 72, 72),
        "shadow": False,
    },
}


def manifest() -> dict:
    """
    Both platforms, explicitly.

    macOS keeps its size ladder. iOS takes a single 1024 per appearance and the
    system derives the rest — and it needs all three appearances, or the home
    screen falls back to the light artwork in dark and tinted modes.
    """
    images: list[dict] = [
        {"idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-ios-light.png"},
        {
            "idiom": "universal", "platform": "ios", "size": "1024x1024",
            "filename": "icon-ios-dark.png",
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
        },
        {
            "idiom": "universal", "platform": "ios", "size": "1024x1024",
            "filename": "icon-ios-tinted.png",
            "appearances": [{"appearance": "luminosity", "value": "tinted"}],
        },
    ]
    for side in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            images.append({
                "idiom": "mac", "size": f"{side}x{side}", "scale": f"{scale}x",
                "filename": f"icon-{side * scale}.png",
            })
    return {"images": images, "info": {"author": "xcode", "version": 1}}


def main() -> None:
    masters = {name: render(palette) for name, palette in PALETTES.items()}

    for name, image in masters.items():
        if name == "light":
            # The iOS marketing icon must be fully opaque. App Store upload
            # rejects it otherwise, with error 90717 — "the large app icon ...
            # can't be transparent or contain an alpha channel" — and the
            # rejection arrives minutes after the upload, not during the build.
            #
            # Flattening onto the artwork's own top-of-gradient paper rather
            # than onto white, so the rounded corners blend into the icon's
            # background instead of showing a bright halo. iOS masks the corners
            # itself, so nothing is lost by filling them.
            backdrop = Image.new("RGB", image.size, PALETTES["light"]["paper_top"])
            backdrop.paste(image, mask=image.split()[-1])
            backdrop.save(ICONSET / "icon-ios-light.png")
        else:
            # Dark and tinted keep their alpha on purpose: the system composites
            # those over its own background, so a flattened one would show a
            # rectangle of the wrong colour behind the artwork.
            image.save(ICONSET / f"icon-ios-{name}.png")

    # macOS uses the light artwork; the system handles its own dark treatment.
    light = masters["light"]
    for side in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = side * scale
            light.resize((pixels, pixels), Image.LANCZOS).save(ICONSET / f"icon-{pixels}.png")

    (ICONSET / "Contents.json").write_text(json.dumps(manifest(), indent=2) + "\n")
    print(f"wrote icon slots to {ICONSET}")


if __name__ == "__main__":
    main()
