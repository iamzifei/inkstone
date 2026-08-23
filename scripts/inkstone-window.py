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
    # Optional: --title SUBSTRING picks a named window instead of the largest
    # one, and relaxes the size floor with it. The Settings window is 560x460 —
    # under the floor above, so without this it is not merely deprioritised, it
    # is invisible, and the capture silently gets the document window instead.
    wanted = None
    argv = sys.argv[1:]
    if "--title" in argv:
        wanted = argv[argv.index("--title") + 1].lower()
    min_w, min_h = (0, 0) if wanted else (MIN_W, MIN_H)

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
        if width < min_w or height < min_h:
            continue
        if wanted and wanted not in (window.get("kCGWindowName") or "").lower():
            continue
        # Largest wins: the document window, not an inspector that happens to
        # clear the minimum.
        if best is None or width * height > best[0]:
            best = (width * height, int(window["kCGWindowNumber"]),
                    int(bounds.get("X", 0)), int(bounds.get("Y", 0)), width, height)

    if best is None:
        print(f"no on-screen {OWNER} window" + (f" titled {wanted!r}" if wanted else ""), file=sys.stderr)
        return 1
    _, wid, x, y, w, h = best
    print(f"{wid} {x} {y} {w} {h}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
