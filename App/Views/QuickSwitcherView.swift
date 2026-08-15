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
                TextField(String(localized: "Find or create a note…"), text: $query)
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
            refresh()
        }
        .onChange(of: query) { _, _ in refresh() }
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

    private func refresh() {
        guard let root = workspace.root else { return }
        results = SearchEngine.quickSwitch(query: query, in: workspace.index, vaultRoot: root)
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
    @State private var iCloudUnavailable = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(style.accent)
                Text("Inkstone")
                    .font(.system(size: 30, weight: .medium, design: .serif))
                Text("Your notes, as plain files you own.")
                    .font(style.uiFont)
                    .foregroundStyle(style.secondaryText)
            }

            VStack(spacing: 10) {
                Button {
                    isPickingFolder = true
                } label: {
                    Label("Open Folder as Vault", systemImage: "folder")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    createICloudVault()
                } label: {
                    Label("Create Vault in iCloud Drive", systemImage: "icloud")
                        .frame(maxWidth: 260)
                }
                .controlSize(.large)
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
        .alert("iCloud Drive isn't available", isPresented: $iCloudUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Sign in to iCloud and enable iCloud Drive, then try again. You can also open any folder as a vault.")
        }
    }

    /// Creates a vault inside the app's iCloud container, which is the
    /// zero-configuration path to cross-device sync.
    ///
    /// The container is unavailable when the iCloud entitlement isn't in the
    /// build or the user is signed out; say so rather than doing nothing.
    private func createICloudVault() {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            iCloudUnavailable = true
            return
        }
        let documents = container.appending(path: "Documents", directoryHint: .isDirectory)
        let vaultURL = documents.appending(path: "Inkstone", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        if let vault = try? workspace.registry.register(folder: vaultURL, name: "Inkstone (iCloud)") {
            workspace.open(vault)
        }
    }
}
