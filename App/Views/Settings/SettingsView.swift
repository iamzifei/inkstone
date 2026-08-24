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
        TabView(selection: $tab) {
            ForEach(Pane.allCases) { pane in
                pane.view
                    .tabItem { Label(pane.title, systemImage: pane.symbol) }
                    .tag(pane)
            }
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

    #if os(macOS)
    /// Which tab is showing. A selection rather than TabView's own default, so a
    /// pane can be opened from code — the Sync pane is five tabs in and behind a
    /// click, which is exactly the kind of thing that never gets screenshotted or
    /// checked because reaching it by hand is tedious.
    ///
    ///     INKSTONE_OPEN_SETTINGS=sync .../Inkstone
    @State private var tab: Pane = {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["INKSTONE_OPEN_SETTINGS"],
           let pane = Pane(rawValue: name) { return pane }
        #endif
        return .appearance
    }()
    #else
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
    #endif

    /// Both platforms use these: the Mac tags its tabs with them, iOS pushes
    /// them onto a navigation path.
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

/// Where the sync guide lives, in the language the app is being read in.
///
/// One place rather than a literal per call site: the link appears in both
/// sections of this pane, and a help link that 404s is worse than no help link —
/// it is a promise the app breaks in front of someone already confused.
/// `site/tests/test_site.py` resolves every URL this can return against the
/// pages the site actually publishes.
///
/// Three languages, not the site's eight, and deliberately: these are the ones
/// the app itself ships (`CFBundleLocalizations`). Sending a reader who chose
/// 繁體中文 to an English page is a worse answer than the site's language
/// switcher, and offering French here would promise a translation the app does
/// not have.
enum SyncHelp {
    private static let site = "https://inkslab.app"

    /// The path segment per language, matching `LANGS[…]["dir"]` in
    /// `site/build.py`. English is the default and has no prefix.
    static let directories: [String: String] = ["zh-Hans": "zh/", "zh-Hant": "zh-Hant/"]

    static func url(for locale: Locale) -> URL {
        URL(string: site + "/" + directory(for: locale) + "sync.html")!
    }

    /// Matched on script rather than on region: a reader in Singapore is
    /// `zh-Hans-SG` and one in Hong Kong is `zh-Hant-HK`, and the script is what
    /// decides which page they can read. `Locale` resolves the script for us
    /// when the identifier omits it — `zh-TW` reports `Hant`.
    static func directory(for locale: Locale) -> String {
        guard locale.language.languageCode?.identifier == "zh" else { return "" }
        let script = locale.language.script?.identifier
            ?? Locale.Language(identifier: locale.identifier).script?.identifier
        return script == "Hant" ? directories["zh-Hant"]! : directories["zh-Hans"]!
    }
}

private struct SyncSettings: View {
    @Environment(Workspace.self) private var workspace
    /// The app's chosen language, injected by `InkstoneApp`. Not
    /// `Locale.current`, which is the system's — someone who set the app to
    /// 繁體中文 on an English Mac should get the Chinese guide.
    @Environment(\.locale) private var locale
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
        let repository = workspace.syncBinding.repository
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
                    .disabled(off || isVerifying || !workspace.syncBinding.isConfigured)
            )))
        }
        list[list.count - 1].isLast = true
        list.append(SyncAction(button: AnyView(
            Button(workspace.isSyncing ? "Syncing…" : "Sync now") {
                startSync()
            }
            .buttonStyle(.borderedProminent)
            .disabled(off || workspace.isSyncing || workspace.root == nil
                      || !workspace.syncBinding.isConfigured)
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
        let chosen = workspace.syncBinding.repository
        var names = repositories.map(\.fullName)
        if !chosen.isEmpty, !names.contains(chosen) { names.insert(chosen, at: 0) }
        return names
    }

    /// SwiftUI bindings onto the open vault's own sync binding.
    ///
    /// The pane used to edit `settings.data.gitHubRepository` directly — one
    /// global field every vault shared. Editing it here while a different vault
    /// was open is how an unrelated folder ended up bound to someone's
    /// repository.
    private var repositoryBinding: Binding<String> {
        Binding(get: { workspace.syncBinding.repository },
                set: { workspace.syncBinding.repository = $0 })
    }

    private var branchBinding: Binding<String> {
        Binding(get: { workspace.syncBinding.branch },
                set: { workspace.syncBinding.branch = $0 })
    }

    private var syncEnabledBinding: Binding<Bool> {
        Binding(get: { workspace.syncBinding.isEnabled },
                set: { workspace.syncBinding.isEnabled = $0 })
    }

    private var gitOverrideBinding: Binding<Bool> {
        Binding(get: { workspace.overridesGitWorkingCopyGuard },
                set: { workspace.overridesGitWorkingCopyGuard = $0 })
    }

    private func runFirstSync(_ direction: FirstSyncDirection) {
        startSync(firstSyncDirection: direction)
    }

    /// Starts a sync the way the platform allows it to finish.
    ///
    /// On iOS this hands the work to a continued-processing task, so it keeps
    /// going when the user leaves the app and the system shows its progress
    /// while it does. That matters most for exactly the run being started here:
    /// a first sync moves the whole vault and will not fit in the window an
    /// ordinary background refresh gets.
    ///
    /// Falls back to a plain in-app sync when the scheduler will not take it,
    /// which still works — it just stops when the app is suspended. On macOS
    /// there is nothing to survive: the process keeps running.
    private func startSync(
        firstSyncDirection: FirstSyncDirection? = nil,
        confirmingLargeDeletion: Bool = false
    ) {
        #if os(iOS)
        // Not through the continued task when confirming a deletion: that path
        // hands the work to the system and comes back through a fresh handler,
        // which would not carry the answer that was just given.
        if !confirmingLargeDeletion,
           BackgroundSync.syncVisibly(workspace: workspace, firstSyncDirection: firstSyncDirection) {
            return
        }
        #endif
        Task {
            await workspace.sync(
                firstSyncDirection: firstSyncDirection,
                confirmingLargeDeletion: confirmingLargeDeletion
            )
        }
    }

    /// The fields that travel between devices, as one comparable value.
    private var sharedFingerprint: String {
        let data = workspace.settings.data
        return [
            workspace.syncBinding.repository,
            workspace.syncBinding.branch,
            String(workspace.syncBinding.isEnabled),
            String(data.gitHubAutoSync),
            String(data.gitHubSyncIntervalMinutes),
        ].joined(separator: "\u{1}")
    }

    /// Same rule as the repositories: whatever is configured stays selectable,
    /// so opening the picker cannot quietly move the branch.
    private var branchOptions: [String] {
        let chosen = workspace.syncBinding.branch
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
            // A determinate bar once the plan exists. A spinner and a filename
            // cannot answer "is this nearly done or barely started", which is
            // the only question anyone actually has while waiting on a first
            // sync of a whole vault.
            VStack(alignment: .leading, spacing: 6) {
                if let fraction = workspace.syncProgress?.fraction,
                   let progress = workspace.syncProgress {
                    ProgressView(value: fraction)
                    HStack(spacing: 8) {
                        Text(message).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(progress.completed) / \(progress.total)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        case .interrupted:
            // Reads as a failure otherwise, and it is not one: a first sync of a
            // large vault takes more than one turn, and the system decides how
            // long each turn is. Saying that it continues by itself is the part
            // that stops someone tapping Sync over and over.
            Label(
                "Sync ran out of time and will carry on by itself. Everything transferred so far is kept — the next run picks up where this one stopped, and a first sync of a large vault usually takes several.",
                systemImage: "hourglass"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
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
            // Its own row, before anything that could confuse someone.
            //
            // This was a link inside a section footer, and it was invisible for
            // a reason worth keeping: the footer carried
            // `.foregroundStyle(.secondary)`, which overrides a Link's tint, so
            // it rendered as one more line of small grey prose. A link that does
            // not look like a link is not a link — and a footer is the part of a
            // settings pane people skip.
            Section {
                Link(destination: SyncHelp.url(for: locale)) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("How syncing works")
                            Text("Setting up iCloud or GitHub, and when a conflict happens")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "questionmark.circle")
                    }
                }
            }

            Section {
                @Bindable var settings = workspace.settings
                // Named for what it does. It used to say "Sync this vault with
                // iCloud Drive", which reads as a sync switch and is not one:
                // the only thing behind it is `ICloudFiles.requestDownloads`.
                // A folder in iCloud Drive is synced by the system, and no app
                // can turn that off — the way to stop it is to keep the folder
                // somewhere else.
                Toggle("Keep files downloaded", isOn: $settings.data.iCloudSyncEnabled)
                    .disabled(workspace.vault?.isCloudBacked != true)

                if workspace.vault?.isCloudBacked == true {
                    Label(
                        settings.data.iCloudSyncEnabled
                            ? "Notes are kept on this device rather than evicted."
                            : "iCloud may move notes off this device to save space.",
                        systemImage: settings.data.iCloudSyncEnabled ? "checkmark.icloud" : "icloud.slash"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    Text("This vault is stored locally, so iCloud does not carry it. Create a vault in iCloud Drive, or move this folder there, to sync it across your devices.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("iCloud Drive")
            } footer: {
                // Worth stating plainly, because the switch does less than it
                // looks like it does: iCloud moves the files, not this app.
                Text("Whether iCloud carries this vault depends on where the folder is, not on a switch here — a folder in iCloud Drive is synced by the system. This setting only decides whether its notes stay on this device or may be evicted to placeholders to save space.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                @Bindable var settings = workspace.settings
                // One repository, one vault, per device. Offered as a move
                // rather than a wall: a binding outlives the folder it was made
                // for, and a refusal with no way through would leave someone
                // unable to bind that repository anywhere, ever, without being
                // told why.
                if let other = workspace.vaultSharingThisRepository {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "\(workspace.syncBinding.repository) is already used by “\(other.name)”",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.callout.weight(.medium))
                        .foregroundStyle(style.palette.unresolvedLink.color)
                        Text("Two folders pointing at one repository overwrite each other: every sync makes the repository look like whichever one ran last. Neither will sync until one of them gives it up.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Use it for this vault instead") {
                            workspace.claimRepositoryFromOtherVault()
                        }
                        .font(.footnote)
                    }
                }

                // Said before the toggle, because it explains why the toggle
                // is off and cannot be turned on. Git is not a lesser sync to
                // be worked around — it is the better one for this folder, and
                // Inkstone's would overwrite the merges it produces.
                if workspace.vaultIsGitWorkingCopy {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "This vault is a git working copy.",
                            systemImage: "arrow.triangle.branch"
                        )
                        .font(.callout.weight(.medium))
                        Text("Git already syncs this folder, and it merges — Inkstone's sync overwrites file by file and answers a conflict with a second copy of the file. Running both leaves the two undoing each other. Use git here, and let other devices sync the same repository through Inkstone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Toggle("Sync it anyway", isOn: gitOverrideBinding)
                            .font(.footnote)
                            .onChange(of: workspace.overridesGitWorkingCopyGuard) {
                                workspace.restartAutoSync()
                            }
                    }
                }

                // Offered, never applied. Adopting this is what binds *this*
                // vault to that repository, and it is the user's call because
                // only they know whether this folder is a copy of that vault.
                if let shared = workspace.pendingSharedConfiguration {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "Another device syncs \(shared.repository)",
                            systemImage: "iphone.and.arrow.forward"
                        )
                        .font(.callout.weight(.medium))
                        Text("Use it for this vault only if this folder holds the same notes. Pointing two different folders at one repository makes them overwrite each other.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Use this repository") { workspace.adoptSharedConfiguration() }
                            Button("Ignore") { workspace.pendingSharedConfiguration = nil }
                        }
                        .font(.footnote)
                    }
                }

                Toggle("Sync this vault with GitHub", isOn: syncEnabledBinding)
                    .disabled(workspace.root == nil || workspace.isBlockedByGitWorkingCopy)
                    .onChange(of: workspace.syncBinding.isEnabled) { workspace.restartAutoSync() }

                let off = !workspace.syncBinding.isEnabled
                    || workspace.isBlockedByGitWorkingCopy
                    || workspace.vaultSharingThisRepository != nil

                SecureField("Personal access token", text: $token, prompt: Text(
                    SyncCredentials.hasToken ? "Saved in Keychain" : "ghp_…"
                ))
                .onSubmit(saveToken)
                .disabled(off)

                // Chosen from a list once there is a token to ask with, typed
                // when there is not. Both are kept: a fine-grained token without
                // metadata permission cannot list anything and still syncs.
                if repositories.isEmpty {
                    TextField("Repository", text: repositoryBinding, prompt: Text("owner/repository"))
                        .disabled(off)
                } else {
                    Picker("Repository", selection: repositoryBinding) {
                        ForEach(repositoryOptions, id: \.self) { name in
                            Text(label(for: name)).tag(name)
                        }
                    }
                    .disabled(off)
                    .onChange(of: workspace.syncBinding.repository) { _, name in
                        // Follow the repository's own default branch rather than
                        // leaving "main" pointing at a repository that uses
                        // "master" — the failure it causes is a 404 at sync time.
                        if let repository = repositories.first(where: { $0.fullName == name }) {
                            workspace.syncBinding.branch = repository.defaultBranch
                        }
                        verification = nil
                        Task { await loadBranches() }
                    }
                }

                if branches.isEmpty {
                    TextField("Branch", text: branchBinding, prompt: Text("main"))
                        .disabled(off)
                } else {
                    Picker("Branch", selection: branchBinding) {
                        ForEach(branchOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(off)
                    .onChange(of: workspace.syncBinding.branch) { verification = nil }
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

                // Only a first sync can ask this, and only once. Three buttons
                // rather than a sentence, because the answer is a choice and the
                // alternative — a conflict copy per differing file — produced 369
                // of them in a real vault before this existed.
                if workspace.pendingFirstSync != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Which copy should win?")
                            .font(.callout.weight(.medium))
                        HStack {
                            Button("Keep this Mac's") { runFirstSync(.preferLocal) }
                            Button("Keep GitHub's") { runFirstSync(.preferRemote) }
                            Button("Keep both") { runFirstSync(.keepBoth) }
                        }
                    }
                }

                // Its own block, and its own wording. This is the one button
                // in the pane whose answer cannot be undone, so it says what
                // will go rather than "Continue".
                if let pending = workspace.pendingLargeDeletion {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            pending.localizedDescription,
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.callout)
                        .foregroundStyle(style.palette.unresolvedLink.color)
                        HStack {
                            Button("Delete them and sync", role: .destructive) {
                                startSync(confirmingLargeDeletion: true)
                            }
                            Button("Cancel") { workspace.pendingLargeDeletion = nil }
                        }
                    }
                }

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

            #if os(iOS)
            // Only iOS suspends the app, so only iOS needs to explain what the
            // system did with the sync requests.
            BackgroundSyncSection()
            #endif

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

            Section {
                // Free text rather than a folder picker: the patterns are
                // per-device but the vault is shared, and a picker would only
                // offer folders that exist on whichever device is being set up.
                TextEditor(text: excludedPathsBinding)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 76)
            } header: {
                Text("Folders to skip on this device")
            } footer: {
                Text(
                    """
                    One pattern per line, in .gitignore syntax — `Rules/` for a \
                    folder, `*.tmp.md` for a glob, `!keep.md` to bring one back. \
                    Skipped files are neither uploaded from here nor downloaded \
                    to here, and are never deleted from the other devices.
                    """
                )
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
        // One observer for the whole setup rather than five: every field here
        // publishes the same shared value, and the timestamp that decides which
        // device wins should move when any of them does.
        .onChange(of: sharedFingerprint) { workspace.publishSyncConfiguration() }
    }

    private func syncBinding(for kind: AttachmentKind) -> Binding<Bool> {
        Binding(
            get: { workspace.settings.data.syncPolicy.syncs(kind) },
            set: { workspace.settings.data.syncPolicy.setSyncs(kind, $0) }
        )
    }

    /// One pattern per line, which is how the list is edited and not how it is
    /// stored. Blank lines are dropped on the way in so that trailing newlines
    /// and stray blank rows never reach the matcher, where an empty pattern
    /// would be a rule that matches nothing and costs a regex to find out.
    private var excludedPathsBinding: Binding<String> {
        Binding(
            get: { workspace.settings.data.syncPolicy.excludedPaths.joined(separator: "\n") },
            set: {
                workspace.settings.data.syncPolicy.excludedPaths = $0
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
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
