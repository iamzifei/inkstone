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
import guide  # noqa: E402


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

    def test_sync_guide_is_published_in_every_language_it_claims(self) -> None:
        for lang, (prefix, _, _) in guide.LANGS.items():
            with self.subTest(lang=lang):
                page = self.out / prefix / "sync.html"
                self.assertTrue(page.exists(), f"{prefix}sync.html is missing")
                html = page.read_text(encoding="utf-8")
                # Both mechanisms: the page is linked from both sections of the
                # app's Sync pane, and someone arriving from either must find
                # their half.
                self.assertIn("iCloud", html)
                self.assertIn("GitHub", html)

    def test_the_languages_have_the_same_page(self) -> None:
        """Same structure, different words — the point of generating them.

        Section ids are the check: they are what the structure is made of, and
        a translation that quietly loses a section would otherwise be invisible
        until a reader of that language noticed.
        """
        ids = {}
        for lang, (prefix, _, _) in guide.LANGS.items():
            html = (self.out / prefix / "sync.html").read_text(encoding="utf-8")
            ids[lang] = re.findall(r'<h2 id="([^"]+)"', html)
        reference = ids[guide.DEFAULT]
        self.assertTrue(reference, "the guide has no sections at all")
        for lang, found in ids.items():
            with self.subTest(lang=lang):
                self.assertEqual(found, reference)

    def test_every_language_carries_the_screenshots(self) -> None:
        for lang, (prefix, _, _) in guide.LANGS.items():
            html = (self.out / prefix / "sync.html").read_text(encoding="utf-8")
            for shot in guide.SHOTS.values():
                with self.subTest(lang=lang, shot=shot.name):
                    self.assertIn(f"{shot.name}.png", html)
                    self.assertIn(f"{shot.name}.webp", html)

    def test_screenshots_show_nothing_private(self) -> None:
        """The pictures are of a real app, so this is worth asserting.

        The first attempt leaked a private repository name across the top of the
        Sync pane — published by another device into iCloud's key-value store,
        which the demo isolation did not cover at the time. The capture script
        now runs against a scratch defaults suite *and* a neutered shared-config
        store; this checks the result rather than trusting that.
        """
        forbidden = ("iamzifei", "zhanyoucai", "ghp_1", "github_pat_")
        for shot in guide.SHOTS.values():
            png = ROOT / "site" / "assets" / "guide" / f"{shot.name}.png"
            with self.subTest(shot=shot.name):
                self.assertTrue(png.exists(), f"{png} is missing")
                blob = png.read_bytes()
                for needle in forbidden:
                    self.assertNotIn(needle.encode(), blob)

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

    @classmethod
    def setUpClass(cls) -> None:
        cls._tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls._tmp.name)
        build.build(cls.out)
        cls.source = (ROOT / "App/Views/Settings/SettingsView.swift").read_text(encoding="utf-8")

    @classmethod
    def tearDownClass(cls) -> None:
        cls._tmp.cleanup()

    def test_the_app_and_the_site_agree_on_the_host(self) -> None:
        match = re.search(r'private static let site = "([^"]+)"', self.source)
        self.assertIsNotNone(match, "SyncHelp.site is gone or has been renamed")
        self.assertEqual(match.group(1), build.SITE)

    def test_every_language_the_app_can_link_to_is_published(self) -> None:
        """`SyncHelp.directories` in Swift against what the site actually emits.

        These are two files that never see each other: Swift compiles whatever
        string it is given, the site builds whatever pages it has. English is
        implicit in Swift — the default, with no prefix — so it is added here.
        """
        # From the `= [` rather than from `directories:`: the declared type is
        # `[String: String]`, so a non-greedy match to the first `]` stops on
        # the type and finds nothing.
        literal = re.search(r'directories:[^=]*=\s*(\[.*?\])', self.source, re.S)
        self.assertIsNotNone(literal, "SyncHelp.directories is gone or has been renamed")
        found = dict(re.findall(r'"([\w-]+)":\s*"([\w-]*/?)"', literal.group(1)))
        found["en"] = ""

        published = {lang: prefix for lang, (prefix, _, _) in guide.LANGS.items()}
        # The app names its languages by BCP-47 tag, the site by directory. Map
        # through the tag the site declares, so the two cannot silently diverge.
        by_tag = {tag: prefix for prefix, tag, _ in guide.LANGS.values()}
        by_tag["en"] = ""

        for tag, prefix in found.items():
            with self.subTest(language=tag):
                self.assertIn(tag, by_tag, f"the app links to {tag}, the site has no such page")
                self.assertEqual(prefix, by_tag[tag])
                self.assertTrue((self.out / prefix / "sync.html").exists())

        self.assertEqual(len(found), len(published),
                         "the app and the guide disagree on how many languages exist")


if __name__ == "__main__":
    unittest.main()


class LandingPages(BuiltSite):
    """The keyword landing pages, and the claims they are allowed to make.

    These pages exist to be found in search, which means two things have to hold
    every build: they have to be *in* the site (a page missing from the sitemap
    is a page that does not exist), and they must not drift into claims that are
    not true. The second is the one worth a test — a marketing page that says the
    app is open source when the repository has no licence is a lie the build
    should refuse to ship.
    """

    PAGES = ["obsidian-alternative.html", "obsidian-sync-free.html"]

    def test_pages_are_built(self) -> None:
        for name in self.PAGES:
            self.assertTrue((self.out / name).is_file(), f"{name} was not built")

    def test_pages_are_in_the_sitemap(self) -> None:
        sitemap = (self.out / "sitemap.xml").read_text(encoding="utf-8")
        for name in self.PAGES:
            self.assertIn(f"{build.SITE}/{name}", sitemap, f"{name} missing from sitemap")

    def test_pages_have_a_canonical_and_one_h1(self) -> None:
        for name in self.PAGES:
            html = (self.out / name).read_text(encoding="utf-8")
            self.assertIn(f'rel="canonical" href="{build.SITE}/{name}"', html)
            self.assertEqual(len(re.findall(r"<h1[ >]", html)), 1, f"{name}: expected one h1")

    def test_structured_data_parses(self) -> None:
        import json
        for name in self.PAGES:
            html = (self.out / name).read_text(encoding="utf-8")
            blocks = re.findall(
                r'<script type="application/ld\+json">(.*?)</script>', html, re.S)
            self.assertTrue(blocks, f"{name}: no structured data")
            for block in blocks:
                data = json.loads(block)  # raises if malformed
                self.assertEqual(data["@type"], "FAQPage")
                self.assertTrue(data["mainEntity"], f"{name}: empty FAQ")

    def test_internal_links_resolve(self) -> None:
        for name in self.PAGES:
            html = (self.out / name).read_text(encoding="utf-8")
            for href in re.findall(r'href="([^"#]+)"', html):
                if href.startswith(("http://", "https://", "mailto:")):
                    continue
                target = href if href != "./" else "index.html"
                self.assertTrue((self.out / target).exists(),
                                f"{name} links to {href}, which is not in the build")

    def test_no_open_source_claim_without_a_licence(self) -> None:
        # The repository has no LICENSE file, so the app is source-available and
        # not open source. The pages are allowed to *discuss* open source — one
        # of them answers "is Obsidian open source?" — but never to assert it of
        # Inkstone. This catches the specific phrasings that would.
        forbidden = [
            "inkstone is open source",
            "inkstone is an open source",
            "inkstone is an open-source",
            "open source obsidian alternative for macos",
        ]
        licensed = any((ROOT / n).exists() for n in ("LICENSE", "LICENSE.md", "LICENSE.txt"))
        if licensed:
            self.skipTest("a licence exists now; the claim would be true")
        for name in self.PAGES:
            text = (self.out / name).read_text(encoding="utf-8").lower()
            for phrase in forbidden:
                self.assertNotIn(phrase, text, f"{name} claims to be open source")


class LLMsFile(BuiltSite):
    """`llms.txt` — the plain-text summary crawlers and assistants read."""

    def test_is_published(self) -> None:
        self.assertTrue((self.out / "llms.txt").is_file())

    def test_every_page_it_names_exists(self) -> None:
        text = (self.out / "llms.txt").read_text(encoding="utf-8")
        for url in re.findall(rf"{re.escape(build.SITE)}/([^)\s]*)", text):
            target = url or "index.html"
            self.assertTrue((self.out / target).exists(),
                            f"llms.txt names {url}, which is not in the build")
