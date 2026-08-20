---
tags: [design/typography, 排版]
---

# CJK Line Breaking

`line-break: strict` 才会禁止在小假名和长音符号前断行。

避头尾：`、。，；：？！` 不能出现在行首，`（「《` 不能出现在行尾。

英文靠 `overflow-wrap` 兜底，中文不需要——它本来就可以在任意两字之间断。

#排版/断行
