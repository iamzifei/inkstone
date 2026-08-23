import Foundation
import Observation
import SwiftUI
import InkstoneCore

/// What an open tab is showing.
enum TabContent: Hashable, Identifiable {
    case note(URL)
    case canvas(URL)
    case graph
    case calendar

    var id: String {
        switch self {
        case .note(let url): return "note:" + url.path(percentEncoded: false)
        case .canvas(let url): return "canvas:" + url.path(percentEncoded: false)
        case .graph: return "graph"
        case .calendar: return "calendar"
        }
    }

    var url: URL? {
        switch self {
        case .note(let url), .canvas(let url): return url
        case .graph, .calendar: return nil
        }
    }
}

/// Which pane the sidebar is showing.
enum SidebarSection: String, CaseIterable, Identifiable {
    case files, search, tags, links, outline
    var id: String { rawValue }
}

/// The application's central state: the open vault, its index, and the tabs.
///
/// Deliberately one object rather than several: nearly every action (open a link,
/// rename a note, follow a tag) touches the vault, the index, and the tab stack
/// together, and splitting them would only spread the coordination around.
@MainActor
@Observable
final class Workspace {
    // MARK: - Dependencies

    let registry: VaultRegistry
    let settings: AppSettings

    // MARK: - Vault state

    private(set) var vault: Vault?
    private(set) var root: URL?
    private(set) var store: NoteStore?
    private(set) var tree: FileNode?
    private(set) var index = IndexSnapshot()

    /// Bumped whenever the index is replaced.
    ///
    /// The editor styles a link by asking the index whether its target exists,
    /// and it does that once, when it highlights. Indexing is asynchronous, so
    /// the first render of the first note after opening a vault asks an *empty*
    /// index — every wikilink came out unresolved and every `![[Note]]` embed
    /// failed to find its content, and nothing put it right until the next
    /// keystroke. SwiftUI panes observe `index` directly; the editor is a wrapped
    /// text view and needs to be told.
    private(set) var indexGeneration = 0
    /// Non-note files, so `![[diagram.png]]` can resolve. Rebuilt with the tree.
    private(set) var attachments = AttachmentIndex()
    private(set) var isIndexing = false

    // MARK: - Editing state

    /// Open documents, keyed by URL. Kept alive across tab switches so scroll
    /// position and unsaved edits survive.
    private(set) var documents: [URL: NoteDocument] = [:]

    /// The text `![[Note#fragment]]` should show, or nil if there is nothing to
    /// show for it.
    ///
    /// Only Markdown: an `![[image.png]]` is an attachment and is resolved
    /// elsewhere. Returning nil rather than an empty string matters — an embed
    /// naming a heading the note does not have should read as unresolved, not as
    /// an empty box.
    func embeddedNoteText(for link: WikiLink, from source: URL) -> String? {
        #if DEBUG
        func trace(_ why: String) {
            if ProcessInfo.processInfo.environment["INKSTONE_EMBED_TRACE"] != nil {
                FileHandle.standardError.write(Data("[embed] \(link.target): \(why)\n".utf8))
            }
        }
        #else
        func trace(_ why: String) {}
        #endif

        guard let root, !link.target.isEmpty else { trace("no vault root"); return nil }
        guard let destination = index.resolve(link.target, from: source, vaultRoot: root) else {
            trace("index could not resolve it — index holds \(index.noteCount) notes, "
                  + "names: \(index.namesToNotes.keys.sorted().prefix(6).joined(separator: ", "))")
            return nil
        }
        guard destination.pathExtension.lowercased() == "md" else {
            trace("resolved to \(destination.pathExtension), not markdown")
            return nil
        }
        guard destination != source else { trace("embeds itself"); return nil }
        guard let text = try? String(contentsOf: destination, encoding: .utf8) else {
            trace("could not read \(destination.lastPathComponent)")
            return nil
        }
        trace("resolved to \(destination.lastPathComponent), \(text.count) chars")

        let range = NoteSlice.range(in: text, fragment: link.fragment)
        guard range.length > 0 else { return nil }
        let slice = (text as NSString).substring(with: range)
        return slice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : slice
    }

    /// A request from elsewhere in the UI — the outline, for now — to bring a
    /// particular range of the open note into view.
    ///
    /// A value rather than a method call because the editor is a wrapped
    /// `NSTextView`/`UITextView` several layers down, and SwiftUI's way to reach
    /// it is to change something it observes. `token` makes repeated requests for
    /// the *same* range distinct, so tapping one heading twice scrolls twice.
    struct RevealTarget: Equatable {
        let url: URL
        let range: NSRange
        let token: Int
    }

    private(set) var revealTarget: RevealTarget?
    private var revealToken = 0

    /// Scrolls the editor to `range` in `url`, opening the note first if needed.
    func reveal(_ range: NSRange, in url: URL) {
        if activeTab?.url != url { openNote(at: url) }
        revealToken += 1
        revealTarget = RevealTarget(url: url, range: range, token: revealToken)
    }

    var tabs: [TabContent] = []
    var activeTab: TabContent? {
        didSet {
            guard let activeTab, activeTab != oldValue else { return }
            pushHistory(activeTab)
        }
    }

    var sidebarSection: SidebarSection = .files
    var isQuickSwitcherPresented = false
    var searchQuery = ""

    /// Back/forward navigation, like a browser. Cheap to maintain and users
    /// expect it the moment links exist.
    private(set) var history: [TabContent] = []
    private(set) var historyIndex = -1
    private var isNavigatingHistory = false

    private var watcher: VaultWatcher?
    private let indexBuilder = IndexBuilder()
    private var reindexTask: Task<Void, Never>?

    init(registry: VaultRegistry = VaultRegistry(), settings: AppSettings = AppSettings()) {
        self.registry = registry
        self.settings = settings
    }

    // MARK: - Vault lifecycle

    /// Opens a vault.
    ///
    /// `startingBackgroundWork` exists for the one caller that is not a person:
    /// the iOS background task handler. Opening normally starts a sync and the
    /// repeat timer, which is right when someone has just picked a vault and
    /// wrong when the OS woke a scene-less process to do exactly one sync — that
    /// combination gave two `sync()` runs racing over the same working tree.
    func open(_ vault: Vault, startingBackgroundWork: Bool = true) {
        closeCurrentVault()
        do {
            let url = try registry.beginAccess(to: vault)
            self.vault = vault
            root = url
            store = NoteStore(root: url)
            settings.loadThemes(fromVault: url)

            // A vault in iCloud may have had notes evicted to save disk space,
            // leaving hidden placeholders in their place. Ask for them back, off
            // the main thread — the watcher rescans as they land.
            if settings.data.iCloudSyncEnabled && vault.isCloudBacked {
                Task.detached(priority: .utility) { ICloudFiles.requestDownloads(in: url) }
            }

            // Before the auto-sync below can read a binding.
            migrateSyncBindingIfNeeded(for: vault, root: url)

            refreshTree()
            reindex()
            startWatching(url)

            if startingBackgroundWork {
                if settings.data.gitHubAutoSync {
                    Task { await syncIfEnabled() }
                }
                restartAutoSync()
            }
        } catch {
            self.vault = nil
            root = nil
            store = nil
        }
    }

    /// Reopens the most recently used vault, if none is open.
    ///
    /// Lives here rather than in the App struct because a background launch
    /// needs it too. `InkstoneApp` opened the last vault from `.onAppear`, which
    /// only fires when a scene is actually rendered — and iOS waking the app for
    /// a background task renders nothing. Sync would then find no vault, do
    /// nothing, and report success.
    func openMostRecentVaultIfNeeded(startingBackgroundWork: Bool = true) {
        guard vault == nil,
              let latest = registry.vaults.max(by: { $0.lastOpened < $1.lastOpened })
        else { return }
        open(latest, startingBackgroundWork: startingBackgroundWork)
    }

    /// Syncs only if it is configured and switched on, and stays quiet
    /// otherwise. Used by the automatic paths, which must not surface a "not
    /// configured" error to someone who never asked for GitHub sync.
    func syncIfEnabled() async {
        guard canSync else { return }
        await sync()
    }

    /// Restarts the periodic sync to match the current settings.
    func restartAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil

        guard syncBinding.isEnabled, !isBlockedByGitWorkingCopy,
              settings.data.gitHubAutoSync else { return }
        let minutes = settings.data.gitHubSyncIntervalMinutes
        guard minutes > 0 else { return }

        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard !Task.isCancelled else { return }
                await self?.syncIfEnabled()
            }
        }
    }

    /// Removes a vault from Inkstone's list, leaving the folder on disk alone.
    ///
    /// The registry has had `forget` since the beginning and nothing ever called
    /// it, so a vault added by mistake could not be got rid of. That is how a
    /// folder belonging to another app — picked once through the document
    /// picker — stayed in the list and kept syncing.
    ///
    /// Takes the vault's sync binding with it. Leaving one behind would mean a
    /// folder re-added later silently inheriting a repository it was bound to in
    /// some forgotten session, which is the class of bug this whole change is
    /// about.
    func forget(_ vault: Vault) {
        if self.vault?.id == vault.id { closeCurrentVault() }
        settings.data.vaultSync.removeValue(forKey: vault.id.uuidString)
        settings.data.syncOverridesGit.remove(vault.id.uuidString)
        registry.forget(vault)
    }

    func closeCurrentVault() {
        saveAll()
        autoSyncTask?.cancel()
        autoSyncTask = nil
        watcher?.stop()
        watcher = nil
        if let vault { registry.endAccess(to: vault) }
        vault = nil
        root = nil
        store = nil
        tree = nil
        index = IndexSnapshot()
        documents.removeAll()
        tabs.removeAll()
        activeTab = nil
        history.removeAll()
        historyIndex = -1
    }

    private func startWatching(_ url: URL) {
        let watcher = VaultWatcher(root: url) { [weak self] in
            Task { @MainActor in
                self?.handleExternalChange()
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    private func handleExternalChange() {
        refreshTree()
        reindex()
        for document in documents.values {
            document.reloadIfUnchangedLocally()
        }
    }

    // MARK: - Index

    func refreshTree() {
        guard let root else { return }
        let scanned = VaultScanner().scan(root)
        tree = scanned
        attachments = AttachmentIndex(tree: scanned)
    }

    // MARK: - Sync

    /// Where a sync run has got to, for the settings pane to display.
    enum SyncStatus: Equatable {
        case idle
        case running(String)
        case finished(SyncReport)
        case failed(String)
        /// Cut short rather than broken. Distinct from `failed` because the
        /// honest thing to tell someone is different: nothing went wrong, the
        /// run simply ran out of time, what it managed is kept, and the next run
        /// picks up from there. Reporting that as a failure is what makes a
        /// working background sync look like a broken one.
        case interrupted
    }

    private(set) var syncStatus: SyncStatus = .idle

    /// How far the running sync has got. `nil` when nothing is running, and
    /// present with a `nil` fraction during the phases before the plan exists.
    private(set) var syncProgress: SyncProgress?

    /// The repeating background sync, cancelled when the vault closes or the
    /// interval changes.
    @ObservationIgnored private var autoSyncTask: Task<Void, Never>?
    var isSyncing: Bool { if case .running = syncStatus { return true }; return false }

    /// Whether the vault has never completed a sync against this repository.
    ///
    /// The expensive case, and the one worth treating differently: a first sync
    /// moves the whole vault, takes minutes rather than seconds, and is exactly
    /// the run that a thirty-second app-refresh window cannot finish.
    var needsFirstSync: Bool {
        guard let root else { return false }
        return SyncState.load(from: root).lastSyncedAt == nil
    }

    /// Which repository the open vault syncs with.
    ///
    /// Reads and writes `settings.data.vaultSync` under the open vault's id. An
    /// unopened or unbound vault reads as an empty binding, which is not
    /// configured and therefore does not sync — the whole point of the change:
    /// a vault now has to be told where it syncs, instead of inheriting whatever
    /// the last one used.
    var syncBinding: VaultSyncBinding {
        get {
            guard let vault else { return VaultSyncBinding() }
            return settings.data.vaultSync[vault.id.uuidString] ?? VaultSyncBinding()
        }
        set {
            guard let vault else { return }
            settings.data.vaultSync[vault.id.uuidString] = newValue
        }
    }

    /// Whether the open vault is a git working copy.
    ///
    /// If it is, git is already syncing this folder, and it does it properly:
    /// three-way merges, a history, conflict markers a person resolves.
    /// Inkstone's sync is file-level and last-write-wins — it has no merge base
    /// and answers a conflict by writing a second copy of the file. Running both
    /// over one folder is not redundancy, it is two mechanisms overwriting each
    /// other's results, which is what happened to a user's vault: 1409 API
    /// commits landed on `master` over four days while the local branch, 71
    /// commits of real work, knew nothing about any of them.
    ///
    /// Note this can only ever be true where git exists. On iOS it is always
    /// false, so a phone still syncs the repository normally — which is the
    /// arrangement that works: git on the desktop, the API on the phone, one
    /// writer each.
    var vaultIsGitWorkingCopy: Bool {
        guard let root else { return false }
        return FileManager.default.fileExists(atPath: root.appending(path: ".git").path)
    }

    /// Set by the user to sync a git working copy anyway. Per vault, and off
    /// unless asked for: the default protects, the escape hatch respects.
    var overridesGitWorkingCopyGuard: Bool {
        get { vault.map { settings.data.syncOverridesGit.contains($0.id.uuidString) } ?? false }
        set {
            guard let vault else { return }
            if newValue { settings.data.syncOverridesGit.insert(vault.id.uuidString) }
            else { settings.data.syncOverridesGit.remove(vault.id.uuidString) }
        }
    }

    /// Whether sync is being held back because git owns this folder.
    var isBlockedByGitWorkingCopy: Bool {
        vaultIsGitWorkingCopy && !overridesGitWorkingCopyGuard
    }

    /// Whether a sync could run right now — bound, permitted, configured, idle.
    var canSync: Bool {
        syncBinding.isEnabled
            && syncBinding.isConfigured
            && !isBlockedByGitWorkingCopy
            && SyncCredentials.hasToken
            && root != nil
            && !isSyncing
    }

    /// Moves the old single global repository onto a vault, if that vault can
    /// show it was the one using it.
    ///
    /// The proof is the vault's own `.inkstone/sync.json`, which records the
    /// repository of its last run. A vault that never synced to that repository
    /// has no such record and gets no binding.
    ///
    /// An earlier version of this attached the legacy repository to whichever
    /// vault was opened most recently. That is wrong in exactly the case this
    /// whole change exists for: on the phone, the most recently opened vault was
    /// the root of **On My iPhone**, picked once through the document picker —
    /// not a copy of the notes at all. Migrating onto it would have carried the
    /// broken setup into the new model unchanged.
    ///
    /// Runs on open rather than at launch because it needs the vault's files,
    /// and a vault's files are only reachable once its security-scoped bookmark
    /// has been resolved.
    private func migrateSyncBindingIfNeeded(for vault: Vault, root: URL) {
        guard settings.data.vaultSync[vault.id.uuidString] == nil else { return }
        let legacy = settings.data.gitHubRepository
        guard !legacy.isEmpty else { return }
        guard SyncState.load(from: root).repository == legacy else { return }

        settings.data.vaultSync[vault.id.uuidString] = VaultSyncBinding(
            repository: legacy,
            branch: settings.data.gitHubBranch.isEmpty ? "main" : settings.data.gitHubBranch,
            isEnabled: settings.data.gitHubSyncEnabled
        )
    }

    /// Pushes and pulls the vault against the configured GitHub repository.
    ///
    /// This used to be manual only, on the reasoning that a background sync
    /// hitting a conflict mid-sentence would cost the user's trust. That worry
    /// does not survive contact with how conflicts are actually handled: the
    /// remote copy is saved *alongside* the local one and nothing is
    // MARK: - Shared setup

    private var sharedSyncObserver: Any?

    /// The GitHub setup as this device currently has it, for the open vault.
    var syncConfiguration: GitHubSyncConfiguration {
        GitHubSyncConfiguration(
            repository: syncBinding.repository,
            branch: syncBinding.branch,
            isEnabled: syncBinding.isEnabled,
            isAutomatic: settings.data.gitHubAutoSync,
            intervalMinutes: settings.data.gitHubSyncIntervalMinutes,
            updatedAt: settings.data.gitHubConfigurationUpdatedAt ?? .distantPast
        )
    }

    /// Adopts another device's setup if it is newer, publishes this one if not,
    /// and keeps listening.
    ///
    /// Called at launch rather than when the Sync pane opens: a second device is
    /// configured by opening the app, and someone who has to find Settings before
    /// their vault appears has not been saved any typing.
    func startSharingSyncConfiguration() {
        SharedSyncConfiguration.refresh()
        applyShared(SharedSyncConfiguration.published())
        sharedSyncObserver = SharedSyncConfiguration.observe { [weak self] configuration in
            self?.applyShared(configuration)
        }
    }

    private func applyShared(_ remote: GitHubSyncConfiguration?) {
        switch SyncConfigurationMerge.resolve(local: syncConfiguration, remote: remote) {
        case .keepLocal:
            break
        case .publishLocal:
            // Nothing to publish from a device that has never been configured;
            // it would only overwrite the other side with blanks.
            guard syncBinding.isConfigured else { break }
            SharedSyncConfiguration.publish(syncConfiguration)
        case .adopt(let configuration):
            // **This is the line that spread the damage.** It used to write the
            // repository straight into the global settings, so a repository
            // configured for one device's vault was applied to whatever vault
            // the other device happened to have open — a different folder
            // entirely, which then started making the repository look like
            // itself.
            //
            // Now a shared configuration can only ever *confirm* a binding the
            // open vault already has. Anything else is held as a suggestion for
            // the Sync pane to offer, because "this is the repository your other
            // device uses" is useful and "so I applied it to this unrelated
            // folder" is not.
            guard syncBinding.repository == configuration.repository else {
                pendingSharedConfiguration = configuration
                break
            }
            syncBinding.branch = configuration.branch
            syncBinding.isEnabled = configuration.isEnabled
            settings.data.gitHubAutoSync = configuration.isAutomatic
            settings.data.gitHubSyncIntervalMinutes = configuration.intervalMinutes
            settings.data.gitHubConfigurationUpdatedAt = configuration.updatedAt
            restartAutoSync()
        }
    }

    /// Another device's setup, offered rather than applied. `nil` when there is
    /// nothing to offer or the open vault already matches it.
    var pendingSharedConfiguration: GitHubSyncConfiguration?

    /// Accepts the offer above, binding the open vault to that repository.
    func adoptSharedConfiguration() {
        guard let configuration = pendingSharedConfiguration else { return }
        syncBinding = VaultSyncBinding(
            repository: configuration.repository,
            branch: configuration.branch,
            isEnabled: configuration.isEnabled
        )
        settings.data.gitHubConfigurationUpdatedAt = configuration.updatedAt
        pendingSharedConfiguration = nil
        restartAutoSync()
    }

    /// Records that this device changed the setup, and tells the others.
    func publishSyncConfiguration() {
        settings.data.gitHubConfigurationUpdatedAt = Date()
        guard syncBinding.isConfigured else { return }
        SharedSyncConfiguration.publish(syncConfiguration)
    }

    /// A client for the configured repository, or nil when no token is stored.
    ///
    /// Shared by sync and by the Settings pickers so they cannot disagree about
    /// what "the configured repository" means — the pickers exist to stop a
    /// mistyped repository being discovered at sync time, which they could not do
    /// if they talked to a different one.
    ///
    /// - Parameter repository: overrides the configured value, for listing the
    ///   branches of a repository the user is considering but has not chosen yet.
    func gitHubClient(repository: String? = nil) -> GitHubClient? {
        guard let token = SyncCredentials.token() else { return nil }
        return GitHubClient(
            configuration: .init(
                repository: repository ?? syncBinding.repository,
                branch: syncBinding.branch.isEmpty ? "main" : syncBinding.branch
            ),
            token: token
        )
    }

    /// overwritten, so the cost of a badly timed sync is an extra file, not lost
    /// work. Requiring someone to remember to press a button is the larger risk.
    /// Set when a first sync needs the user to say which side wins; the Sync
    /// pane turns it into three buttons.
    var pendingFirstSync: SyncError?

    /// Set when a run stopped rather than delete most of the synced files. The
    /// Sync pane turns it into one button, and it is deliberately not the same
    /// button as anything else: saying yes here is the irreversible one.
    var pendingLargeDeletion: SyncError?

    func sync(
        firstSyncDirection: FirstSyncDirection? = nil,
        confirmingLargeDeletion: Bool = false
    ) async {
        guard let root else { return }
        guard syncBinding.isConfigured, let token = SyncCredentials.token() else {
            syncStatus = .failed(GitHubError.notConfigured.localizedDescription)
            return
        }

        // Flush anything the user has typed but not yet auto-saved, or sync
        // would upload a stale copy and then report success.
        saveAll()

        _ = token
        guard let client = gitHubClient() else {
            syncStatus = .failed(GitHubError.notConfigured.localizedDescription)
            return
        }
        let engine = SyncEngine(client: client, vaultRoot: root, policy: settings.data.syncPolicy)

        syncStatus = .running("Starting…")
        syncProgress = SyncProgress(message: "Starting…")
        pendingFirstSync = nil
        pendingLargeDeletion = nil
        do {
            let report = try await engine.run(
                firstSyncDirection: firstSyncDirection,
                confirmingLargeDeletion: confirmingLargeDeletion
            ) { update in
                Task { @MainActor in
                    self.syncStatus = .running(update.message)
                    self.syncProgress = update
                }
            }
            syncProgress = nil
            syncStatus = .finished(report)
            // Files may have arrived or vanished underneath us.
            refreshTree()
            reindex()
            for document in documents.values { document.reloadIfUnchangedLocally() }
        } catch is CancellationError {
            // Not a failure. The engine saved what it moved before rethrowing,
            // so the next run resumes rather than restarts.
            syncProgress = nil
            syncStatus = .interrupted
        } catch let error as SyncError {
            // A question, not a failure: it is waiting for an answer only the
            // user has, and the pane offers it rather than burying it in a
            // sentence that ends the run.
            if case .firstSyncNeedsDirection = error { pendingFirstSync = error }
            if case .tooManyDeletions = error { pendingLargeDeletion = error }
            syncProgress = nil
            syncStatus = .failed(error.localizedDescription)
        } catch {
            syncProgress = nil
            syncStatus = .failed(error.localizedDescription)
        }
    }

    // MARK: - Attachments

    /// Where a newly imported file should live: the configured attachment folder,
    /// created on demand, falling back to the vault root if it cannot be made.
    private func attachmentDestination(for root: URL) -> URL {
        let folder = settings.data.attachmentFolder.trimmingCharacters(in: .whitespaces)
        guard !folder.isEmpty else { return root }
        let url = root.appending(path: folder)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : root
    }

    /// Copies a file into the vault and returns its new location.
    ///
    /// The file is *copied*, never moved or referenced in place: a vault has to
    /// stay self-contained, or the note breaks as soon as the original is moved
    /// or the external volume is unplugged. Name collisions get a numeric suffix
    /// rather than overwriting someone's existing attachment.
    @discardableResult
    func importAttachment(from source: URL, preferredName: String? = nil) -> URL? {
        guard let root else { return nil }
        let folder = attachmentDestination(for: root)
        let name = preferredName ?? source.lastPathComponent
        let destination = uniqueURL(in: folder, name: name)

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            return nil
        }
        refreshTree()
        return destination
    }

    /// Writes raw data — a pasted image, say — into the attachment folder.
    @discardableResult
    func importAttachment(data: Data, name: String) -> URL? {
        guard let root else { return nil }
        let destination = uniqueURL(in: attachmentDestination(for: root), name: name)
        guard (try? data.write(to: destination)) != nil else { return nil }
        refreshTree()
        return destination
    }

    private func uniqueURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let suffixed = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appending(path: suffixed)
            counter += 1
        }
        return candidate
    }

    /// The embed text to insert for a file that now lives inside the vault.
    ///
    /// Uses a path relative to the vault root when the file sits in a subfolder,
    /// so the link keeps working if two attachments ever share a name.
    func embedMarkup(for url: URL) -> String {
        guard let root else { return "![[\(url.lastPathComponent)]]" }
        let relative = url.path.hasPrefix(root.path + "/")
            ? String(url.path.dropFirst(root.path.count + 1))
            : url.lastPathComponent
        return "![[\(relative)]]"
    }

    /// Resolves an embed target to a file on disk, note or attachment.
    func resolveEmbed(_ target: String, from source: URL) -> URL? {
        guard let root else { return nil }
        if let attachment = attachments.resolve(target, from: source, vaultRoot: root) {
            return attachment
        }
        return index.resolve(target, from: source, vaultRoot: root)
    }

    func reindex() {
        guard let root else { return }
        reindexTask?.cancel()
        isIndexing = true
        reindexTask = Task { [indexBuilder] in
            let snapshot = await indexBuilder.build(vaultRoot: root)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.index = snapshot
                self.indexGeneration += 1
                self.isIndexing = false
            }
        }
    }

    // MARK: - Documents

    func document(for url: URL) -> NoteDocument? {
        guard let store else { return nil }
        if let existing = documents[url] { return existing }
        let document = NoteDocument(url: url, store: store)
        documents[url] = document
        return document
    }

    func saveAll() {
        for document in documents.values { document.save() }
    }

    // MARK: - Tabs & navigation

    func open(_ content: TabContent, inNewTab: Bool = false) {
        if !tabs.contains(content) {
            if inNewTab || tabs.isEmpty || activeTab == nil {
                tabs.append(content)
            } else if let activeTab, let index = tabs.firstIndex(of: activeTab) {
                // Replace the current tab, matching how a browser handles a
                // plain click versus a ⌘-click.
                tabs[index] = content
            } else {
                tabs.append(content)
            }
        }
        activeTab = content
    }

    func openNote(at url: URL, inNewTab: Bool = false) {
        // Opening an evicted note has to wait for its bytes, or it opens blank
        // and an empty buffer then overwrites the real note on the next save.
        // Costs nothing in the normal case, where the file is already on disk.
        if settings.data.iCloudSyncEnabled, vault?.isCloudBacked == true {
            _ = ICloudFiles.ensureDownloaded(url, timeout: 2)
        }
        if url.pathExtension.lowercased() == "canvas" {
            open(.canvas(url), inNewTab: inNewTab)
        } else {
            open(.note(url), inNewTab: inNewTab)
        }
    }

    func closeTab(_ content: TabContent) {
        if let url = content.url {
            documents[url]?.save()
            documents.removeValue(forKey: url)
        }
        guard let index = tabs.firstIndex(of: content) else { return }
        tabs.remove(at: index)
        if activeTab == content {
            activeTab = tabs.indices.contains(index) ? tabs[index] : tabs.last
        }
    }

    private func pushHistory(_ content: TabContent) {
        guard !isNavigatingHistory else { return }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(content)
        historyIndex = history.count - 1
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        navigateHistory()
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        navigateHistory()
    }

    private func navigateHistory() {
        isNavigatingHistory = true
        defer { isNavigatingHistory = false }
        let target = history[historyIndex]
        if !tabs.contains(target) { tabs.append(target) }
        activeTab = target
    }

    // MARK: - Link following

    /// Opens a `[[wikilink]]`. Creating the note on the fly when it doesn't exist
    /// is what makes writing-first workflows work: you link to an idea, then fill
    /// it in later.
    func follow(link: WikiLink, from source: URL, createIfMissing: Bool = true) {
        guard let root, let store else { return }
        if let destination = index.resolve(link.target, from: source, vaultRoot: root) {
            openNote(at: destination)
            return
        }
        guard createIfMissing, !link.target.isEmpty else { return }

        let folder = settings.data.defaultNewNoteFolder.isEmpty
            ? source.deletingLastPathComponent()
            : root.appending(path: settings.data.defaultNewNoteFolder, directoryHint: .isDirectory)
        guard let url = try? store.createNote(named: link.target, in: folder) else { return }
        refreshTree()
        reindex()
        openNote(at: url)
    }

    // MARK: - File actions

    @discardableResult
    func createNote(named name: String = "Untitled", in directory: URL? = nil) -> URL? {
        guard let store else { return nil }
        guard let url = try? store.createNote(named: name, in: directory) else { return nil }
        refreshTree()
        reindex()
        openNote(at: url)
        return url
    }

    @discardableResult
    func createCanvas(named name: String = "Untitled", in directory: URL? = nil) -> URL? {
        guard let store, let root else { return nil }
        let url = store.uniqueURL(for: name, extension: "canvas", in: directory ?? root)
        guard (try? CanvasDocument().save(to: url)) != nil else { return nil }
        refreshTree()
        open(.canvas(url))
        return url
    }

    func rename(_ url: URL, to newBasename: String) {
        guard let store, let root, !newBasename.isEmpty else { return }
        let oldBasename = url.deletingPathExtension().lastPathComponent
        guard oldBasename != newBasename else { return }
        guard let destination = try? store.rename(url, to: newBasename) else { return }

        if settings.data.updateLinksOnRename {
            let others = VaultScanner().markdownFiles(in: root).filter { $0 != destination }
            LinkRewriter(store: store).rename(from: oldBasename, to: newBasename, in: others)
        }

        // Move any open document/tab over to the new URL.
        if let document = documents.removeValue(forKey: url) {
            document.save()
            documents[destination] = NoteDocument(url: destination, store: store)
            _ = document
        }
        if let tabIndex = tabs.firstIndex(where: { $0.url == url }) {
            let replacement: TabContent = destination.pathExtension == "canvas"
                ? .canvas(destination) : .note(destination)
            tabs[tabIndex] = replacement
            if activeTab?.url == url { activeTab = replacement }
        }

        refreshTree()
        reindex()
    }

    func delete(_ url: URL) {
        guard let store else { return }
        try? store.delete(url)
        documents.removeValue(forKey: url)
        tabs.removeAll { $0.url == url }
        if activeTab?.url == url { activeTab = tabs.last }
        refreshTree()
        reindex()
    }

    // MARK: - Daily notes

    /// Opens (creating if needed) the daily note for a date.
    @discardableResult
    func openDailyNote(for date: Date = .now) -> URL? {
        guard let store, let root else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = settings.data.dailyNoteFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let name = formatter.string(from: date)

        let folder = settings.data.dailyNoteFolder.isEmpty
            ? root
            : root.appending(path: settings.data.dailyNoteFolder, directoryHint: .isDirectory)
        let url = folder.appending(path: name + ".md")

        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            openNote(at: url)
            return url
        }

        let template = settings.data.dailyNoteTemplate.isEmpty
            ? "# \(name)\n\n"
            : settings.data.dailyNoteTemplate
        try? store.write(template, to: url)
        refreshTree()
        reindex()
        openNote(at: url)
        return url
    }

    /// Existing daily notes keyed by day, for the calendar's dot indicators.
    func dailyNoteDates() -> Set<DateComponents> {
        guard let root else { return [] }
        let folder = settings.data.dailyNoteFolder.isEmpty
            ? root
            : root.appending(path: settings.data.dailyNoteFolder, directoryHint: .isDirectory)
        let formatter = DateFormatter()
        formatter.dateFormat = settings.data.dailyNoteFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var result: Set<DateComponents> = []
        for (url, _) in index.notes where url.path(percentEncoded: false).hasPrefix(folder.path(percentEncoded: false)) {
            guard let date = formatter.date(from: url.deletingPathExtension().lastPathComponent) else { continue }
            result.insert(Calendar.current.dateComponents([.year, .month, .day], from: date))
        }
        return result
    }
}
