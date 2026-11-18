#!/usr/bin/env python3
"""Writes assets/demo-vault-zh (Simplified) and assets/demo-vault-zh-Hant.

The welcome guide's screenshots are rendered from real views against a demo
vault (see App/Support/GuideShots.swift). The English set uses assets/demo-vault;
these two give the Chinese sets Chinese file names, folders, tags and note text,
so the sidebar, graph labels and backlinks panel are in the language of the guide.

The Traditional vault is made from the Simplified one by ICU's Hans-Hant transform
(character level) followed by a Taiwan-vocabulary pass, because the transform
alone yields Hong Kong / mainland wording (軟件, 文件夾, 鏈接).

    python3 scripts/make-zh-demo-vaults.py
"""
import json, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "assets"

HANS = {
"首页.md": """---
title: 首页
tags: [moc, 入口]
---

# 首页

一个仓库就是一个装着 Markdown 的文件夹。没有数据库，没有导入，
删掉这个应用，文件还在原地。

## 从这里开始

- [[排版笔记]] — 中英文混排到底难在哪
- [[行长]] — 一行该有多长
- [[图谱思考]] — 链接会长出你没规划过的结构
- [[项目/Inkstone]]

## 最近

- [[日记/2026-08-20]]
- [[阅读/布林赫斯特]]
- [[阅读/奇肖尔德]]

标签：#moc #示例

> [!tip] 实时预览
> 把光标放到这一行，`>` 的语法就会重新出现。
""",
"行长.md": """---
tags: [design/typography, 排版]
---

# 行长

> 一行 45 到 75 个字符，被普遍认为是单栏页面里比较合适的长度。

— [[阅读/布林赫斯特]]，§2.1.2

66 个字符是他给的那个数。超过 75，眼睛回到下一行行首时会找错行；
少于 45，行与行之间断得太碎。

中文没有词间空格，所以同样宽度里字数更多，行距要相应放开。
参见 [[排版笔记#四分之一字宽的间隙]]。

#排版/行长
""",
"排版笔记.md": """---
tags: [design/typography, 排版]
aliases: [中英混排, Mixed Setting]
---

# 排版笔记

好的中文排版需要 **合适的行高**、==恰当的字号==，以及 ~~随便什么字体~~
精心挑选的字体。

Mixing 中文 and English in one paragraph is where most editors fall apart —
适合拉丁字母的字号和行距，放到汉字上就显得挤。

## 四分之一字宽的间隙

汉字与拉丁字母相邻时，中间应该有约四分之一字宽的间隙。W3C 的
[中文排版需求](https://www.w3.org/TR/clreq/) 称之为文字间隙。

| 场景 | 该不该加 | 说明 |
| --- | --- | --- |
| 汉字 + Latin | 要 | 约四分之一字宽 |
| 汉字 + 全角标点 | 不要 | 标点自带二分空 |
| Latin + 数字 | 不要 | 同属拉丁 |

## 代码不一样

正文字体和代码字体应该分开设置：

```swift
let font = Typography().codeFont.platformFont(size: 13.5)
// #notatag — 在代码围栏里，不会被当成标签
```

行内的 `code` 也用代码字体。

另见 [[行长]] 和 [[图谱思考]]。 ^typography-anchor
""",
"想法.md": """---
tags: [moc, 想法]
---

# 想法

- 用 [[图谱思考]] 找出孤立的笔记
- 把 [[阅读/布林赫斯特]] 的规则做成一张检查表
- 一个只有段落、没有标题的写作模式

#想法/未整理
""",
"图谱思考.md": """---
tags: [thinking, 图谱]
---

# 图谱思考

链接会长出你没规划过的结构。[[排版笔记#代码不一样]]
是个好例子——它本来只是一条笔记，后来变成了三条笔记共同指向的地方。

- [x] 让布局保持确定
- [x] 局部图谱
- [ ] 未链接的提及
- [ ] 调整力导向模拟的阻尼

这条链接指向一篇还不存在的笔记：[[未来的笔记]]

#thinking/networked
""",
"阅读/布林赫斯特.md": """---
tags: [reading, 读书]
author: Robert Bringhurst
year: 1992
---

# 排版风格的要素

> 排版的存在，是为了尊重内容。

读它像读一本讲礼仪的书：几乎每一条规则背后都是「不要让读者注意到你」。

- [[行长]] 出自 §2.1
- 关于 [[笔记/中日韩断行]] 他没写，那是 CLReq 的活

#读书/排版
""",
"阅读/奇肖尔德.md": """---
tags: [reading, 读书]
author: Jan Tschichold
year: 1928
---

# 新排版

1928 年他要求一切非对称、无衬线、去装饰。二十年后他自己推翻了大半，
去 Penguin 做古典式的书籍排版。

两个奇肖尔德都对——只是对的东西不同：一个在做海报，一个在做书。

[[阅读/布林赫斯特]] 更接近后期的他。

#读书/排版
""",
"项目/Inkstone.md": """---
tags: [project/active, 项目]
status: building
---

# Inkstone

一个把笔记留成文件的 macOS / iOS 应用。

## 已经做完

- 仓库、文件树、外部改动重载
- 双链、别名、块引用、反向链接
- 关系图谱、白板、日记
- iCloud 与 GitHub 同步

## 设计原则

文件才是事实。见 [[笔记/文件即真相]]。

$E = mc^2$ 这样的行内公式也认。
""",
"日记/2026-08-19.md": """---
tags: [daily]
---

# 2026-08-19

- [x] 修好表格对齐
- [x] [[笔记/中日韩断行]] 的笔记整理进库

#日记
""",
"日记/2026-08-20.md": """---
tags: [daily]
---

# 2026-08-20

- [x] 把 [[行长]] 写完
- [ ] 给 [[项目/Inkstone]] 录一段演示
- [ ] 读 [[阅读/奇肖尔德]] 第三章

今天想明白的一件事：[[笔记/文件即真相]] 不是一个功能，是一个约束。
所有别的行为都是它的后果。
""",
"笔记/中日韩断行.md": """---
tags: [design/typography, 排版]
---

# 中日韩断行

`line-break: strict` 才会禁止在小假名和长音符号前断行。

避头尾：`、。，；：？！` 不能出现在行首，`（「《` 不能出现在行尾。

英文靠 `overflow-wrap` 兜底，中文不需要——它本来就可以在任意两字之间断。

#排版/断行
""",
"笔记/文件即真相.md": """---
tags: [principle, 原则]
---

# 文件即真相

没有数据库，就没有「导出」这回事——文件一直在那儿。

代价是：断掉的链接是永久的。所以重命名必须同时改写整个库里指向它的
每一处 [[排版笔记]]。

> [!warning] 这不是可选项
> 一旦允许「稍后修复」，就等于承认有一个第二真相源。
""",
}

CANVAS = {
 "edges": [{"fromNode":"n1","id":"e1","toEnd":"arrow","toNode":"n2"},
           {"fromNode":"n2","id":"e2","toEnd":"arrow","toNode":"n3"},
           {"fromNode":"n4","id":"e3","toEnd":"arrow","toNode":"n3"},
           {"fromNode":"n3","id":"e4","toEnd":"arrow","toNode":"n5"}],
 "nodes": [
  {"color":"1","height":140,"id":"n1","text":"# 一个原则\n\n文件才是事实。\n其余都是它的后果。","type":"text","width":300,"x":-460,"y":-260},
  {"file":"笔记/文件即真相.md","height":180,"id":"n2","type":"file","width":300,"x":-60,"y":-280},
  {"file":"排版笔记.md","height":180,"id":"n3","type":"file","width":300,"x":-60,"y":-40},
  {"color":"4","height":120,"id":"n4","text":"重命名 → 全库改写\n\n没有第二真相源。","type":"text","width":300,"x":-460,"y":-40},
  {"file":"行长.md","height":180,"id":"n5","type":"file","width":300,"x":340,"y":-160}]}

# Taiwan wording the character-level transform cannot know. Order matters:
# longer phrases first.
TAIWAN = [("文件夾","資料夾"),("數據庫","資料庫"),("軟件","軟體"),("設置","設定"),("鏈接","連結"),
          ("導入","匯入"),("導出","匯出"),("默認","預設"),("里字數","裡字數"),("寬度里","寬度裡"),
          ("文件","檔案"),("信息","資訊"),
          ("倉庫","儲存庫"),("字符","字元"),("面里","面裡"),("應用","App"),("光標","游標"),
          ("實時預覽","即時預覽"),("項目","專案"),("代碼圍欄里","程式碼區塊裡"),
          ("庫里","庫裡"),("代碼","程式碼")]

def to_hant(texts):
    """Transforms a list of strings with ICU Hans-Hant, via a throwaway Swift tool."""
    swift = 'import Foundation\nlet i = FileHandle.standardInput.readDataToEndOfFile()\n' \
            'let a = try! JSONDecoder().decode([String].self, from: i)\n' \
            'let o = a.map { $0.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false)! }\n' \
            'print(String(data: try! JSONEncoder().encode(o), encoding: .utf8)!)\n'
    with tempfile.TemporaryDirectory() as d:
        src = Path(d) / "t.swift"; src.write_text(swift)
        subprocess.run(["swiftc", str(src), "-o", f"{d}/t"], check=True, capture_output=True)
        out = subprocess.run([f"{d}/t"], input=json.dumps(texts).encode(), check=True, capture_output=True).stdout
    res = json.loads(out)
    for old, new in TAIWAN:
        res = [r.replace(old, new) for r in res]
    return res

def write(vault, files):
    if vault.exists(): shutil.rmtree(vault)
    for rel, text in files.items():
        p = vault / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(text, encoding="utf-8")

canvas_text = json.dumps(CANVAS, ensure_ascii=False, indent=2)
hans = {**HANS, "地图.canvas": canvas_text}
write(ROOT / "demo-vault-zh", hans)

keys = list(hans); vals = [hans[k] for k in keys]
hk = to_hant(keys); hv = to_hant(vals)
write(ROOT / "demo-vault-zh-Hant", dict(zip(hk, hv)))
print("wrote", len(hans), "notes x 2 vaults")
