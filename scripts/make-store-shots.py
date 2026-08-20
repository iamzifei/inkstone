#!/usr/bin/env python3
"""Compose the App Store marketing screenshots.

    scripts/make-store-shots.py

Raw device captures show what the app looks like. These sell one idea each — the
distinction the App Store screenshot guidance keeps making, and the reason a
listing of six unadorned UI captures converts badly: nobody reads a screenshot,
they read the sentence above it and then glance at the picture for proof.

Rendered through headless Chrome rather than an image library, for the same
reason the Open Graph cards are: the whole argument this app makes is
typographic, so the captions have to be set in the real Source Serif with real
mixed-script spacing, not approximated by whatever font a compositor found.

Output lands at exactly the sizes Apple requires — 1320x2868 for the 6.9" iPhone
and 2064x2752 for the 13" iPad — so nothing is ever resized or padded, which is
the usual reason a screenshot upload is rejected.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "assets" / "ios-shots"
OUT = ROOT / "assets" / "store-shots"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Straight out of the app's Theme.swift, like the site and the OG cards. One
# cinnabar, ink on paper, nothing else.
PAPER, PAPER_2, INK, INK_2, CINNABAR = "#FCFBF8", "#F4F2EC", "#1F1D1A", "#57534B", "#C0453B"

FONTS = ("https://fonts.googleapis.com/css2"
         "?family=Source+Serif+4:opsz,wght@8..60,300..700"
         "&family=Noto+Serif+SC:wght@400;600&display=swap")

# One idea per slide, strongest first — the first two are the only ones most
# people will ever swipe to.
IPHONE = [
    ("02-live-preview", "Your notes are files.<br>They stay that way.",
     "Plain Markdown in a folder you choose. No database, no import."),
    ("03-typography", "中英文混排，<br>终于排对了。",
     "The gap between Han and Latin, set the way the standard asks for."),
    ("05-graph", "Links you never<br>planned, made visible.",
     "The same vault draws the same picture every time."),
    ("04-measure", "Every note knows<br>what points at it.",
     "Backlinks, block references, and links that have no target yet."),
    ("06-search", "Find a note before<br>you finish typing.",
     "Fuzzy over every note, and search that takes tag: and path:."),
    ("01-library", "A folder of Markdown.<br>That is the whole format.",
     "Open it in any other editor, on any device, forever."),
]

IPAD = [
    ("ipad/01-live-preview", "Write on the big screen.",
     "The same vault, the same files, a wider measure."),
    ("ipad/02-typography", "中英文混排，终于排对了。",
     "Body font and code font, set independently."),
    ("ipad/03-measure", "Every note knows what points at it.",
     "Backlinks and outgoing links, always in view."),
]


def page(shot: Path, title: str, subtitle: str, w: int, h: int, pad: int,
         title_px: int, sub_px: int, radius: int) -> str:
    """One slide. The caption gets the top third; the device fills the rest."""
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="{FONTS}">
<style>
  * {{ box-sizing: border-box; margin: 0; }}
  html, body {{ width: {w}px; height: {h}px; }}
  body {{
    background: {PAPER};
    /* A cinnabar hairline across the top, the same device the site uses to
       head a section. It is the only ornament on the page. */
    border-top: {max(8, w // 110)}px solid {CINNABAR};
    font-family: "Source Serif 4", "Noto Serif SC", Georgia, serif;
    font-optical-sizing: auto;
    display: flex; flex-direction: column; align-items: center;
    padding: {pad}px {pad}px 0;
    overflow: hidden;
  }}
  h1 {{
    font-size: {title_px}px; line-height: 1.08; font-weight: 400;
    letter-spacing: -0.025em; color: {INK}; text-align: center;
    font-variation-settings: "opsz" 60;
    text-autospace: normal;
    text-wrap: balance;
  }}
  p {{
    margin-top: {int(title_px * 0.42)}px;
    font-size: {sub_px}px; line-height: 1.5; color: {INK_2};
    text-align: center; max-width: {int(w * 0.72)}px;
    text-autospace: normal;
    /* Balanced, or the second line ends up carrying one orphaned word — which
       on a listing whose second slide is about typography is not a detail. */
    text-wrap: balance;
  }}
  .device {{
    margin-top: {int(title_px * 0.75)}px;
    width: {int(w * 0.84)}px;
    border-radius: {radius}px;
    overflow: hidden;
    background: {PAPER_2};
    /* Lifted off the page rather than floated on it — a hairline plus one soft
       shadow, so the screenshot reads as an object on paper. */
    border: 1px solid rgba(31,29,26,.10);
    box-shadow: 0 2px 6px rgba(31,29,26,.06), 0 {int(w*0.03)}px {int(w*0.07)}px -{int(w*0.02)}px rgba(31,29,26,.22);
  }}
  .device img {{ display: block; width: 100%; }}
</style></head><body>
  <h1>{title}</h1>
  <p>{subtitle}</p>
  <div class="device"><img src="{shot.name}"></div>
</body></html>"""


def render(spec, w, h, pad, title_px, sub_px, radius, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    for index, (name, title, subtitle) in enumerate(spec, start=1):
        source = RAW / f"{name}.png"
        if not source.exists():
            sys.exit(f"missing raw screenshot: {source}")

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            shutil.copyfile(source, work / source.name)
            (work / "slide.html").write_text(
                page(source, title, subtitle, w, h, pad, title_px, sub_px, radius),
                encoding="utf-8")

            target = out_dir / f"{index:02d}-{Path(name).name}.png"
            subprocess.run([
                CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                f"--window-size={w},{h}", "--force-device-scale-factor=1",
                # Without a virtual-time budget the shot is taken mid-fallback
                # and ships set in Georgia, which on this listing would be
                # arguing against its own second slide.
                "--virtual-time-budget=9000",
                f"--screenshot={target}", f"file://{work / 'slide.html'}",
            ], check=True, capture_output=True)

            size = subprocess.run(
                ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(target)],
                capture_output=True, text=True).stdout.split()
            got = (int(size[size.index("pixelWidth:") + 1]),
                   int(size[size.index("pixelHeight:") + 1]))
            if got != (w, h):
                sys.exit(f"{target.name}: rendered {got}, needed {(w, h)}")
            print(f"  {target.name}  {got[0]}x{got[1]}")


def main() -> int:
    if not Path(CHROME).exists():
        sys.exit("Google Chrome not found")
    print("==> iPhone 6.9\"")
    render(IPHONE, 1320, 2868, pad=96, title_px=104, sub_px=52, radius=44,
           out_dir=OUT)
    print("==> iPad 13\"")
    render(IPAD, 2064, 2752, pad=150, title_px=132, sub_px=66, radius=40,
           out_dir=OUT / "ipad")
    print(f"\n==> {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
