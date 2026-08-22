#!/usr/bin/env python3
"""Print Inkstone's main window as: <windowId> <x> <y> <width> <height>

Why a window ID and not a screen rectangle: `screencapture -R x,y,w,h`
photographs whatever happens to be at those coordinates. If the app failed to
launch, or the window opened on the other display, or a dialog stole the front,
the capture still succeeds and still writes a file — of the desktop. A window ID
cannot be stale in that way. If the window is not on screen there is no ID, and
the caller stops instead of shipping a picture of a wallpaper.

Windows with alpha 0 or with no title are skipped for the same reason: a closed
panel can linger in the window list, and photographing one produces a plausible
but empty frame.

Exits 1 with nothing on stdout when there is no usable window.
"""
from __future__ import annotations

import sys

import Quartz

OWNER = "Inkstone"
# Anything smaller is a tooltip, a popover or the quick switcher rather than the
# document window this is asked for.
MIN_W, MIN_H = 640, 400


def main() -> int:
    listing = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID,
    ) or []

    best = None
    for window in listing:
        if window.get("kCGWindowOwnerName") != OWNER:
            continue
        if window.get("kCGWindowAlpha", 1) < 0.9:
            continue
        if window.get("kCGWindowLayer", 0) != 0:      # 0 is a normal window
            continue
        bounds = window.get("kCGWindowBounds") or {}
        width, height = int(bounds.get("Width", 0)), int(bounds.get("Height", 0))
        if width < MIN_W or height < MIN_H:
            continue
        # Largest wins: the document window, not an inspector that happens to
        # clear the minimum.
        if best is None or width * height > best[0]:
            best = (width * height, int(window["kCGWindowNumber"]),
                    int(bounds.get("X", 0)), int(bounds.get("Y", 0)), width, height)

    if best is None:
        print(f"no on-screen {OWNER} window", file=sys.stderr)
        return 1
    _, wid, x, y, w, h = best
    print(f"{wid} {x} {y} {w} {h}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
