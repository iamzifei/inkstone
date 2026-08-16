import Foundation
import os

/// UI languages Inkstone ships with.
public enum AppLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    public var id: String { rawValue }

    /// Name shown in the picker, always written in the language itself so users
    /// can find their language without reading the current one.
    public var endonym: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        }
    }

    public var localeIdentifier: String? {
        self == .system ? nil : rawValue
    }
}

public enum AppearanceMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
}

/// How the editor presents Markdown.
public enum EditorMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Syntax is hidden except on the line the cursor is on — Obsidian's default.
    case livePreview
    /// Raw Markdown with syntax highlighting.
    case source
    /// Fully rendered, read-only.
    case reading
    public var id: String { rawValue }
}

/// Everything the user can configure, persisted as one JSON blob.
///
/// A single serialised value keeps migration simple and makes it trivial to
/// export/import settings or sync them alongside the vault later.
public struct SettingsData: Codable, Hashable, Sendable {
    public var language: AppLanguage = .system
    public var appearance: AppearanceMode = .system
    public var themeID: String = Theme.inkstone.id
    public var typography = Typography()
    public var editorMode: EditorMode = .livePreview

    // Editor behaviour
    public var showLineNumbers = false
    /// Off by default. In Markdown the checker flags LaTeX, code, wikilinks and
    /// tags as misspellings, and on collapsed syntax the squiggle shrinks to a
    /// stray red dot under the rendered content. Obsidian defaults to off too.
    public var spellCheck = false
    public var autoPairBrackets = true
    /// Turns `- ` into a continued list on Return, and continues checkboxes.
    public var smartLists = true
    public var showFrontmatterAsProperties = true
    public var indentWithTabs = false
    public var tabSize = 4

    // Links
    /// Insert `[[Note]]` (shortest form) rather than a full path.
    public var useShortestPathLinks = true
    /// Update links in other notes when a note is renamed.
    public var updateLinksOnRename = true
    /// Wrap the alias automatically when linking to a note with a display name.
    public var newLinkFormat: LinkFormat = .wikilink

    // Daily notes / calendar
    public var dailyNoteFolder = "Daily"
    public var dailyNoteFormat = "yyyy-MM-dd"
    public var dailyNoteTemplate = ""
    public var weekStartsOnMonday = true

    // Files
    public var attachmentFolder = "Attachments"
    public var defaultNewNoteFolder = ""

    /// Which file types take part in sync.
    public var syncPolicy = SyncFilePolicy()
    /// "owner/repository" for GitHub sync. The token lives in the Keychain, not
    /// here — this struct is a plain JSON blob in UserDefaults.
    public var gitHubRepository = ""
    public var gitHubBranch = "main"

    // Graph
    public var graphShowTags = true
    public var graphShowAttachments = false
    public var graphShowUnresolved = true

    public enum LinkFormat: String, Codable, CaseIterable, Sendable, Identifiable {
        case wikilink      // [[Note]]
        case markdown      // [Note](Note.md)
        public var id: String { rawValue }
    }

    public init() {}

    /// Decodes leniently: any key that is absent keeps its default.
    ///
    /// This is not a nicety, it is a data-loss guard. Settings are loaded with
    /// `try? JSONDecoder().decode(...)`, and Swift's synthesised decoding treats
    /// a *missing* key as an error even when the property has a default value.
    /// With synthesised decoding, therefore, adding any new field to this struct
    /// makes every settings file written by an earlier build fail to decode — and
    /// because the failure is swallowed by `try?`, the user silently loses every
    /// preference they had set. Decoding field by field means an old file simply
    /// picks up defaults for whatever is new.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        let defaults = SettingsData()

        language = value(.language, defaults.language)
        appearance = value(.appearance, defaults.appearance)
        themeID = value(.themeID, defaults.themeID)
        typography = value(.typography, defaults.typography)
        editorMode = value(.editorMode, defaults.editorMode)

        showLineNumbers = value(.showLineNumbers, defaults.showLineNumbers)
        spellCheck = value(.spellCheck, defaults.spellCheck)
        autoPairBrackets = value(.autoPairBrackets, defaults.autoPairBrackets)
        smartLists = value(.smartLists, defaults.smartLists)
        showFrontmatterAsProperties = value(.showFrontmatterAsProperties, defaults.showFrontmatterAsProperties)
        indentWithTabs = value(.indentWithTabs, defaults.indentWithTabs)
        tabSize = value(.tabSize, defaults.tabSize)

        useShortestPathLinks = value(.useShortestPathLinks, defaults.useShortestPathLinks)
        updateLinksOnRename = value(.updateLinksOnRename, defaults.updateLinksOnRename)
        newLinkFormat = value(.newLinkFormat, defaults.newLinkFormat)

        dailyNoteFolder = value(.dailyNoteFolder, defaults.dailyNoteFolder)
        dailyNoteFormat = value(.dailyNoteFormat, defaults.dailyNoteFormat)
        dailyNoteTemplate = value(.dailyNoteTemplate, defaults.dailyNoteTemplate)
        weekStartsOnMonday = value(.weekStartsOnMonday, defaults.weekStartsOnMonday)

        attachmentFolder = value(.attachmentFolder, defaults.attachmentFolder)
        defaultNewNoteFolder = value(.defaultNewNoteFolder, defaults.defaultNewNoteFolder)
        syncPolicy = value(.syncPolicy, defaults.syncPolicy)
        gitHubRepository = value(.gitHubRepository, defaults.gitHubRepository)
        gitHubBranch = value(.gitHubBranch, defaults.gitHubBranch)

        graphShowTags = value(.graphShowTags, defaults.graphShowTags)
        graphShowAttachments = value(.graphShowAttachments, defaults.graphShowAttachments)
        graphShowUnresolved = value(.graphShowUnresolved, defaults.graphShowUnresolved)
    }
}

/// Observable settings store backed by `UserDefaults`.
@MainActor
@Observable
public final class AppSettings {
    public var data: SettingsData {
        didSet { persist() }
    }

    /// User-installed themes loaded from the vault's `.inkstone/themes` folder,
    /// merged with the built-ins.
    public private(set) var availableThemes: [Theme] = Theme.builtIn

    private let defaults: UserDefaults
    private let key = "com.orris.inkstone.settings"
    private let logger = Logger(subsystem: "com.orris.inkstone", category: "Settings")

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: stored) {
            data = decoded
        } else {
            data = SettingsData()
        }
    }

    public var theme: Theme {
        availableThemes.first { $0.id == data.themeID } ?? .inkstone
    }

    /// Loads `.json` themes from a vault so users can drop in community themes.
    public func loadThemes(fromVault root: URL) {
        let folder = root.appending(path: ".inkstone/themes", directoryHint: .isDirectory)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ) else {
            availableThemes = Theme.builtIn
            return
        }
        var loaded = Theme.builtIn
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let theme = try? JSONDecoder().decode(Theme.self, from: data) else {
                logger.warning("Skipping malformed theme: \(file.lastPathComponent, privacy: .public)")
                continue
            }
            loaded.append(theme)
        }
        availableThemes = loaded
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(data), forKey: key)
        } catch {
            logger.error("Failed to persist settings: \(error.localizedDescription)")
        }
    }
}
