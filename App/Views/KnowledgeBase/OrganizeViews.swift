import SwiftUI
import InkstoneCore

/// Which knowledge-base sheet is up — at most one.
enum KnowledgeBaseSheet: Identifiable {
    case ready
    case plan(ChangePlan)
    case drop([URL])

    var id: String {
        switch self {
        case .ready: return "ready"
        case .plan(let p): return "plan-" + p.moves.map(\.from).joined(separator: "|")
        case .drop(let urls): return "drop-" + urls.map(\.path).joined(separator: "|")
        }
    }

    @MainActor static func current(_ kb: KnowledgeBaseController) -> KnowledgeBaseSheet? {
        if kb.isShowingReadyCard { return .ready }
        // Files just dropped come before a round waiting from before.
        if let urls = kb.pendingDrop { return .drop(urls) }
        if let plan = kb.pendingPlan { return .plan(plan) }
        return nil
    }

    @MainActor static func closeCurrent(_ kb: KnowledgeBaseController) {
        if kb.isShowingReadyCard { kb.isShowingReadyCard = false }
        else if kb.pendingDrop != nil { kb.pendingDrop = nil }
        else if kb.pendingPlan != nil { kb.dismissPlan() }
    }
}

/// "Organized 5 files · Undo": shown for half a minute after each round.
struct OrganizeBanner: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    let result: OrganizeResult

    var body: some View {
        let kb = workspace.knowledgeBase
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(style.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Organized \(result.moved) files")
                    .font(.callout.weight(.semibold))
                if let summary = detail {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Undo") { Task { await kb.undoLast() } }
                .buttonStyle(.borderless)
            Button { kb.clearBanner() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .frame(maxWidth: 460)
        .padding(16)
        .task(id: result.batch) {
            try? await Task.sleep(for: .seconds(30))
            if kb.lastResult?.batch == result.batch { kb.clearBanner() }
        }
    }

    /// The parts that need the person: files left for review, files that
    /// could not be moved.
    private var detail: String? {
        var parts: [String] = []
        let review = result.plan.count(.review)
        if review > 0 { parts.append(localized("\(review) waiting for you to check")) }
        if !result.failures.isEmpty { parts.append(localized("\(result.failures.count) left in the inbox")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A round that waits for the person's yes: more than 20 files, or
/// duplicates to put aside. Lists every move by kind; nothing happens until
/// "Organize".
struct ChangePlanSheet: View {
    @Environment(Workspace.self) private var workspace
    let plan: ChangePlan

    var body: some View {
        let kb = workspace.knowledgeBase
        NavigationStack {
            List {
                Section {
                    Text("Nothing is deleted. Duplicates are put aside in the to-delete folder, and the whole round can be undone.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                group(.file, title: "Filed", icon: "folder")
                group(.privateFile, title: "Private", icon: "lock")
                group(.duplicate, title: "Duplicates, put aside", icon: "doc.on.doc")
                group(.review, title: "For you to check", icon: "questionmark.folder")
            }
            .navigationTitle(Text("Organize \(plan.moves.count) files?"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { kb.dismissPlan() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Organize") {
                        // confirm() clears pendingPlan at once, which closes this sheet.
                        let plan = plan
                        Task { await kb.confirm(plan) }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 480)
        #endif
    }

    @ViewBuilder
    private func group(_ kind: OrganizeMove.Kind, title: LocalizedStringKey, icon: String) -> some View {
        let moves = plan.moves.filter { $0.kind == kind }
        if !moves.isEmpty {
            Section {
                ForEach(moves) { move in
                    VStack(alignment: .leading, spacing: 2) {
                        Text((move.from as NSString).lastPathComponent).font(.callout)
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.down.right").font(.caption2)
                            Text(move.to).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                        .foregroundStyle(.secondary)
                        if let kept = move.kept {
                            Text("Same as \(kept)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Label { Text(title) + Text(" · \(moves.count)") } icon: { Image(systemName: icon) }
            }
        }
    }
}
