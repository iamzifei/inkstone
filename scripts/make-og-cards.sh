#!/bin/bash
set -euo pipefail

# Renders the Open Graph cards through headless Chrome rather than compositing
# them with ImageMagick.
#
# The reason is the type. These cards are the site's first impression in a chat
# window or a timeline, and the whole argument the site makes is typographic — a
# card set in Georgia because that is what was installed would be arguing against
# itself. Chrome loads the same Source Serif and Source Han Serif the page does,
# applies the same optical sizing, and sets the mixed Han/Latin line with the
# same rules.
#
# Usage: ./scripts/make-og-cards.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/site/assets"
WORK="$(mktemp -d)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
trap 'rm -rf "$WORK"' EXIT

[ -x "$CHROME" ] || { echo "error: Google Chrome not found" >&2; exit 1; }

card() {  # card <slug> <font-css> <lang-attr> <cjk-stack> <headline> <sub> <h1-measure>
  cat > "$WORK/$1.html" <<HTML
<!doctype html><html lang="$3"><head><meta charset="utf-8">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="$2">
<style>
  * { box-sizing: border-box; margin: 0; }
  html, body { width: 1200px; height: 630px; }
  body {
    background: #FCFBF8; color: #1F1D1A;
    font-family: "Source Serif 4", $4, Charter, Georgia, serif;
    font-optical-sizing: auto;
    display: flex; flex-direction: column; justify-content: center;
    padding: 76px 88px;
    /* The same 3px rule that heads every section on the site, so the card and
       the page it links to are recognisably one object. */
    border-top: 14px solid #C0453B;
  }
  .mark { display: flex; align-items: center; gap: 16px; margin-bottom: 40px; }
  .mark img { width: 56px; height: 56px; border-radius: 12px; }
  .name { font-size: 34px; font-weight: 600; letter-spacing: -.01em; }
  .cjk { font-family: $4, serif; font-size: 24px; color: #78736A; letter-spacing: .24em; }
  h1 {
    font-size: 68px; font-weight: 400; line-height: 1.1; letter-spacing: -.026em;
    font-variation-settings: "opsz" 60; max-width: $7; text-wrap: balance;
  }
  p { margin-top: 28px; font-size: 27px; line-height: 1.5; color: #57534B; max-width: 34ch; }
  .foot {
    margin-top: auto; padding-top: 30px; border-top: 1px solid #E4E0D6;
    font-family: -apple-system, sans-serif; font-size: 19px; letter-spacing: .16em;
    text-transform: uppercase; color: #78736A;
  }
</style></head><body>
  <div class="mark">
    <img src="icon.png" alt="">
    <span class="name">Inkstone</span>
    <span class="cjk">墨砚</span>
  </div>
  <h1>$5</h1>
  <p>$6</p>
  <div class="foot">inkslab.app &nbsp;·&nbsp; macOS 26 &nbsp;·&nbsp; iOS 26</div>
</body></html>
HTML
  cp "$OUT/icon.png" "$WORK/icon.png"
  # --virtual-time-budget waits for the webfonts to arrive. Without it the card
  # is captured mid-fallback and ships set in Georgia, which is exactly the
  # failure this whole approach exists to avoid.
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --window-size=1200,630 --force-device-scale-factor=1 \
    --virtual-time-budget=8000 \
    --screenshot="$OUT/$1.png" "file://$WORK/$1.html" >/dev/null 2>&1
  echo "  $1.png  $(sips -g pixelWidth -g pixelHeight "$OUT/$1.png" | tail -2 | tr -d ' \n')"
}

LATIN_CSS="https://fonts.googleapis.com/css2?family=Source+Serif+4:opsz,wght@8..60,300..700&family=Noto+Serif+SC:wght@400;600&display=swap"

echo "==> Open Graph cards"
card og-card "$LATIN_CSS" en '"Noto Serif SC"' \
  "Your notes are files. They should stay that way." \
  "Plain Markdown on your own disk. Wikilinks, a graph, a canvas — native for macOS and iOS." \
  "17ch"

card og-card-zh "$LATIN_CSS" zh-Hans '"Noto Serif SC"' \
  "笔记本来就是文件，它就该一直是文件。" \
  "纯 Markdown，存在你自己选的文件夹里。双链、图谱、白板，原生 macOS 与 iOS。" \
  "14ch"
