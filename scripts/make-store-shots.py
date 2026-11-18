#!/usr/bin/env python3
"""Compose the App Store marketing screenshots.

    scripts/make-store-shots.py

Raw device captures show what the app looks like. These sell one idea each — the
distinction the App Store screenshot guidance keeps making, and the reason a
listing of six unadorned UI captures converts badly: nobody reads a screenshot,
they read the sentence above it and then glance at the picture for proof.

Rendered through headless Chrome rather than an image library, for the same
reason the Open Graph cards are: the whole argument this app makes is
typographic, so the captions have to be set in the real Source Serif with real
mixed-script spacing, not approximated by whatever font a compositor found.

Output lands at exactly the sizes Apple requires — 1320x2868 for the 6.9" iPhone
and 2064x2752 for the 13" iPad — so nothing is ever resized or padded, which is
the usual reason a screenshot upload is rejected.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "assets" / "ios-shots"
OUT = ROOT / "assets" / "store-shots"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Straight out of the app's Theme.swift, like the site and the OG cards. One
# cinnabar, ink on paper, nothing else.
PAPER, PAPER_2, INK, INK_2, CINNABAR = "#FCFBF8", "#F4F2EC", "#1F1D1A", "#57534B", "#C0453B"

FONTS = ("https://fonts.googleapis.com/css2"
         "?family=Source+Serif+4:opsz,wght@8..60,300..700"
         "&family=Noto+Serif+SC:wght@400;600&family=Noto+Serif+TC:wght@400;600&display=swap")

# One idea per slide, strongest first — the first two are the only ones most
# people will ever swipe to. Per language: the store shows each locale its own
# listing, so the captions and the app in the picture are in that language.
CAPTIONS = {
    "en": {
        "iphone": [
            ("02-live-preview", "Your notes are files.<br>They stay that way.",
             "Plain Markdown in a folder you choose. No database, no import."),
            ("03-typography", "中英文混排，<br>终于排对了。",
             "The gap between Han and Latin, set the way the standard asks for."),
            ("05-graph", "Links you never<br>planned, made visible.",
             "The same vault draws the same picture every time."),
            ("04-measure", "Every note knows<br>what points at it.",
             "Backlinks, block references, and links that have no target yet."),
            ("06-search", "Find a note before<br>you finish typing.",
             "Fuzzy over every note, and search that takes tag: and path:."),
            ("07-palette", "Every command,<br>a few letters away.",
             "Templates, export to PDF, and the rest — no menu hunting."),
            ("01-library", "A folder of Markdown.<br>That is the whole format.",
             "Open it in any other editor, on any device, forever."),
        ],
        "ipad": [
            ("01-live-preview", "The whole vault, beside the note.",
             "A split view that keeps your files where you can see them."),
            ("02-typography", "中英文混排，终于排对了。",
             "The gap between Han and Latin, set the way the standard asks for."),
            ("03-measure", "Every note knows what points at it.",
             "Backlinks and outgoing links, always in view."),
            ("04-project", "Diagrams and maths, in place.",
             "Mermaid and LaTeX render as you type — no plugin, no preview pane."),
            ("05-callout", "Callouts, quotes, tasks.",
             "GitHub Flavored Markdown, plus the Obsidian syntax you already use."),
            ("06-reading", "Reading mode, when you want the page.",
             "The same file, without the scaffolding."),
        ],
        "duo": [
            ("01-open", "Unfolded: the vault and the note, side by side.",
             "Made for iPhone Duo's inner screen."),
            ("02-half-open", "Half-open: the note on one side, its links on the other.",
             "Nothing is drawn across the crease."),
            ("03-graph", "Your notes, on a bigger page.",
             "The graph, the canvas and the editor use the whole inner screen."),
        ],
    },
    "zh-Hans": {
        "iphone": [
            ("02-live-preview", "笔记就是文件，<br>永远都是。",
             "纯 Markdown，放在你选的文件夹里。没有数据库，不用导入。"),
            ("03-typography", "中英文混排，<br>终于排对了。",
             "汉字与拉丁字母之间的间距，按标准排。"),
            ("05-graph", "没刻意建的联系，<br>一眼看见。",
             "同一个库，每次都画出同一张图。"),
            ("04-measure", "每条笔记都知道<br>谁在指向它。",
             "反向链接、块引用，还有尚无目标的链接。"),
            ("06-search", "没打完字，<br>笔记已经找到。",
             "模糊匹配全部笔记，搜索支持 tag: 和 path:。"),
            ("07-palette", "所有命令，<br>几个字就到。",
             "模板、导出 PDF……不用翻菜单。"),
            ("01-library", "一个 Markdown 文件夹，<br>这就是全部格式。",
             "换任何编辑器、任何设备都能打开，永远。"),
        ],
        "ipad": [
            ("01-live-preview", "整个库，就在笔记旁边。",
             "分栏视图，文件一直在你看得见的地方。"),
            ("02-typography", "中英文混排，终于排对了。",
             "汉字与拉丁字母之间的间距，按标准排。"),
            ("03-measure", "每条笔记都知道谁在指向它。",
             "反向链接和出链，始终在侧边。"),
            ("04-project", "图表和公式，就地渲染。",
             "Mermaid 与 LaTeX 边写边出，不用插件，不用预览窗。"),
            ("05-callout", "标注块、引用、任务。",
             "GitHub 风格 Markdown，加上你熟悉的 Obsidian 语法。"),
            ("06-reading", "想安静读的时候，用阅读模式。",
             "同一个文件，去掉脚手架。"),
        ],
        "duo": [
            ("01-open", "展开：库和笔记左右并排。",
             "为 iPhone Duo 内屏而做。"),
            ("02-half-open", "半开：笔记在一侧，链接在另一侧。",
             "折痕上什么都不画。"),
            ("03-graph", "你的笔记，摊在更大的纸上。",
             "关系图、白板和编辑器都用满整块内屏。"),
        ],
    },
    "zh-Hant": {
        "iphone": [
            ("02-live-preview", "筆記就是檔案，<br>永遠都是。",
             "純 Markdown，放在你選的資料夾裡。沒有資料庫，不用匯入。"),
            ("03-typography", "中英文混排，<br>終於排對了。",
             "漢字與拉丁字母之間的間距，照標準排。"),
            ("05-graph", "沒刻意建立的關聯，<br>一眼看見。",
             "同一個庫，每次都畫出同一張圖。"),
            ("04-measure", "每則筆記都知道<br>誰在指向它。",
             "反向連結、區塊引用，還有尚無目標的連結。"),
            ("06-search", "還沒打完字，<br>筆記已經找到。",
             "模糊比對全部筆記，搜尋支援 tag: 和 path:。"),
            ("07-palette", "所有命令，<br>幾個字就到。",
             "範本、匯出 PDF……不用翻選單。"),
            ("01-library", "一個 Markdown 資料夾，<br>這就是全部格式。",
             "換任何編輯器、任何裝置都能打開，永遠。"),
        ],
        "ipad": [
            ("01-live-preview", "整個庫，就在筆記旁邊。",
             "分欄檢視，檔案一直在你看得見的地方。"),
            ("02-typography", "中英文混排，終於排對了。",
             "漢字與拉丁字母之間的間距，照標準排。"),
            ("03-measure", "每則筆記都知道誰在指向它。",
             "反向連結和外連，始終在側邊。"),
            ("04-project", "圖表和公式，就地呈現。",
             "Mermaid 與 LaTeX 邊寫邊出，不用外掛，不用預覽窗。"),
            ("05-callout", "標註區塊、引用、待辦。",
             "GitHub 風格 Markdown，加上你熟悉的 Obsidian 語法。"),
            ("06-reading", "想安靜讀的時候，用閱讀模式。",
             "同一個檔案，拿掉鷹架。"),
        ],
        "duo": [
            ("01-open", "展開：庫和筆記左右並排。",
             "為 iPhone Duo 內螢幕而做。"),
            ("02-half-open", "半開：筆記在一側，連結在另一側。",
             "摺痕上什麼都不畫。"),
            ("03-graph", "你的筆記，攤在更大的紙上。",
             "關係圖、白板和編輯器都用滿整塊內螢幕。"),
        ],
    },
}
# Where fastlane looks for each language's screenshots.
FASTLANE_LOCALE = {"en": "en-US", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant"}


def page(shot: Path, title: str, subtitle: str, w: int, h: int, pad: int,
         title_px: int, sub_px: int, radius: int, lang: str = "en", device: float = 0.84) -> str:
    """One slide. The caption gets the top third; the device fills the rest."""
    cjk_font = '"Noto Serif TC"' if lang == "zh-Hant" else '"Noto Serif SC"'
    return f"""<!doctype html><html lang="{lang}"><head><meta charset="utf-8">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="{FONTS}">
<style>
  * {{ box-sizing: border-box; margin: 0; }}
  html, body {{ width: {w}px; height: {h}px; }}
  body {{
    background: {PAPER};
    /* A cinnabar hairline across the top, the same device the site uses to
       head a section. It is the only ornament on the page. */
    border-top: {max(8, w // 110)}px solid {CINNABAR};
    font-family: "Source Serif 4", {cjk_font}, Georgia, serif;
    font-optical-sizing: auto;
    display: flex; flex-direction: column; align-items: center;
    padding: {pad}px {pad}px 0;
    overflow: hidden;
  }}
  h1 {{
    font-size: {title_px}px; line-height: 1.08; font-weight: 400;
    letter-spacing: -0.025em; color: {INK}; text-align: center;
    font-variation-settings: "opsz" 60;
    text-autospace: normal;
    text-wrap: balance;
  }}
  p {{
    margin-top: {int(title_px * 0.42)}px;
    font-size: {sub_px}px; line-height: 1.5; color: {INK_2};
    text-align: center; max-width: {int(w * 0.72)}px;
    text-autospace: normal;
    /* Balanced, or the second line ends up carrying one orphaned word — which
       on a listing whose second slide is about typography is not a detail. */
    text-wrap: balance;
  }}
  .device {{
    margin-top: {int(title_px * 0.75)}px;
    width: {int(w * device)}px;
    border-radius: {radius}px;
    overflow: hidden;
    background: {PAPER_2};
    /* Lifted off the page rather than floated on it — a hairline plus one soft
       shadow, so the screenshot reads as an object on paper. */
    border: 1px solid rgba(31,29,26,.10);
    box-shadow: 0 2px 6px rgba(31,29,26,.06), 0 {int(w*0.03)}px {int(w*0.07)}px -{int(w*0.02)}px rgba(31,29,26,.22);
  }}
  .device img {{ display: block; width: 100%; }}
</style></head><body>
  <h1>{title}</h1>
  <p>{subtitle}</p>
  <div class="device"><img src="{shot.name}"></div>
</body></html>"""


def render(spec, w, h, pad, title_px, sub_px, radius, out_dir: Path, raw: Path, lang: str, device: float = 0.84) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    for index, (name, title, subtitle) in enumerate(spec, start=1):
        source = raw / f"{name}.png"
        if not source.exists():
            sys.exit(f"missing raw screenshot: {source}")

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            shutil.copyfile(source, work / source.name)
            (work / "slide.html").write_text(
                page(source, title, subtitle, w, h, pad, title_px, sub_px, radius, lang, device),
                encoding="utf-8")

            target = out_dir / f"{index:02d}-{Path(name).name}.png"
            subprocess.run([
                CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                f"--window-size={w},{h}", "--force-device-scale-factor=1",
                # Without a virtual-time budget the shot is taken mid-fallback
                # and ships set in Georgia, which on this listing would be
                # arguing against its own second slide.
                "--virtual-time-budget=9000",
                f"--screenshot={target}", f"file://{work / 'slide.html'}",
            ], check=True, capture_output=True)

            size = subprocess.run(
                ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(target)],
                capture_output=True, text=True).stdout.split()
            got = (int(size[size.index("pixelWidth:") + 1]),
                   int(size[size.index("pixelHeight:") + 1]))
            if got != (w, h):
                sys.exit(f"{target.name}: rendered {got}, needed {(w, h)}")
            print(f"  {target.name}  {got[0]}x{got[1]}")


def main() -> int:
    if not Path(CHROME).exists():
        sys.exit("Google Chrome not found")
    langs = sys.argv[1:] or list(CAPTIONS)
    for lang in langs:
        raw = RAW / lang
        out = OUT / lang
        sets = CAPTIONS[lang]
        print(f"==> {lang}: iPhone 6.9\"")
        render(sets["iphone"], 1320, 2868, pad=96, title_px=104, sub_px=52, radius=44,
               out_dir=out / "iphone", raw=raw / "iphone", lang=lang)
        print(f"==> {lang}: iPad 13\"")
        render(sets["ipad"], 2064, 2752, pad=150, title_px=132, sub_px=66, radius=40,
               out_dir=out / "ipad", raw=raw / "ipad", lang=lang)
        # The inner screen of iPhone Duo, at its native size: App Store
        # Connect's APP_IPHONE_DUO slot. Uploaded by Tools/upload-duo-shots.py,
        # since fastlane does not know the size.
        print(f"==> {lang}: iPhone Duo")
        # Unfolded, the inner screen is landscape.
        render(sets["duo"], 2853, 2007, pad=110, title_px=104, sub_px=52, radius=36,
               out_dir=out / "duo", raw=raw / "duo", lang=lang, device=0.66)
        # fastlane picks the device from the image size; iPad files need
        # "ipad" in the name only for ordering clarity.
        target = ROOT / "fastlane" / "screenshots" / FASTLANE_LOCALE[lang]
        if target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True)
        for f in sorted((out / "iphone").glob("*.png")):
            shutil.copyfile(f, target / f"iphone-{f.name}")
        for f in sorted((out / "ipad").glob("*.png")):
            shutil.copyfile(f, target / f"ipad-{f.name}")
        print(f"    → {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
