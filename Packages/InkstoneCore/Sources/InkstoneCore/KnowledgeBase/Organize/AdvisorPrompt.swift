import Foundation

/// The words sent to a model that advises where a file goes, and the reading
/// of its answer. Shared by the on-device model (guided generation) and a
/// person's own cloud model (JSON), so both see the same question.
///
/// Budgeted: Apple's on-device model has a 4,096-token window (about 3,600
/// characters to send), so the prompt is assembled piece by piece within a
/// character budget — the file first, then the folders, then the rules.
public enum AdvisorPrompt {
    public static func instructions(_ layout: KnowledgeBaseLayout) -> String {
        switch layout.language {
        case .simplifiedChinese:
            return """
            你是知识库整理助手。根据文件内容，从给出的文件夹里选一个最合适的放置位置。\
            只能选列出的文件夹，或在「\(layout.projects)」「\(layout.areas)」「\(layout.resources)」下新建一层子文件夹。\
            拿不准就把 confidence 设低于 0.7。不要编造文件里没有的信息。\
            涉及身份证件、银行、病历、密码等隐私内容时 isPrivate 设为 true。\
            title 用 2–6 个词概括主题，不要日期和扩展名。
            """
        case .traditionalChinese:
            return """
            你是知識庫整理助手。根據檔案內容，從給出的資料夾裡選一個最合適的放置位置。\
            只能選列出的資料夾，或在「\(layout.projects)」「\(layout.areas)」「\(layout.resources)」下新建一層子資料夾。\
            拿不準就把 confidence 設低於 0.7。不要編造檔案裡沒有的資訊。\
            涉及身分證件、銀行、病歷、密碼等隱私內容時 isPrivate 設為 true。\
            title 用 2–6 個詞概括主題，不要日期和副檔名。
            """
        case .english:
            return """
            You organize a knowledge base. From the file's content, pick the best folder for it from the list. \
            Only pick a listed folder, or a new subfolder one level under "\(layout.projects)", "\(layout.areas)" or "\(layout.resources)". \
            If unsure, set confidence below 0.7. Never invent facts that are not in the file. \
            Set isPrivate to true for ID documents, bank, medical or password content. \
            title: 2–6 words naming the topic, no date or extension.
            """
        }
    }

    /// The question about one file, within `budget` characters.
    public static func prompt(_ facts: FileFacts, context: AdvisorContext, budget: Int = 3_000) -> String {
        let layout = context.layout
        let en = layout.language == .english
        var out = en ? "File: \(facts.name).\(facts.ext) (\(facts.kind.rawValue))" : "文件：\(facts.name).\(facts.ext)（\(facts.kind.rawValue)）"
        if let title = facts.title, !title.isEmpty { out += en ? "\nTitle: \(title)" : "\n标题：\(title)" }
        let excerpt = facts.text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .prefix(max(0, budget / 2 - out.count))
        if !excerpt.isEmpty { out += (en ? "\nContent: " : "\n内容：") + excerpt }

        // Folders a file may go in: the machinery left out.
        let allowed = context.folders.filter { folder in
            !(layout.systemFolders + [layout.inbox]).contains { folder == $0 || folder.hasPrefix($0 + "/") }
        }
        var folders = en ? "\n\nFolders:" : "\n\n文件夹："
        for f in allowed {
            let line = "\n- \(f)"
            if out.count + folders.count + line.count > budget * 5 / 6 { break }
            folders += line
        }
        out += folders

        // The person's own rules, if any fit.
        let own = ownRules(context.rules)
        if !own.isEmpty {
            let head = en ? "\n\nMy rules:\n" : "\n\n我的规则：\n"
            let room = budget - out.count - head.count
            if room > 40 { out += head + own.prefix(room) }
        }
        return String(out.prefix(budget))
    }

    /// The own-rules section of the rules file, prose included (the model can
    /// read sentences the parser cannot).
    static func ownRules(_ text: String) -> String {
        var inSection = false
        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if OrganizingRules.sectionTitles.contains(t) { inSection = true; continue }
            if inSection, t.hasPrefix("#") { break }
            if inSection, !t.isEmpty, !t.hasPrefix("<!--") { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    /// The JSON a cloud model is asked to answer with.
    public static let jsonShape = #"{"folder": "...", "confidence": 0.0, "title": "...", "tags": ["..."], "summary": "...", "isPrivate": false, "reason": "..."}"#

    /// Reads a model's JSON answer (the first `{…}` object in the text, so a
    /// sentence or a code fence around it does not matter). Nil when it is
    /// not there or has no folder.
    public static func parse(_ text: String) -> PlacementAdvice? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let folder = object["folder"] as? String, !folder.isEmpty else { return nil }
        let confidence = (object["confidence"] as? NSNumber)?.doubleValue ?? 0
        return PlacementAdvice(
            folder: folder,
            confidence: min(max(confidence, 0), 1),
            title: (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            tags: (object["tags"] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty }.prefix(8).map { $0 } ?? [],
            summary: (object["summary"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) },
            isPrivate: (object["isPrivate"] as? Bool) ?? false,
            reason: String(((object["reason"] as? String) ?? "").prefix(120)))
    }
}
