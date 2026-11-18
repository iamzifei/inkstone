#!/usr/bin/env python3
"""Puts a screen recording into Apple's official iPhone Duo product bezels,
the way Photoshop would, for the four postures the site's film shows.

Apple's bezels (Apple Design Resources, "iPhone Duo — Photoshop, PNG") are
licensed, not redistributable, so they are not in this repository: they are
read from `assets/footage-duo/bezel/` (git-ignored), which `extract` fills
from the mounted Bezel-iPhone-Duo.dmg. They are used as Apple ships them —
nothing in the artwork is redrawn or reshaped.

* Folded / unfolded: the PNG bezels have a transparent screen. The recording
  goes *under* the bezel, so the rounded inner corners are Apple's own
  anti-aliased edge, not a mask cut here.
* Half-open (book, upright): the Photoshop templates hold the screen in a
  smart object bent by a "Perspective Warp" smart filter — three quads (two
  halves and the hinge), each a projective map from its source to its warped
  vertices. This applies exactly those maps (and the smart object's own
  transform), the screen layer's mask and blend mode, the "Screen Reflection"
  curves (luminosity blend, layer and group masks and opacities) and the
  camera layers, in the template's layer order. `verify` renders the
  template's own placeholder screen this way and compares the result with
  the composite Photoshop saved in the file.

    scripts/duo_bezel.py extract <mounted-volume>
    scripts/duo_bezel.py verify
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
BEZEL = ROOT / "assets" / "footage-duo" / "bezel"
COLOR = "Night Sky"


# ---------------------------------------------------------------- extraction

def extract(volume: Path) -> None:
    """Copies the PNG bezels and decomposes the two half-open templates into
    layers plus their warp parameters (JSON)."""
    from psd_tools import PSDImage
    from psd_tools.constants import Tag

    BEZEL.mkdir(parents=True, exist_ok=True)
    for name in ("Inner Open Landscape", "Inner Open Portrait", "Outer Closed Portrait", "Outer Closed Landscape"):
        src = volume / "PNG" / f"iPhone Duo - {COLOR} - {name}.png"
        Image.open(src).save(BEZEL / f"{name}.png")

    def value(v):
        return getattr(v, "value", v)

    for posture in ("Landscape", "Portrait"):
        psd = PSDImage.open(volume / "Photoshop" / f"iPhone Duo - {COLOR} - Inner Partially Open {posture}.psd")
        out = BEZEL / f"partial-{posture}"
        out.mkdir(exist_ok=True)
        W, H = psd.size
        meta = {"size": [W, H], "layers": []}

        def full_canvas(img: Image.Image, bbox, fill=0) -> Image.Image:
            canvas = Image.new(img.mode, (W, H), fill)
            canvas.paste(img, (bbox[0], bbox[1]))
            return canvas

        def save_mask(layer, path):
            m = layer.mask
            canvas = Image.new("L", (W, H), int(m.background_color))
            if m.bbox[2] > m.bbox[0]:
                canvas.paste(m.topil(), (m.bbox[0], m.bbox[1]))
            canvas.save(path)

        for layer in psd:
            entry = {"name": layer.name.strip(), "kind": layer.kind, "blend": layer.blend_mode.name,
                     "opacity": layer.opacity, "visible": layer.visible}
            key = entry["name"].replace(" ", "_")
            if layer.kind == "pixel":
                full_canvas(layer.topil(), layer.bbox).save(out / f"{key}.png")
            elif layer.kind == "smartobject":
                desc = layer.tagged_blocks.get_data(Tag.SMART_OBJECT_LAYER_DATA1).data
                fltr = desc[b"filterFX"][b"filterFXList"][0][b"Fltr"]
                pts = lambda lst: [[float(value(p[b"Hrzn"])), float(value(p[b"Vrtc"]))] for p in lst]
                entry["transform"] = [float(value(v)) for v in desc[b"Trnf"]]
                entry["content_size"] = [float(value(desc[b"Sz  "][b"Wdth"])), float(value(desc[b"Sz  "][b"Hght"]))]
                entry["vertices"] = pts(fltr[b"vertices"])
                entry["warped"] = pts(fltr[b"warpedVertices"])
                entry["quads"] = [[int(value(i)) for i in q[b"indices"]] for q in fltr[b"quads"]]
                save_mask(layer, out / f"{key}-mask.png")
                # The template's own placeholder screen, for `verify`.
                PSDImage.open(__import__("io").BytesIO(layer.smart_object.data)).composite().convert("RGB").save(out / "placeholder.png")
            elif layer.kind == "group":
                entry["children"] = []
                if layer.has_mask():
                    save_mask(layer, out / f"{key}-mask.png")
                    entry["mask"] = True
                for i, child in enumerate(layer):
                    c = {"name": child.name, "kind": child.kind, "blend": child.blend_mode.name,
                         "opacity": child.opacity, "visible": child.visible}
                    ck = f"{key}-{i}"
                    if child.kind == "curves":
                        # psd-tools gives (output, input) pairs.
                        c["curve"] = [[int(a), int(b)] for a, b in child.data.data[0]]
                    elif child.kind == "pixel":
                        full_canvas(child.topil(), child.bbox).save(out / f"{ck}.png")
                    if child.has_mask():
                        save_mask(child, out / f"{ck}-mask.png")
                        c["mask"] = True
                    entry["children"].append(c)
            meta["layers"].append(entry)
        psd.topil().save(out / "photoshop-composite.png")
        (out / "template.json").write_text(json.dumps(meta, indent=1))
        print(f"extracted {posture}: {[l['name'] for l in meta['layers']]}")


# ------------------------------------------------------------------ geometry

def homography(src, dst) -> np.ndarray:
    """3x3 projective map taking the four src points to the four dst points."""
    A = []
    for (x, y), (u, v) in zip(src, dst):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y, -u])
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y, -v])
    _, _, vt = np.linalg.svd(np.array(A, dtype=np.float64))
    h = vt[-1].reshape(3, 3)
    return h / h[2, 2]


def apply_h(h, x, y):
    w = h[2, 0] * x + h[2, 1] * y + h[2, 2]
    return (h[0, 0] * x + h[0, 1] * y + h[0, 2]) / w, (h[1, 0] * x + h[1, 1] * y + h[1, 2]) / w


def inside_quad(quad, x, y):
    """Point-in-convex-quad, either winding."""
    signs = []
    for i in range(4):
        (x0, y0), (x1, y1) = quad[i], quad[(i + 1) % 4]
        signs.append((x1 - x0) * (y - y0) - (y1 - y0) * (x - x0))
    pos = np.all([s >= 0 for s in signs], axis=0)
    neg = np.all([s <= 0 for s in signs], axis=0)
    return pos | neg


class PartialTemplate:
    """One half-open template, rendered at `scale` of its native size."""

    def __init__(self, posture: str, scale: float):
        self.dir = BEZEL / f"partial-{posture}"
        self.meta = json.loads((self.dir / "template.json").read_text())
        W, H = self.meta["size"]
        self.scale = scale
        self.size = (round(W * scale), round(H * scale))
        cache: dict = {}

        def load(name, mode):
            # Layers are static: read and scaled once, not on every frame.
            if (name, mode) not in cache:
                cache[(name, mode)] = np.asarray(
                    Image.open(self.dir / name).convert(mode).resize(self.size, Image.LANCZOS), dtype=np.float32) / 255.0
            return cache[(name, mode)]
        self.load = load
        self.screen = next(l for l in self.meta["layers"] if l["kind"] == "smartobject")
        self._build_map()

    # Each output pixel samples the screen at 2x2 sub-pixel positions and
    # averages them: where the warp squeezes the screen (the upright posture's
    # lower half, ~5x), a single bilinear tap would alias and shimmer.
    SUB = ((0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75))

    def _build_map(self):
        self.maps = [self._map_at(dx, dy) for dx, dy in self.SUB]
        self.valid = np.mean([m[2] for m in self.maps], axis=0).astype(np.float32)

    def _map_at(self, dx, dy):
        s, layer = self.scale, self.screen
        w, h = self.size
        ys, xs = np.mgrid[0:h, 0:w].astype(np.float64)
        X, Y = (xs + dx) / s, (ys + dy) / s
        verts, warped = layer["vertices"], layer["warped"]
        qx = np.full(X.shape, np.nan)
        qy = np.full(X.shape, np.nan)
        for quad in layer["quads"]:
            src = [verts[i] for i in quad]
            dst = [warped[i] for i in quad]
            hit = inside_quad(dst, X, Y) & np.isnan(qx)
            inv = homography(dst, src)
            ux, uy = apply_h(inv, X[hit], Y[hit])
            qx[hit], qy[hit] = ux, uy
        # Undo the smart object's own transform: content corners TL, TR, BR, BL.
        cw, ch = layer["content_size"]
        t = layer["transform"]
        to_canvas = homography([(0, 0), (cw, 0), (cw, ch), (0, ch)], [(t[0], t[1]), (t[2], t[3]), (t[4], t[5]), (t[6], t[7])])
        cx, cy = apply_h(np.linalg.inv(to_canvas), qx, qy)
        self.content_size = (cw, ch)
        nx, ny = cx / cw, cy / ch                    # normalised content coordinates
        valid = ~np.isnan(cx) & (nx >= 0) & (nx <= 1) & (ny >= 0) & (ny <= 1)
        return nx, ny, valid

    def sample(self, content: np.ndarray) -> np.ndarray:
        """The screen at each output pixel: mean of the 2x2 sub-pixel taps."""
        acc = None
        for nx, ny, valid in self.maps:
            tap = self._bilinear(content, nx, ny) * valid[..., None]
            acc = tap if acc is None else acc + tap
        with np.errstate(divide="ignore", invalid="ignore"):
            return np.nan_to_num(acc / (self.valid[..., None] * len(self.maps)))

    @staticmethod
    def _bilinear(content, nx, ny):
        ch, cw = content.shape[:2]
        x = np.clip(np.nan_to_num(nx) * cw - 0.5, 0, cw - 1)
        y = np.clip(np.nan_to_num(ny) * ch - 0.5, 0, ch - 1)
        x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
        x1, y1 = np.minimum(x0 + 1, cw - 1), np.minimum(y0 + 1, ch - 1)
        fx, fy = (x - x0)[..., None], (y - y0)[..., None]
        top = content[y0, x0] * (1 - fx) + content[y0, x1] * fx
        bot = content[y1, x0] * (1 - fx) + content[y1, x1] * fx
        return top * (1 - fy) + bot * fy

    # -------------------------------------------------------------- blending
    @staticmethod
    def lum(c):
        return 0.3 * c[..., 0] + 0.59 * c[..., 1] + 0.11 * c[..., 2]

    @classmethod
    def set_lum(cls, c, l):
        """Photoshop's non-separable luminosity: hue/saturation of c, luminance l."""
        d = (l - cls.lum(c))[..., None]
        c = c + d
        L = cls.lum(c)[..., None]
        n = c.min(axis=-1, keepdims=True)
        x = c.max(axis=-1, keepdims=True)
        with np.errstate(divide="ignore", invalid="ignore"):
            c = np.where(n < 0, L + (c - L) * L / (L - n), c)
            c = np.where(x > 1, L + (c - L) * (1 - L) / (x - L), c)
        return np.clip(np.nan_to_num(c), 0, 1)

    @staticmethod
    def curve_lut(points):
        """Photoshop curves: a natural cubic spline through (input, output)."""
        from scipy.interpolate import CubicSpline
        pts = sorted((b, a) for a, b in points)        # stored as (output, input)
        xs, ys = zip(*pts)
        lut = CubicSpline(xs, ys, bc_type="natural")(np.arange(256)) if len(xs) > 2 else np.interp(np.arange(256), xs, ys)
        lut = np.clip(lut, 0, 255)
        lut[: int(xs[0])] = ys[0]
        lut[int(xs[-1]):] = ys[-1]
        return (lut / 255.0).astype(np.float32)

    def render(self, content: np.ndarray) -> np.ndarray:
        """content: the screen as the smart object holds it (content_size
        aspect), float RGB 0-1. Returns premultiplied-free RGBA float."""
        rgb = np.zeros(self.size[::-1] + (3,), np.float32)
        alpha = np.zeros(self.size[::-1], np.float32)

        def over(src_rgb, src_a, blend="NORMAL"):
            nonlocal rgb, alpha
            if blend == "SCREEN":
                # Separable blend over a partly transparent backdrop, as
                # Photoshop does: (1 - αb)·Cs + αb·B(Cb, Cs).
                mixed = 1 - (1 - rgb) * (1 - src_rgb)
                ab = alpha[..., None]
                src_rgb = (1 - ab) * src_rgb + ab * mixed
            a = src_a[..., None]
            out_a = alpha + src_a * (1 - alpha)
            with np.errstate(divide="ignore", invalid="ignore"):
                rgb = np.nan_to_num((src_rgb * a + rgb * alpha[..., None] * (1 - a)) / out_a[..., None])
            alpha = out_a

        for layer in self.meta["layers"]:
            if not layer["visible"]:
                continue
            key = layer["name"].replace(" ", "_")
            op = layer["opacity"] / 255.0
            if layer["kind"] == "pixel":
                img = self.load(f"{key}.png", "RGBA")
                over(img[..., :3], img[..., 3] * op, layer["blend"])
            elif layer["kind"] == "smartobject":
                mask = self.load(f"{key}-mask.png", "L")
                over(self.sample(content), self.valid * mask * op, layer["blend"])
            elif layer["kind"] == "group":
                group_mask = self.load(f"{key}-mask.png", "L") if layer.get("mask") else 1.0
                before_rgb, before_a = rgb.copy(), alpha.copy()
                for i, child in enumerate(layer["children"]):
                    if not child["visible"]:
                        continue
                    cop = child["opacity"] / 255.0 * (self.load(f"{key}-{i}-mask.png", "L") if child.get("mask") else 1.0)
                    if child["kind"] == "curves":
                        lut = self.curve_lut(child["curve"])
                        adjusted = lut[np.clip((rgb * 255 + 0.5).astype(int), 0, 255)]
                        if child["blend"] == "LUMINOSITY":
                            adjusted = self.set_lum(rgb, self.lum(adjusted))
                        rgb = rgb + (adjusted - rgb) * np.asarray(cop)[..., None]
                    elif child["kind"] == "pixel":
                        img = self.load(f"{key}-{i}.png", "RGBA")
                        over(img[..., :3], img[..., 3] * cop, child["blend"])
                # Pass-through group: its opacity and mask fade the group's
                # effect against what was below it.
                g = (layer["opacity"] / 255.0) * np.asarray(group_mask)
                g3 = g[..., None] if np.ndim(g) else g
                rgb = before_rgb + (rgb - before_rgb) * g3
                alpha = before_a + (alpha - before_a) * g
        return np.dstack([rgb, alpha])


def verify(scale: float = 0.5) -> None:
    for posture in ("Landscape", "Portrait"):
        t = PartialTemplate(posture, scale)
        placeholder = np.asarray(Image.open(t.dir / "placeholder.png").convert("RGB"), dtype=np.float32) / 255.0
        ours = t.render(placeholder)
        ps = np.asarray(Image.open(t.dir / "photoshop-composite.png").convert("RGBA").resize(t.size, Image.LANCZOS),
                        dtype=np.float32) / 255.0
        a = (ps[..., 3] > 0.99) & (ours[..., 3] > 0.99)
        diff = np.abs(ours[..., :3] - ps[..., :3])[a] * 255
        screen = t.valid[a] > 0.5
        print(f"{posture}: mean |diff| {diff.mean():.2f}/255, 99th pct {np.percentile(diff, 99):.1f}; "
              f"on the screen {diff[screen].mean():.2f}, off it {diff[~screen].mean():.2f}; "
              f"alpha mean |diff| {np.abs(ours[..., 3] - ps[..., 3]).mean() * 255:.2f}")
        Image.fromarray((np.clip(ours, 0, 1) * 255).astype(np.uint8), "RGBA").save(t.dir / "verify-ours.png")


if __name__ == "__main__":
    if sys.argv[1:2] == ["extract"]:
        extract(Path(sys.argv[2]))
    elif sys.argv[1:2] == ["verify"]:
        verify()
    else:
        sys.exit(__doc__)
