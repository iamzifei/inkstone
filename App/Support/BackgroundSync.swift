#if os(iOS)
import BackgroundTasks
import InkstoneCore
import SwiftUI
import UIKit

/// Runs the GitHub sync while the app is not in the foreground.
///
/// The foreground auto-sync is a `Task` with a sleep loop in `Workspace`. On the
/// Mac that is enough, because the process keeps running. On iOS it is not: the
/// system suspends the app moments after it leaves the screen and that loop
/// stops mid-sleep. Without what is in this file, "sync every 15 minutes" means
/// "sync every 15 minutes, as long as you are looking at it".
///
/// Three separate problems, three mechanisms:
///
/// 1. **The app is suspended while a sync is already running.** `beginBackgroundTask`
///    buys the rest of the sync a grace period instead of having it cut in half.
/// 2. **The app is not running at all.** `BGAppRefreshTask` lets the system wake
///    it briefly, on a schedule it learns from when this app is actually opened,
///    so the vault is already current when it is next opened.
/// 3. **There is more to move than a refresh window allows.** `BGProcessingTask`
///    asks for a longer run, and the system grants it when the device is idle
///    and, ideally, charging.
///
/// Two things about this API that bite:
///
/// * **Registration must happen before the app finishes launching**, and each
///   identifier may be registered exactly once — the header is explicit that a
///   second registration of the same identifier kills the app. So this is called
///   from `InkstoneApp.init`, not from a view.
/// * **Nothing repeats.** A task request is consumed when it runs. If the
///   handler does not schedule the next one, background sync works exactly once
///   and then silently never again.
///
/// **A fourth mechanism, added after the first three were not enough.**
/// `BGContinuedProcessingTask` (iOS 26) was originally dismissed here as fitting
/// "tap Sync, then leave the app" rather than unattended periodic sync. That
/// reasoning was right about what it is and wrong about whether it was needed,
/// for two reasons that only showed up in use:
///
/// * **A first sync cannot finish in a refresh window.** It moves the whole
///   vault — minutes, not the ~30 seconds an app-refresh run gets. So the run
///   that matters most is the one guaranteed to be cut off.
/// * **Unattended work with no visible sign is indistinguishable from no work.**
///   The other three mechanisms are silent by design. Someone watching for five
///   minutes cannot tell a sync that is running from one that never started, and
///   reasonably concludes the feature is broken.
///
/// This one is the answer to both: it runs to completion after the app leaves
/// the screen, and the system shows a live progress display while it does. It
/// must be submitted while foregrounded, so it is what "Sync now" and the
/// first-sync buttons use — not a replacement for the periodic tasks above.
///
/// Its identifier is a **wildcard**: the header requires the form
/// `<bundle id>.<context>.*`, registered once and submitted with a concrete
/// suffix each time. It also requires real `Progress` unit counts — the header
/// is explicit that a task which looks stalled may be forcibly expired — which
/// is why `SyncProgress` carries counts rather than a sentence.
@MainActor
enum BackgroundSync {
    /// Identifiers must also appear in `BGTaskSchedulerPermittedIdentifiers` in
    /// Info.plist, or `submit` throws `notPermitted`.
    static let refreshIdentifier = "com.orris.inkstone.sync.refresh"
    static let processingIdentifier = "com.orris.inkstone.sync.processing"

    /// Continued-processing identifiers come in three forms, and they are not
    /// interchangeable. The framework binary names all three —
    /// `isIdentifierValidContinuedProcessing{Base,Composed,Wildcard}Notation:` —
    /// and holds the permitted set as
    /// `permittedContinuedProcessingBaseNotationIdentifiers`:
    ///
    /// * **wildcard**, `…continued.*` — what goes in Info.plist.
    /// * **base**, `…continued` — never used at runtime.
    /// * **composed**, `…continued.<suffix>` — what *both* `register` and
    ///   `submit` take, for one specific task.
    ///
    /// **Registration is per request, immediately before submitting.** Both
    /// other forms are refused by `register`, silently, exactly as a missing
    /// Info.plist entry would be. Establishing that cost a crash on device:
    /// registering the wildcard returned `false`, the submission was accepted
    /// anyway, and the system then terminated the app with
    /// `No launch handler registered for task with identifier
    /// com.orris.inkstone.sync.continued.z5pvzdplrm5m` — naming the composed
    /// identifier, which is the answer.
    ///
    /// This is also what the scheduler header means by continued-processing
    /// registrations being exempt from the register-before-launch-finishes rule.
    /// They have to be: the identifier does not exist until there is a task to
    /// submit. The same header warns that registering one identifier twice kills
    /// the app — so every request gets a fresh suffix and is never reused.
    static let continuedBase = "com.orris.inkstone.sync.continued"

    /// Suffixes are alphanumeric. A UUID string would bring hyphens into an
    /// identifier whose accepted form is checked by the framework, and this is
    /// not the place to find out which characters it allows.
    private static func composedIdentifier() -> String {
        let suffix = (0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }
        return "\(continuedBase).\(String(suffix))"
    }

    private static var registered = false

    /// Whether the system accepted both handlers. `register` returns false when
    /// the identifier is absent from `BGTaskSchedulerPermittedIdentifiers`, and
    /// that is the single most common way background work is wired up, builds,
    /// ships, and never runs — nothing throws and nothing is logged. Kept so a
    /// diagnostic can assert on it rather than on hope.
    private(set) static var registrationSucceeded: [String: Bool] = [:]

    /// Held only so the diagnostic can reach the same workspace the handlers
    /// close over. Not used by the handlers themselves.
    private static weak var workspaceRef: Workspace?

    // MARK: - Registration

    /// The queue every launch handler runs on.
    ///
    /// **Not `nil`.** `nil` means "a default background queue", and the handlers
    /// below reach `Workspace`, which is `@MainActor`. `MainActor.assumeIsolated`
    /// on a dispatch worker thread does not warn or fall back — it traps, and
    /// the app dies before the first line of the handler body.
    ///
    /// This was not a theoretical risk. Three crash reports pulled off the
    /// device — 2026-08-20 21:48, 2026-08-21 18:25, 2026-08-21 22:47 — are the
    /// same stack every time:
    ///
    ///     _dispatch_assert_queue_fail
    ///     swift_task_isCurrentExecutorWithFlags
    ///     closure #1 in static BackgroundSync.register(workspace:)
    ///     -[BGTaskScheduler _runTask:registration:]_block_invoke
    ///     _dispatch_workloop_worker_thread
    ///
    /// So iOS *was* waking the app on schedule, and every wake-up crashed on
    /// arrival. From the outside that is indistinguishable from a system that
    /// never grants background time — which is exactly what it was mistaken for,
    /// twice. `BackgroundSyncLog.record(.launched)` could not tell the
    /// difference either: it is the first statement in the handler body, and the
    /// trap happens before the body is entered.
    private static let handlerQueue = DispatchQueue.main

    /// Registers the handlers. Call once, from the app's `init`.
    static func register(workspace: Workspace) {
        workspaceRef = workspace
        guard !registered else { return }
        registered = true

        registrationSucceeded[refreshIdentifier] = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshIdentifier, using: handlerQueue
        ) { task in
            MainActor.assumeIsolated {
                run(task, workspace: workspace, thenScheduling: .refresh)
            }
        }

        registrationSucceeded[processingIdentifier] = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: processingIdentifier, using: handlerQueue
        ) { task in
            MainActor.assumeIsolated {
                run(task, workspace: workspace, thenScheduling: .processing)
            }
        }
    }

    /// Registers a handler for one continued-processing task, keyed to the exact
    /// identifier that will be submitted. Must be called before `submit`, or the
    /// system terminates the app when it tries to launch the task.
    private static func registerContinued(_ identifier: String, workspace: Workspace) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: handlerQueue) { task in
            MainActor.assumeIsolated {
                guard let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                runContinued(continued, workspace: workspace)
            }
        }
    }

    // MARK: - Scheduling

    enum Kind { case refresh, processing }

    /// Asks the system for both kinds of run. Call when the app leaves the
    /// foreground and again after each background run completes — a request is
    /// consumed when it fires, so nothing here is periodic by itself.
    static func schedule(workspace: Workspace) {
        guard workspace.syncBinding.isEnabled,
              !workspace.isBlockedByGitWorkingCopy,
              workspace.settings.data.gitHubAutoSync else {
            // Settings may have been turned off since the last request was
            // queued. Leaving it pending would wake the app to do nothing.
            cancelAll()
            return
        }
        submit(.refresh, workspace: workspace)
        submit(.processing, workspace: workspace)
    }

    static func cancelAll() {
        BGTaskScheduler.shared.cancelAllTaskRequests()
    }

    private static func submit(_ kind: Kind, workspace: Workspace) {
        // The user's chosen interval is a floor, not a promise. iOS decides when
        // a background task actually runs, weighing battery, network and how
        // often this app gets opened; asking for five minutes does not make five
        // minutes happen.
        let minutes = max(15, workspace.settings.data.gitHubSyncIntervalMinutes)

        let request: BGTaskRequest
        switch kind {
        case .refresh:
            let refresh = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
            refresh.earliestBeginDate = Date(timeIntervalSinceNow: Double(minutes) * 60)
            request = refresh
        case .processing:
            let processing = BGProcessingTaskRequest(identifier: processingIdentifier)
            // Syncing without a network is a guaranteed failure, and the system
            // will happily run the task anyway if not told otherwise.
            processing.requiresNetworkConnectivity = true
            // Not required: a vault is small, and demanding a charger would mean
            // a phone that is never plugged in overnight never syncs at all.
            processing.requiresExternalPower = false
            processing.earliestBeginDate = Date(timeIntervalSinceNow: Double(minutes) * 60)
            request = processing
        }

        do {
            try BGTaskScheduler.shared.submit(request)
            BackgroundSyncLog.record(.scheduled, "\(request.identifier) in \(minutes)m")
        } catch {
            // Expected and harmless in two cases: the Simulator, which has no
            // scheduler, and a duplicate request, which simply replaces the
            // pending one. Neither is worth showing anyone, but swallowing it
            // silently is how "background sync never ran" becomes unexplainable —
            // so it is written down rather than shown.
            BackgroundSyncLog.record(.scheduleFailed, "\(request.identifier): \(error)")
            #if DEBUG
            print("[BackgroundSync] could not submit \(kind): \(error)")
            #endif
        }
    }

    // MARK: - A sync the user can see, that survives leaving the app

    /// How far the last continued run got, so the next one can tell whether
    /// carrying on is making progress or spinning.
    private static var lastContinuedPercent = -1

    /// Consecutive expiries that moved nothing. Three is enough to conclude the
    /// work is not going to fit, and stopping beats a loop the user cannot see
    /// the end of.
    private static var fruitlessExpiries = 0
    private static let fruitlessLimit = 3

    /// Which side wins, handed to the handler that actually runs the sync.
    /// Static because the request carries no payload: the system launches the
    /// registered handler and the only channel between submission and handler is
    /// the app's own memory. Safe because only one sync runs at a time.
    private static var pendingDirection: FirstSyncDirection?

    /// Starts a sync as a continued-processing task, so it keeps running after
    /// the user leaves and shows a system progress display while it does.
    ///
    /// Must be called while the app is foregrounded — the request is defined as
    /// being made on behalf of the frontmost app, and `earliestBeginDate` is
    /// ignored in favour of now.
    ///
    /// - Returns: whether the scheduler took it. `false` means the caller should
    ///   fall back to an ordinary in-app sync, which still works — it just dies
    ///   when the app is suspended.
    @discardableResult
    static func syncVisibly(
        workspace: Workspace, firstSyncDirection: FirstSyncDirection? = nil
    ) -> Bool {
        guard !workspace.isSyncing else { return false }

        let identifier = composedIdentifier()
        guard registerContinued(identifier, workspace: workspace) else {
            BackgroundSyncLog.record(.scheduleFailed, "continued: register refused \(identifier)")
            return false
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: workspace.vault?.name ?? "Vault",
            subtitle: "Preparing to sync…"
        )
        // `.queue` rather than `.fail`: a busy system should delay this, not
        // refuse it. The cost is that the request is dropped if the app is
        // removed from the app switcher, which is fair — that is the user saying
        // stop.
        request.strategy = .queue

        do {
            try BGTaskScheduler.shared.submit(request)
            pendingDirection = firstSyncDirection
            BackgroundSyncLog.record(.scheduled, "continued")
            return true
        } catch {
            BackgroundSyncLog.record(.scheduleFailed, "continued: \(error)")
            return false
        }
    }

    /// Tracks whether the task has already been completed, so the expiration
    /// handler and the finishing sync cannot both report an outcome. A reference
    /// type because both closures need the same box.
    private final class Completion {
        var done = false
    }

    /// Set by `diagnose` so the handler can recognise its own probe. Without it
    /// the only way to find out whether a continued task can actually be
    /// submitted *and* launched is to tap Sync and watch — which is not a check
    /// that can be run from a terminal.
    private static var probeIdentifier: String?

    private static func runContinued(_ task: BGContinuedProcessingTask, workspace: Workspace) {
        if task.identifier == probeIdentifier {
            probeIdentifier = nil
            print("[bg] continued probe launched: \(task.identifier)")
            task.setTaskCompleted(success: true)
            return
        }

        BackgroundSyncLog.record(.launched, "continued")

        let direction = pendingDirection
        pendingDirection = nil

        workspace.openMostRecentVaultIfNeeded(startingBackgroundWork: false)
        guard workspace.canSync else {
            BackgroundSyncLog.record(.skipped, skipReason(workspace))
            task.setTaskCompleted(success: true)
            return
        }

        // Determinate from the first second, on a 0…100 scale.
        //
        // This was indeterminate until the plan existed, on the reasoning that
        // the phases before it have no meaningful denominator. True, and it got
        // the task killed: iOS forcibly expires a continued-processing task that
        // looks stalled, and listing a large remote outlasts its patience. Two
        // runs died that way, at 31 seconds and at 3½ minutes, with the bar
        // never having moved.
        //
        // `SyncProgress.percent` gives the phases before the plan a small fixed
        // share each rather than a fabricated crawl: the number moves when the
        // run moves, and never sits at zero for minutes.
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 0

        // Kept so an expiry can say how far it got. "Expired" alone cannot tell
        // a task killed while listing from one killed with two files to go, and
        // those need opposite fixes.
        var lastReported: SyncProgress?

        let completion = Completion()
        func finish(_ success: Bool) {
            guard !completion.done else { return }
            completion.done = true
            task.setTaskCompleted(success: success)
        }

        // Two tasks rather than one: the sync is a single long `await` with no
        // place to hang UI updates off, so a second one samples it. Polling is
        // the same choice `finishInFlightWork` makes and for the same reason —
        // `Workspace.sync()` hands back no handle.
        let pump = Task { @MainActor in
            while !Task.isCancelled, workspace.isSyncing {
                if let update = workspace.syncProgress {
                    // Never backwards: `Progress` treats a decrease as a reset,
                    // and a bar that jumps back reads as a restart.
                    let percent = Int64(update.percent)
                    if percent > task.progress.completedUnitCount {
                        task.progress.completedUnitCount = percent
                    }
                    lastReported = update
                    task.updateTitle(workspace.vault?.name ?? "Vault", subtitle: update.message)
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }

        let work = Task { @MainActor in
            await workspace.sync(firstSyncDirection: direction)
            pump.cancel()
            switch workspace.syncStatus {
            case .failed(let message):
                BackgroundSyncLog.record(.failed, message)
                finish(false)
            case .interrupted:
                BackgroundSyncLog.record(.expired, "continued")
                finish(false)
            default:
                BackgroundSyncLog.record(.finished, "continued")
                lastContinuedPercent = -1
                fruitlessExpiries = 0
                finish(true)
            }
        }

        task.expirationHandler = {
            let reached = lastReported?.percent ?? 0
            let where_ = lastReported.map { "\($0.percent)% — \($0.message)" } ?? "before it started"
            BackgroundSyncLog.record(.expired, "continued (system) at \(where_)")
            pump.cancel()
            work.cancel()
            finish(false)

            // Carry on rather than stop here.
            //
            // A first sync of a real vault does not fit in one of these — the
            // system grants what it grants, and for a few hundred megabytes that
            // is several goes. The engine already resumes rather than restarts,
            // so the only thing missing was asking for the next turn. Without
            // it the run stalls until iOS happens to grant a background refresh,
            // and the user is left looking at "failed".
            //
            // Guarded against spinning: three expiries that move nothing and it
            // stops, leaving the periodic tasks to try later.
            if reached > lastContinuedPercent {
                fruitlessExpiries = 0
            } else {
                fruitlessExpiries += 1
            }
            lastContinuedPercent = reached

            guard fruitlessExpiries < fruitlessLimit else {
                BackgroundSyncLog.record(.skipped, "continued made no progress \(fruitlessLimit)× — leaving it to the periodic tasks")
                return
            }
            if syncVisibly(workspace: workspace, firstSyncDirection: direction) {
                BackgroundSyncLog.record(.scheduled, "continued (carrying on from \(reached)%)")
            } else {
                // Submission is only allowed on behalf of the frontmost app, so
                // this fails whenever the expiry caught the app in the
                // background. The periodic tasks are already queued for that.
                BackgroundSyncLog.record(.scheduleFailed, "continued (could not carry on from \(reached)%)")
            }
        }
    }

    // MARK: - Running

    private static func run(_ task: BGTask, workspace: Workspace, thenScheduling kind: Kind) {
        // The one line that distinguishes "this feature does not work" from "iOS
        // has never once woken us". Written before anything that could fail.
        BackgroundSyncLog.record(.launched, task.identifier)

        // Queue the next one first. If the sync throws, or the system expires
        // the task, this has already happened — scheduling at the end would mean
        // one failed run silently ends background sync forever.
        submit(kind, workspace: workspace)

        // A background launch never renders a scene, so `onAppear` does not fire
        // and the vault the app was last using is not open. Without this the
        // handler would find `root == nil`, sync nothing, report success, and
        // look exactly like a feature that works.
        //
        // `startingBackgroundWork: false` matters here. Opening a vault normally
        // kicks off its own sync and starts the foreground repeat timer; in a
        // background launch that meant a second `sync()` racing the one below
        // over the same vault, and a sleep loop that the system suspends
        // seconds later. The handler wants the vault open and nothing else.
        workspace.openMostRecentVaultIfNeeded(startingBackgroundWork: false)

        guard workspace.canSync else {
            BackgroundSyncLog.record(.skipped, skipReason(workspace))
            task.setTaskCompleted(success: true)
            return
        }

        let work = Task { @MainActor in
            await workspace.sync()
            let succeeded: Bool
            switch workspace.syncStatus {
            case .failed(let message):
                succeeded = false
                BackgroundSyncLog.record(.failed, message)
            case .interrupted:
                // Ran out of window rather than broke. Reported unsuccessful so
                // the scheduler knows the work is not done, but logged as what
                // it was.
                succeeded = false
                BackgroundSyncLog.record(.expired, "\(task.identifier) (ran out of window)")
            default:
                succeeded = true
                BackgroundSyncLog.record(.finished, task.identifier)
            }
            task.setTaskCompleted(success: succeeded)
        }

        // The system gives no warning beyond this.
        //
        // What cancelling actually does, having checked rather than assumed:
        // SyncEngine has no cancellation checkpoints of its own, but its network
        // calls go through URLSession's async API, which throws on cancellation —
        // so the run aborts partway through the file loop and `sync()` records a
        // failure. `SyncState` is written **once, at the end** of a successful
        // run, so an interrupted sync leaves it untouched.
        //
        // That is survivable, and worth being precise about because it is not
        // obvious: the next run re-derives its plan from the actual local and
        // remote file lists, not from the state, and uses state only to tell a
        // remote *deletion* apart from a local *addition*. A file moved before
        // the interruption therefore looks like a local addition next time and is
        // re-uploaded — a redundant commit of identical content, not data loss.
        //
        // The real consequence is about *which* task type does the work. A sync
        // of a real vault was measured on device taking over 90 seconds, and an
        // app-refresh window is around 30. So refresh runs will often expire
        // here, and BGProcessingTask — which gets minutes — is what actually
        // finishes the job. Both are scheduled for that reason.
        task.expirationHandler = {
            BackgroundSyncLog.record(.expired, task.identifier)
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    /// Why `canSync` said no, term by term. A single false flag with three
    /// possible causes is the kind of thing that gets guessed at instead of
    /// looked up.
    private static func skipReason(_ workspace: Workspace) -> String {
        var missing: [String] = []
        if !workspace.syncBinding.isEnabled { missing.append("sync off for this vault") }
        if !workspace.syncBinding.isConfigured { missing.append("no repo bound to this vault") }
        if workspace.isBlockedByGitWorkingCopy { missing.append("git working copy") }
        if !SyncCredentials.hasToken { missing.append("no token") }
        if workspace.root == nil { missing.append("no vault") }
        if workspace.isSyncing { missing.append("already syncing") }
        return missing.isEmpty ? "unknown" : missing.joined(separator: ", ")
    }

    // MARK: - Diagnostics

    /// Reports what the system actually thinks, for the on-device check.
    ///
    ///   INKSTONE_BG_CHECK=1 ... Inkstone      (see InkstoneApp)
    ///
    /// Asks three questions whose answers cannot be inferred from a successful
    /// build: did the handlers register, did a submission survive, and does the
    /// scheduler hold the requests afterwards.
    static func diagnose() async {
        func emit(_ line: String) { print(line) }
        emit("[bg] registration:")
        for (identifier, ok) in registrationSucceeded.sorted(by: { $0.key < $1.key }) {
            emit("[bg]   \(ok ? "ok  " : "FAIL") \(identifier)")
        }

        let refresh = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        let processing = BGProcessingTaskRequest(identifier: processingIdentifier)
        processing.requiresNetworkConnectivity = true
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 60)

        for request in [refresh as BGTaskRequest, processing as BGTaskRequest] {
            do {
                try BGTaskScheduler.shared.submit(request)
                emit("[bg] submit ok   \(request.identifier)")
            } catch {
                emit("[bg] submit FAIL \(request.identifier): \(error)")
            }
        }

        // The continued-processing path, end to end: submit a request that does
        // no work, and see whether the system launches the handler for it.
        let probe = composedIdentifier()
        if let target = workspaceRef, registerContinued(probe, workspace: target) {
            emit("[bg] continued register ok   \(probe)")
            probeIdentifier = probe
            let probeRequest = BGContinuedProcessingTaskRequest(
                identifier: probe, title: "Inkstone", subtitle: "Checking background sync…"
            )
            // `.fail` rather than `.queue`: a probe that sits in a queue answers
            // nothing. Either the system can run it now or it says why not.
            probeRequest.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(probeRequest)
                emit("[bg] continued submit ok   \(probe)")
            } catch {
                emit("[bg] continued submit FAIL \(probe): \(error)")
                probeIdentifier = nil
            }
        } else {
            emit("[bg] continued register FAIL \(probe)")
        }

        let pending = await BGTaskScheduler.shared.pendingTaskRequests()
        emit("[bg] pending: \(pending.count)")
        for request in pending {
            emit("[bg]   \(request.identifier) earliest=\(request.earliestBeginDate?.description ?? "now")")
        }

        // The other half of the handler, run without a BGTask. This does not
        // prove iOS will call the handler — only a real background launch does
        // that — but it does prove the body works when called, which is the part
        // that would otherwise open no vault and report a cheerful success.
        emit("[bg] handler body:")
        emit("[bg]   vault before: \(workspaceRef?.vault?.name ?? "none")")
        workspaceRef?.openMostRecentVaultIfNeeded()
        emit("[bg]   vault after:  \(workspaceRef?.vault?.name ?? "none")")
        emit("[bg]   canSync: \(workspaceRef?.canSync == true)")
        if workspaceRef?.canSync == true {
            await workspaceRef?.sync()
            emit("[bg]   sync finished: \(String(describing: workspaceRef?.syncStatus))")
        } else {
            // Every term of `canSync`, so a false answer names its own cause
            // instead of leaving three candidates and a guess.
            emit("[bg]   not syncing: enabled=\(workspaceRef?.syncBinding.isEnabled == true)"
                         + " repo=\(workspaceRef?.syncBinding.repository ?? "none")"
                         + " git=\(workspaceRef?.isBlockedByGitWorkingCopy == true)"
                         + " token=\(SyncCredentials.hasToken)"
                         + " root=\(workspaceRef?.root != nil)"
                         + " isSyncing=\(workspaceRef?.isSyncing == true)")
            // If a sync was already under way, wait it out and report how it
            // ended — that is the same work the background handler would do.
            if workspaceRef?.isSyncing == true {
                // Bounded. An unbounded wait here is why an earlier run of this
                // diagnostic printed nothing at all: the sync outlasted the
                // console session and took the report down with it.
                let deadline = Date(timeIntervalSinceNow: 120)
                while workspaceRef?.isSyncing == true, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                if workspaceRef?.isSyncing == true {
                    emit("[bg]   still syncing after 120s — this vault needs the processing task, not refresh")
                }
                emit("[bg]   in-flight sync ended: \(String(describing: workspaceRef?.syncStatus))")
            }
        }
        emit("[bg] done")
    }

    // MARK: - Finishing a sync that was already running

    /// Keeps the app alive long enough to finish a sync that was in flight when
    /// the user left. Returns once the work is done or the system takes the time
    /// back, whichever is first.
    static func finishInFlightWork(workspace: Workspace) async {
        guard workspace.isSyncing else { return }

        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Finish sync") {
            // Expiry. End the assertion, or iOS terminates the app for holding
            // one past its welcome.
            if identifier != .invalid {
                UIApplication.shared.endBackgroundTask(identifier)
                identifier = .invalid
            }
        }
        guard identifier != .invalid else { return }

        // Poll rather than await the sync task: `sync()` is owned by Workspace
        // and may have been started by the timer, a button or a background run,
        // and none of those hand back a handle to wait on.
        while workspace.isSyncing {
            try? await Task.sleep(for: .milliseconds(250))
            if identifier == .invalid { return }   // the system took the time back
        }

        if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
}
#endif
