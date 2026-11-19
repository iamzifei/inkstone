import Foundation

/// Making a knowledge base for someone who has never heard the word "vault":
/// a new folder with the skeleton and entry files, or an existing folder
/// adopted as one (only the system folder and entry files are added — none of
/// their files move).
public enum KnowledgeBaseCreator {
    public static func defaultName(_ language: KnowledgeBaseLanguage) -> String {
        switch language {
        case .simplifiedChinese: return "我的知识库"
        case .traditionalChinese: return "我的知識庫"
        case .english: return "My Knowledge Base"
        }
    }

    /// A name usable as a folder name: no path separators or characters
    /// Finder or Windows refuse, no leading dot, not empty.
    public static func folderName(_ raw: String, language: KnowledgeBaseLanguage) -> String {
        var name = raw.replacingOccurrences(of: #"[/\\:*?"<>|\x00-\x1F]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        while name.utf8.count > 200 { name.removeLast() }
        return name.isEmpty ? defaultName(language) : name
    }

    /// Creates `<parent>/<name>` — or `<name> 2`, `<name> 3` … when a folder
    /// with files in it already has that name (an empty one is used as is) —
    /// and lays out the knowledge base in it. Returns the folder.
    @discardableResult
    public static func create(named raw: String, in parent: URL, language: KnowledgeBaseLanguage) throws -> URL {
        let fm = FileManager.default
        let base = folderName(raw, language: language)
        var folder = parent.appending(path: base, directoryHint: .isDirectory)
        var n = 2
        while fm.fileExists(atPath: folder.path(percentEncoded: false)) {
            let contents = (try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? ["x"]
            if contents.allSatisfy({ $0 == ".DS_Store" }) { break }
            folder = parent.appending(path: "\(base) \(n)", directoryHint: .isDirectory)
            n += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try VaultBlueprint.apply(to: folder, language: language)
        return folder
    }

    /// Makes an existing folder a knowledge base without touching its files:
    /// adds the system folder (rules, log, index) and the entry files, or —
    /// for an empty folder — the whole skeleton.
    @discardableResult
    public static func adopt(_ folder: URL, language: KnowledgeBaseLanguage) throws -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let isEmpty = contents.allSatisfy { $0.hasPrefix(".") }
        var created = try VaultBlueprint.apply(to: folder, language: language, skeleton: isEmpty)
        // An inbox, so there is somewhere to drop things (the rest of the
        // skeleton is made as the organizer needs it).
        let layout = KnowledgeBaseLayout.detect(in: folder) ?? KnowledgeBaseLayout(language: language)
        let inbox = folder.appending(path: layout.inbox, directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: inbox.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            created.append(layout.inbox)
        }
        return created
    }
}
