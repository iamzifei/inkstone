import Foundation
import Observation
import InkstoneCore

/// The live, editable state of one open note.
///
/// Holds the text in memory, tracks dirtiness, and debounces writes so typing
/// doesn't hammer the disk (or an iCloud upload) on every keystroke. Saves are
/// also forced on blur, app background, and quit.
@MainActor
@Observable
final class NoteDocument {
    let url: URL

    var text: String {
        didSet {
            guard text != oldValue else { return }
            isDirty = true
            scheduleSave()
        }
    }

    private(set) var isDirty = false
    private(set) var lastSaved: Date?
    private(set) var loadError: (any Error)?

    /// Modification date at load time. Used to detect that another device or app
    /// changed the file underneath us before we overwrite it.
    private var diskModificationDate: Date?

    private let store: NoteStore
    private var saveTask: Task<Void, Never>?
    private let autosaveDelay: Duration = .milliseconds(700)

    init(url: URL, store: NoteStore) {
        self.url = url
        self.store = store
        do {
            text = try store.read(url)
            diskModificationDate = store.modificationDates(of: url).modified
        } catch {
            text = ""
            loadError = error
        }
    }

    var wordCount: Int { NoteParser.wordCount(of: text) }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [autosaveDelay] in
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    /// Called before each write so the previous state can be kept.
    ///
    /// Set by `Workspace`, which owns the vault root the history lives in. A
    /// closure rather than a reference to the workspace: a document should not
    /// need to know about tabs and sync to save itself.
    var onWillWrite: ((String) -> Void)?
    /// Called after a successful write, with the text that was written.
    ///
    /// Separate from `onWillWrite`, which snapshots the *previous* text for
    /// version history. Anything that indexes content needs the new text, and
    /// only once it is really on disk.
    var onDidWrite: ((String) -> Void)?

    func save() {
        guard isDirty else { return }
        // Snapshot what is about to be replaced, not what replaces it: recovery
        // means getting back the state *before* the edit that went wrong.
        onWillWrite?(text)
        do {
            try store.write(text, to: url)
            isDirty = false
            lastSaved = .now
            diskModificationDate = store.modificationDates(of: url).modified
            onDidWrite?(text)
        } catch {
            loadError = error
        }
    }

    /// Reloads from disk when an external change is detected and we have no
    /// unsaved edits. With unsaved edits we keep the user's version — silently
    /// discarding typing is never acceptable.
    func reloadIfUnchangedLocally() {
        guard !isDirty else { return }
        let current = store.modificationDates(of: url).modified
        guard current != diskModificationDate else { return }
        guard let fresh = try? store.read(url), fresh != text else { return }
        text = fresh
        isDirty = false
        diskModificationDate = current
    }
}
