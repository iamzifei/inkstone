#if DEBUG && os(macOS)
import Foundation
import InkstoneCore

/// Drives the real app through a real vault, from the command line.
///
///     INKSTONE_SMOKE=1 .../Inkstone.app/Contents/MacOS/Inkstone
///
/// Why this exists rather than more unit tests: `Workspace` lives in the app
/// target, not in `InkstoneCore`, so the package's suite cannot reach it. It is
/// also the layer where the two sync incidents actually happened — the binding,
/// the git guard, opening and forgetting vaults. Everything below runs against
/// files on disk in a temporary directory, through the same object the UI uses.
///
/// It is deliberately not a UI test. Nothing here needs a window, which is what
/// makes it runnable from a script; the context menu and the Settings toggles are
/// out of reach and are not pretended otherwise.
@MainActor
enum SmokeTest {

    private static var failures = 0

    private static func check(_ label: String, _ passed: Bool) {
        if !passed { failures += 1 }
        print("[smoke] \(passed ? "ok  " : "FAIL") \(label)")
    }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["INKSTONE_SMOKE"] != nil else { return }
        Task { @MainActor in
            await run()
            print(failures == 0
                  ? "[smoke] all checks passed"
                  : "[smoke] \(failures) check(s) failed")
            exit(failures == 0 ? 0 : 1)
        }
    }

    private static func run() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-smoke-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A defaults suite of its own. The real registry and settings belong to
        // whoever is using the app; a smoke run must not touch them, and in
        // particular must not leave a temporary folder in someone's vault list
        // or a repository binding in their settings.
        let suiteName = "com.orris.inkstone.smoke"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("open an isolated defaults suite", false)
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = Workspace(registry: VaultRegistry(defaults: defaults),
                                  settings: AppSettings(defaults: defaults))

        guard let vault = try? workspace.registry.register(folder: root, name: "Smoke") else {
            check("register a vault", false)
            return
        }
        workspace.open(vault)
        check("open a vault", workspace.root != nil)

        // --- notes ---
        guard let note = workspace.createNote(named: "Smoke Note") else {
            check("create a note", false)
            return
        }
        check("create a note", FileManager.default.fileExists(atPath: note.path))

        let body = "# Smoke\n\nA #smoketag and a [[Second Note]] link.\n"
        try? Data(body.utf8).write(to: note)
        workspace.refreshTree()
        workspace.reindex()

        // reindex is asynchronous; give it the same chance the UI does.
        await waitUntil("the index sees the note") { workspace.index.notes[note] != nil }
        check("index the note", workspace.index.notes[note] != nil)
        check("collect its tag", workspace.index.tagCounts["smoketag"] == 1)
        check("record the unresolved link", workspace.index.unresolved["Second Note"] == 1)

        if let store = workspace.store {
            let hits = SearchEngine.fullText(query: "smoke", in: workspace.index, store: store)
            check("find it by full-text search", hits.contains { $0.url == note })
        } else {
            check("find it by full-text search", false)
        }

        // --- rename and delete ---
        workspace.rename(note, to: "Renamed Note")
        let renamed = root.appending(path: "Renamed Note.md")
        check("rename a note", FileManager.default.fileExists(atPath: renamed.path))
        check("the old name is gone", !FileManager.default.fileExists(atPath: note.path))

        workspace.delete(renamed)
        check("delete a note", !FileManager.default.fileExists(atPath: renamed.path))

        // --- bookmarks, moving, split panes, history ---
        guard let pinned = workspace.createNote(named: "Pinned") else {
            check("create a note to pin", false)
            return
        }
        workspace.toggleBookmark(pinned)
        check("pin a file", workspace.isBookmarked(pinned))
        check("it appears in the list", workspace.bookmarkedURLs.contains(pinned))

        let folder = root.appending(path: "Moved")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        workspace.refreshTree()
        let movedTo = workspace.move(pinned, to: folder)
        // Compared by path, not by URL: `deletingLastPathComponent()` hands back
        // a directory URL with a trailing slash, so `==` is false even when the
        // move worked — which is what this assertion claimed the first time.
        check("move a file into a folder",
              movedTo?.deletingLastPathComponent().path(percentEncoded: false)
                  .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                  == folder.path(percentEncoded: false)
                  .trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        // The pin follows: the user pinned the note, not the path.
        if let movedTo {
            check("the bookmark follows the move", workspace.isBookmarked(movedTo))
            check("and not the old path", !workspace.isBookmarked(pinned))
        }

        let target = movedTo ?? pinned
        workspace.openBeside(target)
        check("open to the right makes a split", workspace.isSplit)
        check("and focuses the new pane", workspace.focusedPane == .secondary)
        if let secondary = workspace.secondaryActiveTab {
            workspace.closeTab(secondary)
        }
        check("closing its last tab closes the split", !workspace.isSplit)
        check("and focus returns to the left", workspace.focusedPane == .primary)

        // History records the state *before* a write, so the first save of an
        // edited note keeps what it replaced.
        if let document = workspace.document(for: target) {
            document.text = "first\n"
            document.save()
            document.text = "second\n"
            document.save()
        }
        let versions = workspace.versions(of: target)
        check("an edit leaves a version behind", !versions.isEmpty)
        if let newest = versions.first {
            check("restoring puts the note back", workspace.restore(newest, of: target))
        }

        workspace.delete(target)
        check("deleting drops the bookmark", !workspace.isBookmarked(target))
        check("and the history with it", workspace.versions(of: target).isEmpty)

        // --- sync bindings ---
        check("a fresh vault is unbound", !workspace.syncBinding.isConfigured)
        check("an unbound vault does not sync", !workspace.canSync)

        workspace.syncBinding = VaultSyncBinding(
            repository: "owner/notes", branch: "main", isEnabled: true)
        check("a binding can be set", workspace.syncBinding.repository == "owner/notes")

        // --- the git guard ---
        check("a plain folder is not a git working copy", !workspace.vaultIsGitWorkingCopy)
        try? FileManager.default.createDirectory(
            at: root.appending(path: ".git"), withIntermediateDirectories: true)
        check("a .git folder is noticed", workspace.vaultIsGitWorkingCopy)
        check("and holds sync back", workspace.isBlockedByGitWorkingCopy)
        check("even with a binding, it cannot sync", !workspace.canSync)
        workspace.overridesGitWorkingCopyGuard = true
        check("the override releases it", !workspace.isBlockedByGitWorkingCopy)

        // --- one repository, one vault ---
        //
        // The real implementation, not a restatement of the rule: this is the
        // check that would have caught a phone holding two vaults pointed at
        // one repository, which is what it was doing.
        check("one vault holding a repository is fine", workspace.vaultSharingThisRepository == nil)

        try? FileManager.default.createDirectory(
            at: root.appending(path: "Second"), withIntermediateDirectories: true)
        if let second = try? workspace.registry.register(
            folder: root.appending(path: "Second"), name: "Second"
        ) {
            workspace.settings.data.vaultSync[second.id.uuidString] = VaultSyncBinding(
                repository: "owner/notes", branch: "main", isEnabled: true)
            check("a second vault on the same repository is caught",
                  workspace.vaultSharingThisRepository?.id == second.id)
            check("and neither may sync", !workspace.canSync)

            workspace.claimRepositoryFromOtherVault()
            check("claiming it clears the other", workspace.vaultSharingThisRepository == nil)
            check("the other vault is left unbound",
                  workspace.settings.data.vaultSync[second.id.uuidString] == nil)

            // Switching between vaults bound to *different* repositories is
            // ordinary use and must stay untouched by any of this.
            workspace.settings.data.vaultSync[second.id.uuidString] = VaultSyncBinding(
                repository: "owner/journal", branch: "main", isEnabled: true)
            check("a different repository is not a conflict",
                  workspace.vaultSharingThisRepository == nil)
            workspace.forget(second)
        } else {
            check("register a second vault", false)
        }

        // --- the help link, per language ---
        //
        // The site tests check that every URL this can produce lands on a page
        // that exists. Nothing checked the mapping itself, and it cannot be
        // read off the binary either: `"zh-Hant/"` and `"sync.html"` are short
        // enough for Swift to store inline rather than as literals, so grepping
        // the shipped binary for them finds nothing and proves nothing.
        let expected: [(String, String)] = [
            ("en_AU", "https://inkslab.app/sync.html"),
            ("zh-Hans", "https://inkslab.app/zh/sync.html"),
            ("zh-Hant", "https://inkslab.app/zh-Hant/sync.html"),
            // Region rather than script: the script is the half that decides
            // which page a reader can actually read.
            ("zh-TW", "https://inkslab.app/zh-Hant/sync.html"),
            ("zh-CN", "https://inkslab.app/zh/sync.html"),
            ("zh-HK", "https://inkslab.app/zh-Hant/sync.html"),
            ("fr_FR", "https://inkslab.app/sync.html"),
        ]
        for (identifier, url) in expected {
            let got = SyncHelp.url(for: Locale(identifier: identifier)).absoluteString
            check("help link for \(identifier) → \(url)", got == url)
        }

        // --- forgetting ---
        let id = vault.id.uuidString
        workspace.forget(vault)
        check("forget a vault", workspace.registry.vaults.isEmpty)
        check("and its binding goes with it", workspace.settings.data.vaultSync[id] == nil)
        check("and its git override too", !workspace.settings.data.syncOverridesGit.contains(id))
    }

    /// Yields rather than spins.
    ///
    /// The first version spun the run loop, on the reasoning that the indexing
    /// task would be serviced by it. It was not: this runs from the app's
    /// `init`, before the main run loop is in a state that drains main-actor
    /// continuations, so every indexing check timed out against work that had
    /// never been given a chance to start. `Task.sleep` suspends the caller and
    /// lets it.
    private static func waitUntil(
        _ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool
    ) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if !condition() { print("[smoke] timed out waiting for \(what)") }
    }
}
#endif
