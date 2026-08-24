import Foundation

/// Which side a first sync should take when the two disagree.
public enum FirstSyncDirection: Sendable, Hashable {
    /// This device's copies win; the remote's are overwritten.
    case preferLocal
    /// The repository's copies win; the local ones are overwritten.
    case preferRemote
    /// Keep both, as a conflict copy beside each local file.
    case keepBoth
}

/// Refusals to sync, as opposed to failures of individual files.
public enum SyncError: LocalizedError, Sendable {
    /// The remote listed nothing while the recorded state says it held files.
    case remoteUnexpectedlyEmpty(recorded: Int)
    /// A first sync found files that differ on the two sides, and there is no
    /// basis for choosing between them.
    case firstSyncNeedsDirection(differing: Int, localFiles: Int, remoteFiles: Int)
    /// This run would remove most of what was recorded. Needs saying yes to.
    case tooManyDeletions(deleting: Int, of: Int, side: DeletionSide)

    /// Which side a mass deletion would fall on. The two read very differently
    /// to whoever has to answer: one empties a repository, the other empties the
    /// folder in front of them.
    public enum DeletionSide: Sendable, Hashable {
        case local, remote
    }

    public var errorDescription: String? {
        switch self {
        case .firstSyncNeedsDirection(let differing, let localFiles, let remoteFiles):
            return """
                This vault has never synced with GitHub. It has \(localFiles) files \
                and the repository has \(remoteFiles); \(differing) of them differ. \
                There is no earlier sync to compare against, so neither side is \
                known to be newer — choose which one to keep.
                """
        case .tooManyDeletions(let deleting, let total, let side):
            let place = side == .remote ? "from GitHub" : "from this device"
            return """
                Stopped: this sync would delete \(deleting) of \(total) synced files \
                \(place). That is usually a sign the wrong folder or branch is \
                configured rather than a deletion anyone asked for. Check them, or \
                confirm if it is what you meant.
                """
        case .remoteUnexpectedlyEmpty(let recorded):
            return """
                Stopped: GitHub reported no files, but \(recorded) were synced there \
                before. Syncing now would delete them from this device. Check the \
                repository and branch, then sync again.
                """
        }
    }
}

/// How far along a sync is, while it is running.
///
/// Was a bare `String`. A sentence is enough for a status line and not enough
/// for anything else: iOS 26's `BGContinuedProcessingTask` requires a real
/// `Progress` with unit counts and will forcibly expire a task that looks
/// stalled, and "Downloading notes/2026-08-14.md…" says nothing about whether
/// that is the second file of eight hundred or the last.
public struct SyncProgress: Sendable {
    /// Which part of a run this is.
    ///
    /// Carried because the phases before the plan exists have no counts, and a
    /// task that reports no movement through them is not merely uninformative —
    /// iOS forcibly expires a continued-processing task that looks stalled. On a
    /// vault of any size, listing the remote alone can outlast the scheduler's
    /// patience, and that is exactly what it did: two runs killed at 31 seconds
    /// and 3½ minutes with nothing on the bar.
    public enum Phase: Int, Sendable, CaseIterable {
        case verifying, listing, scanning, planning, transferring

        /// Where this phase begins on a 0…100 scale. The first four are given
        /// small, fixed shares because their duration is unknowable; the work
        /// that can be counted gets the rest.
        public var start: Int {
            switch self {
            case .verifying: return 0
            case .listing: return 2
            case .scanning: return 8
            case .planning: return 12
            case .transferring: return 15
            }
        }
    }

    public let phase: Phase

    /// What is happening, for a status line.
    public let message: String
    /// Actions finished so far, and how many there are in total. Both zero
    /// during the phases before the plan exists — verifying the repository,
    /// listing the remote, scanning the vault — which is honest: at that point
    /// the total is genuinely not known yet.
    public let completed: Int
    public let total: Int

    public init(phase: Phase = .transferring, message: String,
                completed: Int = 0, total: Int = 0) {
        self.phase = phase
        self.message = message
        self.completed = completed
        self.total = total
    }

    /// The run's position on a 0…100 scale, always determinate.
    ///
    /// Deliberately never a fabricated crawl: within a phase that has no counts
    /// the number sits at that phase's start and moves when the phase does. What
    /// it must not do is stay at zero for minutes, which is the shape a
    /// scheduler reads as a hung task.
    public var percent: Int {
        guard phase == .transferring, total > 0 else { return phase.start }
        let span = 100 - Phase.transferring.start
        return Phase.transferring.start + Int(Double(span) * Double(completed) / Double(total))
    }

    /// `nil` while the total is unknown, so a caller can show an indeterminate
    /// bar rather than a bar pinned at zero.
    public var fraction: Double? {
        guard total > 0 else { return nil }
        return Double(completed) / Double(total)
    }
}

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

    /// - Parameter firstSyncDirection: which side wins when a *first* sync finds
    ///   files differing on both sides. Required in that situation and ignored in
    ///   every other: once there is a recorded state, a difference on both sides
    ///   is a real conflict with a real answer, and keeping both is it.
    /// The share of recorded files a run may delete before it stops to ask.
    ///
    /// Half is deliberately generous. This is not trying to catch a careless
    /// tidy-up; it is trying to catch the shape both of this week's incidents
    /// had — a vault pointed at a repository that is not its own, where nearly
    /// everything on one side looks deleted on the other.
    public static let deletionShareNeedingConfirmation = 0.5

    /// Below this, the share is meaningless. Two of three files is 67% and is
    /// nobody's disaster; stopping for it would train the answer out of people.
    public static let deletionsAlwaysAllowed = 10

    /// - Parameter confirmingLargeDeletion: says yes to a run that would remove
    ///   most of the recorded files. Required only when `tooManyDeletions` has
    ///   already been thrown, and ignored otherwise.
    public func run(
        firstSyncDirection: FirstSyncDirection? = nil,
        confirmingLargeDeletion: Bool = false,
        progress: (@Sendable (SyncProgress) -> Void)? = nil
    ) async throws -> SyncReport {
        progress?(SyncProgress(phase: .verifying, message: "Checking repository…"))
        _ = try await client.verify()

        progress?(SyncProgress(phase: .listing, message: "Listing remote files…"))
        let remote = try await client.listFiles()
        let remoteByPath = Dictionary(uniqueKeysWithValues: remote.map { ($0.path, $0) })

        progress?(SyncProgress(phase: .scanning, message: "Scanning vault…"))
        let (local, excludedLocally) = localFiles()
        var state = SyncState.load(from: vaultRoot)

        // A remote that has gone from "files we recorded" to "nothing at all" is
        // either someone deliberately emptying the repository or, far more often,
        // this side failing to see it — a wrong branch, a token that lost access,
        // an API answering oddly. The planner cannot tell those apart: a file
        // that is unchanged locally and absent remotely is a remote deletion, and
        // the answer to a remote deletion is to delete the local copy.
        //
        // So the whole vault's worth of notes hangs on one listing being right.
        // Stop instead, and say so. A sync that refuses to run is an annoyance; a
        // sync that empties the vault is the end of the vault.
        if remote.isEmpty, !state.blobs.isEmpty {
            throw SyncError.remoteUnexpectedlyEmpty(recorded: state.blobs.count)
        }

        let paths = Set(local.keys).union(remoteByPath.keys).union(state.blobs.keys)
        let entries = paths.sorted().map { path in
            SyncEntry(
                path: path,
                local: local[path],
                remote: remoteByPath[path]?.sha,
                base: state.blobs[path]
            )
        }

        progress?(SyncProgress(phase: .planning, message: "Working out what changed…"))
        var report = SyncReport()
        var actions = SyncPlanner.plan(
            entries: entries, policy: policy, excludedLocally: excludedLocally
        )

        // A first sync has no base, so every file that differs looks like "both
        // sides changed" — which is a category error. Neither side changed;
        // there is simply no common ancestor to have changed from. Answering it
        // with a conflict copy per file turned one unanswered question into 123
        // of them in a real vault, and the answer was the same for all of them.
        //
        // Only on a first sync. After that a difference on both sides really is
        // a conflict, and keeping both really is the answer.
        let conflicts = actions.compactMap { action -> String? in
            if case .conflict(let path) = action { return path }
            return nil
        }
        if !conflicts.isEmpty, state.blobs.isEmpty {
            guard let firstSyncDirection else {
                throw SyncError.firstSyncNeedsDirection(
                    differing: conflicts.count,
                    localFiles: local.count,
                    remoteFiles: remoteByPath.count
                )
            }
            // Seeding the base is how a direction is expressed: set it to the
            // side that is to *lose*, and the ordinary three-way rules carry the
            // other one over. No special case in the planner.
            for path in conflicts {
                switch firstSyncDirection {
                case .preferLocal: state.blobs[path] = remoteByPath[path]?.sha
                case .preferRemote: state.blobs[path] = local[path]
                case .keepBoth: break
                }
            }
            if firstSyncDirection != .keepBoth {
                let reseeded = paths.sorted().map { path in
                    SyncEntry(
                        path: path,
                        local: local[path],
                        remote: remoteByPath[path]?.sha,
                        base: state.blobs[path]
                    )
                }
                actions = SyncPlanner.plan(
                    entries: reseeded, policy: policy, excludedLocally: excludedLocally
                )
            }
        }
        // Before anything is written. A plan that deletes most of what was
        // recorded is far more often a misconfiguration than an instruction —
        // the wrong folder bound to the repository, or a branch that is not the
        // one the files are on. Both of those look exactly like "the user
        // deleted everything", and the engine's answer to a deletion is to
        // propagate it.
        //
        // Checked against `state.blobs`, not against what is on disk now: the
        // question is how much of the *previously synced* vault is about to go,
        // and a vault that has genuinely grown should not raise the bar for
        // noticing that the rest of it is disappearing.
        if !confirmingLargeDeletion, !state.blobs.isEmpty {
            let recorded = state.blobs.count
            for side in [SyncError.DeletionSide.remote, .local] {
                let count = actions.filter { action in
                    switch action {
                    case .deleteRemote: return side == .remote
                    case .deleteLocal: return side == .local
                    default: return false
                    }
                }.count
                guard count > Self.deletionsAlwaysAllowed,
                      Double(count) >= Double(recorded) * Self.deletionShareNeedingConfirmation
                else { continue }
                throw SyncError.tooManyDeletions(deleting: count, of: recorded, side: side)
            }
        }

        let stamp = timestamp()

        // Whether the run stopped early. Kept separate from the failure list
        // because it means something different: not "these files could not be
        // synced" but "this run was cut short and the rest has not been tried".
        var interrupted = false

        for (index, action) in actions.enumerated() {
            // Cancellation used to be invisible here. The network calls throw on
            // cancellation, the `catch` below treats that like any other
            // per-file failure, and the loop carries on — so an expired
            // background task did not stop the sync, it converted every one of
            // the remaining files into a failure entry and then reported a
            // finished run. On a first sync of a real vault that is thousands of
            // spurious failures and a report that says the sync completed.
            if Task.isCancelled {
                interrupted = true
                break
            }

            do {
                switch action {
                case .skip(_, let reason):
                    if reason == .filtered { report.skipped += 1 }

                case .upload(let path):
                    progress?(SyncProgress(
                        message: "Uploading \(path)…", completed: index, total: actions.count
                    ))
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
                    progress?(SyncProgress(
                        message: "Downloading \(path)…", completed: index, total: actions.count
                    ))
                    guard let file = remoteByPath[path] else { break }
                    let data = try await client.download(sha: file.sha, path: path)
                    try write(data, to: path)
                    state.blobs[path] = file.sha
                    report.downloaded.append(path)

                case .deleteRemote(let path):
                    progress?(SyncProgress(
                        message: "Removing \(path) from GitHub…", completed: index, total: actions.count
                    ))
                    guard let file = remoteByPath[path] else { break }
                    try await client.delete(path: path, sha: file.sha, message: "Delete \(path) from Inkstone")
                    state.blobs.removeValue(forKey: path)
                    report.deletedRemotely.append(path)

                case .deleteLocal(let path):
                    progress?(SyncProgress(
                        message: "Removing \(path)…", completed: index, total: actions.count
                    ))
                    try? FileManager.default.removeItem(at: fileURL(path))
                    state.blobs.removeValue(forKey: path)
                    report.deletedLocally.append(path)

                case .conflict(let path):
                    // Never overwrite. The remote copy is saved beside the local
                    // one and the user decides which to keep; losing a note to an
                    // automatic merge is far worse than having two of them.
                    progress?(SyncProgress(
                        message: "Conflict on \(path)…", completed: index, total: actions.count
                    ))
                    guard let file = remoteByPath[path] else {
                        report.conflicted.append(path)
                        break
                    }
                    let data = try await client.download(sha: file.sha, path: path)
                    try write(data, to: SyncPlanner.conflictFilename(for: path, timestamp: stamp))
                    report.conflicted.append(path)

                    // Record the remote's blob as the base, or this conflict is
                    // resolved again on the next run and every run after it: the
                    // two sides still differ, the base is still unset, and the
                    // planner reaches the same conclusion. A vault on a
                    // fifteen-minute schedule gained a copy of every conflicted
                    // note four times an hour.
                    //
                    // Base = *remote* specifically. Next run, local differs from
                    // base and the remote does not, which reads as a local edit
                    // and uploads it — so the local version becomes the live one
                    // and the remote's version survives as the copy just written,
                    // which uploads alongside it. Both versions end up on both
                    // sides, and it terminates. Base = local would invert that
                    // and download the remote over the local file, undoing the
                    // decision not to overwrite it.
                    state.blobs[path] = file.sha
                }
            } catch {
                report.failures.append((path: pathOf(action), message: error.localizedDescription))
            }
        }

        state.repository = client.configuration.repository
        state.branch = client.configuration.branch
        // Saved either way, and that is the point: `state.blobs` holds every
        // file this run did move, plus the first-sync direction seeded above.
        // Persisting it is what stops an interrupted first sync from starting
        // over — and, on a `.preferRemote` first sync, what stops the files it
        // never reached from being re-asked about as fresh conflicts.
        //
        // `lastSyncedAt` is the exception. It answers "did a sync complete", and
        // stamping it after a run that was cut off two thirds of the way through
        // is how a half-synced vault reports itself as up to date.
        if !interrupted { state.lastSyncedAt = Date() }
        try? state.save(to: vaultRoot)

        if interrupted { throw CancellationError() }
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
        // The vault's own statement of what does not belong in this repository,
        // written in the file made for saying it. Excluded rather than dropped,
        // for the same reason an oversized file is: "this vault is not carrying
        // it" must never be read as "the user deleted it".
        let ignore = GitIgnore.load(from: vaultRoot)
        // Two separate lists that answer the same question. `.gitignore` is the
        // vault's own rule about what does not belong in the repository at all;
        // `excludedPaths` is this device's rule about what it does not carry.
        // A desktop and a phone share the first and differ on the second.
        let excluder = policy.pathExcluder
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        // The enumerator hands back paths in whatever form the file system
        // canonicalises to, which is not always the form the root was written
        // in: a vault under `/var/…` comes back as `/private/var/…`. Comparing
        // the two directly fails, and the fallback that used to catch that
        // invented an answer. Both prefixes are kept, and the raw one is tried
        // first so the ordinary case costs nothing.
        let rawPrefix = vaultRoot.path + "/"
        let canonicalPrefix = (vaultRoot.path as NSString).resolvingSymlinksInPath + "/"
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

            // Skipped rather than guessed at. The fallback here was
            // `url.lastPathComponent`, which invents a plausible answer: with a
            // vault reached through a symlink every file in every folder came
            // back as its bare filename, so the tree flattened onto the root and
            // same-named notes overwrote one another in the map.
            let relative: String
            if url.path.hasPrefix(rawPrefix) {
                relative = String(url.path.dropFirst(rawPrefix.count))
            } else {
                let canonical = (url.path as NSString).resolvingSymlinksInPath
                guard canonical.hasPrefix(canonicalPrefix) else { continue }
                relative = String(canonical.dropFirst(canonicalPrefix.count))
            }
            guard !relative.split(separator: "/").contains(where: { Self.excludedComponents.contains(String($0)) })
            else { continue }

            guard !ignore.ignores(relative) else {
                excluded.insert(relative)
                continue
            }

            guard excluder.isEmpty || !excluder.ignores(relative) else {
                // Recorded as excluded rather than simply skipped, so the planner
                // reads it as "this device does not carry it" and not as "the
                // user deleted it" — otherwise turning an exclusion on would
                // delete the remote copy for every other device too.
                excluded.insert(relative)
                continue
            }

            guard policy.allows(url, sizeBytes: values?.fileSize) else {
                // On disk, deliberately not carried. Recorded rather than
                // dropped, so the planner cannot mistake it for a deletion.
                excluded.insert(relative)
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }

            result[relative] = gitBlobSHA(data)
        }

        // `.gitignore` again, by hand, because `.skipsHiddenFiles` above means
        // the enumerator never offered it. Root only — that is the only one
        // `GitIgnore.load` reads, so syncing nested ones would ship rules this
        // engine does not itself apply.
        //
        // A vault whose `.gitignore` names `.gitignore` is telling us not to
        // share it, and that is respected rather than overridden.
        let ignoreFile = vaultRoot.appending(path: SyncFilePolicy.ignoreFileName)
        if !ignore.ignores(SyncFilePolicy.ignoreFileName),
           let data = try? Data(contentsOf: ignoreFile) {
            result[SyncFilePolicy.ignoreFileName] = gitBlobSHA(data)
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
