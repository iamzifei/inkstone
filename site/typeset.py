#!/usr/bin/env python3
"""Mixed CJK-Latin typesetting for the generated HTML.

Chinese sets solid: there are no word spaces, so the reader's eye relies on the
even colour of the line. Drop an English word into that line and it collides —
"中英文混排typography" reads as one clot. The convention, at least since Chinese
type went digital, is a thin gap on each side of the Latin run, roughly a
quarter of the character width. The W3C's *Requirements for Chinese Text
Layout* calls it 文字间隙.

There are two ways to get it, and this file uses both, on purpose:

1. **`text-autospace: normal`**, which is what the browser should do by itself.
   It has been Baseline since November 2025 and its *initial* value is already
   `normal`, so on a current browser the gap is there whether or not anyone asks
   for it.
2. **An injected `<span class="ac"></span>`** at every boundary, for the browsers
   that predate it.

Doing both naively would double the gap on a new browser — which is why the span
is `display: none` by default and only takes a width inside
`@supports not (text-autospace: normal)`. The browser picks one mechanism; it can
never apply two. See the `.ac` rule in styles.css, which is the other half of
this and must not be edited without reading this note.

The span is empty rather than a thin-space character on purpose. A U+2009 in the
text would be copied along with it, would break a reader's ⌘F for
"中英文混排typography", and would be read out by a screen reader as a pause. An
empty element changes how the line *looks* without changing what it *says*.
"""
from __future__ import annotations

import re

# Han, plus the iteration mark 々 and 〇, plus kana so Japanese gets the same
# treatment. Hangul is deliberately absent: Korean is written with word spaces
# already, so adding more would be setting it wrong.
CJK = (
    r"々〇"
    r"぀-ヿ"       # hiragana + katakana
    r"㐀-䶿"       # CJK ext A
    r"一-鿿"       # CJK unified
    r"豈-﫿"       # compatibility ideographs
)

# What counts as "Latin" on the other side of the boundary. Letters, digits, and
# the four symbols that show up mid-sentence in this particular site's copy
# (`macOS 26`, `[[wikilink]]`, `#tag`, `.md`). Kept deliberately short: every
# character added here is a chance to put a gap somewhere that wanted none.
LATIN = r"A-Za-z0-9@#$%&"

# Full-width punctuation — 、。，：；！？“”（）《》「」…—～· — already carries its own
# side bearing, half an em box of deliberate emptiness. A gap added next to one
# reads as a hole, and that is the most common way a pass like this goes wrong.
# They are excluded by omission rather than by a rule: they live in U+3000–303F
# and U+FF00–FFEF, and neither range is in CJK above. Widen CJK and you have
# silently switched that protection off, so check this list before you do.
SPAN = '<span class="ac"></span>'

_CJK_THEN_LATIN = re.compile(f"(?<=[{CJK}])(?=[{LATIN}])")
_LATIN_THEN_CJK = re.compile(f"(?<=[{LATIN}])(?=[{CJK}])")

# Everything that is not a tag, so the pass can walk text nodes without an HTML
# parser. `[^<>]*` cannot span a tag boundary, which is what keeps an attribute
# value — `alt="中英文混排 typography"` — from being rewritten into markup.
_TEXT_OUTSIDE_TAGS = re.compile(r"(<[^>]*>)|([^<]+)")

# Regions whose text is not prose and must be left byte-for-byte alone. A gap
# injected into a code sample would be showing the reader something the compiler
# would reject.
_SKIP = re.compile(
    r"<(script|style|pre|code|textarea)\b[^>]*>.*?</\1>",
    re.IGNORECASE | re.DOTALL,
)


def space_text(text: str) -> str:
    """Insert the boundary span into a bare string with no markup in it."""
    text = _CJK_THEN_LATIN.sub(SPAN, text)
    return _LATIN_THEN_CJK.sub(SPAN, text)


def autospace(html_text: str) -> str:
    """Insert the boundary span into every prose text node of an HTML fragment.

    Tags, attribute values, and the contents of code/pre/script/style/textarea
    come out unchanged.
    """
    # Cut the skipped regions out first and put them back at the end, so the
    # walk below never sees them. Doing it the other way round — tracking depth
    # while walking — needs the walker to understand nesting, and it silently
    # got `<pre><code>` wrong the first time it was written that way.
    holes: list[str] = []

    def stash(m: re.Match) -> str:
        holes.append(m.group(0))
        return f"\x00{len(holes) - 1}\x00"

    stashed = _SKIP.sub(stash, html_text)

    def walk(m: re.Match) -> str:
        tag, text = m.groups()
        return tag if tag is not None else space_text(text)

    out = _TEXT_OUTSIDE_TAGS.sub(walk, stashed)
    return re.sub(r"\x00(\d+)\x00", lambda m: holes[int(m.group(1))], out)
