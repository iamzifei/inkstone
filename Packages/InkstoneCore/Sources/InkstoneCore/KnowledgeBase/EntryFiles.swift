import Foundation

/// The knowledge base's three entry files, the way into it for people and AI
/// agents alike:
///
/// - `AGENTS.md`: the rules any agent follows here (where things go, what
///   never to do), pointing at the rules file.
/// - `README.md`: what this is and where to start, with the folder map.
/// - `SOURCE_OF_TRUTH.md`: "what you are looking for → where the
///   authoritative copy is", one row per place.
///
/// Inkstone keeps one block of each up to date — between
/// `<!-- inkstone:auto:start -->` and `<!-- inkstone:auto:end -->` — from the
/// folders that actually exist. Everything outside the block is the person's
/// and is never changed; a file without the markers (written by hand) is left
/// alone entirely. The block lists structure, not counts, so organizing files
/// does not rewrite it every time.
public enum EntryFiles {
    public static let names = ["AGENTS.md", "README.md", "SOURCE_OF_TRUTH.md"]
    static let start = "<!-- inkstone:auto:start -->"
    static let end = "<!-- inkstone:auto:end -->"

    /// Rewrites the automatic block of each entry file whose block is out of
    /// date. Returns the files changed (none when nothing changed).
    @discardableResult
    public static func refresh(in root: URL) throws -> [String] {
        lock.lock(); defer { lock.unlock() }    // one refresh at a time
        guard let layout = KnowledgeBaseLayout.detect(in: root) else { return [] }
        var changed: [String] = []
        for name in names {
            let url = root.appending(path: name)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let (before, after) = split(text) else { continue }
            let updated = before + start + "\n" + block(name, in: root, layout: layout) + "\n" + end + after
            guard updated != text else { continue }
            var written = false
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                // Unchanged since it was read? Otherwise an edit or a sync
                // landed in between: theirs wins, try again next time.
                guard (try? String(contentsOf: target, encoding: .utf8)) == text else { return }
                written = (try? Data(updated.utf8).write(to: target, options: .atomic)) != nil
            }
            if written { changed.append(name) }
        }
        return changed
    }

    private static let lock = NSLock()

    /// The text before the start marker and after the end marker — when the
    /// file has exactly one of each, each alone on its line, outside code
    /// fences, start before end. Anything else (a quoted marker, two blocks,
    /// markers in an example) is ambiguous: nil, and the file is left alone.
    static func split(_ text: String) -> (String, String)? {
        var starts: [Range<String.Index>] = [], ends: [Range<String.Index>] = []
        var inFence = false
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle() }
            else if !inFence && line == start { starts.append(lineStart..<lineEnd) }
            else if !inFence && line == end { ends.append(lineStart..<lineEnd) }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        guard starts.count == 1, ends.count == 1, starts[0].upperBound <= ends[0].lowerBound else { return nil }
        return (String(text[..<starts[0].lowerBound]), String(text[ends[0].upperBound...]))
    }

    /// A name as inline code that no folder name can break: pipes escaped for
    /// tables, a fence longer than any run of backticks inside, and the
    /// marker text defused.
    static func code(_ name: String) -> String {
        let safe = name.replacingOccurrences(of: "inkstone:auto", with: "inkstone∶auto")
            .replacingOccurrences(of: "|", with: "\\|")
        var longest = 0, run = 0
        for ch in safe { if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 } }
        let fence = String(repeating: "`", count: longest + 1)
        return longest == 0 ? "`\(safe)`" : "\(fence) \(safe) \(fence)"
    }
    static let listCap = 20

    /// A whole new entry file: heading, automatic block, and a line inviting
    /// the person's own additions below it.
    static func newFile(_ name: String, in root: URL, layout: KnowledgeBaseLayout) -> String {
        let l = Words(layout.language)
        let heading = name == "README.md" ? "# \(root.lastPathComponent)" : "# \(name.replacingOccurrences(of: ".md", with: ""))"
        return "\(heading)\n\n\(start)\n\(block(name, in: root, layout: layout))\n\(end)\n\n\(l.yours)\n"
    }

    /// Plain text in a table cell: pipes escaped, marker text defused.
    static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "inkstone:auto", with: "inkstone∶auto").replacingOccurrences(of: "|", with: "\\|")
    }

    static func block(_ name: String, in root: URL, layout: KnowledgeBaseLayout) -> String {
        let tree = Tree(root: root, layout: layout)
        let l = Words(layout.language)
        switch name {
        case "AGENTS.md":
            var out = "\(l.managed)\n\n## \(l.whatTitle)\n\n\(l.what)\n\n## \(l.agentRulesTitle)\n\n"
            out += l.agentRules(layout).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            out += "\n\n## \(l.whereTitle)\n\n| \(l.colFolder) | \(l.colHolds) |\n| --- | --- |\n"
            out += tree.top.map { "| \(code($0 + "/")) | \(l.purpose(of: $0, layout) ?? tree.childList($0, l)) |" }.joined(separator: "\n")
            out += "\n\n## \(l.authorityTitle)\n\n- `SOURCE_OF_TRUTH.md` — \(l.sotLine)\n- `\(layout.rulesFile)` — \(l.rulesLine)\n- `\(layout.logFile)` — \(l.logLine)"
            return out
        case "README.md":
            var out = "\(l.managed)\n\n\(l.readmeIntro)\n\n## \(l.startTitle)\n\n1. `SOURCE_OF_TRUTH.md` — \(l.sotLine)\n2. `AGENTS.md` — \(l.agentsLine)\n3. `\(layout.inbox)/` — \(l.inboxLine)\n\n## \(l.mapTitle)\n\n"
            out += tree.top.map { top in
                let kids = tree.children[top] ?? []
                return "- \(code(top + "/"))" + (l.purpose(of: top, layout).map { " — \($0)" } ?? "")
                    + kids.prefix(listCap).map { "\n  - \(code($0 + "/"))" }.joined()
                    + (kids.count > listCap ? "\n  - \(l.more(kids.count - listCap))" : "")
            }.joined(separator: "\n")
            out += "\n\n## \(l.howTitle)\n\n\(l.how(layout))"
            return out
        case "SOURCE_OF_TRUTH.md":
            var rows: [(String, String, String)] = [
                (l.findRules, layout.rulesFile, l.rulesLine),
                (l.findLog, layout.logFile, l.logLine),
                (l.findIndex, layout.indexFile, ""),
                (l.findDuplicates, layout.duplicatesFile, ""),
                (l.findInbox, layout.inbox + "/", l.inboxLine),
                (l.findReview, layout.review + "/", ""),
                (l.findTrash, layout.trash + "/", l.trashLine),
            ]
            for top in tree.top where !layout.systemFolders.contains(top) && top != layout.inbox {
                let label = l.label(of: top, layout) ?? top
                rows.append((label, top + "/", l.purpose(of: top, layout) ?? ""))
                let kids = tree.children[top] ?? []
                for kid in kids.prefix(listCap) { rows.append((l.labelled(label, kid), "\(top)/\(kid)/", "")) }
                if kids.count > listCap { rows.append((l.more(kids.count - listCap), top + "/", "")) }
            }
            for readme in tree.readmes.prefix(listCap) { rows.append((l.readmeOf(readme), readme, "")) }
            var out = "\(l.managed)\n\n\(l.sotIntro)\n\n| \(l.colFind) | \(l.colWhere) | \(l.colNote) |\n| --- | --- | --- |\n"
            out += rows.map { "| \(cell($0.0)) | \(code($0.1)) | \($0.2) |" }.joined(separator: "\n")
            return out
        default:
            return ""
        }
    }
}

/// The folders that exist, two levels deep, in a stable order.
private struct Tree {
    let top: [String]
    let children: [String: [String]]
    let readmes: [String]

    init(root: URL, layout: KnowledgeBaseLayout) {
        let fm = FileManager.default
        func dirs(_ url: URL) -> [String] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
                .map(\.lastPathComponent)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        // The policy's order (inbox → projects → … → private), then the
        // person's own folders, then the machinery (review, archive, system).
        let found = dirs(root)
        let leading = [layout.inbox, layout.projects, layout.areas, layout.resources, layout.media,
                       layout.outputs, layout.privateFolder].filter(found.contains)
        let trailing = [layout.review, layout.archive, layout.system].filter(found.contains)
        top = leading + found.filter { !leading.contains($0) && !trailing.contains($0) } + trailing
        var kids: [String: [String]] = [:]
        var readmes: [String] = []
        for t in top where t != layout.system {
            let k = dirs(root.appending(path: t))
            kids[t] = k
            for sub in [t] + k.map({ "\(t)/\($0)" }) where fm.fileExists(atPath: root.appending(path: "\(sub)/README.md").path(percentEncoded: false)) {
                readmes.append("\(sub)/README.md")
            }
        }
        children = kids
        self.readmes = readmes
    }

    func childList(_ top: String, _ l: Words) -> String {
        let k = children[top] ?? []
        return k.isEmpty ? "—" : k.prefix(8).map(EntryFiles.cell).joined(separator: l.listSeparator) + (k.count > 8 ? l.andMore : "")
    }
}

/// The words of the entry files, per language.
private struct Words {
    let lang: KnowledgeBaseLanguage
    init(_ lang: KnowledgeBaseLanguage) { self.lang = lang }
    private func t(_ zhHans: String, _ zhHant: String, _ en: String) -> String {
        switch lang { case .simplifiedChinese: zhHans; case .traditionalChinese: zhHant; case .english: en }
    }

    var managed: String { t("> 本节由 Inkstone 自动维护（标记之间的内容会随知识库更新）。标记以外你写的内容不会被改动。",
                            "> 本節由 Inkstone 自動維護（標記之間的內容會隨知識庫更新）。標記以外你寫的內容不會被改動。",
                            "> This section is kept up to date by Inkstone (the text between the markers follows the knowledge base). Whatever you write outside the markers is never changed.") }
    var yours: String { t("<!-- 在这里写你自己的补充内容。 -->", "<!-- 在這裡寫你自己的補充內容。 -->", "<!-- Add your own notes below. -->") }
    var whatTitle: String { t("这是什么", "這是什麼", "What this is") }
    var what: String { t("这是一个知识库：一个普通文件夹，里面是子文件夹和文件（Markdown 笔记、文档、图片、音视频……）。没有数据库，任何工具都能直接打开这些文件。",
                         "這是一個知識庫：一個普通資料夾，裡面是子資料夾和檔案（Markdown 筆記、文件、圖片、影音……）。沒有資料庫，任何工具都能直接打開這些檔案。",
                         "This is a knowledge base: an ordinary folder of subfolders and files (Markdown notes, documents, images, audio, video …). There is no database; any tool can open these files directly.") }
    var agentRulesTitle: String { t("给 AI 智能体的规则", "給 AI 智慧代理的規則", "Rules for AI agents") }
    func agentRules(_ l: KnowledgeBaseLayout) -> [String] {
        [t("新文件先放进 `\(l.inbox)/`，再按 `\(l.rulesFile)` 整理归位。", "新檔案先放進 `\(l.inbox)/`，再依 `\(l.rulesFile)` 整理歸位。", "New files go into `\(l.inbox)/` first, then get filed by `\(l.rulesFile)`."),
         t("不删除任何文件：要删的移到 `\(l.trash)/`，由用户确认后再删。", "不刪除任何檔案：要刪的移到 `\(l.trash)/`，由使用者確認後再刪。", "Never delete a file: move it to `\(l.trash)/` and let the person confirm."),
         t("不改写正文；只移动、重命名、补元数据。", "不改寫內文；只移動、重新命名、補中繼資料。", "Never rewrite a file's text; only move, rename and add metadata."),
         t("每次移动和重命名都写进 `\(l.logFile)`。", "每次移動和重新命名都寫進 `\(l.logFile)`。", "Log every move and rename in `\(l.logFile)`."),
         t("拿不准的放进 `\(l.review)/` 问用户；私密文件只放 `\(l.privateFolder)/`，不外发。", "拿不準的放進 `\(l.review)/` 問使用者；私密檔案只放 `\(l.privateFolder)/`，不外發。", "Unsure? Put it in `\(l.review)/` and ask. Private files only go to `\(l.privateFolder)/` and never leave."),
         t("找东西先读 `SOURCE_OF_TRUTH.md`。", "找東西先讀 `SOURCE_OF_TRUTH.md`。", "To find something, read `SOURCE_OF_TRUTH.md` first.")]
    }
    var whereTitle: String { t("东西放哪里", "東西放哪裡", "Where things go") }
    var colFolder: String { t("文件夹", "資料夾", "Folder") }
    var colHolds: String { t("放什么", "放什麼", "What goes there") }
    var authorityTitle: String { t("权威文件", "權威檔案", "Authoritative files") }
    var sotLine: String { t("要找什么、权威位置在哪", "要找什麼、權威位置在哪", "what you're looking for, and where the authoritative copy is") }
    var rulesLine: String { t("整理规则，优先于应用默认值", "整理規則，優先於 App 預設值", "organizing rules; they beat the app's defaults") }
    var logLine: String { t("每次移动、重命名的记录，可回滚", "每次移動、重新命名的紀錄，可復原", "every move and rename, so it can be undone") }
    var agentsLine: String { t("AI 智能体在这里要遵守的规则", "AI 智慧代理在這裡要遵守的規則", "the rules AI agents follow here") }
    var inboxLine: String { t("把任何东西丢进来，会被自动整理", "把任何東西丟進來，會被自動整理", "drop anything in; it gets organized for you") }
    var trashLine: String { t("待删除的文件先在这里，确认后才真删", "待刪除的檔案先在這裡，確認後才真的刪除", "files to delete wait here until confirmed") }
    var readmeIntro: String { t("这是一个用 Inkstone 管理的知识库。它只是文件夹和文件，换任何工具都能打开。",
                                "這是一個用 Inkstone 管理的知識庫。它只是資料夾和檔案，換任何工具都能打開。",
                                "A knowledge base managed with Inkstone. It is just folders and files; any tool can open it.") }
    var startTitle: String { t("先看哪里", "先看哪裡", "Start here") }
    var mapTitle: String { t("目录", "目錄", "Folders") }
    var howTitle: String { t("怎么用", "怎麼用", "How to use it") }
    func how(_ l: KnowledgeBaseLayout) -> String {
        t("把文件拖进 Inkstone（或直接放进 `\(l.inbox)/`），它会按 `\(l.rulesFile)` 自动分类、去重、改名并归位；拿不准的会放进 `\(l.review)/` 等你决定。每一步都记在 `\(l.logFile)`，随时可以撤销。",
          "把檔案拖進 Inkstone（或直接放進 `\(l.inbox)/`），它會依 `\(l.rulesFile)` 自動分類、去重、改名並歸位；拿不準的會放進 `\(l.review)/` 等你決定。每一步都記在 `\(l.logFile)`，隨時可以復原。",
          "Drag files into Inkstone (or put them straight into `\(l.inbox)/`): it sorts, deduplicates, renames and files them by `\(l.rulesFile)`, and leaves anything it's unsure about in `\(l.review)/` for you. Every step is logged in `\(l.logFile)` and can be undone.")
    }
    var sotIntro: String { t("要找东西、判断哪一份是准的，先查这张表。", "要找東西、判斷哪一份是準的，先查這張表。", "Looking for something, or which copy is the real one? Check this table first.") }
    var colFind: String { t("要找什么", "要找什麼", "Looking for") }
    var colWhere: String { t("权威位置", "權威位置", "Where") }
    var colNote: String { t("备注", "備註", "Notes") }
    var findRules: String { t("整理规则", "整理規則", "Organizing rules") }
    var findLog: String { t("整理日志", "整理日誌", "Organizing log") }
    var findIndex: String { t("文件索引（非文本文件的元数据）", "檔案索引（非文字檔案的中繼資料）", "File index (metadata of non-text files)") }
    var findDuplicates: String { t("重复记录", "重複紀錄", "Duplicates record") }
    var findInbox: String { t("收件箱", "收件匣", "Inbox") }
    var findReview: String { t("待确认的文件", "待確認的檔案", "Files waiting for your decision") }
    var findTrash: String { t("待删除的文件", "待刪除的檔案", "Files to delete") }
    func readmeOf(_ path: String) -> String {
        let folder = EntryFiles.cell(path.replacingOccurrences(of: "/README.md", with: ""))
        return t("「\(folder)」的说明", "「\(folder)」的說明", "About \(folder)")
    }
    var listSeparator: String { t("、", "、", ", ") }
    func more(_ n: Int) -> String { t("……另有 \(n) 个", "……另有 \(n) 個", "… and \(n) more") }
    var andMore: String { t(" 等", " 等", " …") }

    /// A short noun for a skeleton folder, for "what you are looking for".
    func label(of folder: String, _ l: KnowledgeBaseLayout) -> String? {
        switch folder {
        case l.projects: return t("项目", "專案", "Projects")
        case l.areas: return t("领域", "領域", "Areas")
        case l.resources: return t("资料", "資料", "Resources")
        case l.media: return t("素材", "素材", "Media")
        case l.outputs: return t("产出", "產出", "Outputs")
        case l.privateFolder: return t("私密文件", "私密檔案", "Private files")
        default: return nil
        }
    }
    func labelled(_ parent: String, _ child: String) -> String {
        t("\(parent)：\(child)", "\(parent)：\(child)", "\(parent): \(child)")
    }

    func purpose(of folder: String, _ l: KnowledgeBaseLayout) -> String? {
        switch folder {
        case l.inbox: return t("随手丢进来的东西，唯一入口", "隨手丟進來的東西，唯一入口", "anything dropped in; the only way in")
        case l.projects: return t("有目标、有截止的事，一个项目一个文件夹", "有目標、有截止的事，一個專案一個資料夾", "things with a goal and a deadline, one folder each")
        case l.areas: return t("长期负责的方面（工作、健康、财务、家庭……）", "長期負責的方面（工作、健康、財務、家庭……）", "long-term responsibilities (work, health, money, family …)")
        case l.resources: return t("参考资料，按主题分", "參考資料，依主題分", "reference material, by topic")
        case l.media: return t("图片、视频、音频、设计素材", "圖片、影片、音訊、設計素材", "images, video, audio, design")
        case l.outputs: return t("自己做出来的成品", "自己做出來的成品", "finished work")
        case l.privateFolder: return t("敏感文件，不外发", "敏感檔案，不外發", "sensitive files; never leave")
        case l.review: return t("拿不准放哪的，等你决定", "拿不準放哪的，等你決定", "unsure where it goes; waiting for you")
        case l.archive: return t("过期、完结、替换下来的旧版本", "過期、完結、替換下來的舊版本", "expired, finished, replaced versions")
        case l.system: return t("规则、日志、索引、重复记录", "規則、日誌、索引、重複紀錄", "rules, log, index, duplicates")
        default: return nil
        }
    }
}
