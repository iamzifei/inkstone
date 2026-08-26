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
/// Which repository a single vault syncs with.
///
/// Deliberately not `SyncFilePolicy` or the interval: those are preferences and
/// sharing them across vaults is harmless. A *repository* is an identity. The
/// three fields here are the ones that decide which bytes go where.
public struct VaultSyncBinding: Codable, Hashable, Sendable {
    /// "owner/repository".
    public var repository: String
    public var branch: String
    /// Whether this vault syncs at all. A vault with no binding does not sync,
    /// rather than borrowing another vault's.
    public var isEnabled: Bool

    public init(repository: String = "", branch: String = "main", isEnabled: Bool = false) {
        self.repository = repository
        self.branch = branch
        self.isEnabled = isEnabled
    }

    /// Whether this binding names somewhere to sync to.
    public var isConfigured: Bool { !repository.isEmpty }
}

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

    /// Whether to keep an iCloud-backed vault's files present on disk.
    ///
    /// On by default: a vault in iCloud whose notes have been evicted looks like
    /// a vault that has lost notes. Turning it off leaves eviction alone, which
    /// is what you want on a machine short of disk space.
    public var iCloudSyncEnabled = true

    /// Which repository each vault syncs with, keyed by vault id.
    ///
    /// **This used to be one global repository shared by every vault, and that
    /// was the bug.** Opening a second vault made it inherit the first one's
    /// repository and immediately start making that repository look like itself.
    /// It cost content twice: `Samples/Inkstone Demo/` was deleted out of
    /// this repository on 2026-08-18 by a vault that did not contain it, and
    /// a phone vault pointed at `a private notes repository` spent four days fighting
    /// the Mac copy of that vault — 1409 commits, conflict copies every hour,
    /// renamed notes reappearing under their old names.
    ///
    /// A binding is per vault and per device. Vault ids are generated where the
    /// vault is added, so two devices holding the same folder use different
    /// keys; that is fine, because this map never leaves the device it belongs
    /// to. What crosses devices is `GitHubSyncConfiguration`, and it may no
    /// longer introduce a repository to a vault that has none.
    public var vaultSync: [String: VaultSyncBinding] = [:]

    /// Whether GitHub sync is active.
    ///
    /// - Warning: **Legacy.** Read once, by the migration onto `vaultSync`, and
    ///   never again. Kept because removing a key would silently discard it
    ///   before the migration has run. Use `Workspace.syncBinding`.
    public var gitHubSyncEnabled = false

    /// Sync with GitHub on its own, rather than only when asked.
    public var gitHubAutoSync = true
    /// How often to sync while the app is open. 0 syncs only when a vault opens.
    public var gitHubSyncIntervalMinutes = 15

    /// The assistant panel: profiles, the active one, and whether it is on.
    ///
    /// API keys are **not** here, for the same reason the GitHub token is not:
    /// this struct is a plain JSON blob in UserDefaults. Each profile names a
    /// Keychain account instead.
    public var assistant = AssistantSettings()

    /// Which file types take part in sync.
    public var syncPolicy = SyncFilePolicy()
    /// "owner/repository" for GitHub sync. The token lives in the Keychain, not
    /// here — this struct is a plain JSON blob in UserDefaults.
    ///
    /// - Warning: **Legacy**, as `gitHubSyncEnabled` above. Use
    ///   `Workspace.syncBinding`.
    public var gitHubRepository = ""
    /// - Warning: **Legacy.** Use `Workspace.syncBinding`.
    public var gitHubBranch = "main"

    /// Vault ids the user has explicitly allowed to sync despite being a git
    /// working copy. Empty by default: the guard protects, this respects.
    public var syncOverridesGit: Set<String> = []

    /// Retained so settings written by the version that had it still decode
    /// their other keys. The migration is now per vault and decided by that
    /// vault's own `.inkstone/sync.json`, so there is no single moment it is
    /// "done" and nothing reads this.
    public var didMigrateSyncBindings = false
    /// When this device last changed the GitHub setup, so the copy shared
    /// between devices can tell which side is newer. Bookkeeping, not a setting.
    public var gitHubConfigurationUpdatedAt: Date?

    // Graph. Named and scaled to match Obsidian's graph panel, so a reading
    // taken there means the same thing here.
    /// Off, as in Obsidian: a tag node joins every note carrying it, which on a
    /// vault that tags consistently buries the actual link structure.
    public var graphShowTags = false
    public var graphShowAttachments = false
    /// Obsidian words this the other way round, as "Existing files only".
    public var graphShowUnresolved = true
    /// Notes with no links at all. Most vaults are mostly orphans, so this is
    /// the toggle that decides whether the graph is a map or a dust cloud.
    public var graphShowOrphans = true
    /// Draw links as arrows rather than plain lines.
    public var graphArrows = false
    /// Zoom below which labels fade out. 0 keeps them on at every zoom.
    public var graphTextFadeThreshold = 0.0
    /// Multiplier on node radius, 0.1…5.
    public var graphNodeSize = 1.0
    /// Multiplier on link width, 0.1…5.
    public var graphLinkThickness = 1.0
    /// Pull toward the centre, 0…1.
    public var graphCentreForce = 0.52
    /// Node-to-node repulsion, 0…20.
    public var graphRepelForce = 10.0
    /// Spring stiffness along links, 0…1.
    public var graphLinkForce = 1.0
    /// Spring rest length, 30…500.
    public var graphLinkDistance = 250.0
    /// Colour groups: a search query and the colour nodes matching it take.
    public var graphGroups: [GraphGroup] = []

    /// One colour group in the graph: everything matching `query` is drawn in
    /// `colour` instead of its usual colour.
    ///
    /// The query is the same one the search pane takes — plain text matches the
    /// path, `tag:` matches a tag — so there is one thing to learn rather than two.
    public struct GraphGroup: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var query: String
        /// sRGB, 0…1.
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(id: UUID = UUID(), query: String = "", red: Double, green: Double, blue: Double) {
            self.id = id
            self.query = query
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// The colours new groups cycle through, so two groups made in a row are
        /// told apart without anyone reaching for a colour picker.
        public static let palette: [(red: Double, green: Double, blue: Double)] = [
            (0.42, 0.36, 0.90),   // indigo
            (0.90, 0.49, 0.24),   // orange
            (0.24, 0.68, 0.44),   // green
            (0.85, 0.32, 0.48),   // rose
            (0.28, 0.62, 0.85),   // sky
            (0.76, 0.62, 0.20),   // amber
        ]

        public static func next(after existing: [GraphGroup]) -> GraphGroup {
            let colour = palette[existing.count % palette.count]
            return GraphGroup(query: "", red: colour.red, green: colour.green, blue: colour.blue)
        }
    }

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
        iCloudSyncEnabled = value(.iCloudSyncEnabled, defaults.iCloudSyncEnabled)
        gitHubSyncEnabled = value(.gitHubSyncEnabled, defaults.gitHubSyncEnabled)
        gitHubAutoSync = value(.gitHubAutoSync, defaults.gitHubAutoSync)
        gitHubSyncIntervalMinutes = value(.gitHubSyncIntervalMinutes, defaults.gitHubSyncIntervalMinutes)
        syncPolicy = value(.syncPolicy, defaults.syncPolicy)
        gitHubRepository = value(.gitHubRepository, defaults.gitHubRepository)
        gitHubBranch = value(.gitHubBranch, defaults.gitHubBranch)
        // Every stored property needs a line here. The synthesised `CodingKeys`
        // picks new properties up automatically and this hand-written decoder
        // does not — a property added above and forgotten below silently decodes
        // as its default forever, which for these three would mean every vault
        // losing the repository it is bound to on the next launch.
        vaultSync = value(.vaultSync, defaults.vaultSync)
        syncOverridesGit = value(.syncOverridesGit, defaults.syncOverridesGit)
        didMigrateSyncBindings = value(.didMigrateSyncBindings, defaults.didMigrateSyncBindings)
        gitHubConfigurationUpdatedAt = value(.gitHubConfigurationUpdatedAt, defaults.gitHubConfigurationUpdatedAt)

        graphShowTags = value(.graphShowTags, defaults.graphShowTags)
        graphShowAttachments = value(.graphShowAttachments, defaults.graphShowAttachments)
        graphShowUnresolved = value(.graphShowUnresolved, defaults.graphShowUnresolved)
        graphShowOrphans = value(.graphShowOrphans, defaults.graphShowOrphans)
        graphArrows = value(.graphArrows, defaults.graphArrows)
        graphTextFadeThreshold = value(.graphTextFadeThreshold, defaults.graphTextFadeThreshold)
        graphNodeSize = value(.graphNodeSize, defaults.graphNodeSize)
        graphLinkThickness = value(.graphLinkThickness, defaults.graphLinkThickness)
        graphCentreForce = value(.graphCentreForce, defaults.graphCentreForce)
        graphRepelForce = value(.graphRepelForce, defaults.graphRepelForce)
        graphLinkForce = value(.graphLinkForce, defaults.graphLinkForce)
        graphLinkDistance = value(.graphLinkDistance, defaults.graphLinkDistance)
        graphGroups = value(.graphGroups, defaults.graphGroups)
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
        // Settings saved before the assistant existed decode with an empty
        // profile list, which would leave the panel offering nothing to pick.
        data.assistant.seedIfEmpty()
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
