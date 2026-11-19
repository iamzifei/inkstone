import Foundation

/// The knowledge base's rules file (`_系统/整理规则.md`): the person's own
/// rules first, then the organizing policy — the "prompt" Inkstone and any AI
/// agent follow. Edited in Settings as plain text; the file stays the one
/// source of truth (it is also what an agent reading AGENTS.md is sent to).
public enum RulesFile {
    public static func read(root: URL, layout: KnowledgeBaseLayout) -> String {
        (try? String(contentsOf: root.appending(path: layout.rulesFile), encoding: .utf8))
            ?? SystemFileText(layout: layout, date: .now).rules(OrganizingPolicy.defaultText(layout.language))
    }

    /// Saved atomically, keeping the file's metadata.
    public static func save(_ text: String, root: URL, layout: KnowledgeBaseLayout) throws {
        let url = root.appending(path: layout.rulesFile)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path(percentEncoded: false)) {
            try Metadata.overwriteInPlace(url, with: Data(text.utf8))
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        }
    }

    /// The text with the policy part put back to the default for its
    /// language, and everything before it — the header and the person's own
    /// rules — kept exactly. The policy starts at the first top-level heading
    /// (`# `) after the own-rules section; with no own-rules section the whole
    /// text is replaced by a fresh file.
    public static func restoringDefaultPolicy(_ text: String, language: KnowledgeBaseLanguage) -> String {
        let policy = OrganizingPolicy.defaultText(language)
        let lines = text.components(separatedBy: "\n")
        guard let rulesStart = lines.firstIndex(where: { OrganizingRules.sectionTitles.contains($0.trimmingCharacters(in: .whitespaces)) }) else {
            return SystemFileText(layout: KnowledgeBaseLayout(language: language), date: .now).rules(policy)
        }
        let policyStart = lines[(rulesStart + 1)...].firstIndex { $0.hasPrefix("# ") } ?? lines.count
        var head = lines[..<policyStart].joined(separator: "\n")
        while head.hasSuffix("\n\n\n") { head.removeLast() }
        if !head.hasSuffix("\n\n") { head += head.hasSuffix("\n") ? "\n" : "\n\n" }
        return head + policy
    }
}
