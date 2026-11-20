# MiaoYan Markdown / 图表渲染分析

源码：`/private/tmp/claude-501/-Users-james-Dev/6e0d8054-a03f-491d-a70a-a66cda870579/scratchpad/ext-miaoyan`（只读，未构建未运行）。下文路径都相对这个目录。
标注说明：**实测** = 读到了代码；**推断** = 从代码推出来、没运行验证过。

## 1. 管线

- **解析器**：`swift-cmark-gfm` 1.0.2（`Package.resolved`；`DEPENDENCIES.md` 写的约束是 1.0.0+）。扩展有 `table, footnotes, strikethrough, tasklist, autolink`（`Business/Markdown.swift:22`），解析选项 `CMARK_OPT_FOOTNOTES`，渲染选项 `UNSAFE | SOURCEPOS | NOBREAKS/HARDBREAKS`（`Markdown.swift:455-459`）。**原始 HTML 直接透传，每个块都带 `data-sourcepos`。**
- **唯一出口**：`renderMarkdownHTML()`（`Markdown.swift:436`）。预览、分栏、导出、PPT 都走它。cmark 之前先跑一遍 `protectMarkdownMath`（`:51`），让公式不被 Markdown 强调语法误伤；cmark 之后依次做这几步后处理：清理 `$$` 里的 `<br>`（`:465-479`）、把 task checkbox 挪进 `<p>`（`:482`）、把 GitHub Alerts 改写成 callout（`:567`）、处理空 `[ ]` 任务项（`:496`）、`Emphasis.markCJK`（`Packages/MiaoYanCore/Sources/MiaoYanCore/Emphasis.swift:20`）。
- **显示**：`MPreviewView` 是 `WKWebView` 子类（`Views/MPreviewView.swift:14`），每个编辑器窗格一个实例，创建位置在 `Views/EditTextView.swift:646, 1902`，另外 Shell 有一个。它不池化，但会复用：`resetPreviewStateForReuse`（`MPreviewView.swift:617`）。
- **模板**：`DownView.bundle` 启动时复制进 Caches，每次启动只同步一次（`Business/HtmlManager.swift:802-830`）。每次完整加载都会往这份副本里写一个新文件 `index-<UUID>.html`，替换掉 `DOWN_HTML/DOWN_CSS/DOWN_META` 占位符，再 `loadFileURL`，读权限只给这个文件夹（`HtmlManager.swift:975`、`MPreviewView.swift:812-900`）。超过 5 分钟的旧 index 在后台删掉。
- **编辑后怎么推到预览：增量 DOM patch，不整页 reload。**
  - Swift 端：`updateContent`（`MPreviewView.swift:962`）在 `Task.detached` 里渲染 HTML，再用 `buildUpdateScript`（`:635`）把 HTML 当字符串字面量注入 JS。
  - JS 端：`MiaoYanCommon.patchContent`（`Resources/DownView.bundle/js/common.js:776`）只比较顶层块。key 是去掉相对 sourcepos 之后的 `outerHTML`（`blockKey`，`:642`）。先剥掉共同前缀和后缀，中间部分在 64 个块的窗口里按 key 找匹配复用（`:822`）。没变的块直接保留同一个 DOM 节点，图片和图表都不重绘，只平移它的 sourcepos（`shiftSourceLines`，`:683`）。
  - 切换笔记用 `showNoteInPlace`（`MPreviewView.swift:927`）→ `common.js` 里的 `showNote`（`:763`），模板和脚本都不重新解析。只有幻灯片、导出、样式变化这几种情况才回退到完整 load（`canShowNoteInPlace`，`:903`）。
- **防抖**：分栏模式固定 0.15s，输入法有 marked text 时跳过这次更新（`Views/EditTextView.swift:846-860`）。普通预览路径按行数自适应：<500 行 0.3s，<1500 行 0.6s，再长 1.0s（`Controllers/ViewController.swift:1495-1511`）。KaTeX 和图表另有一层节流，每 0.8s 最多一次，并会补跑一次 catch-up，保证最后一次编辑一定被渲染（`MPreviewView.swift:1094-1104`）。
- **滚动同步**：双向，以行号为锚点。注入的 `scrollSyncScript`（`:220`）收集所有 `[data-sourcepos]` 元素的 top，按行二分查找后线性插值（`:246-273`）。`ResizeObserver` 触发锚点重建，滚动事件用 rAF 节流后 `postMessage('previewScroll')`（`:301-310`）。编辑器到预览方向调 `scrollToLine`（`Controllers/ViewController+Editor.swift:181, 1159`）。更新时把视口里第一个被保留的块钉在原位（`buildUpdateScript` 里的 `inView`/`keptAnchor`，`:687-730`）。

## 2. 图表

| 类型 | 库 / 版本 | 来源 | 实现 |
|---|---|---|---|
| Mermaid（含 sequence、gantt、journey 等全部子类型） | mermaid **11.14.0**（`mermaid.min.js` 内的版本字符串；MANIFEST 写的是 unknown） | 本地打包，3.1 MB | `js/diagram-handler.js:46` |
| PlantUML | plantuml-encoder | **远程渲染**：`https://www.plantuml.com/plantuml/svg/~1…`（`diagram-handler.js:129`） | `<img loading=lazy>` |
| Markmap | markmap + markmap-view + d3 6.7.0 | 本地，且 `render()` 打过补丁（MANIFEST 有说明） | `diagram-handler.js:240-341` |

- **不支持** flowchart.js、Graphviz、ECharts、abcjs、WaveDrom：bundle 和 Swift 源码里都 grep 不到。
- **ELK 布局基本是死重**：`mermaid-layout-elk*.js` 共 1.6 MB，打包了，`theme-config.js:151` 也有 `elk` 配置，但 `index.html` 和 `ppt.html` 都没加载它，也没有任何地方调用 `registerLayoutLoaders`。（推断：`layout: elk` 不会生效。如果我错了，最可能错在 mermaid 有我没找到的动态 import 路径。）
- **渲染时机**：首屏在 `renderPage()` 里调 `DiagramHandler.initializeAll()`（`common.js:703`）。编辑时先由 Swift 端判断 HTML 里有没有 `language-mermaid/plantuml/markmap`（`MPreviewView.swift:1035`），再 `setTimeout(initializeAll, 100ms)`，受上面 0.8s 节流约束。处理过的元素打 `data-processed`，所以 patch 保留下来的块不会重画，只画新插入的块。
- **缓存**：Mermaid 按 `(light|dark)+源码` 算 32 位字符串 hash，SVG 存进 `_svgCache` Map（`diagram-handler.js:34-82`）。改了 A 图，B 图直接命中缓存，零延迟。
- **主题**：`theme-config.js:136-160` 产出 Mermaid 配置（`neutral`/`dark` 加暖纸色 themeVariables，CJK 字体栈）、PlantUML skinparam（会先删掉用户自己写的 skinparam 再注入，`:126`），以及 markmap 分支色。切换外观时 `retheme()`（`:188`）用保存的源码重画。PlantUML 换主题时，新图加载成功前旧图保持不动（`:216`）。
- **错误显示**：Mermaid 用 `suppressErrorRendering: true`，失败就保留源码块并加 `mermaid-source-fallback` class，刻意不插入错误 HTML，以免它漏进 PDF（`:86-95`）。PlantUML 和 Markmap 失败时显示一行红字，2 秒后消失（`:17-20`）。

## 3. 数学与代码

- **数学**：KaTeX 0.16.0 + auto-render，字体 woff2 全部本地化（MANIFEST）。定界符 `$$ $ \( \) \[ \]`。在 `requestIdleCallback(timeout 200)` 里对整个 body 跑 `renderMathInElement`（`common.js:706-721`），已渲染的 `.katex` 跳过。
  - 货币 `$` 的处理：Swift 端有 `isCurrencyDollar`（`Markdown.swift:228`），`\$` 会转成 `skip-math-dollar` span（`:203`），JS 端还有 `escapeCurrencyLikeMath`。
  - `needsMath = html.contains("$")`（`MPreviewView.swift:1033`）太粗：任何带美元符号的笔记都会触发整页 KaTeX 扫描。
- **预览代码高亮**：highlight.js 11.5.1 的 common 构建，约 36 种语言（bash, c, cpp, csharp, css, diff, go, ini, java, js, json, kotlin, less, lua, makefile, markdown, objc, perl, php, python, r, ruby, rust, scss, shell, sql, swift, ts, vbnet, xml, yaml…）。没有懒加载，`defer` 一次性加载。首屏调 `hljs.highlightAll()`（`common.js:457`），增量更新时只对新插入的块调 `highlightElement`（`renderBlocks`，`:731`）。
- **index.html 里的全部重 JS 都是 `defer` 同步加载**（`index.html:61-85`），没有按需加载。即使笔记里没有图表，也要解析约 3.1 MB 的 Mermaid 加约 1.5 MB 的其他库。这些成本靠「模板加载一次、之后 in-place 换内容」来摊薄。

## 4. 编辑器内高亮

- **纯 regex 方案，没有用 parser。** 高亮写成 `NSTextStorage` 的 attributes：`MarkdownRuleHighlighter.swift` 里有一长串 `MarklightRegex`（标题、列表、引用、链接、图片、强调、emoji…，`:80-460`），源头是 Marklight 那套。
- **钩子**：用 `@retroactive` 给 `NSTextStorage` 本身扩展 `NSTextStorageDelegate`，在 `didProcessEditing` 里处理，纯属性变更直接忽略（`Helpers/CustomTextStorage.swift:3-12`）。
- **增量**（`CustomTextStorage.swift:36-147`）：
  - 默认只重扫编辑所在段落 `paragraphRange`。
  - 段落以 ```` ``` ```` 开头时（fence 变化）才全量重扫。
  - 一次粘贴或删除多个字符时，走 `highlightMultiline`。
  - 简化模式下，上下文最多向两边各扩展 8 个段落，遇到空行或 fence 停（`expandedSyntaxContextRange`，`:225`）。
  - 光标落在代码块里时，只用 Highlightr 重新高亮那个段落（`:126-131`）。
- **代码块**：Highlightr 2.3.0（JavaScriptCore 里跑 highlight.js），实例按主题缓存（`NotesTextProcessor.swift:150-172`）。>3000 字符的代码块（简化模式下 >500）只上基础样式（`CodeBlockHighlighter.swift:40`）。
- **降级档位**（`NotesTextProcessor.swift:292-330`）：
  - 总长 >1M UTF-16 或单段 >64K：简化高亮，且不高亮代码。
  - >5000 行：同上。
  - >2000 行：简化高亮，代码照常高亮。
  - 代码块多于 20 个：跳过代码高亮。
- **字体细节**：Markdown 标点（`# ** >` 等）用系统字体并小一号（`markSyntax`，`.claude/rules/preview.md` 有说明），因为霞鹜/仓耳的 `<>*` 太宽太重。

## 5. 性能手段

1. Markdown 到 HTML 的渲染在 `Task.detached` 后台跑。`loadEpoch` 和 `contentUpdateVersion` 两个版本号丢弃过期结果（`MPreviewView.swift:826-855, 966, 1023`），解决「快速切换笔记，小笔记先渲染完、反被大笔记覆盖」的问题。
2. 块级 DOM diff，图片和图表节点原地保留（见第 1 节）。
3. 模板只加载一次，切笔记 in-place 替换，没有白屏。
4. 数学和图表 0.8s 节流加 catch-up；KaTeX 放进 `requestIdleCallback`。
5. **图片占位不跳动**：
   - 本地图片从文件头读像素尺寸（ImageIO），按路径、修改时间、长度缓存（`Business/PreviewMedia.swift:84-126`）。
   - 远程图片发 256 KB 的 Range 请求探测尺寸（`RemoteImageProbe`），结果持久化到 Caches（`:201-218`）。
   - 加载完之前显示 `--code-bg` 底色的呼吸占位，`IntersectionObserver` 懒加载（`common.js:210-250`）。
   - `<video preload=none>`，避免拖住 load 事件。
6. 阿里 CDN 图片自动加 `x-oss-process=…resize,w_1600/format,webp`（`HtmlManager.swift:428-440`）。
7. 编辑器侧的大文档降级档位（见第 4 节）。
8. 没找到 benchmark：41 个测试文件里 grep `measure {` 和 `benchmark` 都没有。性能相关的说法只出现在注释里，例如 `NotesTextProcessor.swift:287-291` 写着「NSRegularExpression 处理 100KB+ 单行会卡」。

## 6. 视觉打磨

- **排版**：基于 Heti（`css/typography.css:1-35`）：`line-height 1.64`，`letter-spacing 0.02em`，并且这个值和编辑器的 kern 共用一个常量 `letterSpacingEm`。
- **中西文间距只靠 CSS `text-autospace: normal`**（`typography.css:34`），没有用 JS 插空格，也没有用 heti 的 JS。（推断：只有支持这个属性的较新 WebKit 才有效果。如果我错了，最可能错在 heti 的 spacing 逻辑被内联到了别处。）
- **CJK 斜体**：`<em>` 里是中日韩文字时加 `lang`，CSS 就不做伪斜体（`Emphasis.swift`）。
- **字体栈**：默认 SF 加 PingFang；用户主动选了某个 CJK 字体时，由它统管拉丁字母（`FontCatalog.fontStack`）。
- **表格**：宽表包进 `.table-scroll`，横向滚动不撑宽页面（`base.css:114`，`common.js:70`）；PDF/PNG 导出时强制适配页宽。
- **任务列表**：可点击，按 sourcepos 回写源码（`common.js:94`，`HandlerCheckbox`）。空 `[ ]` 也渲染成框。
- **脚注**：cmark 原生支持。
- **Callout**：只支持 GitHub Alerts 五种，配 Octicon 图标（`Markdown.swift:522-610`）。
- **TOC**：tocbot，悬停触发，可钉住（`index.html:107-116`，`common.js:876`）。
- **Front matter**：每个输出面都会剥掉（`Note.swift:534` → `MiaoYanCore.Frontmatter`）。
- **其他**：emoji 短码、lightense 点击放大图片、标题 hover 显示锚点。
- **图片尺寸语法**：没找到自定义语法，靠 `UNSAFE` 透传原始 `<img width>`。
- **PPT**：reveal.js，用 `---` 分页（`ppt.html`），带 markdown、highlight、math、notes、zoom 插件，主题 white/night。
- **导出**：
  - PDF：普通笔记走离屏窗口加 `NSPrintOperation`（`Helpers/PdfExportController.swift`），PPT 走 `createPDF`。
  - PNG：`takeSnapshot`。
  - HTML：本地图片 base64 内联，但 JS/CSS 通过 `<base href="https://cdn.miaoyan.app/Resources/DownView.bundle/">` 从官方 CDN 加载（`HtmlManager.swift:318, 948`）。导出前会等待图片和 Markmap 渲染稳定。

## 7. 值得借鉴 / 脆弱点

**值得借 ↑**
- 带 `data-sourcepos` 的块级 diff（key 用相对 sourcepos），加上「把视口里第一个被保留的块钉在原位」。这是阅读视图做增量更新、同时保持滚动位置最省事的办法。
- 同一个页面 in-place 换笔记，配合 epoch 丢弃过期渲染结果。
- 图片尺寸预探测：本地读文件头，远程发 Range 请求，结果持久化，彻底消除布局跳动。
- Mermaid SVG 按「主题+源码」做 hash 缓存；换主题时，新图加载好之前旧图不动。
- `frame-fallback.js`：离屏或后台窗口拿不到 rAF 时用定时器代替，否则 d3 动画不启动，导出就是空白。
- 用 `\u{E000}` 标记保护公式里的换行（`Markdown.swift:38`）。
- 编辑器只重扫当前段落，fence 变化才全量，再按文档大小设降级档位。这套模型可以直接对照 TextKit 1 的做法。
- 注入 JS 统一用 `jsStringLiteral`，不用模板字符串（之前反引号把 PDF 导出脚本弄坏过）。

**脆弱或慢 ↓**
- PlantUML 依赖公网 plantuml.com，离线就不能用，而且源码会发到第三方。
- 约 5 MB 的 JS 全部 `defer` 加载，不按需；ELK 的 1.6 MB 打包了但没接线（推断）。
- `ppt.html:9, 12` 引用了 `themes/mermaid.css` 和 `js/index.js`，bundle 里都不存在（实测 `ls` 报不存在），推断是 404 被静默吞掉。
- `needsMath = contains("$")` 判得太宽；Mermaid 缓存用 32 位 hash，理论上会碰撞，碰撞时会显示错图。
- 编辑器高亮全靠 regex，嵌套强调和 HTML 块的边界问题只能靠一个个补丁修（`rules/preview.md` 记录了好几次）。代码里叫 `rescanAllAsync` 的函数其实是同步的（`CustomTextStorage.swift:79-101`）。
- 导出的 HTML 依赖 `cdn.miaoyan.app`，离线打开或 CDN 下线后，样式和图表都会失效。
- 每次完整 load 都往 Caches 写一个新 index 文件，靠 5 分钟清理兜底。
