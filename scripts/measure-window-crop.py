#!/usr/bin/env python3
"""Print the ffmpeg crop for a recorded segment: w:h:x:y

`screencapture -v` ignores `-o`, so every frame carries the window's drop
shadow. The margin is not a constant and not symmetric: an active window casts a
bigger shadow than an inactive one, so footage shot while the app was frontmost
is 3824x2484 around the same 3600x2260 window that measured 3736x2396 when it
was behind something. A hardcoded crop is therefore correct only for the take it
was measured on — this reads it from the frame instead.

The window is found as the largest bright rectangle: everything outside it is
shadow over black, everything inside starts at the app's paper colour. Sampling
a single centre row and a single centre column is enough, because the window is
a rectangle and its edges are hard.

Usage:  measure-window-crop.py segment.mov
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

# Well above the shadow, well below any part of the app's chrome. The darkest
# thing inside the window is text, which is never a whole row or column.
THRESHOLD = 60


def frame(path: Path, out: Path) -> None:
    # A second in, not frame zero: `screencapture -v` starts before the first
    # real frame, and the lead-in can be a partially composited window.
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-ss", "1.0", "-i", str(path),
         "-vframes", "1", str(out)],
        check=True,
    )


def span(values: list[bool]) -> tuple[int, int]:
    first = next(i for i, bright in enumerate(values) if bright)
    last = len(values) - 1 - next(i for i, bright in enumerate(reversed(values)) if bright)
    return first, last


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    src = Path(argv[1])
    with tempfile.TemporaryDirectory() as tmp:
        png = Path(tmp) / "f.png"
        frame(src, png)
        image = Image.open(png).convert("RGB")
        width, height = image.size
        row = [max(image.getpixel((x, height // 2))) > THRESHOLD for x in range(width)]
        col = [max(image.getpixel((width // 2, y))) > THRESHOLD for y in range(height)]
        left, right = span(row)
        top, bottom = span(col)
    print(f"{right - left + 1}:{bottom - top + 1}:{left}:{top}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
