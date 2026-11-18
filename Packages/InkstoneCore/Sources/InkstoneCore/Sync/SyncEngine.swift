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
            // Counts go in as `String`, not `Int`: an `Int` interpolated into a
            // localised string is formatted for the locale ("8,882"), and the
            // message is also read by people grepping a log for the number.
            return localized("""
                This vault has never synced with GitHub. It has \(String(localFiles)) files \
                and the repository has \(String(remoteFiles)); \(String(differing)) of them differ. \
                There is no earlier sync to compare against, so neither side is \
                known to be newer — choose which one to keep.
                """)
        case .tooManyDeletions(let deleting, let total, let side):
            let place = side == .remote
                ? localized("from GitHub") : localized("from this device")
            return localized("""
                Stopped: this sync would delete \(String(deleting)) of \(String(total)) synced files \
                \(place). That is usually a sign the wrong folder or branch is \
                configured rather than a deletion anyone asked for. Check them, or \
                confirm if it is what you meant.
                """)
        case .remoteUnexpectedlyEmpty(let recorded):
            return localized("""
                Stopped: GitHub reported no files, but \(String(recorded)) were synced there \
                before. Syncing now would delete them from this device. Check the \
                repository and branch, then sync again.
                """)
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
        try await perform(firstSyncDirection: firstSyncDirection,
                          confirmingLargeDeletion: confirmingLargeDeletion,
                          progress: progress, dryRun: false).report!
    }

    /// What the next `run()` would do, computed by the same code a run uses —
    /// and nothing more: no file written, renamed or deleted in the vault, no
    /// request that changes GitHub, no sync.json saved. Questions a run would
    /// stop to ask (first-sync direction, mass deletion) are flags here.
    public func preview() async throws -> SyncPreview {
        try await perform(firstSyncDirection: nil, confirmingLargeDeletion: false,
                          progress: nil, dryRun: true).preview!
    }

    private func perform(
        firstSyncDirection: FirstSyncDirection?,
        confirmingLargeDeletion: Bool,
        progress: (@Sendable (SyncProgress) -> Void)?,
        dryRun: Bool
    ) async throws -> (report: SyncReport?, preview: SyncPreview?) {
        var preview = SyncPreview()
        progress?(SyncProgress(phase: .verifying, message: localized("Checking repository…")))
        _ = try await client.verify()

        progress?(SyncProgress(phase: .listing, message: localized("Listing remote files…")))
        // Hidden paths (`.github/…`) take no part in sync, so they are dropped
        // here, before anything counts the remote: a branch holding only
        // `.github` files must read as empty, not as "every note deleted".
        let remote = try await client.listFiles().filter { Self.isSyncablePath($0.path) }
        // Not `uniqueKeysWithValues`: Swift compares strings by canonical
        // equivalence, so a repository holding both the NFC and NFD spelling of
        // one name (written by different operating systems) has two entries
        // that are one key — and that initialiser traps, on every run.
        let remoteByPath = Dictionary(remote.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        progress?(SyncProgress(phase: .scanning, message: localized("Scanning vault…")))
        var state = SyncState.load(from: vaultRoot)
        // Records for hidden paths left by older builds: they take no part in
        // planning any more, but would still count toward "recorded" files.
        state.blobs = state.blobs.filter { Self.isSyncablePath($0.key) }
        let scanStarted = Date.now
        var (local, excludedLocally, stamps) = localFiles(
            cache: state.hashes ?? [:],
            trustBefore: state.hashesRecordedAt?.addingTimeInterval(-3) ?? .distantPast,
            skipPlaceholders: dryRun
        )
        state.hashes = stamps
        state.hashesRecordedAt = scanStarted

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
        //
        // Confirmable like any other mass deletion: when the last file really
        // was deleted on another device, refusing forever wedged every other one.
        if remote.isEmpty, !state.blobs.isEmpty, !confirmingLargeDeletion {
            // Said as what it most likely is — a wrong branch or a token that
            // lost access — rather than planned out as a list of every note
            // under "Delete here".
            if dryRun {
                preview.remoteLooksEmpty = true
                return (nil, preview)
            }
            throw SyncError.remoteUnexpectedlyEmpty(recorded: state.blobs.count)
        }

        // A synced file that is missing locally because iCloud evicted it (iOS
        // leaves a hidden `.name.icloud` stub, which the scan skips) is not a
        // deletion. Without this the stub's absence from the scan was read as
        // "the user deleted it" and the note was removed from GitHub.
        for path in state.blobs.keys where local[path] == nil && isEvictedFromICloud(path) {
            excludedLocally.insert(path)
        }

        // On a case-insensitive volume (the default on Macs and iPhones) a
        // local `note.md` and a remote `Note.md` are one file — another device
        // renamed it by case. Treated as two, the rename deleted the note, or
        // an edit made here under the old name was overwritten. Pair them up
        // as one renamed file before planning: the remote's spelling, this
        // side's content, the old name's base. The ordinary three-way rules
        // then upload an edit or record an unchanged file, and the file on disk
        // takes the new spelling. On a case-sensitive volume they really can be
        // two files, and none of this runs.
        let caseSensitive = (try? vaultRoot.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) ?? false
        if !caseSensitive {
            let localOnly = Dictionary(
                local.keys.filter { remoteByPath[$0] == nil }.map { ($0.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first })
            for remotePath in remoteByPath.keys where local[remotePath] == nil {
                // Only when the *other* side renamed: the local spelling is the
                // one last synced and the remote spelling is new. When this
                // side renamed (remote spelling has the base), the planner
                // already does the right thing — upload the new name, delete
                // the old one from GitHub.
                guard let localPath = localOnly[remotePath.lowercased()], localPath != remotePath,
                      let content = local[localPath],
                      state.blobs[localPath] != nil, state.blobs[remotePath] == nil else { continue }
                local[remotePath] = content
                local.removeValue(forKey: localPath)
                if state.blobs[remotePath] == nil, let base = state.blobs[localPath] {
                    state.blobs[remotePath] = base
                }
                state.blobs.removeValue(forKey: localPath)
                if !dryRun { adoptCase(of: fileURL(remotePath)) }
            }
        }

        // Hidden paths take no part in sync. The local scan skips them, but the
        // remote listing does not: a `.github/…` file was downloaded, never seen
        // by the next scan, and so deleted from GitHub as a local deletion.
        let paths = Set(local.keys).union(remoteByPath.keys).union(state.blobs.keys)
            .filter(Self.isSyncablePath)
        let entries = paths.sorted().map { path in
            SyncEntry(
                path: path,
                local: local[path],
                remote: remoteByPath[path]?.sha,
                base: state.blobs[path]
            )
        }

        progress?(SyncProgress(phase: .planning, message: localized("Working out what changed…")))
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
                if dryRun {
                    preview.needsFirstSyncDirection = true
                    preview.fill(from: actions)
                    return (nil, preview)
                }
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
                if dryRun { preview.wouldStopForLargeDeletion = true; continue }
                throw SyncError.tooManyDeletions(deleting: count, of: recorded, side: side)
            }
        }

        if dryRun {
            preview.fill(from: actions)
            return (nil, preview)
        }

        let stamp = timestamp()

        // Whether the run stopped early. Kept separate from the failure list
        // because it means something different: not "these files could not be
        // synced" but "this run was cut short and the rest has not been tried".
        var interrupted = false
        // Case-folded paths written into the vault by this run. On a
        // case-insensitive volume, downloading `Note.md` replaces `note.md`; a
        // later `deleteLocal note.md` in the same run would then delete the
        // note just downloaded (a case-only rename on another device).
        var writtenFolded: Set<String> = []
        let localFolded = caseSensitive ? [:]
            : Dictionary(local.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })

        for (index, action) in actions.enumerated() {
            // Progress is saved as it goes, not only at the end: a run killed
            // part-way (iOS ends background tasks abruptly) otherwise lost the
            // record of everything it had moved.
            if index > 0, index % 50 == 0 { try? state.save(to: vaultRoot) }
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
                case .skip(let path, let reason):
                    if reason == .filtered { report.skipped += 1 }
                    // Same content on both sides: record it as the base. Never
                    // recording it meant a file both sides already had (a second
                    // device joining, or an upload whose reply was lost) had no
                    // base — so deleting it later read as "never synced" and the
                    // next run downloaded it again.
                    if reason == .unchanged {
                        if let l = local[path], l == remoteByPath[path]?.sha {
                            state.blobs[path] = l
                        } else if local[path] == nil, remoteByPath[path] == nil {
                            state.blobs.removeValue(forKey: path)
                        }
                    }

                case .upload(let path):
                    progress?(SyncProgress(
                        message: localized("Uploading \(path)…"), completed: index, total: actions.count
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
                        message: localized("Downloading \(path)…"), completed: index, total: actions.count
                    ))
                    guard let file = remoteByPath[path] else { break }
                    let data = try await client.download(sha: file.sha, path: path)
                    // Edited since the scan (autosave during a long run)? Then
                    // overwriting would lose the typing: keep it, and save the
                    // remote version beside it as a conflict copy.
                    // Compared with what the scan saw under any case: on a
                    // case-insensitive volume `Note.md` reads the `note.md` the
                    // scan listed.
                    let scanned = local[path] ?? localFolded[path.lowercased()]
                    if let current = try? Data(contentsOf: fileURL(path)), gitBlobSHA(current) != scanned {
                        let copy = uniqueConflictPath(SyncPlanner.conflictFilename(for: path, timestamp: stamp))
                        try write(data, to: copy)
                        writtenFolded.insert(copy.lowercased())
                        state.blobs[path] = file.sha
                        report.conflicted.append(path)
                        break
                    }
                    try write(data, to: path)
                    writtenFolded.insert(path.lowercased())
                    state.blobs[path] = file.sha
                    report.downloaded.append(path)

                case .deleteRemote(let path):
                    progress?(SyncProgress(
                        message: localized("Removing \(path) from GitHub…"), completed: index, total: actions.count
                    ))
                    guard let file = remoteByPath[path] else { break }
                    try await client.delete(path: path, sha: file.sha, message: "Delete \(path) from Inkstone")
                    state.blobs.removeValue(forKey: path)
                    report.deletedRemotely.append(path)

                case .deleteLocal(let path):
                    progress?(SyncProgress(
                        message: localized("Removing \(path)…"), completed: index, total: actions.count
                    ))
                    if !caseSensitive, writtenFolded.contains(path.lowercased()) {
                        // The same file under another case, just written by this
                        // run: only the old name's record goes.
                        state.blobs.removeValue(forKey: path)
                        break
                    }
                    // Deleted only if it is still the version that was synced.
                    // An edit since the scan (autosave during a long run) is
                    // kept and uploaded on the next run instead.
                    let url = fileURL(path)
                    if let current = try? Data(contentsOf: url), gitBlobSHA(current) != state.blobs[path] {
                        report.conflicted.append(path)
                        break
                    }
                    // `try`, not `try?`: a delete that failed and was recorded as
                    // done made the file look new, and it was uploaded again.
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    state.blobs.removeValue(forKey: path)
                    report.deletedLocally.append(path)

                case .conflict(let path):
                    // Never overwrite. The remote copy is saved beside the local
                    // one and the user decides which to keep; losing a note to an
                    // automatic merge is far worse than having two of them.
                    progress?(SyncProgress(
                        message: localized("Conflict on \(path)…"), completed: index, total: actions.count
                    ))
                    guard let file = remoteByPath[path] else {
                        // Edited here, deleted there. The edit is the version
                        // that survives: upload it. Reporting a conflict and
                        // doing nothing repeated the same conflict every run and
                        // the edit never reached the other devices.
                        let data = try Data(contentsOf: fileURL(path))
                        let sha = try await client.upload(
                            path: path, contents: data, sha: nil,
                            message: "Restore \(path) from Inkstone (edited after deletion)")
                        state.blobs[path] = sha
                        report.uploaded.append(path)
                        break
                    }
                    let data = try await client.download(sha: file.sha, path: path)
                    let copy = uniqueConflictPath(SyncPlanner.conflictFilename(for: path, timestamp: stamp))
                    try write(data, to: copy)
                    writtenFolded.insert(copy.lowercased())
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
                // Errors that will fail every remaining request too: stop, keep
                // what was done, and fail the run. Carrying on turned an expired
                // token into one failure per file and a run reported as synced.
                if let github = error as? GitHubError, github.endsRun {
                    state.repository = client.configuration.repository
                    state.branch = client.configuration.branch
                    try? state.save(to: vaultRoot)
                    throw github
                }
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
        if !interrupted, report.failures.isEmpty { state.lastSyncedAt = Date() }
        try? state.save(to: vaultRoot)

        if interrupted { throw CancellationError() }
        return (report, nil)
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
        let scan = localFiles(cache: [:], trustBefore: .distantPast)
        return (scan.files, scan.excluded)
    }

    /// As `localFiles()`, but reusing the SHA from `cache` for any file whose
    /// size, mtime and ctime all match its stamp and whose mtime is earlier
    /// than `trustBefore` (the previous scan's start minus a margin for coarse
    /// timestamps — a write in the same tick as that scan's read could
    /// otherwise match). Returns fresh stamps for every file hashed or reused.
    ///
    /// Before this, every sync read and hashed every file in the vault, even
    /// when nothing had changed.
    func localFiles(
        cache: [String: HashStamp],
        trustBefore: Date,
        skipPlaceholders: Bool = false
    ) -> (files: [String: String], excluded: Set<String>, stamps: [String: HashStamp]) {
        var stamps: [String: HashStamp] = [:]
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
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey,
                                      .contentModificationDateKey, .attributeModificationDateKey]
        let trustLimit = trustBefore.timeIntervalSinceReferenceDate
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
        ) else { return (result, excluded, stamps) }

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
            // A symlink's size and dates are the link's own, but the bytes read
            // below are its target's: an edited target would keep a matching
            // stamp and its new content would never be seen. Always hashed.
            let isLink = values?.isSymbolicLink == true
            let size = values?.fileSize ?? -1
            let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? .nan
            let changed = values?.attributeModificationDate?.timeIntervalSinceReferenceDate ?? .nan
            if !isLink, let old = cache[relative], old.size == size, old.modified == modified,
               old.changed == changed, modified < trustLimit, changed < trustLimit {
                result[relative] = old.sha
                stamps[relative] = old
                continue
            }
            // A preview only looks: reading an iCloud placeholder would download
            // it. Not carried this time, which is never read as a deletion.
            if skipPlaceholders,
               let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                   .ubiquitousItemDownloadingStatus,
               status != .current {
                excluded.insert(relative)
                continue
            }
            // Unreadable (permissions, a file another app holds, a placeholder)
            // is "not carried this run", never "deleted": skipping it silently
            // made it look deleted, and the deletion was sent to GitHub.
            guard let data = try? Data(contentsOf: url) else {
                excluded.insert(relative)
                continue
            }

            let sha = gitBlobSHA(data)
            result[relative] = sha
            if !isLink, !modified.isNaN, !changed.isNaN {
                stamps[relative] = HashStamp(size: size, modified: modified, changed: changed, sha: sha)
            }
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

        return (result, excluded, stamps)
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
        if !isCaseSensitiveVolume { adoptCase(of: url) }
        try data.write(to: url, options: .atomic)
    }

    /// On a case-insensitive volume, writing `Note.md` over an existing
    /// `note.md` keeps the old spelling on disk. The next scan then reported
    /// `note.md`, uploaded it and deleted `Note.md` from GitHub — undoing the
    /// rename another device made. Rename the existing file to the exact
    /// spelling first (through a temporary name, since a case-only rename is a
    /// no-op on some volumes).
    private var isCaseSensitiveVolume: Bool {
        (try? vaultRoot.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) ?? false
    }

    private func adoptCase(of url: URL) {
        let folder = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        guard let listing = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              !listing.contains(name),
              let variant = listing.first(where: { $0.lowercased() == name.lowercased() })
        else { return }
        let temporary = folder.appending(path: ".inkstone-rename-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: folder.appending(path: variant), to: temporary)
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            // Put it back if the second step failed; the write that follows
            // still lands on the right content.
            if FileManager.default.fileExists(atPath: temporary.path) {
                try? FileManager.default.moveItem(at: temporary, to: folder.appending(path: variant))
            }
        }
    }

    private func pathOf(_ action: SyncAction) -> String {
        switch action {
        case .upload(let path), .download(let path), .deleteRemote(let path),
             .deleteLocal(let path), .conflict(let path), .skip(let path, _):
            return path
        }
    }

    private func timestamp() -> String { Self.conflictTimestamp(Date()) }

    /// Whether a vault-relative path takes part in sync at all: no hidden
    /// component (except the root `.gitignore`, which travels on purpose) and
    /// none of the folders the local scan never enters.
    static func isSyncablePath(_ path: String) -> Bool {
        if path == SyncFilePolicy.ignoreFileName { return true }
        return !path.split(separator: "/").contains { part in
            part.hasPrefix(".") || excludedComponents.contains(String(part))
        }
    }

    /// iOS replaces an evicted iCloud file with a hidden `.<name>.icloud` stub.
    private func isEvictedFromICloud(_ path: String) -> Bool {
        let url = fileURL(path)
        let stub = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        if FileManager.default.fileExists(atPath: stub.path) { return true }
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        return status != nil && status != .current
    }

    /// A conflict copy name that does not overwrite an earlier copy made in the
    /// same second.
    private func uniqueConflictPath(_ path: String) -> String {
        guard FileManager.default.fileExists(atPath: fileURL(path).path) else { return path }
        let ns = path as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        for n in 2...99 {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !FileManager.default.fileExists(atPath: fileURL(candidate).path) { return candidate }
        }
        return path
    }

    /// The date in a conflict copy's name. POSIX locale and Gregorian calendar:
    /// without them a device set to Arabic or a Hijri calendar named copies in
    /// other digits and another year, so two devices could not even sort them.
    static func conflictTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter.string(from: date)
    }
}

/// What a sync would do, without doing it. See `SyncEngine.preview()`.
public struct SyncPreview: Sendable, Hashable {
    public var uploads: [String] = []
    public var downloads: [String] = []
    public var deletesRemote: [String] = []
    public var deletesLocal: [String] = []
    public var conflicts: [String] = []
    /// A first sync with differing files: a run would stop to ask which side wins.
    public var needsFirstSyncDirection = false
    /// A run would stop at the mass-deletion guard and ask for confirmation.
    public var wouldStopForLargeDeletion = false
    /// GitHub lists no files although this vault has synced before. A run would
    /// stop; usually a wrong branch or a token that lost access.
    public var remoteLooksEmpty = false

    public init() {}

    public var isEmpty: Bool {
        uploads.isEmpty && downloads.isEmpty && deletesRemote.isEmpty && deletesLocal.isEmpty && conflicts.isEmpty
    }

    mutating func fill(from actions: [SyncAction]) {
        for action in actions {
            switch action {
            case .upload(let p): uploads.append(p)
            case .download(let p): downloads.append(p)
            case .deleteRemote(let p): deletesRemote.append(p)
            case .deleteLocal(let p): deletesLocal.append(p)
            case .conflict(let p): conflicts.append(p)
            case .skip: break
            }
        }
    }
}
