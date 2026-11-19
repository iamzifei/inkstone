import Foundation

/// Sets a folder up as a knowledge base: the skeleton folders, the system
/// files (rules, log, index, duplicates) and the three entry files.
///
/// Only ever adds. A folder or file that already exists is left exactly as it
/// is, so applying it to a hand-made vault (or applying it twice) never
/// overwrites anything a person wrote.
public enum VaultBlueprint {
    /// - Parameters:
    ///   - skeleton: create the organizing folders (inbox, projects …). False
    ///     for an existing folder adopted as a knowledge base: it keeps its
    ///     own structure and only gets the system files and entry files.
    ///   - rules: the organizing rules written into a new rules file; the
    ///     default policy in the vault's language unless Settings replaced it.
    /// - Returns: the vault-relative paths created, in order.
    @discardableResult
    public static func apply(to root: URL, language: KnowledgeBaseLanguage, skeleton: Bool = true,
                             rules: String? = nil, date: Date = .now) throws -> [String] {
        let layout = KnowledgeBaseLayout.detect(in: root) ?? KnowledgeBaseLayout(language: language)
        let fm = FileManager.default
        var created: [String] = []

        func folder(_ path: String) throws {
            let url = root.appending(path: path, directoryHint: .isDirectory)
            var isDir: ObjCBool = false
            guard !fm.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) else { return }
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            created.append(path)
        }
        func file(_ path: String, _ text: String) throws {
            let url = root.appending(path: path)
            guard !fm.fileExists(atPath: url.path(percentEncoded: false)) else { return }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
            created.append(path)
        }

        for path in skeleton ? layout.allFolders : [layout.system] { try folder(path) }
        let s = SystemFileText(layout: layout, date: date)
        try file(layout.rulesFile, s.rules(rules ?? OrganizingPolicy.defaultText(layout.language)))
        try file(layout.logFile, s.log)
        try file(layout.indexFile, s.index)
        try file(layout.duplicatesFile, s.duplicates)
        for name in EntryFiles.names {
            try file(name, EntryFiles.newFile(name, in: root, layout: layout))
        }
        return created
    }
}

/// The starting text of the system files, in the layout's language.
struct SystemFileText {
    let layout: KnowledgeBaseLayout
    let date: Date

    private var day: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    func rules(_ policy: String) -> String {
        switch layout.language {
        case .simplifiedChinese:
            return "<!-- 这是本知识库的整理规则：Inkstone 和任何 AI 智能体整理时都按它执行。可以直接改；它优先于应用里的默认规则。创建于 \(day)。 -->\n\n## 我的规则\n\n（在这里写你自己的规则，例如：「发票 → 20-领域/财务/发票/」。它们排在下面的默认策略之前。）\n\n\(policy)"
        case .traditionalChinese:
            return "<!-- 這是本知識庫的整理規則：Inkstone 和任何 AI 智慧代理整理時都依它執行。可以直接改；它優先於 App 裡的預設規則。建立於 \(day)。 -->\n\n## 我的規則\n\n（在這裡寫你自己的規則，例如：「發票 → 20-領域/財務/發票/」。它們排在下面的預設策略之前。）\n\n\(policy)"
        case .english:
            return "<!-- This knowledge base's organizing rules: Inkstone and any AI agent follow them when organizing. Edit freely; they take precedence over the app's default rules. Created \(day). -->\n\n## My rules\n\n(Write your own rules here, e.g. \"Invoices → 20-Areas/Finance/Invoices/\". They come before the default policy below.)\n\n\(policy)"
        }
    }

    var log: String {
        switch layout.language {
        case .simplifiedChinese:
            return "# 整理日志\n\n每次移动和重命名都记在这里，可以据此完整回滚。最新的在最下面。\n\n| 时间 | 批次 | 操作 | 原路径 | 新路径 | 理由 |\n| --- | --- | --- | --- | --- | --- |\n"
        case .traditionalChinese:
            return "# 整理日誌\n\n每次移動和重新命名都記在這裡，可以據此完整復原。最新的在最下面。\n\n| 時間 | 批次 | 操作 | 原路徑 | 新路徑 | 理由 |\n| --- | --- | --- | --- | --- | --- |\n"
        case .english:
            return "# Organizing log\n\nEvery move and rename is recorded here, so everything can be undone. Newest at the bottom.\n\n| Time | Batch | Action | From | To | Reason |\n| --- | --- | --- | --- | --- | --- |\n"
        }
    }

    var index: String {
        switch layout.language {
        case .simplifiedChinese: return "路径,类型,日期,标签,摘要,SHA256\n"
        case .traditionalChinese: return "路徑,類型,日期,標籤,摘要,SHA256\n"
        case .english: return "path,type,date,tags,summary,sha256\n"
        }
    }

    var duplicates: String {
        switch layout.language {
        case .simplifiedChinese:
            return "# 重复记录\n\n去重从不直接删除：重复的文件移到 `\(layout.trash)/` 并记在这里。\n\n| 时间 | 保留 | 移走 | 依据 |\n| --- | --- | --- | --- |\n"
        case .traditionalChinese:
            return "# 重複紀錄\n\n去重從不直接刪除：重複的檔案移到 `\(layout.trash)/` 並記在這裡。\n\n| 時間 | 保留 | 移走 | 依據 |\n| --- | --- | --- | --- |\n"
        case .english:
            return "# Duplicates\n\nDeduplication never deletes: duplicates are moved to `\(layout.trash)/` and recorded here.\n\n| Time | Kept | Moved | Basis |\n| --- | --- | --- | --- |\n"
        }
    }
}
