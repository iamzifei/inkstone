import Foundation

/// One file's identity on each of the three sides of a sync.
public struct SyncEntry: Hashable, Sendable {
    /// Vault-relative path, using `/` separators.
    public let path: String
    /// Content hash of the file as it is on disk now; nil if it is not there.
    public let local: String?
    /// Blob SHA the remote currently has; nil if the remote does not have it.
    public let remote: String?
    /// Blob SHA recorded the last time this file synced cleanly; nil if it has
    /// never synced.
    public let base: String?

    public init(path: String, local: String?, remote: String?, base: String?) {
        self.path = path
        self.local = local
        self.remote = remote
        self.base = base
    }
}

/// What to do with one file.
public enum SyncAction: Hashable, Sendable {
    case upload(path: String)
    case download(path: String)
    case deleteRemote(path: String)
    case deleteLocal(path: String)
    /// Both sides changed. The remote copy is downloaded alongside the local one
    /// rather than either being overwritten.
    case conflict(path: String)
    case skip(path: String, reason: SkipReason)

    public enum SkipReason: Hashable, Sendable {
        case unchanged
        /// Excluded by the user's file-type policy.
        case filtered
    }
}

/// Decides what a sync run should do, as a pure function of the three sides.
///
/// Kept free of networking and file I/O so the rules — especially the ones that
/// decide when data could be lost — can be tested exhaustively without a repo,
/// a token, or a disk.
///
/// The comparison is three-way. Two-way syncing cannot tell "I changed this"
/// apart from "they deleted this", which is exactly how naive sync tools eat
/// people's notes. `base` is the state at the last clean sync, and it is what
/// makes the difference legible.
public enum SyncPlanner {

    public static func plan(
        entries: [SyncEntry],
        policy: SyncFilePolicy = SyncFilePolicy()
    ) -> [SyncAction] {
        entries.map { entry in
            // The policy governs whether a file participates at all. Notes always
            // do; attachments only if the user opted their kind in.
            guard policy.allows(URL(fileURLWithPath: entry.path)) else {
                return .skip(path: entry.path, reason: .filtered)
            }
            return action(for: entry)
        }
    }

    private static func action(for entry: SyncEntry) -> SyncAction {
        let localChanged = entry.local != entry.base
        let remoteChanged = entry.remote != entry.base

        switch (entry.local, entry.remote) {
        case (nil, nil):
            // Gone from both sides; nothing to do but forget it.
            return .skip(path: entry.path, reason: .unchanged)

        case (.some, nil):
            // Missing remotely: either we created it, or they deleted it.
            return remoteChanged && localChanged
                ? .conflict(path: entry.path)
                : (remoteChanged ? .deleteLocal(path: entry.path) : .upload(path: entry.path))

        case (nil, .some):
            return localChanged && remoteChanged
                ? .conflict(path: entry.path)
                : (localChanged ? .deleteRemote(path: entry.path) : .download(path: entry.path))

        case (.some(let local), .some(let remote)):
            if local == remote {
                // Same content both sides — only the bookkeeping needs updating.
                return .skip(path: entry.path, reason: .unchanged)
            }
            switch (localChanged, remoteChanged) {
            case (true, true): return .conflict(path: entry.path)
            case (true, false): return .upload(path: entry.path)
            case (false, true): return .download(path: entry.path)
            case (false, false):
                // Both sides differ from each other but neither differs from
                // base. That should be impossible; treat it as a conflict rather
                // than guessing, because guessing here loses an edit.
                return .conflict(path: entry.path)
            }
        }
    }

    /// The name a downloaded copy takes when both sides changed.
    ///
    /// Nothing is ever overwritten on a conflict: the remote version lands
    /// beside the local one and the user decides. Losing a note to a merge is
    /// far worse than having two of them.
    public static func conflictFilename(for path: String, timestamp: String) -> String {
        // String surgery rather than URL: these paths are vault-relative, and
        // `URL(fileURLWithPath:)` would resolve them against the process's
        // working directory and hand back an absolute path.
        let ns = path as NSString
        let ext = ns.pathExtension
        let stem = (ns.lastPathComponent as NSString).deletingPathExtension
        let folder = ns.deletingLastPathComponent

        let name = ext.isEmpty
            ? "\(stem) (conflict \(timestamp))"
            : "\(stem) (conflict \(timestamp)).\(ext)"
        return folder.isEmpty ? name : "\(folder)/\(name)"
    }
}

/// What the last clean sync looked like, persisted in the vault's `.inkstone`
/// folder so the next run has a base to compare against.
public struct SyncState: Codable, Hashable, Sendable {
    /// Vault-relative path to the blob SHA recorded at the last clean sync.
    public var blobs: [String: String]
    public var lastSyncedAt: Date?
    public var repository: String?
    public var branch: String?

    public init(
        blobs: [String: String] = [:],
        lastSyncedAt: Date? = nil,
        repository: String? = nil,
        branch: String? = nil
    ) {
        self.blobs = blobs
        self.lastSyncedAt = lastSyncedAt
        self.repository = repository
        self.branch = branch
    }

    public static func load(from vaultRoot: URL) -> SyncState {
        let url = stateURL(in: vaultRoot)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(SyncState.self, from: data)
        else { return SyncState() }
        return decoded
    }

    public func save(to vaultRoot: URL) throws {
        let url = Self.stateURL(in: vaultRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func stateURL(in vaultRoot: URL) -> URL {
        vaultRoot.appending(path: ".inkstone/sync.json")
    }
}
