#!/usr/bin/env python3
"""The site's iPhone Duo film, with the device drawn around the screen in the
posture each take shows — folded, unfolded, half-open as a book, half-open
upright — so the hinge in the picture is where the hinge in the recording is.

    scripts/frame-duo-demo.py

Reads the raw takes from assets/footage-duo (record-duo-demo.sh) and writes
site/assets/video/duo.mp4 / duo.webm / duo-poster.webp, replacing what
encode-duo-demo.sh makes. The device frame is drawn here (PIL), not a
photograph or Apple's device art; the screen in it is the unedited recording,
fitted flat or warped onto the two halves for the half-open postures.

Per take: the recording is normalised (rotation applied, variable frame rate
made constant, trimmed, held on its last frame), then the screen — or each
half of it — is scaled, perspective-warped onto its place, masked to the
screen's shape and laid over the drawn body. The takes are joined with the
same dissolves as before.
"""
from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
IN = ROOT / "assets" / "footage-duo"
OUT = ROOT / "site" / "assets" / "video"
W, H, FPS, XFADE = 1600, 1000, 30, 0.5
PAPER = (241, 239, 232)
SS = 3  # supersampling for the drawn body

BODY = (40, 40, 44)        # graphite
RIM = (120, 120, 128)      # the polished edge, catching light
GLASS = (12, 12, 14)       # black glass around the panel


def poly_image(size, layers):
    """Draws [(polygon, fill, blur)] supersampled, returns RGBA at size."""
    w, h = size
    img = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    for points, fill, blur in layers:
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).polygon([(x * SS, y * SS) for x, y in points], fill=fill)
        if blur:
            layer = layer.filter(ImageFilter.GaussianBlur(blur * SS))
        img = Image.alpha_composite(img, layer)
    return img.resize(size, Image.LANCZOS)


def rounded(size, box, radius, fill, blur=0):
    w, h = size
    img = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle([c * SS for c in box], radius * SS, fill=fill)
    if blur:
        img = img.filter(ImageFilter.GaussianBlur(blur * SS))
    return img.resize(size, Image.LANCZOS)


def flat_device(screen_w, screen_h, *, hinge_side=None, crease=None):
    """A device lying face-on: body, rim, glass, and the screen's box and mask."""
    x0, y0 = (W - screen_w) // 2, (H - screen_h) // 2
    screen = (x0, y0, x0 + screen_w, y0 + screen_h)
    bezel, radius = 16, 64
    body = (screen[0] - bezel, screen[1] - bezel, screen[2] + bezel, screen[3] + bezel)
    img = Image.new("RGBA", (W, H), PAPER + (255,))
    shadow = rounded((W, H), (body[0] + 6, body[1] + 22, body[2] - 6, body[3] + 26), radius, (0, 0, 0, 90), blur=22)
    img = Image.alpha_composite(img, shadow)
    img = Image.alpha_composite(img, rounded((W, H), body, radius, RIM + (255,)))
    img = Image.alpha_composite(img, rounded((W, H), (body[0] + 3, body[1] + 3, body[2] - 3, body[3] - 3), radius - 3, BODY + (255,)))
    img = Image.alpha_composite(img, rounded((W, H), (screen[0] - 6, screen[1] - 6, screen[2] + 6, screen[3] + 6), radius - 12, GLASS + (255,)))
    if hinge_side == "left":
        # The fold, seen edge-on: a slightly raised, lit cylinder along one side.
        img = Image.alpha_composite(img, rounded((W, H), (body[0] - 7, body[1] + 30, body[0] + 9, body[3] - 30), 8, (150, 150, 158, 255)))
        img = Image.alpha_composite(img, rounded((W, H), (body[0] - 3, body[1] + 34, body[0] + 3, body[3] - 34), 3, (205, 205, 212, 255)))
    # Side buttons.
    img = Image.alpha_composite(img, rounded((W, H), (body[2] - 1, body[1] + 150, body[2] + 5, body[1] + 230), 3, RIM + (255,)))
    mask = rounded((W, H), screen, radius - 18, (255, 255, 255, 255))
    overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    if crease == "vertical":
        cx = (screen[0] + screen[2]) / 2
        for dx, a in ((-2, 22), (0, 40), (2, 22)):
            draw.line([(cx + dx, screen[1]), (cx + dx, screen[3])], fill=(0, 0, 0, a), width=1)
    # No drawn camera: the simulator's recording already shows the display's own.
    return img, mask, overlay, screen


def warped_device(halves):
    """A half-open device: each half is (quad, src_crop) — quad = the four
    corners on the canvas (top-left, top-right, bottom-left, bottom-right)."""
    layers = []
    for quad, _ in halves:
        tl, tr, bl, br = quad
        outer = [tl, tr, br, bl]
        # Shadow, rim, body, glass: the same quad grown and shrunk a little.
        def grow(points, d):
            cx = sum(p[0] for p in points) / 4
            cy = sum(p[1] for p in points) / 4
            return [(cx + (x - cx) * (1 + d), cy + (y - cy) * (1 + d)) for x, y in points]
        layers.append(([(x + 8, y + 26) for x, y in grow(outer, 0.03)], (0, 0, 0, 80), 20))
        layers.append((grow(outer, 0.035), RIM + (255,), 0))
        layers.append((grow(outer, 0.03), BODY + (255,), 0))
        layers.append((grow(outer, 0.012), GLASS + (255,), 0))
    body = poly_image((W, H), layers)
    img = Image.alpha_composite(Image.new("RGBA", (W, H), PAPER + (255,)), body)
    masks = [poly_image((W, H), [([q[0], q[1], q[3], q[2]], (255, 255, 255, 255), 0)]) for q, _ in halves]
    return img, masks


def run(cmd):
    subprocess.run(cmd, check=True)


def normalise(name, start, hold, work):
    """Rotation applied, constant frame rate, trimmed, held on its last frame."""
    out = work / f"{name}-norm.mov"
    run(["ffmpeg", "-v", "error", "-y", "-i", str(IN / f"{name}.mov"),
         "-vf", f"fps={FPS},trim=start={start},setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration={hold}",
         "-an", "-c:v", "libx264", "-crf", "12", "-preset", "veryfast", "-pix_fmt", "yuv420p", str(out)])
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                            "stream=width,height", "-of", "csv=p=0", str(out)], capture_output=True, text=True)
    w, h = (int(v) for v in probe.stdout.strip().split(","))
    return out, w, h


def compose_flat(src, sw, sh, frame_kind, out, work):
    if frame_kind == "folded":
        screen_h = 880
        screen_w = round(screen_h * sw / sh)
        img, mask, overlay, screen = flat_device(screen_w, screen_h, hinge_side="left")
    else:  # unfolded
        screen_h = 780
        screen_w = round(screen_h * sw / sh)
        img, mask, overlay, screen = flat_device(screen_w, screen_h, crease="vertical")
    bg, m, ov = work / f"{out.stem}-bg.png", work / f"{out.stem}-mask.png", work / f"{out.stem}-ov.png"
    img.save(bg); mask.save(m); overlay.save(ov)
    x0, y0, x1, y1 = screen
    # Still images loop forever; bound each by the clip, or the graph never ends.
    t = f"{duration(src):.3f}"
    run(["ffmpeg", "-v", "error", "-y", "-loop", "1", "-t", t, "-i", str(bg), "-i", str(src),
         "-loop", "1", "-t", t, "-i", str(m), "-loop", "1", "-t", t, "-i", str(ov), "-filter_complex",
         f"[1:v]scale={x1 - x0}:{y1 - y0}:flags=lanczos,pad={W}:{H}:{x0}:{y0},format=rgba[s];"
         f"[2:v]format=gray[mk];[s][mk]alphamerge[sm];"
         f"[0:v][sm]overlay=shortest=1[a];[a][3:v]overlay=shortest=1,format=yuv420p",
         "-r", str(FPS), "-c:v", "libx264", "-crf", "14", "-preset", "veryfast", str(out)])


def compose_warped(src, sw, sh, halves, out, work):
    """halves: [(quad, (crop_x, crop_y, crop_w, crop_h))] in source pixels."""
    img, masks = warped_device(halves)
    bg = work / f"{out.stem}-bg.png"
    img.save(bg)
    t = f"{duration(src):.3f}"
    inputs = ["-loop", "1", "-t", t, "-i", str(bg), "-i", str(src)]
    graph = "[1:v]split=%d%s;" % (len(halves), "".join(f"[h{i}]" for i in range(len(halves))))
    for i, (m, (quad, (cx, cy, cw, ch))) in enumerate(zip(masks, halves)):
        mp = work / f"{out.stem}-mask{i}.png"
        m.save(mp)
        inputs += ["-loop", "1", "-t", t, "-i", str(mp)]
        (x0, y0), (x1, y1), (x2, y2), (x3, y3) = quad
        graph += (f"[h{i}]crop={cw}:{ch}:{cx}:{cy},scale={W}:{H}:flags=lanczos,"
                  f"perspective=x0={x0}:y0={y0}:x1={x1}:y1={y1}:x2={x2}:y2={y2}:x3={x3}:y3={y3}:sense=destination,"
                  f"format=rgba[w{i}];[{2 + i}:v]format=gray[m{i}];[w{i}][m{i}]alphamerge[s{i}];")
    last = "0:v"
    for i in range(len(halves)):
        graph += f"[{last}][s{i}]overlay=shortest=1[o{i}];"
        last = f"o{i}"
    graph = graph + f"[{last}]format=yuv420p[v]"
    run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", graph, "-map", "[v]",
         "-r", str(FPS), "-c:v", "libx264", "-crf", "14", "-preset", "veryfast", str(out)])


def book_halves(sw, sh):
    """Half-open like a book, opened towards the viewer: the spine recedes,
    the outer edges come forward (taller)."""
    spine_x, spine_top, spine_bottom = W / 2, 175, 825
    edge_top, edge_bottom, reach = 95, 905, 520
    left = ((spine_x - reach, edge_top), (spine_x, spine_top), (spine_x - reach, edge_bottom), (spine_x, spine_bottom))
    right = ((spine_x, spine_top), (spine_x + reach, edge_top), (spine_x, spine_bottom), (spine_x + reach, edge_bottom))
    return [(left, (0, 0, sw // 2, sh)), (right, (sw // 2, 0, sw - sw // 2, sh))]


def upright_halves(sw, sh):
    """Half-open upright, like a small laptop: the top half leans back (its
    far edge narrower), the bottom half lies towards the viewer."""
    hinge_y, hinge_half = 545, 330
    top = ((W / 2 - 290, 85), (W / 2 + 290, 85), (W / 2 - hinge_half, hinge_y), (W / 2 + hinge_half, hinge_y))
    bottom = ((W / 2 - hinge_half, hinge_y), (W / 2 + hinge_half, hinge_y), (W / 2 - 400, 915), (W / 2 + 400, 915))
    return [(top, (0, 0, sw, sh // 2)), (bottom, (0, sh // 2, sw, sh - sh // 2))]


#        take          start  hold  posture
SEGS = [("01-folded",   0.0, 1.5, "folded"),
        ("02-unfolded", 1.8, 2.5, "unfolded"),
        ("03-book",     0.0, 2.0, "book"),
        ("04-upright",  1.4, 2.5, "upright")]


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                         capture_output=True, text=True).stdout
    return float(out.strip())


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        clips = []
        for name, start, hold, posture in SEGS:
            print(f"==> {name} ({posture})")
            src, sw, sh = normalise(name, start, hold, work)
            out = work / f"{name}-framed.mp4"
            if posture in ("folded", "unfolded"):
                compose_flat(src, sw, sh, posture, out, work)
            elif posture == "book":
                compose_warped(src, sw, sh, book_halves(sw, sh), out, work)
            else:
                compose_warped(src, sw, sh, upright_halves(sw, sh), out, work)
            clips.append(out)
        # Join with dissolves.
        inputs, graph, label, acc = [], "", "0:v", duration(clips[0])
        for c in clips:
            inputs += ["-i", str(c)]
        for i in range(1, len(clips)):
            offset = max(0.0, acc - XFADE)
            graph += f"[{label}][{i}:v]xfade=transition=fade:duration={XFADE}:offset={offset:.3f}[v{i}];"
            label = f"v{i}"
            acc = acc - XFADE + duration(clips[i])
        joined = work / "joined.mp4"
        run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", graph.rstrip(";"), "-map", f"[{label}]",
             "-an", "-c:v", "libx264", "-crf", "14", "-preset", "veryfast", str(joined)])
        run(["ffmpeg", "-v", "error", "-y", "-i", str(joined), "-an", "-c:v", "libx264", "-profile:v", "high",
             "-crf", "26", "-preset", "slow", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(OUT / "duo.mp4")])
        run(["ffmpeg", "-v", "error", "-y", "-i", str(joined), "-an", "-c:v", "libvpx-vp9", "-crf", "42", "-b:v", "0",
             "-row-mt", "1", "-deadline", "good", "-cpu-used", "2", str(OUT / "duo.webm")])
        poster = work / "poster.png"
        run(["ffmpeg", "-v", "error", "-y", "-ss", "1.0", "-i", str(joined), "-vframes", "1", str(poster)])
        run(["cwebp", "-quiet", "-q", "82", str(poster), "-o", str(OUT / "duo-poster.webp")])
        # Contact frames for checking: middle of each take.
        t, sheet = 0.0, []
        for c in clips:
            mid = t + duration(c) / 2
            frame = Path(tmp) / f"check-{len(sheet)}.png"
            run(["ffmpeg", "-v", "error", "-y", "-ss", f"{mid:.2f}", "-i", str(OUT / "duo.mp4"), "-vframes", "1", str(frame)])
            sheet.append(Image.open(frame).copy())
            t += duration(c) - XFADE
        check = Image.new("RGB", (W, H), "white")
        for i, im in enumerate(sheet):
            check.paste(im.resize((W // 2, H // 2)), ((i % 2) * W // 2, (i // 2) * H // 2))
        check_path = ROOT / "assets" / "footage-duo" / "framed-check.png"
        check.save(check_path)
        print(f"duration {duration(OUT / 'duo.mp4'):.1f}s; check sheet {check_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
