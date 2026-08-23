#!/usr/bin/env python3
"""Tests for the built site, and for the one link that leaves the app.

Run:  python3 -m unittest discover -s site/tests
"""
from __future__ import annotations

import posixpath
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "site"))

import build  # noqa: E402


class BuiltSite(unittest.TestCase):
    """Builds once, into a temporary directory, and asserts against the result."""

    @classmethod
    def setUpClass(cls) -> None:
        cls._tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls._tmp.name)
        build.build(cls.out)

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmp.cleanup()

    def test_sync_guide_is_published(self) -> None:
        page = self.out / "sync.html"
        self.assertTrue(page.exists(), "the sync guide must reach the built site")
        html = page.read_text(encoding="utf-8")
        self.assertIn("<title>Syncing a vault", html)
        # Both mechanisms, because the page is linked from both sections of the
        # app's Sync pane and someone arriving from either must find their half.
        self.assertIn("iCloud Drive", html)
        self.assertIn("GitHub", html)

    def test_static_pages_are_in_the_sitemap(self) -> None:
        """They were not, until the sync guide needed to be findable.

        A page the app sends people to should be indexable; leaving it out was
        survivable for a privacy policy nobody searches for.
        """
        sitemap = (self.out / "sitemap.xml").read_text(encoding="utf-8")
        for name in ("sync.html", "privacy.html"):
            self.assertIn(f"{build.SITE}/{name}", sitemap, name)

    def test_no_page_references_a_missing_asset(self) -> None:
        """A stylesheet or script that 404s takes the whole page's design with it."""
        published = {
            str(path.relative_to(self.out))
            for path in self.out.rglob("*") if path.is_file()
        }
        pattern = re.compile(r'(?:href|src)="(?!https?:|/|#|data:)([^"?]+)')
        for page in sorted(self.out.rglob("*.html")):
            base = page.parent.relative_to(self.out)
            for ref in pattern.findall(page.read_text(encoding="utf-8")):
                # `normpath` before comparing: a language page links assets as
                # `../assets/site.js`, and the unresolved form matches nothing.
                target = posixpath.normpath(posixpath.join(base.as_posix(), ref))
                # A link to a directory — `../` for the site root — is served by
                # its index.
                if ref.endswith("/") or target == ".":
                    target = posixpath.normpath(posixpath.join(target, "index.html"))
                with self.subTest(page=str(page.relative_to(self.out)), ref=ref):
                    self.assertIn(target, published)


class AppHelpLink(unittest.TestCase):
    """The app hard-codes a URL into this site. It must land on a real page.

    This is the seam nothing else watches: the Swift side compiles whatever
    string it is given, the site builds whatever pages it has, and neither knows
    about the other. A help link that 404s is worse than none — it is a promise
    broken in front of someone already stuck.
    """

    def test_settings_help_url_resolves_to_a_published_page(self) -> None:
        source = (ROOT / "App/Views/Settings/SettingsView.swift").read_text(encoding="utf-8")
        match = re.search(r'SyncHelp\b.*?URL\(string:\s*"([^"]+)"\)', source, re.S)
        self.assertIsNotNone(match, "SyncHelp.url is gone or has been renamed")
        url = match.group(1)

        self.assertTrue(url.startswith(build.SITE + "/"),
                        f"{url} does not point at {build.SITE}")
        name = url.removeprefix(build.SITE + "/")
        self.assertTrue((ROOT / "site" / "static" / name).exists(),
                        f"{name} is linked from Settings but no such page is published")


if __name__ == "__main__":
    unittest.main()
