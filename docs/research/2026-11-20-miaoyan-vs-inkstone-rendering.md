# MiaoYan vs Inkstone：Markdown 渲染对比与可借鉴项（2026-11-20）

对象：https://github.com/tw93/MiaoYan @ b317ef9（2026-11-20，MIT）。只读源码，未构建运行。
MiaoYan 的逐条分析（带文件行号）：`docs/research/2026-11-20-miaoyan-rendering-notes.md`。
标注：**实测** = 读到代码；**推断** = 从代码推出，未跑；**猜测** = 无直接依据。

## 一句话

两者路线不同：MiaoYan 是「原文编辑器 + WebView 预览」（HTML/JS 全家桶），Inkstone 是
「原生 TextKit 就地渲染」（只有 Mermaid 借用一个离屏 WebView）。**整套照搬不合适**，但有
三件事值得直接借：代码块语法着色、Mermaid 渲染器复用、中英文之间的间距。

## 架构对照

| | MiaoYan（实测） | Inkstone（实测） |
|---|---|---|
| 解析 | swift-cmark-gfm → HTML | swift-markdown + 自有扫描器 → 文本属性 |
| 显示 | 每个窗格一个 WKWebView，模板只加载一次，按块 diff 打补丁 | TextKit 1 就地样式，语法符号隐藏，光标所在行露出 |
| 编辑器着色 | 正则 + NSTextStorage，只重扫被改的段落；超 2000/5000 行或 1MB 降级 | 自有扫描器，按段落增量；今天的性能改动后只画可见区 |
| 代码块 | **Highlightr（highlight.js，约 36 种语言）着色** | **只有等宽 + 底色，没有按语言着色** |
| 数学 | KaTeX 0.16（JS，空闲时渲染） | SwiftMath（纯 Swift，直接出图，有缓存）——更轻，保持 |
| Mermaid | Mermaid 11.14，一个 WebView 里渲染，SVG 按「主题+源码」缓存 | Mermaid 11，**每个图新建一个离屏 WKWebView、把 3.4MB 库内联进 HTML 再解析**，出图后销毁；结果按「源码+深浅色」缓存在内存 |
| 其他图 | PlantUML（**发到 plantuml.com 公共服务器渲染**）、Markmap 思维导图 | 无 |
| 中英混排 | CSS `text-autospace`（盘古之白）、中文不做伪斜体 | 无自动间距；斜体用字体变体（中文效果未核） |
| 图片 | 先读尺寸再加载，防跳动 | 今天 0.5.1 已做同样的事（ImageIO 读头 + 占位） |
| 导出 | PDF / PNG / HTML（HTML 引用 cdn.miaoyan.app 的 CSS/JS） | PDF / HTML |
| 幻灯片 | reveal.js | 无 |

## 值得借（按「用户看得见 × 成本」排序）

### 1. 代码块按语言着色 —— 最明显的差距
- 现状（实测）：Inkstone 的代码块只有等宽字体和底色，`MarkdownHighlighter` 里没有任何按语言着色的实现。MiaoYan 编辑器和预览里都有。
- 做法：把 highlight.js 跑在 **JavaScriptCore**（不是 WebView）里，后台线程出 token，按「语言+代码块内容」缓存，落到属性上。Highlightr 就是这个思路（MIT），可直接用或参考。
- 注意：只对可见的、光标不在里面的块着色，跟今天的「只画可见区」配合；首次着色异步，跟 Mermaid 一样先显示原文。
- 推断成本：中（1 个 PR）。如果我错了，最可能错在 JavaScriptCore 在 iOS 后台线程的开销——要先做基准。

### 2. Mermaid 渲染器复用一个常驻 WebView —— 效率
- 现状（实测）：每个图都新开一个 WKWebView、把 3.4MB 的 mermaid.min.js 当字符串塞进 HTML 重新解析一遍（`MermaidRenderer.swift`，`library` + `loadHTMLString`）。一篇有 10 个图的笔记就解析 10 次。
- 做法：一个常驻的离屏 WebView，库只加载一次（从文件 URL 加载，不内联），之后用 `mermaid.render()` 逐个出 SVG；SVG 转图片或直接快照。再加一层**磁盘缓存**（按源码哈希），重开 App 不用重渲染。
- 推断收益：多图笔记的首次渲染时间大幅下降、内存峰值下降。**没有测过**——要先用今天的卡顿基准加一个「10 个 Mermaid 图」场景量出修改前后数字。

### 3. 中英文之间自动留白（盘古之白）—— 中文用户直接感受到
- 现状（推断）：Inkstone 显示中英混排时字挨在一起。MiaoYan 靠 CSS `text-autospace`。
- 做法：在样式化那一遍里，给「中文字符紧挨拉丁字母/数字」的边界加一点 `.kern`（约 0.25 个字宽），**只改显示不改文件内容**。纯原生、开销极小。
- 设置里给一个开关，默认开。

### 4. 小项
- **大文档降级阈值**：MiaoYan 在超大笔记上主动降级着色。Inkstone 今天已有可见区绘制，可以再补一个「单段超长（如 64K 字）不着色」的保护。低优先。
- **图表语法错误时的提示**：两边都是失败就显示源码。可以在源码下方加一行小字错误信息（不进导出）。低成本。
- **导出 PNG**（整篇笔记出长图）：便于分享到微信/小红书，对中文用户有用。中优先。

## 不建议借

- **PlantUML**：MiaoYan 把图表源码发到 plantuml.com 公共服务器渲染——和 Inkstone「不联网显示笔记、本地优先」的隐私承诺冲突。
- **整套 WebView 预览 + KaTeX + highlight.js 全量加载**：每页约 5MB JS，和 Inkstone 原生路线相反；SwiftMath 比 KaTeX 轻。
- **Markmap**：Mermaid 已有 mindmap 子类型，Inkstone 已带 Mermaid，再加一个库收益小。
- **flowchart.js**：MiaoYan 也没有；Mermaid 的 flowchart 已覆盖，且语法更通用。
- **导出 HTML 引用 CDN**：离线打不开，Inkstone 现在的自包含导出更好。

## 建议的下一步

先做 2（Mermaid 复用，带基准）和 1（代码块着色），各一个 PR，按惯例先量后改、独立评审；3 作为第三个小 PR。
