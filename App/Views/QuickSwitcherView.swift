import SwiftUI
import InkstoneCore

/// Fuzzy note opener (⌘O). The fastest path from "I want that note" to having it
/// on screen, which is the single most-used command in any notes app.
struct QuickSwitcherView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [QuickSwitchResult] = []
    @State private var highlighted = 0
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(style.faintText)
                TextField(localized("Find or create a note…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($isFieldFocused)
                    .onSubmit(activateHighlighted)
                    .onKeyPress(.upArrow) {
                        highlighted = max(0, highlighted - 1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        highlighted = min(results.count - 1, highlighted + 1)
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().overlay(style.divider)

            ScrollViewReader { proxy in
                List(Array(results.enumerated()), id: \.element.id) { index, result in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                            .foregroundStyle(style.faintText)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.title)
                                .font(style.uiFont.weight(index == highlighted ? .semibold : .regular))
                            if !result.subtitle.isEmpty {
                                Text(result.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(style.faintText)
                            }
                        }
                        Spacer()
                    }
                    .listRowBackground(index == highlighted ? style.selection : Color.clear)
                    .contentShape(.rect)
                    .onTapGesture {
                        highlighted = index
                        activateHighlighted()
                    }
                    .id(index)
                }
                .listStyle(.plain)
                .onChange(of: highlighted) { _, new in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
                }
            }

            if results.isEmpty, !query.isEmpty {
                createRow
            }
        }
        .frame(minWidth: 440, minHeight: 380)
        .background(style.background)
        .onAppear {
            isFieldFocused = true
            #if DEBUG
            if !workspace.quickSwitcherSeed.isEmpty {
                query = workspace.quickSwitcherSeed
                workspace.quickSwitcherSeed = ""
            }
            #endif
        }
        // Also covers the first appearance, so the switcher opens showing the
        // whole vault rather than an empty list.
        .task(id: query) { await refresh() }
    }

    private var createRow: some View {
        Button {
            workspace.createNote(named: query)
            dismiss()
        } label: {
            Label("Create \"\(query)\"", systemImage: "plus.circle")
                .font(style.uiFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .buttonStyle(.plain)
    }

    /// Ranks the vault off the main actor.
    ///
    /// Measured at **100 ms per keystroke** on an 8,852-note vault, and it ran
    /// synchronously from `onChange` — so the switcher fell behind the typing on
    /// exactly the vaults it is most needed in. No debounce here, unlike the
    /// search pane: this reads no files, and a switcher that waits before showing
    /// anything is a switcher that feels broken. `.task(id:)` cancels the
    /// previous ranking when the next character arrives, which is enough.
    private func refresh() async {
        guard let root = workspace.root else { return }
        let snapshot = workspace.index
        let query = query
        let ranked = await Task.detached(priority: .userInitiated) {
            SearchEngine.quickSwitch(query: query, in: snapshot, vaultRoot: root)
        }.value
        guard !Task.isCancelled else { return }
        results = ranked
        highlighted = 0
    }

    private func activateHighlighted() {
        if results.indices.contains(highlighted) {
            workspace.openNote(at: results[highlighted].url)
        } else if !query.isEmpty {
            workspace.createNote(named: query)
        }
        dismiss()
    }
}

/// Shown when no vault is open.
struct WelcomeView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    @State private var isPickingFolder = false

    var body: some View {
        ScrollView {
        VStack(spacing: 24) {
            // A new person starts here: a knowledge base made for them.
            CreateKnowledgeBaseView()

            Divider().frame(maxWidth: 320)

            // Someone who already has notes (an Obsidian vault) opens them
            // as they are: nothing is added, nothing reorganized.
            VStack(spacing: 10) {
                Text("Already have notes?")
                    .font(.caption)
                    .foregroundStyle(style.faintText)
                Button {
                    isPickingFolder = true
                } label: {
                    Label("Open Folder as Vault", systemImage: "folder")
                        .frame(maxWidth: 260)
                }

            }

            if !workspace.registry.vaults.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent vaults")
                        .font(.caption)
                        .foregroundStyle(style.faintText)
                    ForEach(workspace.registry.vaults.sorted(by: { $0.lastOpened > $1.lastOpened })) { vault in
                        Button {
                            workspace.open(vault)
                        } label: {
                            Label(vault.name, systemImage: vault.isCloudBacked ? "icloud" : "folder")
                                .font(style.uiFont)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove from list", role: .destructive) {
                                workspace.registry.forget(vault)
                            }
                        }
                    }
                }
                .frame(maxWidth: 300, alignment: .leading)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.background)
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            if let vault = try? workspace.registry.register(folder: url) {
                workspace.open(vault)
            }
        }
    }

}
