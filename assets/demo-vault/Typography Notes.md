---
tags: [design/typography, 排版]
aliases: [排版笔记, Mixed Setting]
---

# Typography Notes

好的中文排版需要 **合适的行高**、==恰当的字号==，以及 ~~随便什么字体~~
精心挑选的字体。

Mixing 中文 and English in one paragraph is where most editors fall apart —
适合拉丁字母的字号和行距，放到汉字上就显得挤。

## The quarter-em gap

汉字与拉丁字母相邻时，中间应该有约四分之一字宽的间隙。W3C 的
[中文排版需求](https://www.w3.org/TR/clreq/) 称之为文字间隙。

| 场景 | 该不该加 | 说明 |
| --- | --- | --- |
| 汉字 + Latin | 要 | 约四分之一字宽 |
| 汉字 + 全角标点 | 不要 | 标点自带二分空 |
| Latin + 数字 | 不要 | 同属拉丁 |

## Code is different

正文字体和代码字体应该分开设置：

```swift
let font = Typography().codeFont.platformFont(size: 13.5)
// #notatag — 在代码围栏里，不会被当成标签
```

行内的 `code` 也用代码字体。

See also [[The Measure]] and [[Graph Thinking]]. ^typography-anchor
