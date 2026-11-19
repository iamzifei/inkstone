import Foundation

/// The language a knowledge base's skeleton was created in. Fixed at creation:
/// folder names are paths, and paths do not follow the interface language.
public enum KnowledgeBaseLanguage: String, CaseIterable, Codable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"

    /// The interface language a new knowledge base should use: Chinese scripts
    /// by their region/script, everything else English.
    public static func forInterface(_ identifier: String) -> KnowledgeBaseLanguage {
        let id = identifier.lowercased()
        if id.hasPrefix("zh") {
            return id.contains("hant") || id.contains("-tw") || id.contains("-hk") || id.contains("-mo")
                ? .traditionalChinese : .simplifiedChinese
        }
        return .english
    }
}

/// Where everything lives in a knowledge base: the folders of the organizing
/// policy (inbox, projects, areas, resources, media, outputs, private, review,
/// archive, system), named in the knowledge base's language.
///
/// The language is not stored anywhere: it is read back from the folders that
/// exist (`detect`), so the layout follows the vault to other devices with the
/// files themselves.
public struct KnowledgeBaseLayout: Equatable, Sendable {
    public let language: KnowledgeBaseLanguage

    public let inbox: String
    public let projects: String
    public let areas: String
    public let resources: String
    public let media: String
    public let mediaImages: String
    public let mediaVideo: String
    public let mediaAudio: String
    public let mediaDesign: String
    public let outputs: String
    public let privateFolder: String
    public let review: String
    public let archive: String
    public let trash: String
    public let oldVersions: String
    public let archivedProjects: String
    public let system: String
    public let rulesFile: String
    public let logFile: String
    public let indexFile: String
    public let duplicatesFile: String

    public init(language: KnowledgeBaseLanguage) {
        self.language = language
        let n: [String]
        switch language {
        case .simplifiedChinese:
            n = ["00-收件箱", "10-项目", "20-领域", "30-资料", "40-素材", "图片", "视频", "音频", "设计",
                 "50-产出", "私密", "_待确认", "_归档", "待删除", "旧版本", "项目",
                 "_系统", "整理规则.md", "整理日志.md", "文件索引.csv", "重复记录.md"]
        case .traditionalChinese:
            n = ["00-收件匣", "10-專案", "20-領域", "30-資料", "40-素材", "圖片", "影片", "音訊", "設計",
                 "50-產出", "私密", "_待確認", "_封存", "待刪除", "舊版本", "專案",
                 "_系統", "整理規則.md", "整理日誌.md", "檔案索引.csv", "重複紀錄.md"]
        case .english:
            n = ["00-Inbox", "10-Projects", "20-Areas", "30-Resources", "40-Media", "Images", "Video", "Audio", "Design",
                 "50-Outputs", "Private", "_Review", "_Archive", "To-Delete", "Old-Versions", "Projects",
                 "_System", "Organizing Rules.md", "Organizing Log.md", "File Index.csv", "Duplicates.md"]
        }
        inbox = n[0]; projects = n[1]; areas = n[2]; resources = n[3]; media = n[4]
        mediaImages = "\(n[4])/\(n[5])"; mediaVideo = "\(n[4])/\(n[6])"
        mediaAudio = "\(n[4])/\(n[7])"; mediaDesign = "\(n[4])/\(n[8])"
        outputs = n[9]; privateFolder = n[10]; review = n[11]; archive = n[12]
        trash = "\(n[12])/\(n[13])"; oldVersions = "\(n[12])/\(n[14])"; archivedProjects = "\(n[12])/\(n[15])"
        system = n[16]
        rulesFile = "\(n[16])/\(n[17])"; logFile = "\(n[16])/\(n[18])"
        indexFile = "\(n[16])/\(n[19])"; duplicatesFile = "\(n[16])/\(n[20])"
    }

    /// Every skeleton folder, parents before children.
    public var allFolders: [String] {
        [inbox, projects, areas, resources, media, mediaImages, mediaVideo, mediaAudio, mediaDesign,
         outputs, privateFolder, review, archive, trash, oldVersions, archivedProjects, system]
    }

    /// The folders that hold the knowledge base's own machinery: the
    /// organizer never files anything into these by itself.
    public var systemFolders: [String] { [system, archive, review] }

    /// The layout a folder already uses: its rules file, or at least two of
    /// its skeleton folders. One folder that merely shares a name (a vault of
    /// someone's own with a `_System` folder) is not enough. Nil for a plain or
    /// hand-made vault.
    public static func detect(in root: URL) -> KnowledgeBaseLayout? {
        let fm = FileManager.default
        func isDirectory(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: root.appending(path: path).path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
        }
        for language in KnowledgeBaseLanguage.allCases {
            let layout = KnowledgeBaseLayout(language: language)
            if fm.fileExists(atPath: root.appending(path: layout.rulesFile).path(percentEncoded: false)) { return layout }
            let present = [layout.inbox, layout.projects, layout.areas, layout.resources, layout.media,
                           layout.outputs, layout.review, layout.archive, layout.system].filter(isDirectory).count
            if present >= 2 { return layout }
        }
        return nil
    }
}
