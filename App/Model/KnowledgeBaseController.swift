import Foundation
import Observation
import InkstoneCore

/// Runs the organizer for the open knowledge base: when something lands in
/// the inbox (a drop, a share, a sync, a file saved there by another app),
/// shortly after, it plans a round; a small round is done at once (and can be
/// undone from the banner), a round that needs confirmation waits as
/// `pendingPlan` for the person to look at.
///
/// Only a knowledge base made or adopted by Inkstone is ever organized — one
/// with its rules file. Folder names alone are not enough: an Obsidian vault
/// laid out as `00-Inbox`, `10-Projects` … (a common method) is someone's own,
/// and is never reorganized.
@MainActor
@Observable
final class KnowledgeBaseController {
    private(set) var root: URL?
    private(set) var layout: KnowledgeBaseLayout?
    /// A round waiting for the person's yes (more than 20 files, duplicates).
    private(set) var pendingPlan: ChangePlan?
    /// The last round done, for the "organized N files · Undo" banner.
    private(set) var lastResult: OrganizeResult?
    private(set) var isOrganizing = false
    private(set) var failure: String?
    /// The "your knowledge base is ready" card, shown once after creating.
    var isShowingReadyCard = false

    private let settings: AppSettings
    private var debounce: Task<Void, Never>?
    /// Bumped on every attach and detach. Work started for one vault checks
    /// it after every wait and drops its result if the vault has changed — a
    /// plan for vault A must never be shown, executed or undone in vault B.
    private var generation = 0
    /// The inbox as it was when last looked at automatically (names, sizes,
    /// dates). Unchanged — a plan dismissed, a round undone, a file that
    /// cannot be moved — means nothing to do, without planning again.
    private var lastSeenInbox: [String]?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isKnowledgeBase: Bool { layout != nil }

    func attach(_ root: URL) {
        detach()
        self.root = root
        layout = Self.knowledgeBaseLayout(at: root)
        inboxMayHaveChanged(delay: .seconds(1))
    }

    func detach() {
        generation += 1
        debounce?.cancel()
        root = nil; layout = nil; pendingPlan = nil; lastResult = nil; failure = nil
        lastSeenInbox = nil; isOrganizing = false; isShowingReadyCard = false
    }

    /// The layout, only for a folder with its rules file (made or adopted by
    /// Inkstone).
    nonisolated static func knowledgeBaseLayout(at root: URL) -> KnowledgeBaseLayout? {
        guard let layout = KnowledgeBaseLayout.detect(in: root),
              FileManager.default.fileExists(atPath: root.appending(path: layout.rulesFile).path(percentEncoded: false))
        else { return nil }
        return layout
    }

    func showReadyCard() { isShowingReadyCard = true }
    func clearFailure() { failure = nil }
    func clearBanner() { lastResult = nil }

    /// The vault changed on disk. Re-detects (a knowledge base may just have
    /// been made here) and, after things settle, looks at the inbox.
    func inboxMayHaveChanged(delay: Duration = .seconds(2)) {
        guard let root else { return }
        if layout == nil { layout = Self.knowledgeBaseLayout(at: root) }
        guard layout != nil else { return }
        let kb = settings.data.knowledgeBase
        let token = generation
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            if kb.autoOrganize { await self.organize(automatic: true) }
            // A folder made or renamed by hand shows up in the entry files.
            if kb.maintainEntryFiles, self.generation == token {
                _ = await Task.detached(priority: .utility) { try? EntryFiles.refresh(in: root) }.value
            }
        }
    }

    /// "Organize now" (or automatic): plans the inbox; a round that needs
    /// confirmation is shown first, the rest done at once.
    func organize(automatic: Bool = false) async {
        guard let root, let layout, !isOrganizing, pendingPlan == nil else { return }
        let token = generation
        let inbox = await Task.detached(priority: .utility) { Self.inboxSignature(root: root, layout: layout) }.value
        guard generation == token else { return }
        if automatic {
            guard !inbox.isEmpty, inbox != lastSeenInbox else { return }
        }
        lastSeenInbox = inbox
        isOrganizing = true
        defer { if generation == token { isOrganizing = false } }
        failure = nil
        let organizer = makeOrganizer(root: root, layout: layout)
        do {
            let plan = try await Task.detached(priority: .utility) { try await organizer.plan() }.value
            guard generation == token, !plan.isEmpty else { return }
            if plan.needsConfirmation {
                pendingPlan = plan
                return
            }
            let result = try await Task.detached(priority: .utility) { try organizer.execute(plan) }.value
            guard generation == token else { return }
            lastResult = result
            lastSeenInbox = Self.inboxSignature(root: root, layout: layout)
        } catch {
            if generation == token { failure = error.localizedDescription }
        }
    }

    /// The person said yes to this round (the plan is passed in: the sheet
    /// closing on its own clears `pendingPlan`).
    func confirm(_ plan: ChangePlan) async {
        guard let root, let layout, !isOrganizing else { return }
        let token = generation
        pendingPlan = nil
        isOrganizing = true
        defer { if generation == token { isOrganizing = false } }
        let organizer = makeOrganizer(root: root, layout: layout)
        do {
            let result = try await Task.detached(priority: .utility) { try organizer.execute(plan) }.value
            guard generation == token else { return }
            lastResult = result
            lastSeenInbox = Self.inboxSignature(root: root, layout: layout)
        } catch {
            if generation == token { failure = error.localizedDescription }
        }
    }

    /// Not now: the files stay in the inbox, and are not asked about again
    /// until something in the inbox changes.
    func dismissPlan() {
        pendingPlan = nil
    }

    func undoLast() async {
        guard let result = lastResult, let root, let layout else { return }
        let token = generation
        lastResult = nil
        let organizer = makeOrganizer(root: root, layout: layout)
        do {
            let undone = try await Task.detached(priority: .utility) { try organizer.undo(batch: result.batch) }.value
            guard generation == token else { return }
            // The files are back in the inbox: not filed again until it changes.
            lastSeenInbox = Self.inboxSignature(root: root, layout: layout)
            if !undone.skipped.isEmpty {
                failure = localized("Some files were left as they are: \(undone.skipped.joined(separator: ", "))")
            }
        } catch {
            if generation == token { failure = error.localizedDescription }
        }
    }

    /// What is in the inbox — path, size and date of each item — cheap to
    /// compare, so an unchanged inbox is never planned twice.
    nonisolated static func inboxSignature(root: URL, layout: KnowledgeBaseLayout) -> [String] {
        let items = (try? Organizer.inboxFiles(root: root, layout: layout)) ?? []
        return items.map { url in
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(url.path(percentEncoded: false))|\(v?.fileSize ?? -1)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
    }

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
