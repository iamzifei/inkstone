#!/usr/bin/env python3
"""Build the Inkstone website from per-language content files into site/_site/.

Structure lives here, copy lives in site/content/<lang>/index.yml. That split is
the point: eight languages of a hand-written page drift structurally — one of
them loses a section, another keeps a feature that was renamed — and the drift is
invisible until someone who reads that language looks. Here every language is
poured through the same template, so a missing key is a build error rather than a
missing paragraph nobody notices for a year.

The head tags, hreflang graph, sitemap, robots.txt, CNAME and asset fingerprints
are all computed from SITE and the content tree, so no URL in the output is ever
typed by hand.

Usage:  python3 site/build.py            build into site/_site
        python3 site/build.py --check    build to a temp dir and diff, for CI
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

import yaml

from typeset import autospace

ROOT = Path(__file__).resolve().parent.parent
CONTENT = ROOT / "site" / "content"
OUT = ROOT / "site" / "_site"

# Registered 2026-08-20. `inkstone` is the English for 砚 — an ink slab — so the
# name is a translation rather than a near-miss: inkstone.com/.app/.io/.dev were
# all taken, and inkstone.md, the one a Markdown app actually wants, had been
# registered three weeks earlier on 2026-07-31.
SITE = "https://inkslab.app"
REPO = "https://github.com/iamzifei/inkstone"
KOFI = "https://ko-fi.com/james_ai/tip"

# v0.1.0 shipped 2026-08-20: signed, notarised, stapled, and Gatekeeper-accepted.
# The URL is the `latest` alias rather than a pinned tag, so cutting the next
# release does not require touching the site. Every release must therefore keep
# naming its asset `Inkstone.dmg`.
HAS_RELEASE = True
DOWNLOAD = f"{REPO}/releases/latest/download/Inkstone.dmg"

# The other three macOS apps. Someone who liked one is the likeliest person to
# want another, which is why each site links to the rest rather than to a
# portfolio page nobody visits.
SIBLINGS = [
    ("AudioSwitch", "https://audioswitch.dev"),
    ("Candela", "https://getcandela.app"),
    ("ClipStack", "https://getclipstack.app"),
]

# BCP 47, because that is what hreflang takes. The default language lives at the
# site root, so its URLs carry no prefix at all.
LANGS = {
    "en": {"hreflang": "en", "dir": "", "label": "English", "locale": "en_US"},
    "zh": {"hreflang": "zh-Hans", "dir": "zh/", "label": "简体中文", "locale": "zh_CN"},
    "zh-Hant": {"hreflang": "zh-Hant", "dir": "zh-Hant/", "label": "繁體中文", "locale": "zh_TW"},
    "ja": {"hreflang": "ja", "dir": "ja/", "label": "日本語", "locale": "ja_JP"},
    "ko": {"hreflang": "ko", "dir": "ko/", "label": "한국어", "locale": "ko_KR"},
    "de": {"hreflang": "de", "dir": "de/", "label": "Deutsch", "locale": "de_DE"},
    "fr": {"hreflang": "fr", "dir": "fr/", "label": "Français", "locale": "fr_FR"},
    "es": {"hreflang": "es", "dir": "es/", "label": "Español", "locale": "es_ES"},
}
DEFAULT_LANG = "en"

# Languages whose script needs the CJK webfont. Loading a 20 MB serif for a
# German reader who will never see a Han glyph is the kind of cost that only
# shows up on someone else's connection.
CJK_LANGS = {"zh", "zh-Hant", "ja", "ko"}

# Google Fonts CSS endpoints, per script. Source Serif and Source Han Serif were
# drawn to sit together — Source Han's Latin *is* Source Serif — so the mixed
# line is set in one designer's idea of a serif rather than two.
FONT_CSS = {
    None: "https://fonts.googleapis.com/css2?family=Source+Serif+4:opsz,wght@8..60,300..700&display=swap",
    "zh": "https://fonts.googleapis.com/css2?family=Source+Serif+4:opsz,wght@8..60,300..700&family=Noto+Serif+SC:wght@300;400;600&display=swap",
    "zh-Hant": "https://fonts.googleapis.com/css2?family=Source+Serif+4:opsz,wght@8..60,300..700&family=Noto+Serif+TC:wght@300;400;600&display=swap",
    "ja": "https://fonts.googleapis.com/css2?family=Source+Serif+4:opsz,wght@8..60,300..700&family=Noto+Serif+JP:wght@300;400;600&display=swap",
    "ko": "https://fonts.googleapis.com/css2?family=Source+Serif+4:opsz,wght@8..60,300..700&family=Noto+Serif+KR:wght@300;400;600&display=swap",
}

# Screenshots, in the order the page shows them. The keys are the YAML keys each
# language fills in with a title, body and alt text; the values are the files in
# site/assets/shots/. Listing them here rather than in the content means a
# translator cannot accidentally point a caption at the wrong picture.
FEATURE_SHOTS = [
    ("live_preview", "live-preview"),
    ("links", "backlinks"),
    ("graph", "graph"),
    ("canvas", "canvas"),
    ("search", "quickswitcher"),
    ("sync", "sync"),
]


@dataclass
class Page:
    lang: str
    slug: str
    data: dict

    @property
    def path(self) -> str:
        prefix = LANGS[self.lang]["dir"]
        return prefix if self.slug == "index" else f"{prefix}{self.slug}.html"

    @property
    def url(self) -> str:
        return f"{SITE}/{self.path}"

    @property
    def out_file(self) -> Path:
        prefix = LANGS[self.lang]["dir"]
        name = "index.html" if self.slug == "index" else f"{self.slug}.html"
        return OUT / prefix / name

    @property
    def depth(self) -> int:
        """How many directories deep, so relative asset links resolve."""
        return 1 if LANGS[self.lang]["dir"] else 0

    @property
    def up(self) -> str:
        return "../" if self.depth else ""


def e(value) -> str:
    """Escape for use as text or in an attribute."""
    return html.escape(str(value), quote=True)


def get(data: dict, path: str):
    """Fetch a dotted key, failing loudly rather than rendering an empty page.

    A KeyError here stops the build with the language and the missing key. The
    alternative — `.get()` with a default — is how a translation ends up shipping
    with a blank headline that reads as a design choice.
    """
    node = data
    for part in path.split("."):
        if not isinstance(node, dict) or part not in node:
            raise KeyError(path)
        node = node[part]
    return node


# ----------------------------------------------------------------- assets

def asset_hash(rel: str) -> str:
    """Short content hash of a file in site/, appended to its URL.

    Without it a returning visitor keeps whatever CSS their browser cached,
    which is how a fixed style stays broken for exactly the people who have been
    here before.
    """
    path = ROOT / "site" / rel
    if not path.exists():
        return "0"
    return hashlib.sha256(path.read_bytes()).hexdigest()[:8]


def read_shot_sizes() -> dict[str, tuple[int, int, list[int]]]:
    """Intrinsic sizes of the screenshots, written by scripts/capture-site-shots.sh.

    Read from a manifest rather than measured here, so building the site needs no
    image tooling and CI can check it without ImageMagick installed.
    """
    manifest = ROOT / "site" / "assets" / "shots" / "manifest.txt"
    if not manifest.exists():
        return {}
    sizes = {}
    for line in manifest.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) >= 3:
            sizes[parts[0]] = (int(parts[1]), int(parts[2]),
                               [int(w) for w in parts[3:]])
    return sizes


SHOT_SIZES: dict[str, tuple[int, int, list[int]]] = {}


def shot_img(name: str, alt: str, up: str, sizes_attr: str, eager: bool = False) -> str:
    """One screenshot, with its intrinsic size and a srcset from the manifest.

    Intrinsic width/height come from the manifest rather than the template, so
    the browser reserves a box of the right shape before the picture lands and
    the text below it does not jump. Re-shooting the screenshots updates the
    numbers by rebuilding.
    """
    entry = SHOT_SIZES.get(f"{name}.webp")
    src = f"{up}assets/shots/{name}.webp"
    if not entry:
        return f'<img src="{src}" alt="{e(alt)}" loading="lazy" decoding="async">'
    width, height, variants = entry
    loading = ('loading="eager" fetchpriority="high"' if eager else 'loading="lazy"')
    srcset = ", ".join([f"{up}assets/shots/{name}-{w}.webp {w}w" for w in variants]
                       + [f"{src} {width}w"])
    return (f'<img src="{src}" srcset="{srcset}" sizes="{sizes_attr}" '
            f'width="{width}" height="{height}" alt="{e(alt)}" {loading} decoding="async">')


# ----------------------------------------------------------------- chrome

def lang_picker(page: Page, by_slug: dict, css_class: str) -> str:
    """Every language, each pointing at this page.

    Written as links rather than a <select>: they are crawlable, they work with
    JavaScript off, and the footer copy of the list is what tells a search engine
    the other languages exist at all.
    """
    items = []
    for lang, meta in LANGS.items():
        if lang == page.lang:
            items.append(f'<span class="lang-current" aria-current="true">{meta["label"]}</span>')
            continue
        target = by_slug.get((lang, page.slug)) or by_slug.get((lang, "index"))
        if not target:
            continue
        items.append(
            f'<a class="lang" href="{SITE}/{target.path}" hreflang="{meta["hreflang"]}"'
            f' data-lang="{lang}">{meta["label"]}</a>'
        )
    return (f'<nav class="{css_class}" aria-label="Language">' + "".join(items) + "</nav>")


def cta(page: Page, primary: bool = True) -> str:
    d = page.data
    if HAS_RELEASE:
        href, label = DOWNLOAD, get(d, "cta.download")
    else:
        href, label = REPO, get(d, "cta.source")
    cls = "btn btn-primary" if primary else "btn btn-quiet"
    return f'<a class="{cls}" href="{e(href)}">{e(label)}</a>'


def nav(page: Page, by_slug: dict) -> str:
    d = page.data
    up = page.up
    home = up if page.depth else "./"
    return f"""<a class="skip" href="#main">{e(get(d, 'nav.skip'))}</a>
<header class="nav" id="nav">
  <div class="nav-inner">
    <a class="wordmark" href="{home}">
      <img src="{up}assets/icon.png" alt="" width="28" height="28">
      <span class="wordmark-name">Inkstone</span>
      <span class="wordmark-cjk" aria-hidden="true">墨砚</span>
    </a>
    <nav class="nav-links" aria-label="{e(get(d, 'nav.label'))}">
      <a href="#features">{e(get(d, 'nav.features'))}</a>
      <a href="#typography">{e(get(d, 'nav.typography'))}</a>
      <a href="#specs">{e(get(d, 'nav.specs'))}</a>
      <a href="{REPO}" rel="noopener">GitHub</a>
      <details class="lang-menu">
        <summary aria-label="Language">{LANGS[page.lang]['label']}</summary>
        {lang_picker(page, by_slug, "lang-menu-list")}
      </details>
      {cta(page)}
    </nav>
  </div>
</header>"""


def footer(page: Page, by_slug: dict) -> str:
    d = page.data
    sibs = "".join(
        f'<li><a href="{url}" rel="noopener">'
        f'<img src="{page.up}assets/{name.lower()}.png" alt="" width="28" height="28" '
        f'loading="lazy" decoding="async">'
        f'<span class="sib-text"><span class="sib-name">{name}</span>'
        f'<span class="sib-note">{e(get(d, f"siblings.{name.lower()}"))}</span></span></a></li>'
        for name, url in SIBLINGS
    )
    return f"""<footer class="site-footer">
  <div class="footer-grid">
    <div class="footer-brand">
      <img src="{page.up}assets/icon.png" alt="" width="32" height="32">
      <p class="footer-tagline">{e(get(d, 'footer.tagline'))}</p>
    </div>
    <div class="footer-col">
      <h2 class="footer-h">{e(get(d, 'footer.project'))}</h2>
      <ul>
        <li><a href="{REPO}" rel="noopener">GitHub</a></li>
        <li><a href="{REPO}/issues" rel="noopener">{e(get(d, 'footer.issues'))}</a></li>
        <li><a href="{KOFI}" rel="noopener">Ko-fi</a></li>
      </ul>
    </div>
    <div class="footer-col footer-siblings">
      <h2 class="footer-h">{e(get(d, 'footer.also'))}</h2>
      <ul>{sibs}</ul>
    </div>
  </div>
  {lang_picker(page, by_slug, "footer-langs")}
  <p class="colophon">{e(get(d, 'footer.colophon'))}</p>
</footer>"""


# ----------------------------------------------------------------- sections

def hero(page: Page) -> str:
    d = page.data
    up = page.up
    poster = f"{up}assets/video/poster.webp"
    return f"""<section class="hero">
  <p class="eyebrow">{e(get(d, 'hero.eyebrow'))}</p>
  <h1 class="hero-title">{e(get(d, 'hero.title'))}</h1>
  <p class="hero-lede">{e(get(d, 'hero.lede'))}</p>
  <div class="hero-actions">
    {cta(page)}
    <a class="btn btn-quiet" href="#features">{e(get(d, 'cta.tour'))}</a>
  </div>
  <p class="hero-note">{e(get(d, 'hero.note'))}</p>
  <figure class="film">
    <div class="film-mat">
      <video class="film-frame" poster="{poster}" autoplay muted loop playsinline
             preload="metadata" aria-label="{e(get(d, 'hero.video_alt'))}">
        <source src="{up}assets/video/hero.webm" type="video/webm">
        <source src="{up}assets/video/hero.mp4" type="video/mp4">
      </video>
    </div>
    <figcaption>{e(get(d, 'hero.video_caption'))}</figcaption>
  </figure>
</section>"""


def creed(page: Page) -> str:
    """The three-column argument under the hero, set like a leader column."""
    d = page.data
    cols = "".join(
        f'<div class="creed-col reveal"><h3>{e(c["title"])}</h3><p>{e(c["body"])}</p></div>'
        for c in get(d, "creed.columns")
    )
    return f"""<section class="creed" aria-labelledby="creed-h">
  <div class="rule-head">
    <h2 id="creed-h">{e(get(d, 'creed.title'))}</h2>
    <p class="rule-sub">{e(get(d, 'creed.sub'))}</p>
  </div>
  <div class="creed-cols">{cols}</div>
</section>"""


def features(page: Page) -> str:
    d = page.data
    rows = []
    for i, (key, shot) in enumerate(FEATURE_SHOTS):
        f = get(d, f"features.items.{key}")
        side = "left" if i % 2 == 0 else "right"
        img = shot_img(shot, f["alt"], page.up,
                       "(max-width: 900px) 92vw, 620px", eager=(i == 0))
        rows.append(f"""<article class="feat feat-{side} reveal">
  <div class="feat-text">
    <p class="kicker">{e(f['kicker'])}</p>
    <h3>{e(f['title'])}</h3>
    <p>{e(f['body'])}</p>
  </div>
  <figure class="feat-shot">{img}</figure>
</article>""")
    return f"""<section class="features" id="features" aria-labelledby="features-h">
  <div class="rule-head">
    <h2 id="features-h">{e(get(d, 'features.title'))}</h2>
    <p class="rule-sub">{e(get(d, 'features.sub'))}</p>
  </div>
  {''.join(rows)}
</section>"""


def typography(page: Page) -> str:
    """The specimen. Set as a book page, because the claim is about book pages.

    Everything here is live text rather than a picture of text: it is the one
    section whose subject is the rendering, so a screenshot of it would be
    arguing by assertion.
    """
    d = page.data
    notes = "".join(
        f'<div class="spec-note"><dt>{e(n["term"])}</dt><dd>{e(n["def"])}</dd></div>'
        for n in get(d, "typography.notes")
    )
    return f"""<section class="typo" id="typography" aria-labelledby="typo-h">
  <div class="rule-head">
    <h2 id="typo-h">{e(get(d, 'typography.title'))}</h2>
    <p class="rule-sub">{e(get(d, 'typography.sub'))}</p>
  </div>
  <div class="specimen reveal">
    <p class="specimen-folio">{e(get(d, 'typography.folio'))}</p>
    <h3 class="specimen-h">{e(get(d, 'typography.specimen_title'))}</h3>
    <p class="specimen-lead">{e(get(d, 'typography.specimen_lead'))}</p>
    <p class="specimen-body">{e(get(d, 'typography.specimen_body'))}</p>
    <blockquote class="specimen-quote">
      <p>{e(get(d, 'typography.specimen_quote'))}</p>
      <cite>{e(get(d, 'typography.specimen_cite'))}</cite>
    </blockquote>
  </div>
  <dl class="spec-notes">{notes}</dl>
</section>"""


def specs(page: Page) -> str:
    d = page.data
    rows = "".join(
        f'<tr><th scope="row">{e(r["k"])}</th><td>{e(r["v"])}</td></tr>'
        for r in get(d, "specs.rows")
    )
    return f"""<section class="specs" id="specs" aria-labelledby="specs-h">
  <div class="rule-head">
    <h2 id="specs-h">{e(get(d, 'specs.title'))}</h2>
    <p class="rule-sub">{e(get(d, 'specs.sub'))}</p>
  </div>
  <table class="spec-table reveal"><tbody>{rows}</tbody></table>
  <div class="closer reveal">
    <p class="closer-line">{e(get(d, 'specs.closer'))}</p>
    <div class="hero-actions">{cta(page)}
      <a class="btn btn-quiet" href="{KOFI}" rel="noopener">{e(get(d, 'cta.kofi'))}</a></div>
  </div>
</section>"""


# ----------------------------------------------------------------- document

def json_ld(page: Page) -> str:
    d = page.data
    app = {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "name": "Inkstone",
        "alternateName": "墨砚",
        "applicationCategory": "ProductivityApplication",
        "operatingSystem": "macOS 26, iOS 26",
        "url": page.url,
        "description": get(d, "description"),
        "inLanguage": LANGS[page.lang]["hreflang"],
        "isAccessibleForFree": True,
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
        "author": {"@type": "Person", "name": "James Gong", "url": "https://github.com/iamzifei"},
    }
    if HAS_RELEASE:
        app["downloadUrl"] = DOWNLOAD
    return ('<script type="application/ld+json">'
            + json.dumps(app, ensure_ascii=False, separators=(",", ":"))
            + "</script>")


def head(page: Page, by_slug: dict) -> str:
    d = page.data
    up = page.up
    title = e(get(d, "title"))
    desc = e(get(d, "description"))
    og = "og-card-zh.png" if page.lang in CJK_LANGS else "og-card.png"
    alts = "\n".join(
        f'<link rel="alternate" hreflang="{LANGS[l]["hreflang"]}" href="{p.url}">'
        for (l, s), p in sorted(by_slug.items()) if s == page.slug
    )
    default = by_slug.get((DEFAULT_LANG, page.slug))
    font_css = FONT_CSS.get(page.lang if page.lang in CJK_LANGS else None)
    return f"""<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{desc}">
<meta name="theme-color" content="#FCFBF8" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#16161A" media="(prefers-color-scheme: dark)">
<link rel="canonical" href="{page.url}">
{alts}
<link rel="alternate" hreflang="x-default" href="{default.url if default else page.url}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Inkstone">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{desc}">
<meta property="og:url" content="{page.url}">
<meta property="og:image" content="{SITE}/assets/{og}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:locale" content="{LANGS[page.lang]['locale']}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{title}">
<meta name="twitter:description" content="{desc}">
<meta name="twitter:image" content="{SITE}/assets/{og}">
<link rel="icon" href="{up}assets/icon.png">
<link rel="apple-touch-icon" href="{up}assets/icon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="{font_css}">
<link rel="stylesheet" href="{up}assets/styles.css?v={asset_hash('assets/styles.css')}">
{json_ld(page)}"""


# Sends a first-time visitor to the page in their own language, once, and never
# again. Without the memory it would fight anyone who deliberately picks English:
# they would land on English and be bounced straight back to Chinese.
LANG_REDIRECT = """<script>
(function () {
  try {
    if (localStorage.getItem('inkstone-lang')) return;
    var urls = LANG_URLS;
    var wanted = navigator.languages || [navigator.language || ''];
    for (var i = 0; i < wanted.length; i++) {
      var tag = String(wanted[i]).toLowerCase();
      var pick = tag.indexOf('zh') === 0
        ? (/hant|tw|hk|mo/.test(tag) ? 'zh-Hant' : 'zh')
        : tag.split('-')[0];
      if (pick === 'en') return;
      if (urls[pick]) {
        localStorage.setItem('inkstone-lang', pick);
        location.replace(urls[pick]);
        return;
      }
    }
  } catch (e) {}
})();
</script>"""


def render(page: Page, by_slug: dict) -> str:
    body = "\n".join([
        hero(page), creed(page), features(page), typography(page), specs(page),
    ])
    # One pass, over the assembled body only. Running it over the whole document
    # would put spans inside <title> and the JSON-LD, where they are text rather
    # than markup and would be shown to the reader as literal angle brackets.
    body = autospace(body)

    redirect = ""
    if page.lang == DEFAULT_LANG:
        urls = {l: f"{SITE}/{(by_slug.get((l, page.slug)) or by_slug[(l, 'index')]).path}"
                for l in LANGS if l != DEFAULT_LANG and
                (by_slug.get((l, page.slug)) or by_slug.get((l, "index")))}
        if urls:
            redirect = LANG_REDIRECT.replace(
                "LANG_URLS", json.dumps(urls, separators=(",", ":")))

    lang_attr = LANGS[page.lang]["hreflang"]
    script = f'<script src="{page.up}assets/site.js?v={asset_hash("assets/site.js")}" defer></script>'
    return f"""<!doctype html>
<html lang="{lang_attr}" data-lang="{page.lang}">
<head>
{head(page, by_slug)}
{redirect}
</head>
<body>
{nav(page, by_slug)}
<main class="wrap" id="main">
{body}
</main>
{footer(page, by_slug)}
{script}
</body>
</html>
"""


# ----------------------------------------------------------------- build

def read_pages() -> list[Page]:
    pages: list[Page] = []
    for lang in LANGS:
        directory = CONTENT / lang
        if not directory.exists():
            sys.exit(f"missing content directory: {directory}")
        for src in sorted(directory.glob("*.yml")):
            data = yaml.safe_load(src.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                sys.exit(f"{src}: expected a mapping at the top level")
            pages.append(Page(lang, src.stem, data))
    return pages


def sitemap(pages: list[Page]) -> str:
    entries = "\n".join(
        f"  <url><loc>{p.url}</loc><changefreq>monthly</changefreq></url>"
        for p in sorted(pages, key=lambda p: p.url)
    )
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
            f"{entries}\n</urlset>\n")


def build(out: Path) -> None:
    global SHOT_SIZES
    SHOT_SIZES = read_shot_sizes()
    pages = read_pages()
    by_slug = {(p.lang, p.slug): p for p in pages}

    # A page that exists in one language only would emit an hreflang pointing at
    # a 404, which search engines treat worse than an honest absence.
    slugs = {p.slug for p in pages}
    missing = [f"{lang}/{slug}" for lang in LANGS for slug in sorted(slugs)
               if (lang, slug) not in by_slug]
    if missing:
        sys.exit("every page must exist in every language; missing: " + ", ".join(missing))

    for p in pages:
        try:
            rendered = render(p, by_slug)
        except KeyError as exc:
            sys.exit(f"{p.lang}/{p.slug}.yml: missing key {exc.args[0]}")
        target = out / p.out_file.relative_to(OUT)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(rendered, encoding="utf-8")

    # Copied rather than symlinked: GitHub Pages serves the tree as it finds it
    # and does not follow links.
    assets_src = ROOT / "site" / "assets"
    if assets_src.exists():
        shutil.copytree(assets_src, out / "assets", dirs_exist_ok=True)
    # The manifest is a build input, not something a visitor should be served.
    manifest = out / "assets" / "shots" / "manifest.txt"
    if manifest.exists():
        manifest.unlink()

    # Verbatim pages. These sit outside the eight-language system on purpose:
    # build.py requires every *marketing* page to exist in every language so a
    # dropped translation is a build error, and a privacy policy that Apple
    # requires in one language should not be held hostage to that rule.
    static = ROOT / "site" / "static"
    if static.exists():
        for item in sorted(static.iterdir()):
            if item.is_file():
                shutil.copyfile(item, out / item.name)

    # Sparkle's update feed. It lives at the repository root because that is
    # where Tools/release.sh writes it, and it is published from here because the
    # app's SUFeedURL points at https://inkslab.app/appcast.xml — the site is a
    # stabler address than a branch on GitHub.
    appcast = ROOT / "appcast.xml"
    if appcast.exists():
        shutil.copyfile(appcast, out / "appcast.xml")

    (out / "sitemap.xml").write_text(sitemap(pages), encoding="utf-8")
    (out / "robots.txt").write_text(
        f"User-agent: *\nAllow: /\nSitemap: {SITE}/sitemap.xml\n", encoding="utf-8")
    # GitHub Pages runs Jekyll by default, which drops files beginning with an
    # underscore and rewrites others unpredictably. This turns it off.
    (out / ".nojekyll").write_text("", encoding="utf-8")
    (out / "CNAME").write_text(SITE.removeprefix("https://") + "\n", encoding="utf-8")

    # A fingerprint of everything published, so the deploy wait can compare one
    # file and still notice a deletion — the case a list of named files misses.
    digest = hashlib.sha256()
    for path in sorted(out.rglob("*")):
        if path.is_dir() or path.name == "build-id.txt":
            continue
        digest.update(str(path.relative_to(out)).encode())
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    (out / "build-id.txt").write_text(digest.hexdigest() + "\n", encoding="utf-8")

    print(f"built {len(pages)} pages in {len(LANGS)} languages into {out}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="build to a temp dir and diff against site/_site")
    args = ap.parse_args()

    if not args.check:
        OUT.mkdir(parents=True, exist_ok=True)
        build(OUT)
        return 0

    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp) / "site"
        # Start from what is committed, then build over it, so the fingerprint
        # compares like with like. Building into an empty directory made every
        # check fail on the fingerprint file alone.
        shutil.copytree(OUT, tmpdir)
        build(tmpdir)
        stale = [str(b.relative_to(tmpdir)) for b in tmpdir.rglob("*")
                 if not b.is_dir() and (not (OUT / b.relative_to(tmpdir)).exists()
                 or (OUT / b.relative_to(tmpdir)).read_bytes() != b.read_bytes())]
        if stale:
            print("site/_site is out of date — run python3 site/build.py")
            for s in stale:
                print("  " + s)
            return 1
    print("site/_site matches site/content")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
