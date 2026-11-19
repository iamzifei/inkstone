import Foundation
import Observation
import InkstoneCore

/// Runs the organizer for the open knowledge base: when something lands in
/// the inbox (a drop, a share, a sync, a file saved there by another app),
/// shortly after, it plans a round; a small round is done at once (and can be
/// undone from the banner), a round that needs confirmation waits as
/// `pendingPlan` for the person to look at.
///
/// Does nothing for a vault that is not a knowledge base (no skeleton): an
/// Obsidian vault opened in Inkstone is never reorganized.
@MainActor
@Observable
final class KnowledgeBaseController {
    private(set) var root: URL?
    private(set) var layout: KnowledgeBaseLayout?
    /// A round waiting for the person's yes (more than 20 files, duplicates,
    /// or files already in place would move).
    private(set) var pendingPlan: ChangePlan?
    /// The last round done, for the "organized N files · Undo" banner.
    private(set) var lastResult: OrganizeResult?
    private(set) var isOrganizing = false
    /// The "your knowledge base is ready" card, shown once after creating.
    var isShowingReadyCard = false

    func showReadyCard() { isShowingReadyCard = true }
    private(set) var failure: String?

    private let settings: AppSettings
    private var debounce: Task<Void, Never>?
    /// The plan the person dismissed, so the same inbox does not ask again
    /// until something in it changes.
    private var dismissedSignature: [String]?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isKnowledgeBase: Bool { layout != nil }

    func attach(_ root: URL) {
        detach()
        self.root = root
        layout = KnowledgeBaseLayout.detect(in: root)
        inboxMayHaveChanged(delay: .seconds(1))
    }

    func detach() {
        debounce?.cancel()
        root = nil; layout = nil; pendingPlan = nil; lastResult = nil; failure = nil; dismissedSignature = nil
    }

    /// The vault changed on disk. Re-detects the layout (a skeleton may just
    /// have been created) and, after things settle, looks at the inbox.
    func inboxMayHaveChanged(delay: Duration = .seconds(2)) {
        guard let root else { return }
        if layout == nil { layout = KnowledgeBaseLayout.detect(in: root) }
        guard layout != nil else { return }
        let kb = settings.data.knowledgeBase
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            if kb.autoOrganize { await self?.organize(automatic: true) }
            // A folder made or renamed by hand shows up in the entry files.
            if kb.maintainEntryFiles {
                _ = await Task.detached(priority: .utility) { try? EntryFiles.refresh(in: root) }.value
            }
        }
    }

    /// "Organize now": plans the inbox; a round that needs confirmation is
    /// shown first, the rest done at once.
    func organize(automatic: Bool = false) async {
        guard let root, let layout, !isOrganizing, pendingPlan == nil else { return }
        isOrganizing = true
        defer { isOrganizing = false }
        failure = nil
        let organizer = makeOrganizer(root: root, layout: layout)
        do {
            let plan = try await Task.detached(priority: .utility) { try await organizer.plan() }.value
            guard !plan.isEmpty else { return }
            // Dismissed or just undone, and nothing new since: leave it.
            if automatic, plan.moves.map(\.from) == dismissedSignature { return }
            dismissedSignature = nil
            if plan.needsConfirmation {
                pendingPlan = plan
                return
            }
            lastResult = try await Task.detached(priority: .utility) { try organizer.execute(plan) }.value
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The person said yes to this round (the plan is passed in: the sheet
    /// closing on its own clears `pendingPlan`).
    func confirm(_ plan: ChangePlan) async {
        guard let root, let layout else { return }
        pendingPlan = nil
        dismissedSignature = nil
        isOrganizing = true
        defer { isOrganizing = false }
        let organizer = makeOrganizer(root: root, layout: layout)
        do {
            lastResult = try await Task.detached(priority: .utility) { try organizer.execute(plan) }.value
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Not now: the files stay in the inbox.
    func dismissPlan() {
        dismissedSignature = pendingPlan?.moves.map(\.from)
        pendingPlan = nil
    }

    func undoLast() async {
        guard let result = lastResult, let root, let layout else { return }
        lastResult = nil
        let organizer = makeOrganizer(root: root, layout: layout)
        do {
            try await Task.detached(priority: .utility) { try organizer.undo(batch: result.batch) }.value
            // The files are back in the inbox; don't file them again at once.
            dismissedSignature = result.plan.moves.map(\.from)
        } catch {
            failure = error.localizedDescription
        }
    }

    func clearBanner() { lastResult = nil }

    private func makeOrganizer(root: URL, layout: KnowledgeBaseLayout) -> Organizer {
        let kb = settings.data.knowledgeBase
        var advisor: PlacementAdvisor?
        if kb.useAssistantModel, let profile = settings.data.assistant.activeProfile,
           let provider = try? ProviderFactory.provider(for: profile) {
            advisor = ProviderPlacementAdvisor(provider: provider, model: profile.model)
        } else if kb.useOnDeviceModel {
            advisor = OnDevicePlacementAdvisor.makeIfAvailable()
        }
        return Organizer(root: root, layout: layout, advisor: advisor, ocr: kb.recognizeTextInImages,
                         maintainEntryFiles: kb.maintainEntryFiles)
    }
}
