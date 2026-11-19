#!/usr/bin/env python3
"""The website's knowledge-base pictures, from the raw captures.

    scripts/make-site-kb-shots.py

Inputs (not in git — large, and the bezel is Apple's, used as shipped):
  assets/site-shots/<lang>/iphone/*.png   iPhone 18 Pro simulator, 1206x2622
                                          (scripts/capture-kb-shots.sh)
  assets/site-shots/<lang>/mac/*.png      real macOS window captures with
                                          their shadow (scripts/capture-mac-kb-shots.sh)
  assets/footage-iphone18/bezel/png/      Apple's iPhone 18 Pro product bezel

Each iPhone capture goes under Apple's bezel at the screen opening (measured
from the bezel's alpha: 1206x2622 at 72,69 — the capture's own size, so no
scaling), clipped to the device's silhouette so its square corners never show
outside the body. The bezel is drawn as Apple ships it: never redrawn, recoloured
or stretched. Mac captures are used as the system drew them.

Output: site/assets/kb/<lang>/<name>.webp plus width variants, and
site/assets/kb/manifest.txt (path, width, height, variant widths) for build.py.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageChops
from scipy import ndimage

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "assets" / "site-shots"
BEZEL = ROOT / "assets" / "footage-iphone18" / "bezel" / "png" / "iPhone 18 Pro - Black - Portrait.png"
OUT = ROOT / "site" / "assets" / "kb"
SCREEN = (72, 69, 1206, 2622)          # x, y, width, height of the opening
LANGS = ["en", "zh-Hans", "zh-Hant"]
IPHONE = ["k1-plan", "k2-organized", "k3-agents", "k4-drop", "k6-welcome"]
MAC = ["k1-plan", "k2-organized", "k3-agents", "k5-settings", "k6-welcome"]
IPHONE_WIDTHS = [340, 680]             # rendered ≤ 340 CSS px wide, at 1x and 2x
MAC_WIDTHS = [900, 1800]


def silhouette(bezel: Image.Image) -> Image.Image:
    """The device's outline: everything not connected to the image's edges."""
    alpha = np.array(bezel.split()[-1])
    labels, _ = ndimage.label(alpha < 8)
    edge = set(labels[0, :]) | set(labels[-1, :]) | set(labels[:, 0]) | set(labels[:, -1])
    edge.discard(0)
    outside = np.isin(labels, list(edge))
    return Image.fromarray(((~outside) * 255).astype("uint8"))


def framed(shot_path: Path, bezel: Image.Image, mask: Image.Image) -> Image.Image:
    shot = Image.open(shot_path).convert("RGBA")
    x, y, w, h = SCREEN
    if shot.size != (w, h):
        raise SystemExit(f"{shot_path}: {shot.size}, expected {(w, h)} (an iPhone 18 Pro capture)")
    layer = Image.new("RGBA", bezel.size, (0, 0, 0, 0))
    layer.paste(shot, (x, y))
    layer.putalpha(ImageChops.multiply(layer.split()[-1], mask))
    layer.alpha_composite(bezel)
    return layer


def save(img: Image.Image, dest: Path, widths: list[int], manifest: list[str]) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    variants = []
    for w in widths:
        if w >= img.width:
            continue
        h = round(img.height * w / img.width)
        img.resize((w, h), Image.LANCZOS).save(dest.with_name(f"{dest.stem}-{w}.webp"), quality=86, method=6)
        variants.append(w)
    img.save(dest, quality=86, method=6)
    rel = dest.relative_to(OUT).as_posix()
    manifest.append(" ".join([rel, str(img.width), str(img.height)] + [str(v) for v in variants]))
    print(f"  {rel}  {img.width}x{img.height}  {variants}")


def main() -> None:
    bezel = Image.open(BEZEL).convert("RGBA")
    mask = silhouette(bezel)
    manifest: list[str] = []
    for lang in LANGS:
        for name in IPHONE:
            src = RAW / lang / "iphone" / f"{name}.png"
            save(framed(src, bezel, mask), OUT / lang / f"iphone-{name}.webp", IPHONE_WIDTHS, manifest)
        for name in MAC:
            src = RAW / lang / "mac" / f"{name}.png"
            save(Image.open(src).convert("RGBA"), OUT / lang / f"mac-{name}.webp", MAC_WIDTHS, manifest)
    (OUT / "manifest.txt").write_text("\n".join(manifest) + "\n", encoding="utf-8")
    print(f"==> {len(manifest)} pictures in {OUT}")


if __name__ == "__main__":
    main()
