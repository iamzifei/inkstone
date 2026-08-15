---
tags: [design/typography, 排版]
aliases: [排版笔记]
---

# Typography Notes

好的中文排版需要 **合适的行高**、==恰当的字号== 和 ~~随便什么字体~~ 精心挑选的字体。

Mixing 中文 and English in one paragraph is where most editors fall apart — 字号 and line-height that work for Latin look cramped for 汉字.

## Code is different

Body font and code font should be set separately:

```swift
let font = Typography().codeFont.platformFont(size: 13.5)
// #notatag — inside a fence
```

Inline `code` uses the code font too.

See also [[Graph Thinking]] and [[Home]]. ^typography-anchor
