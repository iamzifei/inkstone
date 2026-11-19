#!/usr/bin/env python3
"""A deterministic vault for main-thread stall benchmarks (scripts/bench-stalls.sh).

    scripts/make-bench-vault.py <dir> [notes=3000]

What it holds, chosen to exercise the paths the jank audit pointed at:
  - <notes> notes in 40 folders, each with tags, wikilinks to 5 others and a
    few paragraphs (index, backlinks, tree);
  - Long/Long-1..3.md — ~60 KB notes (editor styling, layout on open);
  - Images/Gallery.md — embeds 12 full-size 2400x1600 PNGs (image decoding);
  - Switch/A..H.md — mid-sized notes the benchmark flips between.
Same seed, same vault: numbers from two runs are comparable.
"""
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw

out = Path(sys.argv[1])
count = int(sys.argv[2]) if len(sys.argv) > 2 else 3000
rng = random.Random(20261120)
words = ("note link vault index graph canvas river stone ink paper light shadow "
         "reason measure quiet window garden letter field echo morning thread").split()


def para(n: int) -> str:
    return " ".join(rng.choice(words) for _ in range(n)).capitalize() + "."


out.mkdir(parents=True, exist_ok=True)
names = [f"Note {i:05d}" for i in range(count)]
for i, name in enumerate(names):
    folder = out / f"Area {i % 40:02d}"
    folder.mkdir(exist_ok=True)
    links = " ".join(f"[[{rng.choice(names)}]]" for _ in range(5))
    tags = " ".join(f"#{rng.choice(words)}/{rng.choice(words)}" for _ in range(3))
    body = "\n\n".join(para(rng.randint(30, 80)) for _ in range(4))
    (folder / f"{name}.md").write_text(f"# {name}\n\n{tags}\n\n{body}\n\n## Links\n\n{links}\n", encoding="utf-8")

(out / "Long").mkdir(exist_ok=True)
for k in range(4):
    sections = []
    for s in range(60):
        sections.append(f"## Section {s}\n\n" + "\n\n".join(
            f"- [ ] {para(8)}" if j % 5 == 0 else f"**{rng.choice(words)}** {para(25)} [[{rng.choice(names)}]] `code`"
            for j in range(6)))
    name = "Long" if k == 0 else f"Long-{k}"
    (out / "Long" / f"{name}.md").write_text(f"# {name}\n\n" + "\n\n".join(sections), encoding="utf-8")

images = out / "Images"
images.mkdir(exist_ok=True)
embeds = []
for k in range(12):
    img = Image.new("RGB", (2400, 1600), (rng.randrange(256), rng.randrange(256), rng.randrange(256)))
    draw = ImageDraw.Draw(img)
    for _ in range(300):
        x, y = rng.randrange(2400), rng.randrange(1600)
        draw.ellipse((x, y, x + rng.randrange(20, 200), y + rng.randrange(20, 200)),
                     fill=(rng.randrange(256), rng.randrange(256), rng.randrange(256)))
    img.save(images / f"photo-{k:02d}.png")
    embeds.append(f"![[photo-{k:02d}.png]]\n\n{para(20)}")
(images / "Gallery.md").write_text("# Gallery\n\n" + "\n\n".join(embeds), encoding="utf-8")

switch = out / "Switch"
switch.mkdir(exist_ok=True)
for letter in "ABCDEFGH":
    body = "\n\n".join(f"## {letter}{s}\n\n{para(60)} [[{rng.choice(names)}]]" for s in range(25))
    (switch / f"{letter}.md").write_text(f"# {letter}\n\n{body}\n", encoding="utf-8")
print(f"bench vault: {count} notes + Long + Gallery + Switch in {out}")
