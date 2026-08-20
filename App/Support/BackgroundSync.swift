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
/// `BGContinuedProcessingTask` — new in iOS 26, for work the user starts in the
/// foreground and which then continues with a progress display — is deliberately
/// not used here. It fits "tap Sync, then leave the app", which is a different
/// feature from unattended periodic sync, and it must be submitted while the app
/// is foregrounded. Worth adding later; it is not what "background sync" means.
@MainActor
enum BackgroundSync {
    /// Identifiers must also appear in `BGTaskSchedulerPermittedIdentifiers` in
    /// Info.plist, or `submit` throws `notPermitted`.
    static let refreshIdentifier = "com.orris.inkstone.sync.refresh"
    static let processingIdentifier = "com.orris.inkstone.sync.processing"

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

    /// Registers the handlers. Call once, from the app's `init`.
    static func register(workspace: Workspace) {
        workspaceRef = workspace
        guard !registered else { return }
        registered = true

        registrationSucceeded[refreshIdentifier] = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshIdentifier, using: nil
        ) { task in
            MainActor.assumeIsolated {
                run(task, workspace: workspace, thenScheduling: .refresh)
            }
        }

        registrationSucceeded[processingIdentifier] = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: processingIdentifier, using: nil
        ) { task in
            MainActor.assumeIsolated {
                run(task, workspace: workspace, thenScheduling: .processing)
            }
        }
    }

    // MARK: - Scheduling

    enum Kind { case refresh, processing }

    /// Asks the system for both kinds of run. Call when the app leaves the
    /// foreground and again after each background run completes — a request is
    /// consumed when it fires, so nothing here is periodic by itself.
    static func schedule(workspace: Workspace) {
        guard workspace.settings.data.gitHubSyncEnabled,
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
        } catch {
            // Expected and harmless in two cases: the Simulator, which has no
            // scheduler, and a duplicate request, which simply replaces the
            // pending one. Neither is worth showing anyone, but swallowing it
            // silently is how "background sync never ran" becomes unexplainable.
            #if DEBUG
            print("[BackgroundSync] could not submit \(kind): \(error)")
            #endif
        }
    }

    // MARK: - Running

    private static func run(_ task: BGTask, workspace: Workspace, thenScheduling kind: Kind) {
        // Queue the next one first. If the sync throws, or the system expires
        // the task, this has already happened — scheduling at the end would mean
        // one failed run silently ends background sync forever.
        submit(kind, workspace: workspace)

        // A background launch never renders a scene, so `onAppear` does not fire
        // and the vault the app was last using is not open. Without this the
        // handler would find `root == nil`, sync nothing, report success, and
        // look exactly like a feature that works.
        workspace.openMostRecentVaultIfNeeded()

        guard workspace.canSync else {
            task.setTaskCompleted(success: true)
            return
        }

        let work = Task { @MainActor in
            await workspace.sync()
            let succeeded: Bool
            if case .failed = workspace.syncStatus { succeeded = false } else { succeeded = true }
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
            work.cancel()
            task.setTaskCompleted(success: false)
        }
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
            emit("[bg]   not syncing: gitHubSyncEnabled=\(workspaceRef?.settings.data.gitHubSyncEnabled == true)"
                         + " repo=\(workspaceRef?.settings.data.gitHubRepository.isEmpty == false)"
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
