#!/usr/bin/env python3
"""Crop a PNG in place: crop-png.py <file> <x> <y> <w> <h>  (in image pixels).

`sips` crops from the centre only, and `screencapture -R` photographs screen
coordinates rather than a window — the failure mode the whole capture pipeline
avoids. So the crop happens after the window has been captured by id.
"""
from __future__ import annotations

import sys

import Quartz


def main() -> int:
    if len(sys.argv) != 6:
        print(__doc__, file=sys.stderr)
        return 2
    path, x, y, w, h = sys.argv[1], *[int(v) for v in sys.argv[2:]]

    source = Quartz.CGImageSourceCreateWithURL(
        Quartz.CFURLCreateFromFileSystemRepresentation(None, path.encode(), len(path.encode()), False),
        None)
    if source is None:
        print(f"cannot read {path}", file=sys.stderr)
        return 1
    image = Quartz.CGImageSourceCreateImageAtIndex(source, 0, None)
    cropped = Quartz.CGImageCreateWithImageInRect(image, Quartz.CGRectMake(x, y, w, h))
    if cropped is None:
        print("crop rect is outside the image", file=sys.stderr)
        return 1

    url = Quartz.CFURLCreateFromFileSystemRepresentation(None, path.encode(), len(path.encode()), False)
    destination = Quartz.CGImageDestinationCreateWithURL(url, "public.png", 1, None)
    Quartz.CGImageDestinationAddImage(destination, cropped, None)
    if not Quartz.CGImageDestinationFinalize(destination):
        print("could not write the cropped image", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
