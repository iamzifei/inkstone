#!/usr/bin/env python3
"""The site's iPhone Duo film, in Apple's official iPhone Duo bezels, in the
posture each take shows:

    folded     Outer Closed Portrait           (PNG bezel)
    unfolded   Inner Open Landscape            (PNG bezel)
    book       Inner Partially Open Landscape  (Photoshop template)
    upright    Inner Partially Open Portrait   (Photoshop template)

    scripts/duo_bezel.py extract /Volumes/Bezel-iPhone-Duo   # once
    scripts/frame-duo-demo.py

The bezels come from Apple Design Resources and are not in this repository
(see duo_bezel.py). Nothing in them is redrawn: for the PNG bezels the
recording is laid *under* the bezel, so the screen's rounded corners are
Apple's own anti-aliased edge; the half-open templates are rendered exactly
as Photoshop would (duo_bezel.py, checked against Photoshop's composite).

Each frame is rendered at twice the film's size and scaled down once at the
end (Lanczos), so no edge is ever cut at the final resolution.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, str(Path(__file__).resolve().parent))
from duo_bezel import BEZEL, PartialTemplate  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
IN = ROOT / "assets" / "footage-duo"
OUT = ROOT / "site" / "assets" / "video"
W, H, FPS, XFADE = 1600, 1000, 30, 0.5
RW, RH = W * 2, H * 2                  # render size
FIT = 0.94                             # device's share of the frame
PAPER = np.array([241, 239, 232], np.float32) / 255.0

#        take          start  hold  posture
SEGS = [("01-folded",   0.0, 1.5, "folded"),
        ("02-unfolded", 1.8, 2.5, "unfolded"),
        ("03-book",     0.0, 2.0, "book"),
        ("04-upright",  1.4, 2.5, "upright")]


def frames(name: str, start: float, hold: float):
    """The take's frames as float RGB: rotation applied, constant rate,
    trimmed, held on the last frame."""
    src = IN / f"{name}.mov"
    s = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                   "stream=width,height:stream_side_data=rotation", "-of", "json", str(src)],
                                  capture_output=True, text=True, check=True).stdout)["streams"][0]
    w, h = s["width"], s["height"]
    rot = next((abs(int(d["rotation"])) for d in s.get("side_data_list", []) if "rotation" in d), 0)
    if rot in (90, 270):
        w, h = h, w
    proc = subprocess.Popen(["ffmpeg", "-v", "error", "-i", str(src), "-vf",
                             f"fps={FPS},trim=start={start},setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration={hold}",
                             "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    size = w * h * 3
    while True:
        buf = proc.stdout.read(size)
        if len(buf) < size:
            break
        yield np.frombuffer(buf, np.uint8).reshape(h, w, 3).astype(np.float32) / 255.0
    proc.wait()


class FlatBezel:
    """A PNG bezel with a transparent screen; the frame goes under it."""

    def __init__(self, png: str):
        img = np.asarray(Image.open(BEZEL / png).convert("RGBA"), np.float32) / 255.0
        alpha = img[..., 3]
        # The screen: the transparent region holding the image centre (the
        # device's outside is transparent too, but not connected to it).
        labels, _ = ndimage.label(alpha < 0.5)
        centre = labels[alpha.shape[0] // 2, alpha.shape[1] // 2]
        if centre == 0:
            sys.exit(f"{png}: the image centre is not on the transparent screen")
        ys, xs = np.nonzero(labels == centre)
        self.hole = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)
        # The device's own outline: solid inside, Apple's anti-aliased alpha
        # along its outer edge. Everything under the bezel is clipped to it —
        # the screen's rectangle is wider at the corners than the device's
        # rounder outer corners, and poked out past them.
        # Only the solid interior (a few pixels in from the outer edge, where
        # the bezel itself is opaque): the outer anti-aliased edge stays
        # exactly Apple's pixels.
        core = ndimage.binary_erosion(ndimage.binary_fill_holes(alpha > 0.5), iterations=4)
        self.silhouette = core.astype(np.float32)
        dys, dxs = np.nonzero(alpha > 0.02)
        self.device = (dxs.min(), dys.min(), dxs.max() + 1, dys.max() + 1)
        self.rgba = img

    def render(self, frame: np.ndarray) -> np.ndarray:
        x0, y0, x1, y1 = self.hole
        # The bezel's inner edge is anti-aliased (half-transparent pixels):
        # the screen runs a pixel under it all round so no paper shows there.
        x0, y0, x1, y1 = x0 - 1, y0 - 1, x1 + 1, y1 + 1
        screen = np.asarray(Image.fromarray((frame * 255 + 0.5).astype(np.uint8)).resize((x1 - x0, y1 - y0), Image.LANCZOS),
                            np.float32) / 255.0
        h, w = self.rgba.shape[:2]
        rgb = np.zeros((h, w, 3), np.float32)
        # Black under the whole device first — the panel's border beneath the
        # glass. Parts of the bezel's inner rim are semi-transparent; without
        # this the background showed through them as a thin light line.
        a = self.silhouette.copy()
        rgb[y0:y1, x0:x1] = screen
        a[y0:y1, x0:x1] = 1.0
        a = np.minimum(a, self.silhouette)
        ba = self.rgba[..., 3:4]
        out_a = self.rgba[..., 3] + a * (1 - self.rgba[..., 3])
        with np.errstate(divide="ignore", invalid="ignore"):
            out_rgb = np.nan_to_num((self.rgba[..., :3] * ba + rgb * a[..., None] * (1 - ba)) / out_a[..., None])
        return np.dstack([out_rgb, out_a])


def place(rgba: np.ndarray, box) -> np.ndarray:
    """Crops to the device, fits it into the render frame on paper."""
    x0, y0, x1, y1 = box
    crop = rgba[y0:y1, x0:x1]
    ch, cw = crop.shape[:2]
    k = min(RW * FIT / cw, RH * FIT / ch)
    tw, th = round(cw * k), round(ch * k)
    small = np.asarray(Image.fromarray((np.clip(crop, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")
                       .resize((tw, th), Image.LANCZOS), np.float32) / 255.0
    out = np.tile(PAPER, (RH, RW, 1))
    ox, oy = (RW - tw) // 2, (RH - th) // 2
    a = small[..., 3:4]
    out[oy:oy + th, ox:ox + tw] = small[..., :3] * a + out[oy:oy + th, ox:ox + tw] * (1 - a)
    return out


def encode(name: str, rendered, work: Path) -> Path:
    out = work / f"{name}.mp4"
    proc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                             "-s", f"{RW}x{RH}", "-r", str(FPS), "-i", "-",
                             "-vf", f"scale={W}:{H}:flags=lanczos,format=yuv420p",
                             "-c:v", "libx264", "-crf", "12", "-preset", "veryfast", str(out)], stdin=subprocess.PIPE)
    n = 0
    for frame in rendered:
        proc.stdin.write((np.clip(frame, 0, 1) * 255 + 0.5).astype(np.uint8).tobytes())
        n += 1
    proc.stdin.close()
    proc.wait()
    print(f"    {n} frames", flush=True)
    return out


def duration(path) -> float:
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                 str(path)], capture_output=True, text=True).stdout.strip())


def to_content(frame: np.ndarray, posture: str) -> np.ndarray:
    """The upright template's smart object is landscape, placed a quarter
    turn: its x runs up the screen's left edge and its y along the top."""
    if posture == "upright":
        return np.ascontiguousarray(np.transpose(frame[::-1], (1, 0, 2)))
    return frame


def main() -> int:
    if not (BEZEL / "partial-Landscape" / "template.json").exists():
        sys.exit(f"No bezels in {BEZEL}: run scripts/duo_bezel.py extract <mounted Bezel-iPhone-Duo volume>")
    only = sys.argv[1] if len(sys.argv) > 1 else None    # e.g. "check": first frame of each take only
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        clips = []
        for name, start, hold, posture in SEGS:
            print(f"==> {name} ({posture})", flush=True)
            if posture in ("folded", "unfolded"):
                bezel = FlatBezel("Outer Closed Portrait.png" if posture == "folded" else "Inner Open Landscape.png")
                render, box = bezel.render, bezel.device
            else:
                which = "Landscape" if posture == "book" else "Portrait"
                full_w, full_h = json.loads((BEZEL / f"partial-{which}" / "template.json").read_text())["size"]
                # Rendered at the scale the 2x frame needs (the device is
                # most of the template), not at the template's full size.
                t = PartialTemplate(which, min(1.0, 1.1 * min(RW * FIT / full_w, RH * FIT / full_h)))
                ys, xs = np.nonzero(t.load("Hardware.png", "RGBA")[..., 3] > 0.02)
                box = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)
                render = (lambda f, t=t, p=posture: t.render(to_content(f, p)))
            if only == "check":
                f = next(iter(frames(name, start + 1.0, 0)))
                img = place(render(f), box)
                Image.fromarray((img * 255 + 0.5).astype(np.uint8)).save(IN / f"check-2x-{name}.png")
                continue
            clips.append(encode(name, (place(render(f), box) for f in frames(name, start, hold)), work))
        if only == "check":
            return 0

        inputs, graph, label, acc = [], "", "0:v", duration(clips[0])
        for c in clips:
            inputs += ["-i", str(c)]
        for i in range(1, len(clips)):
            graph += f"[{label}][{i}:v]xfade=transition=fade:duration={XFADE}:offset={max(0.0, acc - XFADE):.3f}[v{i}];"
            label = f"v{i}"
            acc = acc - XFADE + duration(clips[i])
        joined = work / "joined.mp4"
        run = lambda *a: subprocess.run(["ffmpeg", "-v", "error", "-y", *a], check=True)
        run(*inputs, "-filter_complex", graph.rstrip(";"), "-map", f"[{label}]", "-an",
            "-c:v", "libx264", "-crf", "12", "-preset", "veryfast", str(joined))
        run("-i", str(joined), "-an", "-c:v", "libx264", "-profile:v", "high", "-crf", "24", "-preset", "slow",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(OUT / "duo.mp4"))
        run("-i", str(joined), "-an", "-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p", "-crf", "40", "-b:v", "0", "-row-mt", "1",
            "-deadline", "good", "-cpu-used", "2", str(OUT / "duo.webm"))
        poster = work / "poster.png"
        run("-ss", "1.0", "-i", str(joined), "-vframes", "1", str(poster))
        subprocess.run(["cwebp", "-quiet", "-q", "85", str(poster), "-o", str(OUT / "duo-poster.webp")], check=True)
        t0 = 0.0
        for i, c in enumerate(clips):
            run("-ss", f"{t0 + duration(c) / 2:.2f}", "-i", str(OUT / "duo.mp4"), "-vframes", "1",
                str(IN / f"framed-check-{i + 1}.png"))
            t0 += duration(c) - XFADE
        print(f"duration {duration(OUT / 'duo.mp4'):.1f}s; check frames {IN}/framed-check-*.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
