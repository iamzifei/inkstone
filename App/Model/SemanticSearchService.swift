import Foundation
import InkstoneCore

/// Owns the semantic index for the open vault and keeps it current.
///
/// Building costs real time — measured on the 8,865-note vault, about fifteen
/// minutes the first time, four model instances in parallel. So it is a
/// background job that saves as it goes and resumes where it stopped, never
/// something the app waits on. Search works without it; it only widens what
/// search can reach.
@MainActor
@Observable
final class SemanticSearchService {
    /// What to say in Settings.
    enum Status: Equatable {
        case off
        case idle
        case building(done: Int, total: Int)
        case ready(notes: Int, chunks: Int)
        case failed(String)
    }

    private(set) var status: Status = .off
    private(set) var index: SemanticIndex?

    private var vaultRoot: URL?
    private var buildTask: Task<Void, Never>?

    /// Whether the user wants this at all.
    ///
    /// Off by default. It is minutes of CPU on a machine someone is writing on,
    /// and the panel is useful without it — turning it on should be a decision,
    /// not something that happens the first time the vault is opened.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }

    private static let enabledKey = "com.orris.inkstone.semantic.enabled"

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Points the service at a vault, loading any index already built for it.
    func open(vault root: URL?) {
        guard root != vaultRoot else { return }
        stop()
        vaultRoot = root
        guard let root, isEnabled else {
            status = isEnabled ? .idle : .off
            index = nil
            return
        }
        let fresh = SemanticIndex(vaultRoot: root)
        index = fresh
        Task {
            await fresh.load()
            let count = await fresh.chunkCount
            status = count > 0 ? .ready(notes: 0, chunks: count) : .idle
        }
    }

    // MARK: - Building

    /// Builds or refreshes the index for every note in the vault.
    func build(notes: [(path: String, text: String)]) {
        guard isEnabled, let index else { return }
        buildTask?.cancel()

        let total = notes.count
        status = .building(done: 0, total: total)
        buildTask = Task { @MainActor [weak self] in
            // Progress arrives from a background actor. Hopping to the main
            // actor per report rather than per note is why the callback is
            // throttled inside the index itself.
            await index.build(notes: notes) { done, total in
                Task { @MainActor in
                    guard let self, !Task.isCancelled else { return }
                    self.status = .building(done: done, total: total)
                }
            }
            guard !Task.isCancelled, let self else { return }
            switch await index.currentState() {
            case .ready(let chunks):
                self.status = .ready(notes: total, chunks: chunks)
            case .unavailable(let reason):
                self.status = .failed(reason)
            default:
                self.status = .idle
            }
        }
    }

    /// Re-embeds one note, after it was edited.
    ///
    /// Cheap — one note is a fraction of a second — and it is what keeps the
    /// index from drifting away from the vault between full builds.
    func update(path: String, text: String) {
        guard isEnabled, let index else { return }
        Task { await index.update(path: path, text: text) }
    }

    func forget(path: String) {
        guard let index else { return }
        Task { await index.remove(path: path) }
    }

    func rebuild(notes: [(path: String, text: String)]) {
        guard let index else { return }
        Task {
            await index.clear()
            build(notes: notes)
        }
    }

    private func start() {
        guard let vaultRoot else { return }
        open(vault: vaultRoot)
    }

    private func stop() {
        buildTask?.cancel()
        buildTask = nil
        status = isEnabled ? .idle : .off
    }

    var progressFraction: Double? {
        guard case .building(let done, let total) = status, total > 0 else { return nil }
        return Double(done) / Double(total)
    }

    var summary: String {
        switch status {
        case .off:
            return String(localized: "Off")
        case .idle:
            return String(localized: "Not built yet")
        case .building(let done, let total):
            return String(localized: "Indexing \(done) of \(total) notes…")
        case .ready(_, let chunks):
            return String(localized: "\(chunks) passages indexed")
        case .failed(let reason):
            return reason
        }
    }
}
