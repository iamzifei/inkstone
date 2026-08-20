#!/usr/bin/env python3
"""Tests for the mixed CJK-Latin spacing pass.

Every claim typeset.py's docstrings make about what it will *not* touch has a
test here. Those are the ones that matter: a missing gap is a cosmetic flaw a
reader forgives, but a gap injected into an attribute value or a code sample is
broken output.

Run:  python3 -m unittest discover -s site/tests
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from typeset import SPAN, autospace, space_text  # noqa: E402


class SpaceText(unittest.TestCase):
    def test_han_before_latin(self):
        self.assertEqual(space_text("中文typography"), f"中文{SPAN}typography")

    def test_latin_before_han(self):
        self.assertEqual(space_text("typography中文"), f"typography{SPAN}中文")

    def test_both_sides_of_a_latin_run(self):
        self.assertEqual(
            space_text("中英文混排typography很难"),
            f"中英文混排{SPAN}typography{SPAN}很难",
        )

    def test_digits_count_as_latin(self):
        self.assertEqual(space_text("需要macOS 26"), f"需要{SPAN}macOS 26")

    def test_existing_space_is_left_alone(self):
        # A boundary that already has a real space in it is not a boundary. The
        # lookarounds are adjacency-only, so nothing fires here.
        self.assertEqual(space_text("中文 typography"), "中文 typography")

    def test_full_width_punctuation_gets_no_gap(self):
        # The whole point of the exclusion. Each of these already carries half an
        # em of built-in space; a span next to it would read as a hole.
        for line in ("中文，typography", "「typography」中文", "中文（English）"):
            with self.subTest(line=line):
                self.assertNotIn(SPAN, space_text(line))

    def test_pure_latin_and_pure_han_are_untouched(self):
        self.assertEqual(space_text("plain English only"), "plain English only")
        self.assertEqual(space_text("纯中文没有拉丁字母"), "纯中文没有拉丁字母")

    def test_kana_is_treated_as_cjk(self):
        self.assertEqual(space_text("ひらがなtext"), f"ひらがな{SPAN}text")

    def test_hangul_is_not(self):
        # Korean is written with word spaces already. Adding more would be
        # setting it wrong, so Hangul is deliberately outside the CJK class.
        self.assertEqual(space_text("한국어text"), "한국어text")


class Autospace(unittest.TestCase):
    def test_walks_text_but_not_tags(self):
        self.assertEqual(
            autospace("<p>中文typography</p>"),
            f"<p>中文{SPAN}typography</p>",
        )

    def test_attribute_values_are_not_rewritten(self):
        # `[^<>]` in the tag branch is what stops this; an injected span inside
        # alt="" would put markup where the parser expects a quoted string.
        html = '<img alt="中文typography" src="a.webp">'
        self.assertEqual(autospace(html), html)

    def test_code_is_left_byte_for_byte(self):
        html = "<p>试试<code>中文code</code>吧</p>"
        out = autospace(html)
        self.assertIn("<code>中文code</code>", out)
        self.assertEqual(out.count(SPAN), 0)

    def test_pre_wrapping_code_is_skipped_once_not_twice(self):
        # The nesting case the docstring says an earlier depth-tracking version
        # got wrong.
        html = "<pre><code>let x = 中文1</code></pre>"
        self.assertEqual(autospace(html), html)

    def test_prose_around_a_skipped_region_still_gets_spaced(self):
        out = autospace("<p>装的是<code>x</code>，写作macOS</p>")
        self.assertIn(f"写作{SPAN}macOS", out)

    def test_boundary_across_an_element_edge_is_not_joined(self):
        # 中 and English are in different text nodes with a tag between them.
        # There is no adjacency, and inventing one would mean guessing at the
        # rendered result rather than reading it.
        html = "<p>中<em>English</em></p>"
        self.assertEqual(autospace(html), html)

    def test_is_idempotent(self):
        # The build runs one pass, but a rebuild over already-built HTML must not
        # compound. `<` in the injected span means the second pass sees a tag.
        once = autospace("<p>中英文混排typography</p>")
        self.assertEqual(autospace(once), once)


if __name__ == "__main__":
    unittest.main()
