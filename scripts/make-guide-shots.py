#!/usr/bin/env python3
"""Crops the raw guide renders into the asset catalog, one image set per language.

    scripts/make-guide-shots.sh          # does the whole thing, including the render

The raw PNGs come from App/Support/GuideShots.swift (real views drawn offscreen,
no screen capture). This only crops and compresses them: 16:10, 1120 x 700, JPEG.
Image sets are named Guide<Page>-<language>, e.g. GuideGraph-zh-Hant, which is
what OnboardingView asks for.

    python3 scripts/make-guide-shots.py <raw dir>
"""
import os, sys
from PIL import Image

RAW = sys.argv[1]
CATALOG = os.path.join(os.path.dirname(__file__), "..", "App", "Resources", "Assets.xcassets")
LANGS = ["en", "zh-Hans", "zh-Hant"]
# Boxes in the website screenshots' 1280-wide space (the same window, 1800pt wide,
# scaled by 1280/1800); every box is 16:10 except the graph, which is padded.
K = 3600 / 1280
PAGES = [
    # name,    raw file, box (x0, y0, x1, y1), pad to 16:10?
    ("Folder",   "note",     (0, 0, 640, 400), False),
    ("Links",    "note",     (330, 0, 1280, 593.75), False),
    ("Switcher", "switcher", (240, 150, 1040, 650), False),
    ("Graph",    "graph",    (185, 20, 1066, 804), True),
    ("Canvas",   "canvas",   (220, 160, 1020, 660), False),
]

def save(img, name):
    folder = os.path.join(CATALOG, f"{name}.imageset")
    os.makedirs(folder, exist_ok=True)
    for old in os.listdir(folder):
        os.remove(os.path.join(folder, old))
    img = img.convert("RGB").resize((1120, 700), Image.LANCZOS)
    img.save(os.path.join(folder, f"{name}.jpg"), quality=80, optimize=True)
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        f.write('{\n  "images" : [\n    {\n      "filename" : "%s.jpg",\n      "idiom" : "universal",\n'
                '      "scale" : "2x"\n    }\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n' % name)
    return os.path.getsize(os.path.join(folder, f"{name}.jpg"))

total = 0
for lang in LANGS:
    for page, raw, box, pad in PAGES:
        im = Image.open(os.path.join(RAW, f"{lang}-{raw}.png")).convert("RGB")
        crop = im.crop(tuple(int(v * K) for v in box))
        if pad:
            background = crop.getpixel((crop.width // 2, 4))
            width = int(crop.height * 1.6)
            canvas = Image.new("RGB", (width, crop.height), background)
            canvas.paste(crop, ((width - crop.width) // 2, 0))
            crop = canvas
        total += save(crop, f"Guide{page}-{lang}")
    # Settings: the tab strip is dropped (a TabView drawn outside a window loses its
    # icons), so this is the pane's content from just under it.
    sync = Image.open(os.path.join(RAW, f"{lang}-sync.png")).convert("RGB")
    total += save(sync.crop((6, 56, 1114, 748)), f"GuideSync-{lang}")
print(f"{len(LANGS) * (len(PAGES) + 1)} images, {total // 1024} KB")
