import SwiftUI
import InkstoneCore

/// Preferences. Tabbed on macOS, a plain form on iOS.
struct SettingsView: View {
    @Environment(Workspace.self) private var workspace

    /// Dismisses the sheet on iOS, where this is presented rather than being a
    /// window of its own. nil on macOS, which closes it the way it closes any
    /// window.
    var onDone: (() -> Void)?

    var body: some View {
        #if os(macOS)
        TabView {
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            TypographySettings().tabItem { Label("Typography", systemImage: "textformat") }
            EditorSettings().tabItem { Label("Editor", systemImage: "square.and.pencil") }
            FilesSettings().tabItem { Label("Files & Links", systemImage: "folder") }
            SyncSettings().tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 560, height: 460)
        #else
        NavigationStack(path: $path) {
            Form {
                ForEach(Pane.allCases) { pane in
                    NavigationLink(value: pane) {
                        Label(pane.title, systemImage: pane.symbol)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: Pane.self) { $0.view }
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
            }
        }
        #endif
    }

    #if !os(macOS)
    /// A value-driven path rather than view-carrying links, so a pane can be
    /// opened from code. Verifying a settings pane otherwise means driving a tap
    /// on each one, which is exactly the kind of check that quietly stops being
    /// done.
    ///
    ///     SIMCTL_CHILD_INKSTONE_OPEN_SETTINGS=typography xcrun simctl launch <sim> com.orris.inkstone
    @State private var path: [Pane] = {
        #if DEBUG
        guard let name = ProcessInfo.processInfo.environment["INKSTONE_OPEN_SETTINGS"],
              let pane = Pane(rawValue: name)
        else { return [] }
        return [pane]
        #else
        return []
        #endif
    }()

    enum Pane: String, CaseIterable, Identifiable, Hashable {
        case appearance, typography, editor, files, sync

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .appearance: return "Appearance"
            case .typography: return "Typography"
            case .editor: return "Editor"
            case .files: return "Files & Links"
            case .sync: return "Sync"
            }
        }

        var symbol: String {
            switch self {
            case .appearance: return "paintpalette"
            case .typography: return "textformat"
            case .editor: return "square.and.pencil"
            case .files: return "folder"
            case .sync: return "arrow.triangle.2.circlepath"
            }
        }

        @ViewBuilder var view: some View {
            switch self {
            case .appearance: AppearanceSettings()
            case .typography: TypographySettings()
            case .editor: EditorSettings()
            case .files: FilesSettings()
            case .sync: SyncSettings()
            }
        }
    }
    #endif
}

private struct AppearanceSettings: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var settings = workspace.settings

        Form {
            Picker("Language", selection: $settings.data.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.endonym).tag(language)
                }
            }
            // Changing the app language needs a relaunch on Apple platforms
            // unless we swap bundles at runtime; say so rather than silently
            // doing nothing.
            Text("Takes effect after restarting Inkstone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Appearance", selection: $settings.data.appearance) {
                Text("System").tag(AppearanceMode.system)
                Text("Light").tag(AppearanceMode.light)
                Text("Dark").tag(AppearanceMode.dark)
            }
            .pickerStyle(.segmented)

            Picker("Theme", selection: $settings.data.themeID) {
                ForEach(settings.availableThemes) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct TypographySettings: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var settings = workspace.settings

        Form {
            // The chrome, which is a different thing from the notes and had no
            // control at all — every other section on this page changes how a
            // *file* looks, so someone finding the file list too small had
            // nowhere to go. The setting existed and drove `style.uiFont`; it
            // was simply never exposed.
            Section {
                FontPicker(
                    title: String(localized: "Font"),
                    selection: $settings.data.typography.interfaceFont,
                    suggestions: Typography.recommendedCJKFonts
                )
                LabeledStepper(
                    title: String(localized: "Size"),
                    value: $settings.data.typography.interfaceFontSize,
                    range: 10...24,
                    step: 0.5,
                    format: "%.1f pt"
                )
            } header: {
                Text("Interface")
            } footer: {
                Text("The file list, sidebar and panels — not the text inside your notes.")
            }

            Section("Body text") {
                FontPicker(
                    title: String(localized: "Font"),
                    selection: $settings.data.typography.editorFont,
                    suggestions: Typography.recommendedCJKFonts
                )
                LabeledStepper(
                    title: String(localized: "Size"),
                    value: $settings.data.typography.editorFontSize,
                    range: 11...32,
                    step: 0.5,
                    format: "%.1f pt"
                )
                LabeledStepper(
                    title: String(localized: "Line height"),
                    value: $settings.data.typography.lineHeightMultiple,
                    range: 1.0...2.6,
                    step: 0.05,
                    format: "%.2f×"
                )
                LabeledStepper(
                    title: String(localized: "Letter spacing"),
                    value: $settings.data.typography.letterSpacing,
                    range: -1...4,
                    step: 0.1,
                    format: "%.1f pt"
                )
            }

            Section("Code") {
                FontPicker(
                    title: String(localized: "Font"),
                    selection: $settings.data.typography.codeFont,
                    suggestions: Typography.recommendedCodeFonts
                )
                LabeledStepper(
                    title: String(localized: "Size"),
                    value: $settings.data.typography.codeFontSize,
                    range: 9...24,
                    step: 0.5,
                    format: "%.1f pt"
                )
                LabeledStepper(
                    title: String(localized: "Line height"),
                    value: $settings.data.typography.codeLineHeightMultiple,
                    range: 1.0...2.2,
                    step: 0.05,
                    format: "%.2f×"
                )
            }

            Section("Layout") {
                Toggle("Limit line width", isOn: $settings.data.typography.isReadableLineWidthEnabled)
                LabeledStepper(
                    title: String(localized: "Max line width"),
                    value: $settings.data.typography.readableLineWidth,
                    range: 400...1200,
                    step: 20,
                    format: "%.0f pt"
                )
                .disabled(!settings.data.typography.isReadableLineWidthEnabled)
                LabeledStepper(
                    title: String(localized: "Heading scale"),
                    value: $settings.data.typography.headingScale,
                    range: 1.05...1.5,
                    step: 0.01,
                    format: "%.2f"
                )
            }

            Section("Chinese typography") {
                Toggle("Space between Chinese and Latin", isOn: $settings.data.typography.cjkLatinSpacing)
                Text("Adds a hair space between 中文 and English while rendering. Your files are never modified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Compress full-width punctuation", isOn: $settings.data.typography.cjkPunctuationCompression)
            }
        }
        .formStyle(.grouped)
    }
}

private struct EditorSettings: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var settings = workspace.settings

        Form {
            Picker("Default mode", selection: $settings.data.editorMode) {
                Text("Live Preview").tag(EditorMode.livePreview)
                Text("Source").tag(EditorMode.source)
                Text("Reading").tag(EditorMode.reading)
            }
            Toggle("Continue lists on Return", isOn: $settings.data.smartLists)
            Toggle("Auto-close brackets and quotes", isOn: $settings.data.autoPairBrackets)
            Toggle("Check spelling", isOn: $settings.data.spellCheck)
            Toggle("Show frontmatter as properties", isOn: $settings.data.showFrontmatterAsProperties)
            Toggle("Indent with tabs", isOn: $settings.data.indentWithTabs)
            Stepper("Tab size: \(settings.data.tabSize)", value: $settings.data.tabSize, in: 2...8)
        }
        .formStyle(.grouped)
    }
}

private struct FilesSettings: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var settings = workspace.settings

        Form {
            Section("New notes") {
                TextField("Default folder", text: $settings.data.defaultNewNoteFolder)
                TextField("Attachment folder", text: $settings.data.attachmentFolder)
            }
            Section("Links") {
                Picker("New link format", selection: $settings.data.newLinkFormat) {
                    Text("[[Wikilink]]").tag(SettingsData.LinkFormat.wikilink)
                    Text("[Markdown](link.md)").tag(SettingsData.LinkFormat.markdown)
                }
                Toggle("Use shortest path when possible", isOn: $settings.data.useShortestPathLinks)
                Toggle("Update links when a note is renamed", isOn: $settings.data.updateLinksOnRename)
            }
            Section("Daily notes") {
                TextField("Folder", text: $settings.data.dailyNoteFolder)
                TextField("Date format", text: $settings.data.dailyNoteFormat)
                Toggle("Week starts on Monday", isOn: $settings.data.weekStartsOnMonday)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SyncSettings: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    /// Held only long enough to save it; the stored value lives in the Keychain.
    @State private var token = ""

    // The picker's contents. Empty until asked for, and falling back to the
    // free-text fields when it stays empty — a picker that cannot be filled must
    // not be the only way to name a repository.
    @State private var repositories: [GitHubClient.Repository] = []
    @State private var branches: [String] = []
    @State private var isLoadingRepositories = false
    @State private var listError: String?
    @State private var verification: String?
    @State private var isVerifying = false

    private func saveToken() {
        SyncCredentials.setToken(token)
        token = ""
        // The token is what makes the list askable, so ask as soon as there is
        // one rather than making the user find a second button.
        Task { await loadRepositories() }
    }

    /// Repositories this token can reach.
    private func loadRepositories() async {
        guard let client = workspace.gitHubClient() else { return }
        isLoadingRepositories = true
        listError = nil
        defer { isLoadingRepositories = false }
        do {
            repositories = try await client.listRepositories()
            await loadBranches()
        } catch {
            // Say why and leave the text fields in place; a token with no
            // metadata permission can still sync perfectly well.
            listError = error.localizedDescription
        }
    }

    private func loadBranches() async {
        let repository = workspace.settings.data.gitHubRepository
        guard !repository.isEmpty, let client = workspace.gitHubClient() else { return }
        branches = (try? await client.listBranches()) ?? []
    }

    /// Answers "is this configuration going to work" now, rather than at the end
    /// of the first sync.
    private func verify() async {
        guard let client = workspace.gitHubClient() else {
            verification = String(localized: "No token saved.")
            return
        }
        isVerifying = true
        defer { isVerifying = false }
        do {
            let name = try await client.verify()
            let files = try await client.listFiles()
            verification = String(localized: "Verified \(name) · \(files.count) files")
        } catch {
            verification = error.localizedDescription
        }
    }

    /// One action row, so the Mac and the phone lay out the same set of buttons
    /// differently without either of them going out of date when one changes.
    private struct SyncAction: Identifiable {
        let id = UUID()
        let button: AnyView
        var isLast = false
    }

    @MainActor
    private func actions(off: Bool) -> [SyncAction] {
        var list: [SyncAction] = [
            SyncAction(button: AnyView(
                Button("Save token", action: saveToken).disabled(token.isEmpty || off)
            ))
        ]
        if SyncCredentials.hasToken {
            list.append(SyncAction(button: AnyView(
                Button(isLoadingRepositories ? "Loading…" : "Refresh list") {
                    Task { await loadRepositories() }
                }
                .disabled(off || isLoadingRepositories)
            )))
            list.append(SyncAction(button: AnyView(
                Button(isVerifying ? "Checking…" : "Verify") { Task { await verify() } }
                    .disabled(off || isVerifying || workspace.settings.data.gitHubRepository.isEmpty)
            )))
        }
        list[list.count - 1].isLast = true
        list.append(SyncAction(button: AnyView(
            Button(workspace.isSyncing ? "Syncing…" : "Sync now") {
                Task { await workspace.sync() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(off || workspace.isSyncing || workspace.root == nil
                      || workspace.settings.data.gitHubRepository.isEmpty)
        )))
        if SyncCredentials.hasToken {
            list.append(SyncAction(button: AnyView(
                Button("Remove token", role: .destructive) {
                    SyncCredentials.setToken(nil)
                    token = ""
                    repositories = []
                    branches = []
                    verification = nil
                }
                .disabled(off)
            )))
        }
        return list
    }

    /// The chosen repository is always offered, even if listing did not return
    /// it — otherwise opening the picker would silently change the setting.
    private var repositoryOptions: [String] {
        let chosen = workspace.settings.data.gitHubRepository
        var names = repositories.map(\.fullName)
        if !chosen.isEmpty, !names.contains(chosen) { names.insert(chosen, at: 0) }
        return names
    }

    /// Same rule as the repositories: whatever is configured stays selectable,
    /// so opening the picker cannot quietly move the branch.
    private var branchOptions: [String] {
        let chosen = workspace.settings.data.gitHubBranch
        var names = branches
        if !chosen.isEmpty, !names.contains(chosen) { names.insert(chosen, at: 0) }
        return names
    }

    private func label(for name: String) -> String {
        guard let repository = repositories.first(where: { $0.fullName == name }) else { return name }
        return repository.canPush ? name : name + String(localized: " (read-only)")
    }

    @ViewBuilder
    private var syncStatusView: some View {
        switch workspace.syncStatus {
        case .idle:
            EmptyView()
        case .running(let message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(style.palette.unresolvedLink.color)
        case .finished(let report):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    report.changeCount == 0
                        ? "Already up to date."
                        : "\(report.uploaded.count) uploaded, \(report.downloaded.count) downloaded, "
                          + "\(report.deletedLocally.count + report.deletedRemotely.count) deleted.",
                    systemImage: "checkmark.circle"
                )
                .font(.callout)

                // Conflicts are surfaced rather than buried: each one left a
                // second copy in the vault that the user has to resolve.
                if !report.conflicted.isEmpty {
                    Label(
                        "\(report.conflicted.count) conflict(s) — a copy of the GitHub version was saved next to each: "
                            + report.conflicted.prefix(3).joined(separator: ", "),
                        systemImage: "arrow.triangle.branch"
                    )
                    .font(.callout)
                    .foregroundStyle(style.palette.accent.color)
                }
                if !report.failures.isEmpty {
                    Label(
                        "\(report.failures.count) file(s) failed: \(report.failures.first?.message ?? "")",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(style.palette.unresolvedLink.color)
                }
                if report.skipped > 0 {
                    Text("\(report.skipped) file(s) skipped by the file-type filter.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var body: some View {
        Form {
            Section {
                @Bindable var settings = workspace.settings
                Toggle("Sync this vault with iCloud Drive", isOn: $settings.data.iCloudSyncEnabled)
                    .disabled(workspace.vault?.isCloudBacked != true)

                if workspace.vault?.isCloudBacked == true {
                    Label(
                        settings.data.iCloudSyncEnabled
                            ? "Syncing. Notes are kept downloaded on this Mac."
                            : "Paused. iCloud may move notes off this Mac to save space.",
                        systemImage: settings.data.iCloudSyncEnabled ? "checkmark.icloud" : "icloud.slash"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    Text("This vault is stored locally. Create a vault in iCloud Drive, or move this folder there, to sync it across your devices.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("iCloud Drive")
            } footer: {
                // Worth stating plainly, because the switch does less than it
                // looks like it does: iCloud moves the files, not this app.
                Text("iCloud Drive syncs the folder itself. This keeps notes downloaded rather than evicted, so they stay visible and open instantly — turn it off on a Mac short of disk space.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                @Bindable var settings = workspace.settings
                Toggle("Sync this vault with GitHub", isOn: $settings.data.gitHubSyncEnabled)
                    .onChange(of: settings.data.gitHubSyncEnabled) { workspace.restartAutoSync() }

                let off = !settings.data.gitHubSyncEnabled

                SecureField("Personal access token", text: $token, prompt: Text(
                    SyncCredentials.hasToken ? "Saved in Keychain" : "ghp_…"
                ))
                .onSubmit(saveToken)
                .disabled(off)

                // Chosen from a list once there is a token to ask with, typed
                // when there is not. Both are kept: a fine-grained token without
                // metadata permission cannot list anything and still syncs.
                if repositories.isEmpty {
                    TextField("Repository", text: $settings.data.gitHubRepository, prompt: Text("owner/repository"))
                        .disabled(off)
                } else {
                    Picker("Repository", selection: $settings.data.gitHubRepository) {
                        ForEach(repositoryOptions, id: \.self) { name in
                            Text(label(for: name)).tag(name)
                        }
                    }
                    .disabled(off)
                    .onChange(of: settings.data.gitHubRepository) { _, name in
                        // Follow the repository's own default branch rather than
                        // leaving "main" pointing at a repository that uses
                        // "master" — the failure it causes is a 404 at sync time.
                        if let repository = repositories.first(where: { $0.fullName == name }) {
                            settings.data.gitHubBranch = repository.defaultBranch
                        }
                        verification = nil
                        Task { await loadBranches() }
                    }
                }

                if branches.isEmpty {
                    TextField("Branch", text: $settings.data.gitHubBranch, prompt: Text("main"))
                        .disabled(off)
                } else {
                    Picker("Branch", selection: $settings.data.gitHubBranch) {
                        ForEach(branchOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(off)
                    .onChange(of: settings.data.gitHubBranch) { verification = nil }
                }

                if let listError {
                    Text(listError)
                        .font(.footnote)
                        .foregroundStyle(style.palette.unresolvedLink.color)
                }

                Toggle("Sync automatically", isOn: $settings.data.gitHubAutoSync)
                    .disabled(off)
                    .onChange(of: settings.data.gitHubAutoSync) { workspace.restartAutoSync() }

                if settings.data.gitHubAutoSync {
                    Picker("Every", selection: $settings.data.gitHubSyncIntervalMinutes) {
                        Text("Only when opening a vault").tag(0)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("Hour").tag(60)
                    }
                    .disabled(off)
                    .onChange(of: settings.data.gitHubSyncIntervalMinutes) {
                        workspace.restartAutoSync()
                    }
                }

                // Five actions in one row fits a 560pt settings window and does
                // not fit a phone: on iOS they wrapped into two ragged lines with
                // "Save token" split across them. A Form row each is the native
                // answer there, and the Mac keeps its single row.
                #if os(macOS)
                HStack {
                    ForEach(Array(actions(off: off).enumerated()), id: \.offset) { _, action in
                        action.button
                        if action.isLast { Spacer() }
                    }
                }
                #else
                ForEach(Array(actions(off: off).enumerated()), id: \.offset) { _, action in
                    action.button
                }
                #endif

                if let verification {
                    Text(verification)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                syncStatusView
            } header: {
                Text("GitHub")
            } footer: {
                Text("Create a fine-grained token with Contents: read and write for this repository. It is stored in your Keychain, never in the vault or the settings file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Images", isOn: syncBinding(for: .image))
                Toggle("Audio", isOn: syncBinding(for: .audio))
                Toggle("PDFs", isOn: syncBinding(for: .pdf))
                Toggle("Video", isOn: syncBinding(for: .video))
                Toggle("Other files", isOn: syncBinding(for: .other))

                LabeledContent("Skip files larger than") {
                    HStack(spacing: 6) {
                        TextField(
                            "",
                            value: sizeLimitBinding,
                            format: .number
                        )
                        .labelsHidden()
                        .frame(width: 70)
                        Text("MB")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("File types to sync")
            } footer: {
                Text("Notes and canvases always sync. Set the size limit to 0 for no limit.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            // A stored token means the list can be filled without being asked
            // for. Someone opening this pane to change repository should find the
            // choice already there.
            if SyncCredentials.hasToken, repositories.isEmpty { await loadRepositories() }
        }
    }

    private func syncBinding(for kind: AttachmentKind) -> Binding<Bool> {
        Binding(
            get: { workspace.settings.data.syncPolicy.syncs(kind) },
            set: { workspace.settings.data.syncPolicy.setSyncs(kind, $0) }
        )
    }

    private var sizeLimitBinding: Binding<Int> {
        Binding(
            get: { workspace.settings.data.syncPolicy.maximumFileSizeMB },
            set: { workspace.settings.data.syncPolicy.maximumFileSizeMB = max(0, $0) }
        )
    }
}

// MARK: - Reusable controls

private struct FontPicker: View {
    let title: String
    @Binding var selection: FontChoice
    let suggestions: [String]

    var body: some View {
        Picker(title, selection: Binding(
            get: { key(for: selection) },
            set: { selection = choice(for: $0) }
        )) {
            Text("System").tag("system")
            Text("Serif").tag("serif")
            Text("Rounded").tag("rounded")
            Text("Monospaced").tag("monospaced")
            Divider()
            ForEach(availableSuggestions, id: \.self) { family in
                Text(family).tag("named:" + family)
            }
        }
    }

    /// Only offer families actually installed — a picker full of fonts that
    /// silently fall back to the system font is worse than a short list.
    private var availableSuggestions: [String] {
        #if os(macOS)
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        #else
        let installed = Set(UIFont.familyNames)
        #endif
        let matching = suggestions.filter { installed.contains($0) }
        if case .named(let current) = selection, !matching.contains(current) {
            return matching + [current]
        }
        return matching
    }

    private func key(for choice: FontChoice) -> String {
        switch choice {
        case .system: return "system"
        case .serif: return "serif"
        case .rounded: return "rounded"
        case .monospaced: return "monospaced"
        case .named(let family): return "named:" + family
        }
    }

    private func choice(for key: String) -> FontChoice {
        switch key {
        case "system": return .system
        case "serif": return .serif
        case "rounded": return .rounded
        case "monospaced": return .monospaced
        default: return .named(String(key.dropFirst("named:".count)))
        }
    }
}

private struct LabeledStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(String(format: format, value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}
