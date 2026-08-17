import Foundation

/// Result of one sync run, for reporting back to the user.
public struct SyncReport: Sendable, Hashable {
    public var uploaded: [String] = []
    public var downloaded: [String] = []
    public var deletedLocally: [String] = []
    public var deletedRemotely: [String] = []
    /// Paths where both sides changed; each produced a "(conflict …)" copy.
    public var conflicted: [String] = []
    public var skipped: Int = 0
    public var failures: [(path: String, message: String)] = []

    /// Every change, labelled by what happened to it.
    ///
    /// A count tells you a sync was not quiet; it does not tell you which file
    /// would not settle, which is the only part worth knowing. Used by the
    /// integration tests' failure messages, and cheap enough to be worth having
    /// wherever a report is reported.
    public var changeSummary: String {
        var parts: [String] = []
        func add(_ label: String, _ paths: [String]) {
            guard !paths.isEmpty else { return }
            parts.append("\(label): " + paths.sorted().joined(separator: ", "))
        }
        add("uploaded", uploaded)
        add("downloaded", downloaded)
        add("deleted locally", deletedLocally)
        add("deleted remotely", deletedRemotely)
        add("conflicted", conflicted)
        add("failed", failures.map { "\($0.path) (\($0.message))" })
        return parts.isEmpty ? "no changes" : parts.joined(separator: "; ")
    }

    public var changeCount: Int {
        uploaded.count + downloaded.count + deletedLocally.count
            + deletedRemotely.count + conflicted.count
    }

    public static func == (lhs: SyncReport, rhs: SyncReport) -> Bool {
        lhs.uploaded == rhs.uploaded && lhs.downloaded == rhs.downloaded
            && lhs.deletedLocally == rhs.deletedLocally && lhs.deletedRemotely == rhs.deletedRemotely
            && lhs.conflicted == rhs.conflicted && lhs.skipped == rhs.skipped
            && lhs.failures.map(\.path) == rhs.failures.map(\.path)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(uploaded)
        hasher.combine(downloaded)
    }

    public init() {}
}

/// Runs a sync between a vault folder and a GitHub repository.
///
/// The decision-making lives in `SyncPlanner`, which is pure and heavily tested.
/// This type does the I/O: read the vault, ask GitHub what it has, carry out the
/// plan, and record the result so the next run has a base to compare against.
public struct SyncEngine: Sendable {
    private let client: GitHubClient
    private let vaultRoot: URL
    private let policy: SyncFilePolicy

    /// Files and folders that are never synced, whatever the policy says.
    /// `.inkstone` holds the sync state itself — uploading it would make every
    /// machine fight over its own bookkeeping.
    static let excludedComponents: Set<String> = [
        ".inkstone", ".obsidian", ".git", ".trash", ".DS_Store", "node_modules",
    ]

    public init(client: GitHubClient, vaultRoot: URL, policy: SyncFilePolicy) {
        self.client = client
        self.vaultRoot = vaultRoot
        self.policy = policy
    }

    public func run(progress: (@Sendable (String) -> Void)? = nil) async throws -> SyncReport {
        progress?("Checking repository…")
        _ = try await client.verify()

        progress?("Listing remote files…")
        let remote = try await client.listFiles()
        let remoteByPath = Dictionary(uniqueKeysWithValues: remote.map { ($0.path, $0) })

        progress?("Scanning vault…")
        let (local, excludedLocally) = localFiles()
        var state = SyncState.load(from: vaultRoot)

        let paths = Set(local.keys).union(remoteByPath.keys).union(state.blobs.keys)
        let entries = paths.sorted().map { path in
            SyncEntry(
                path: path,
                local: local[path],
                remote: remoteByPath[path]?.sha,
                base: state.blobs[path]
            )
        }

        var report = SyncReport()
        let actions = SyncPlanner.plan(
            entries: entries, policy: policy, excludedLocally: excludedLocally
        )
        let stamp = timestamp()

        for action in actions {
            do {
                switch action {
                case .skip(_, let reason):
                    if reason == .filtered { report.skipped += 1 }

                case .upload(let path):
                    progress?("Uploading \(path)…")
                    let data = try Data(contentsOf: fileURL(path))
                    let sha = try await client.upload(
                        path: path,
                        contents: data,
                        sha: remoteByPath[path]?.sha,
                        message: "Update \(path) from Inkstone"
                    )
                    state.blobs[path] = sha
                    report.uploaded.append(path)

                case .download(let path):
                    progress?("Downloading \(path)…")
                    guard let file = remoteByPath[path] else { break }
                    let data = try await client.download(sha: file.sha, path: path)
                    try write(data, to: path)
                    state.blobs[path] = file.sha
                    report.downloaded.append(path)

                case .deleteRemote(let path):
                    progress?("Removing \(path) from GitHub…")
                    guard let file = remoteByPath[path] else { break }
                    try await client.delete(path: path, sha: file.sha, message: "Delete \(path) from Inkstone")
                    state.blobs.removeValue(forKey: path)
                    report.deletedRemotely.append(path)

                case .deleteLocal(let path):
                    progress?("Removing \(path)…")
                    try? FileManager.default.removeItem(at: fileURL(path))
                    state.blobs.removeValue(forKey: path)
                    report.deletedLocally.append(path)

                case .conflict(let path):
                    // Never overwrite. The remote copy is saved beside the local
                    // one and the user decides which to keep; losing a note to an
                    // automatic merge is far worse than having two of them.
                    progress?("Conflict on \(path)…")
                    guard let file = remoteByPath[path] else {
                        report.conflicted.append(path)
                        break
                    }
                    let data = try await client.download(sha: file.sha, path: path)
                    try write(data, to: SyncPlanner.conflictFilename(for: path, timestamp: stamp))
                    report.conflicted.append(path)
                }
            } catch {
                report.failures.append((path: pathOf(action), message: error.localizedDescription))
            }
        }

        state.lastSyncedAt = Date()
        state.repository = client.configuration.repository
        state.branch = client.configuration.branch
        try? state.save(to: vaultRoot)

        return report
    }

    // MARK: - Local side

    /// Every syncable file in the vault, keyed by relative path, valued by the
    /// git blob SHA of its current contents.
    ///
    /// - Returns: the files, and separately the paths that are on disk but which
    ///   the policy excludes. The two must not be conflated: "not carried by this
    ///   vault" and "deleted by the user" look identical once a file is merely
    ///   missing from the map, and only one of them should propagate to the
    ///   remote.
    func localFiles() -> (files: [String: String], excluded: Set<String>) {
        var result: [String: String] = [:]
        var excluded: Set<String> = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: vaultRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return (result, excluded) }

        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if Self.excludedComponents.contains(url.lastPathComponent) {
                    walker.skipDescendants()
                }
                continue
            }
            let relative = url.path.hasPrefix(vaultRoot.path + "/")
                ? String(url.path.dropFirst(vaultRoot.path.count + 1))
                : url.lastPathComponent
            guard !relative.split(separator: "/").contains(where: { Self.excludedComponents.contains(String($0)) })
            else { continue }

            guard policy.allows(url, sizeBytes: values?.fileSize) else {
                // On disk, deliberately not carried. Recorded rather than
                // dropped, so the planner cannot mistake it for a deletion.
                excluded.insert(relative)
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }

            result[relative] = gitBlobSHA(data)
        }
        return (result, excluded)
    }

    private func fileURL(_ path: String) -> URL {
        vaultRoot.appending(path: path)
    }

    private func write(_ data: Data, to path: String) throws {
        let url = fileURL(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func pathOf(_ action: SyncAction) -> String {
        switch action {
        case .upload(let path), .download(let path), .deleteRemote(let path),
             .deleteLocal(let path), .conflict(let path), .skip(let path, _):
            return path
        }
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: Date())
    }
}
