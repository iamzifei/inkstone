#!/usr/bin/env python3
"""Post keystrokes straight to Inkstone's process, without activating it.

Why this exists rather than `cliclick` or System Events' `keystroke`: both of
those deliver to whatever is frontmost. That is fine at a desk and useless here
— the capture rig drives the app while another window is in front, and on a
locked screen nothing can be brought to the front at all. `CGEventPostToPid`
addresses a process directly, so the app receives the key whether or not anyone
is looking at it.

The same asymmetry is why the recording works at all: `screencapture -l` reads a
window's own backing store, so a window can be filmed while it is covered. Input
is the only half that needed solving.

Usage:
    send-keys.py key <keycode> [cmd] [shift] [option]
    send-keys.py text "中英文混排 typography"   [--delay 0.045]
    send-keys.py click <x> <y>                 # global screen points
    send-keys.py scroll <lines>                # negative scrolls down

Exits 1 if Inkstone is not running, rather than posting into the void.
"""
from __future__ import annotations

import sys
import time

import Quartz

FLAGS = {
    "cmd": Quartz.kCGEventFlagMaskCommand,
    "shift": Quartz.kCGEventFlagMaskShift,
    "option": Quartz.kCGEventFlagMaskAlternate,
    "ctrl": Quartz.kCGEventFlagMaskControl,
}


def inkstone_pid() -> int:
    listing = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID) or []
    for window in listing:
        if window.get("kCGWindowOwnerName") == "Inkstone":
            return int(window["kCGWindowOwnerPID"])
    raise SystemExit("Inkstone is not running")


def post(pid: int, event) -> None:
    Quartz.CGEventPostToPid(pid, event)


def send_key(pid: int, code: int, flags: int) -> None:
    for down in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(None, code, down)
        Quartz.CGEventSetFlags(event, flags)
        post(pid, event)
        time.sleep(0.012)


def send_text(pid: int, text: str, delay: float) -> None:
    for char in text:
        # The keycode is ignored once a Unicode string is attached, which is what
        # lets a Han character through: it has no key on the layout, so anything
        # that goes via the layout — System Events' `keystroke` included — drops
        # it silently and types the Latin part only.
        for down in (True, False):
            event = Quartz.CGEventCreateKeyboardEvent(None, 0, down)
            Quartz.CGEventKeyboardSetUnicodeString(event, len(char), char)
            post(pid, event)
            time.sleep(0.008)
        time.sleep(delay)


def send_click(pid: int, x: float, y: float) -> None:
    """A press and release at a global screen point, delivered to one process.

    The coordinates are still the screen's, because that is the space the window
    server hands the app and the app converts from. Posting to a pid changes who
    receives the event, not how it is addressed — so this lands where it would
    have landed had the window been in front, even when it is covered.
    """
    for kind in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
        event = Quartz.CGEventCreateMouseEvent(None, kind, (x, y),
                                               Quartz.kCGMouseButtonLeft)
        post(pid, event)
        time.sleep(0.03)


def send_scroll(pid: int, lines: int) -> None:
    # In steps, because one large scroll event jumps rather than moves, and the
    # point of scrolling on camera is to show the page travelling.
    step = 1 if lines > 0 else -1
    for _ in range(abs(lines)):
        event = Quartz.CGEventCreateScrollWheelEvent(
            None, Quartz.kCGScrollEventUnitLine, 1, step)
        post(pid, event)
        time.sleep(0.05)


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__)
        return 2
    pid = inkstone_pid()
    mode = argv[1]

    if mode == "key":
        code = int(argv[2])
        flags = 0
        for name in argv[3:]:
            flags |= FLAGS.get(name, 0)
        send_key(pid, code, flags)
    elif mode == "text":
        delay = 0.045
        args = argv[2:]
        if "--delay" in args:
            index = args.index("--delay")
            delay = float(args[index + 1])
            args = args[:index] + args[index + 2:]
        send_text(pid, "".join(args), delay)
    elif mode == "click":
        send_click(pid, float(argv[2]), float(argv[3]))
    elif mode == "scroll":
        send_scroll(pid, int(argv[2]))
    else:
        print(f"unknown mode: {mode}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
