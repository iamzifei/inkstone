import Foundation

/// The knowledge base's rules file (`_系统/整理规则.md`): the person's own
/// rules first, then the organizing policy — the "prompt" Inkstone and any AI
/// agent follow. Edited in Settings as plain text; the file stays the one
/// source of truth (it is also what an agent reading AGENTS.md is sent to).
public enum RulesFile {
    public enum SaveError: Error, Equatable {
        /// The file changed on disk (a sync, another app) since it was read.
        case changedOnDisk(String)
    }

    /// The file's text — nil when it can't be read (not downloaded from
    /// iCloud yet, not UTF-8). Never the defaults in its place: saving those
    /// would replace the person's real rules.
    public static func read(root: URL, layout: KnowledgeBaseLayout) -> String? {
        try? String(contentsOf: root.appending(path: layout.rulesFile), encoding: .utf8)
    }

    /// Saved atomically, keeping the file's metadata — only if the file is
    /// still what the editor started from (`expected`); otherwise
    /// `changedOnDisk` with what is there now, and nothing is written.
    public static func save(_ text: String, expected: String, root: URL, layout: KnowledgeBaseLayout) throws {
        let url = root.appending(path: layout.rulesFile)
        guard let current = read(root: root, layout: layout) else { throw CocoaError(.fileReadNoPermission) }
        guard current == expected else { throw SaveError.changedOnDisk(current) }
        try Metadata.overwriteInPlace(url, with: Data(text.utf8))
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
        // The policy's own title line when it is there (a "# " line the
        // person wrote among their rules is theirs); else the first "# ".
        let titles = KnowledgeBaseLanguage.allCases.compactMap { OrganizingPolicy.defaultText($0).components(separatedBy: "\n").first }
        let after = lines[(rulesStart + 1)...]
        let policyStart = after.firstIndex { titles.contains($0.trimmingCharacters(in: .whitespaces)) }
            ?? after.firstIndex { $0.hasPrefix("# ") } ?? lines.count
        var head = lines[..<policyStart].joined(separator: "\n")
        while head.hasSuffix("\n\n\n") { head.removeLast() }
        if !head.hasSuffix("\n\n") { head += head.hasSuffix("\n") ? "\n" : "\n\n" }
        return head + policy
    }
}
