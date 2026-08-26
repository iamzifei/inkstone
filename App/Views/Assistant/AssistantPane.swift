import SwiftUI
import InkstoneCore

/// The assistant, living in the inspector beside the outline and backlinks.
///
/// Replies are drawn by `ReadingView` — the same typesetter as reading mode — so
/// a table the model writes looks like a table in a note, and code, formulas and
/// diagrams come for free. That reuse is the reason this panel is small: the
/// hard half of a chat interface is usually its Markdown renderer, and this app
/// already had one worth using.
struct AssistantPane: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    /// Reached through the workspace, which is what the app injects.
    ///
    /// `@Environment(AppSettings.self)` compiles and then traps at launch:
    /// nothing ever puts an `AppSettings` into the environment, and reading a
    /// missing environment object is a runtime assertion, not a type error. The
    /// app builds and every test passes right up until the window opens.
    private var settings: AppSettings { workspace.settings }

    @State private var conversation = Conversation()
    @State private var catalogue = ModelCatalogue()
    @State private var store = ConversationStore()
    /// Which message is being edited, if any.
    @State private var editing: UUID?
    @State private var editDraft = ""
    @State private var showingHistory = false
    @Environment(SkillLibrary.self) private var library
    /// The skill chosen for the next message, if any.
    @State private var pendingSkill: SkillManifest?
    @State private var reviewing = false
    @State private var reviewQueue = EditQueue()
    /// The edit store lives as long as the panel, so changes proposed in one
    /// turn survive into the next.
    @State private var editStore = PendingEditStore()
    @State private var saveFailure: String?
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var profile: AssistantProfile? { settings.data.assistant.activeProfile }

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            composer
        }
        .background(style.background)
        .onChange(of: workspace.activeTab?.url) { attachCurrentNote() }
        .onChange(of: settings.data.assistant.includesCurrentNote) { attachCurrentNote() }
        .onAppear {
            attachCurrentNote()
            if let profile { catalogue.load(profile) }
            // Wire the transcript to the store, then load whatever was open.
            conversation.onChange = { store.update(messages: $0) }
            if let stored = store.active { conversation.load(stored.messages) }
            refreshToolbox()
        }
        // The snapshot is a value, so a toolbox built once would keep answering
        // from the vault as it was when the panel opened — including for notes
        // the assistant itself had just been told about.
        .sheet(isPresented: $reviewing) {
            ReviewChangesView(
                queue: $reviewQueue,
                onApply: { applyEdits($0) },
                onDiscard: { Task { await conversation.discardPendingEdits() } })
        }
        .onChange(of: reviewing) { _, showing in
            // Carry the reviewer's decisions back even when the sheet is
            // dismissed without saving, so a later question sees the same state.
            if !showing { Task { await conversation.syncPendingEdits(reviewQueue) } }
        }
        .onChange(of: workspace.index.notes.count) { refreshToolbox() }
        .onChange(of: workspace.root) { refreshToolbox() }
        .onChange(of: profile?.id) { if let profile { catalogue.load(profile) } }
    }

    // MARK: - Header

    /// A thin strip: history on the left, new conversation on the right.
    ///
    /// Always present now that there is history to reach, but kept to one line
    /// of controls with no title — the panel's title is the tab that opened it.
    private var header: some View {
        HStack(spacing: 8) {
            historyMenu

            Spacer(minLength: 0)

            if let usage = conversation.lastUsage, usage.total > 0 {
                Text("\(usage.total) tokens")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(style.faintText)
            }

            Button {
                store.startNew()
                conversation.load([])
                editing = nil
                inputFocused = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(style.secondaryText)
            }
            .buttonStyle(.plain)
            .disabled(conversation.isEmpty)
            .help(String(localized: "New conversation"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var historyMenu: some View {
        Menu {
            if store.conversations.filter({ !$0.isEmpty }).isEmpty {
                Text("No past conversations")
            } else {
                ForEach(store.conversations.filter { !$0.isEmpty }) { stored in
                    Button {
                        store.activeID = stored.id
                        conversation.load(stored.messages)
                        editing = nil
                    } label: {
                        // A tick rather than a highlight: a menu of one-line
                        // titles gives no other way to see which is open.
                        if stored.id == store.activeID {
                            Label(stored.title, systemImage: "checkmark")
                        } else {
                            Text(stored.title)
                        }
                    }
                }
                Divider()
                Button(String(localized: "Delete this conversation"), role: .destructive) {
                    if let id = store.activeID {
                        store.delete(id)
                        conversation.load(store.active?.messages ?? [])
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock.arrow.circlepath")
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundStyle(style.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Past conversations"))
    }

    private var profileBinding: Binding<UUID?> {
        Binding(
            get: { settings.data.assistant.activeProfileID ?? profile?.id },
            set: { settings.data.assistant.activeProfileID = $0 })
    }

    private var thinkingBinding: Binding<ThinkingEffort> {
        Binding(
            get: { profile?.thinking ?? .off },
            set: { effort in
                guard let id = profile?.id,
                      let index = settings.data.assistant.profiles
                        .firstIndex(where: { $0.id == id }) else { return }
                settings.data.assistant.profiles[index].thinking = effort
            })
    }

    /// A word, for the composer, where the full phrase would not fit.
    static func thinkingShortLabel(_ effort: ThinkingEffort) -> String {
        switch effort {
        case .off: return ""
        case .low: return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high: return String(localized: "High")
        }
    }

    static func thinkingLabel(_ effort: ThinkingEffort) -> String {
        switch effort {
        case .off: return String(localized: "No extra thinking")
        case .low: return String(localized: "Think briefly")
        case .medium: return String(localized: "Think")
        case .high: return String(localized: "Think hard")
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.isEmpty { emptyState }
                    ForEach(conversation.visibleMessages) { message in
                        MessageRow(
                            message: message,
                            isEditing: editing == message.id,
                            editDraft: $editDraft,
                            canRegenerate: conversation.canRegenerate
                                && message.id == conversation.messages.last?.id,
                            onEdit: { beginEditing(message) },
                            onCommitEdit: { commitEdit(message) },
                            onCancelEdit: { editing = nil },
                            onRegenerate: {
                                if let profile { conversation.regenerate(using: profile) }
                            }
                        )
                        .id(message.id)
                    }
                    if let failure = conversation.failure,
                       conversation.visibleMessages.last?.failure == nil {
                        FailureRow(text: Conversation.describe(failure),
                                   canRetry: failure.isRetryable) {
                            if let profile { conversation.retry(using: profile) }
                        }
                    }
                    // An anchor to scroll to, rather than the last message:
                    // scrolling to a message that is still growing lands part
                    // way up it, and the text then streams off the bottom.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                // Matching the composer card's outer inset, so the column of
                // text has one left edge rather than two.
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: conversation.streaming?.blocks.count) { follow(proxy) }
            .onChange(of: conversation.messages.count) { follow(proxy) }
        }
    }

    private static let bottomAnchor = "assistant-bottom"

    private func follow(_ proxy: ScrollViewProxy) {
        // Unanimated during streaming: an animated scroll restarts on every
        // delta and the text visibly judders.
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
    }

    /// What the panel says before it has been asked anything.
    ///
    /// Centred and quiet. The previous version was a line of prose in the top
    /// left, which in an otherwise empty column reads like a rendering error
    /// rather than an invitation.
    private var emptyState: some View {
        VStack(spacing: 10) {
            if let profile, profile.kind == .appleOnDevice,
               let unavailable = AppleOnDeviceProvider.availabilityMessage {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(style.faintText)
                Text(unavailable)
                    .font(.callout)
                    .foregroundStyle(style.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if needsKey {
                Image(systemName: "key")
                    .font(.title2)
                    .foregroundStyle(style.faintText)
                Text("Add an API key in Settings › Assistant to start.")
                    .font(.callout)
                    .foregroundStyle(style.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                #if os(macOS)
                // `SettingsLink` and `.link` are both macOS-only; on iOS the
                // Settings sheet is reached from the sidebar, so pointing at it
                // in words is the honest option rather than a button that
                // cannot open anything.
                SettingsLink {
                    Text("Open Settings")
                }
                .buttonStyle(.borderless)
                .font(.callout)
                #endif
            } else if profile?.kind == .appleOnDevice {
                // Said before the first question, not after it fails. This
                // model cannot search the vault at all — its window is smaller
                // than one note — and that is the opposite of what the panel
                // otherwise promises.
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.title2)
                    .foregroundStyle(style.faintText)
                Text("Runs on this Mac, free and offline. It cannot search your vault — ask it to rewrite, summarise or name the note in front of you.")
                    .font(.callout)
                    .foregroundStyle(style.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.title2)
                    .foregroundStyle(style.faintText)
                Text("Ask about this note, or anything in the vault.")
                    .font(.callout)
                    .foregroundStyle(style.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.top, 40)
    }

    /// Whether the chosen profile still wants a credential.
    ///
    /// Asked of the Keychain rather than of the settings, because that is where
    /// the answer is; a profile looks fully configured either way.
    private var needsKey: Bool {
        guard let profile, profile.kind.needsAPIKey else { return false }
        return AssistantCredentials.key(for: profile.credentialAccount) == nil
    }

    // MARK: - Composer

    /// The composer: one rounded card holding the field, the model, and send.
    ///
    /// Shaped after what ChatGPT and Claude both settled on, for the same
    /// reasons. The field was a bare `TextField` pinned to the bottom edge,
    /// which read as a search box rather than a place to write, and sat close
    /// enough to the window's rounded corner that the corner clipped it. A card
    /// with its own inset keeps clear of the corner radius, and gives the model
    /// picker somewhere to live that is next to the message it governs.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !conversation.pendingEdits.isEmpty { changesBar }
            if !slashMatches.isEmpty { slashMenu }
            if let skill = pendingSkill { skillChip(skill) }
            if settings.data.assistant.includesCurrentNote,
               let note = conversation.attachedNote {
                Label(note.title, systemImage: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(style.faintText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            TextField(String(localized: "Ask about your notes…"),
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(style.uiFont)
                .foregroundStyle(style.text)
                .lineLimit(1...10)
                .focused($inputFocused)
                .disabled(conversation.isRunning)
                // ⌘↩ sends; Return alone makes a new line. A single-line Return
                // would make a multi-paragraph question impossible to type,
                // which is the kind of question this panel is for.
                .onSubmit(send)

            HStack(spacing: 4) {
                modelPicker
                Spacer(minLength: 4)
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(style.secondaryBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(inputFocused ? style.accent.opacity(0.5) : style.divider,
                                      lineWidth: 1)
                }
        }
        // Clear of the window's rounded corner on every side. Pinned flush, the
        // corner radius cut the card's own corner and the send button with it.
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 4)
        .animation(.easeOut(duration: 0.12), value: inputFocused)
    }

    /// Channel, model, and thinking effort, in one menu.
    ///
    /// Three levels because they are three decisions and only the first is
    /// rare: the channel is a key and an endpoint, set once; the model changes
    /// with the task; the effort changes with the question. Binding a model to a
    /// channel — which is what the first version did — meant changing model was
    /// a trip to Settings.
    ///
    /// The model list is fetched from the endpoint rather than hard-coded. A
    /// baked-in list is wrong the day a model ships, and a custom endpoint
    /// serves models this app has never heard of.
    private var modelPicker: some View {
        Menu {
            if settings.data.assistant.profiles.count > 1 {
                Picker(String(localized: "Channel"), selection: profileBinding) {
                    ForEach(settings.data.assistant.profiles) { candidate in
                        Text(candidate.name).tag(candidate.id as UUID?)
                    }
                }
                .pickerStyle(.inline)
                Divider()
            }

            modelSection
            Divider()
            thinkingSection
        } label: {
            HStack(spacing: 3) {
                Text(modelLabel)
                    .foregroundStyle(style.secondaryText)
                if let profile, profile.thinking != .off, thinkingIsAvailable {
                    Text(Self.thinkingShortLabel(profile.thinking))
                        .foregroundStyle(style.faintText)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(style.faintText)
            }
            .font(.caption)
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(settings.data.assistant.profiles.isEmpty)
    }

    @ViewBuilder
    private var modelSection: some View {
        if let profile {
            switch catalogue.state(for: profile) {
            case .loading:
                Text("Loading models…")
            case .failed(let message):
                // Shown in the menu rather than swallowed: a channel that
                // cannot list its models usually has a bad key, and this is
                // where someone will look first.
                Text(message)
                Button(String(localized: "Try again")) { catalogue.load(profile, force: true) }
            case .idle, .loaded:
                let models = catalogue.models(for: profile)
                if models.isEmpty {
                    Text("No models")
                } else {
                    Picker(String(localized: "Model"), selection: modelBinding) {
                        ForEach(models) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
        }
    }

    /// The effort control, which is not offered where it would fail.
    ///
    /// Sending a reasoning parameter to a model that does not take one is a
    /// **400, not an ignored field** — `gpt-4.1-mini` answers `Unrecognized
    /// request argument supplied: reasoning_effort`. So offering the control
    /// everywhere meant the message simply would not send. The provider retries
    /// without it when the guess is wrong; this stops the guess being offered.
    @ViewBuilder
    private var thinkingSection: some View {
        if thinkingIsAvailable {
            Picker(String(localized: "Thinking"), selection: thinkingBinding) {
                ForEach(ThinkingEffort.allCases, id: \.self) { effort in
                    Text(Self.thinkingLabel(effort)).tag(effort)
                }
            }
            .pickerStyle(.inline)
        } else {
            Text("This model does not support extended thinking")
        }
    }

    private var thinkingIsAvailable: Bool {
        guard let profile, !profile.model.isEmpty else { return false }
        if conversation.modelsRefusingThinking.contains(profile.model) { return false }
        return ModelCapabilities.supportsThinking(model: profile.model, kind: profile.kind)
    }

    /// What the composer shows: the model, since that is what a person is
    /// choosing. The channel appears only when there is more than one, because
    /// with a single channel its name is noise.
    private var modelLabel: String {
        guard let profile else { return String(localized: "No model") }
        let model = profile.model.isEmpty
            ? String(localized: "Choose a model")
            : ModelCapabilities.displayName(for: profile.model)
        return settings.data.assistant.profiles.count > 1
            ? "\(profile.name) · \(model)"
            : model
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { profile?.model ?? "" },
            set: { model in
                guard let id = profile?.id,
                      let index = settings.data.assistant.profiles
                        .firstIndex(where: { $0.id == id }) else { return }
                settings.data.assistant.profiles[index].model = model
                // A model that refuses to reason cannot carry an effort setting.
                if !ModelCapabilities.supportsThinking(
                    model: model, kind: settings.data.assistant.profiles[index].kind) {
                    settings.data.assistant.profiles[index].thinking = .off
                }
            })
    }

    @ViewBuilder
    private var sendButton: some View {
        if conversation.isRunning {
            Button(action: conversation.stop) {
                Image(systemName: "stop.fill")
                    .font(.caption)
                    .foregroundStyle(style.background)
                    .frame(width: 22, height: 22)
                    .background(style.text, in: .circle)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Stop"))
        } else {
            let ready = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && profile != nil
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ready ? style.background : style.faintText)
                    .frame(width: 22, height: 22)
                    .background(ready ? style.accent : style.divider.opacity(0.5), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .keyboardShortcut(.return, modifiers: .command)
            .help(String(localized: "Send (⌘↩)"))
        }
    }

    // MARK: - Skills

    /// The `/` query, if the draft is one.
    ///
    /// Only when `/` opens the message. A slash mid-sentence is a date or a
    /// path, and popping a menu over either would make the field unusable for
    /// writing about files — which is most of what this panel is for.
    private var slashQuery: String? {
        guard pendingSkill == nil, draft.hasPrefix("/") else { return nil }
        let rest = String(draft.dropFirst())
        guard !rest.contains(" "), !rest.contains("\n") else { return nil }
        return rest
    }

    private var slashMatches: [SkillManifest] {
        guard let query = slashQuery, library.isConfigured else { return [] }
        return Array(library.matching(query).prefix(6))
    }

    private var slashMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(slashMatches) { skill in
                Button {
                    pendingSkill = skill
                    draft = ""
                    inputFocused = true
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(skill.name)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(style.text)
                            if skill.hasScripts {
                                // Said here rather than discovered when the
                                // model asks to run something and nothing
                                // happens. A sandboxed app cannot exec outside
                                // its bundle; the prose still works.
                                Text("prompt only")
                                    .font(.caption2)
                                    .foregroundStyle(style.faintText)
                            }
                        }
                        if !skill.description.isEmpty {
                            Text(skill.description)
                                .font(.caption2)
                                .foregroundStyle(style.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
        .background(style.background, in: .rect(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style.divider, lineWidth: 1)
        }
    }

    /// The one thing standing between a proposal and the vault.
    ///
    /// Deliberately prominent, and deliberately not automatic: nothing is
    /// written until this is opened and something is accepted.
    private var changesBar: some View {
        Button {
            reviewQueue = conversation.pendingEdits
            reviewing = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.ellipsis")
                Text(changesSummary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("Review")
                    .foregroundStyle(style.accent)
            }
            .font(.caption)
            .foregroundStyle(style.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(style.accent.opacity(0.08), in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var changesSummary: String {
        let paths = conversation.pendingEdits.affectedPaths
        if paths.count == 1 {
            return String(localized: "1 unsaved change to \(paths[0])")
        }
        return String(localized: "\(paths.count) files with unsaved changes")
    }

    private func skillChip(_ skill: SkillManifest) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "wand.and.stars").font(.caption2)
            Text(skill.name).font(.caption2)
            Button {
                pendingSkill = nil
            } label: {
                Image(systemName: "xmark.circle.fill").font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(style.secondaryText)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(style.background, in: .capsule)
        .overlay { Capsule().strokeBorder(style.divider, lineWidth: 1) }
    }

    /// Hands the assistant the vault it can currently see.
    private func refreshToolbox() {
        guard let root = workspace.root, let store = workspace.store else {
            // No vault means no tools, rather than tools that fail on every
            // call: a model given a broken tool keeps trying it.
            conversation.toolbox = nil
            return
        }
        conversation.editStore = editStore
        conversation.toolbox = NoteToolbox(
            snapshot: workspace.index, store: store, vaultRoot: root, edits: editStore)
    }

    /// Writes the accepted hunks, and nothing else.
    ///
    /// Through `NoteStore`, the same path the editor saves by, so a note written
    /// here is indexed, versioned and synced like any other. Writing the file
    /// directly would leave the index describing a note that no longer says
    /// what it says.
    private func applyEdits(_ edits: [PendingEdit]) {
        guard let root = workspace.root else { return }
        var failures: [String] = []

        for edit in edits {
            let text = edit.resolved
            let url = root.appending(path: edit.path)
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                failures.append("\(edit.path): \(error.localizedDescription)")
            }
        }

        Task {
            await conversation.discardPendingEdits()
            workspace.reindex()
        }
        if !failures.isEmpty {
            saveFailure = failures.joined(separator: "\n")
        }
    }

    private func beginEditing(_ message: ChatMessage) {
        guard message.role == .user, !conversation.isRunning else { return }
        editDraft = message.text
        editing = message.id
    }

    private func commitEdit(_ message: ChatMessage) {
        guard let profile else { return }
        conversation.edit(message.id, to: editDraft, using: profile)
        editing = nil
    }

    private func send() {
        guard let profile else { return }
        let text = draft
        draft = ""
        // The skill's instructions ride with this one message rather than
        // becoming a standing system prompt: a skill is a way of answering one
        // question, and leaving it in place would silently colour every answer
        // after it.
        conversation.skillInstructions = pendingSkill.flatMap { library.instructions(for: $0) }
        conversation.send(text, using: profile)
        pendingSkill = nil
    }

    /// Attaches the open note, so "summarise this" has something to mean.
    private func attachCurrentNote() {
        guard settings.data.assistant.includesCurrentNote,
              let url = workspace.activeTab?.url else {
            conversation.attachedNote = nil
            return
        }
        // Read from the open document rather than from disk: the question is
        // usually about what is on screen, including edits not yet saved.
        let text = workspace.document(for: url)?.text
            ?? (try? String(contentsOf: url, encoding: .utf8))
        guard let text else {
            conversation.attachedNote = nil
            return
        }
        conversation.attachedNote = (title: url.deletingPathExtension().lastPathComponent,
                                     text: text)
    }
}

/// One turn in the transcript, with the actions that apply to it.
///
/// The actions appear on hover rather than always, which is what every client
/// compared here does: a row of buttons under each message doubles the height of
/// a transcript and competes with the text for attention.
private struct MessageRow: View {
    let message: ChatMessage
    let isEditing: Bool
    @Binding var editDraft: String
    let canRegenerate: Bool
    let onEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onRegenerate: () -> Void

    @Environment(\.style) private var style
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch message.role {
            case .user:
                if isEditing { editor } else { bubble }
            case .assistant:
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                    BlockView(block: block)
                }
                if let failure = message.failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if !isEditing { actions }
        }
        // The whole row is hit-testable, which is what makes the buttons
        // reachable. `.opacity(0)` does not receive hit tests, and a VStack with
        // no background only responds where its children draw — so moving off
        // the text set `hovering` to false, which set the buttons' opacity to
        // zero before the pointer arrived. They could be seen and never
        // clicked.
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    private var bubble: some View {
        Text(message.text)
            .font(style.uiFont)
            .foregroundStyle(style.text)
            .textSelection(.enabled)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(style.secondaryBackground,
                        in: .rect(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 24)
    }

    /// In place, not in a sheet: the question is being changed in the context of
    /// the answer it produced, and a modal would hide exactly that.
    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("", text: $editDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(style.uiFont)
                .lineLimit(1...10)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(style.background, in: .rect(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style.accent.opacity(0.5), lineWidth: 1)
                }
            HStack(spacing: 8) {
                Button(String(localized: "Cancel"), action: onCancelEdit)
                    .buttonStyle(.plain)
                    .foregroundStyle(style.secondaryText)
                Button(String(localized: "Send"), action: onCommitEdit)
                    .buttonStyle(.plain)
                    .foregroundStyle(style.accent)
            }
            .font(.caption)
        }
        .padding(.leading, 24)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            if message.role == .assistant {
                Button {
                    copy(message.blocks.map(\.plainText).joined(separator: "\n\n"))
                } label: {
                    Label(copied ? String(localized: "Copied") : String(localized: "Copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                if canRegenerate {
                    Button {
                        onRegenerate()
                    } label: {
                        Label(String(localized: "Regenerate"), systemImage: "arrow.clockwise")
                    }
                }
            } else {
                Button {
                    copy(message.text)
                } label: {
                    Label(copied ? String(localized: "Copied") : String(localized: "Copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button(action: onEdit) {
                    Label(String(localized: "Edit"), systemImage: "pencil")
                }
            }
        }
        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
        .font(.caption)
        .foregroundStyle(style.faintText)
        .frame(maxWidth: .infinity,
               alignment: message.role == .user ? .trailing : .leading)
        // Kept in the layout when hidden, so the transcript does not jump by a
        // row's height every time the pointer crosses a message.
        .opacity(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.1), value: hovering)
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// One block of an assistant turn.
private struct BlockView: View {
    let block: ContentBlock
    @Environment(\.style) private var style
    @State private var expanded = false

    var body: some View {
        switch block {
        case .text(let markdown):
            // The note renderer, without the page margins it uses when a note
            // fills the window.
            ReadingView(markdown: markdown, isCompact: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

        case .thinking(let text):
            DisclosureGroup(isExpanded: $expanded) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(style.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(String(localized: "Thinking"), systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(style.faintText)
            }

        case .toolUse(_, let name, let input):
            // One line saying what it is doing, in the vocabulary of the vault
            // rather than of the API. "Searching for 拖延" is a step someone can
            // follow; `search_notes({"query":"拖延"})` is a payload.
            ToolStepView(summary: Self.summarise(name: name, input: input),
                         detail: input.jsonString,
                         symbol: Self.symbol(for: name),
                         isError: false)

        case .toolResult(_, let content, let isError):
            ToolStepView(summary: Self.summariseResult(content, isError: isError),
                         detail: content,
                         symbol: isError ? "exclamationmark.triangle" : "text.alignleft",
                         isError: isError)

        case .image:
            Label(String(localized: "Image"), systemImage: "photo")
                .font(.caption)
                .foregroundStyle(style.faintText)
        }
    }

    static func symbol(for name: String) -> String {
        switch name {
        case "search_notes": return "magnifyingglass"
        case "read_note": return "doc.text"
        case "list_links": return "link"
        case "list_notes": return "folder"
        default: return "wrench.and.screwdriver"
        }
    }

    static func summarise(name: String, input: JSONValue) -> String {
        switch name {
        case "search_notes":
            let query = input["query"]?.stringValue ?? ""
            return String(localized: "Searching for \(query)")
        case "read_note":
            return String(localized: "Reading \(input["path"]?.stringValue ?? "")")
        case "list_links":
            return String(localized: "Links of \(input["path"]?.stringValue ?? "")")
        case "list_notes":
            let folder = input["folder"]?.stringValue ?? ""
            return folder.isEmpty
                ? String(localized: "Listing the vault")
                : String(localized: "Listing \(folder)")
        default:
            return name
        }
    }

    /// The first line of a result, which is where the tools put the count.
    static func summariseResult(_ content: String, isError: Bool) -> String {
        let first = content.split(separator: "\n").first.map(String.init) ?? content
        return first.count > 80 ? String(first.prefix(80)) + "…" : first
    }
}

/// One step of the agent's work: a line, expandable to what it actually said.
///
/// Collapsed by default. A transcript that shows every tool payload in full is
/// unreadable, and the payloads are almost never what someone wants to see —
/// but "almost never" is not never, which is why they are one click away rather
/// than absent.
private struct ToolStepView: View {
    let summary: String
    let detail: String
    let symbol: String
    let isError: Bool

    @Environment(\.style) private var style
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.caption2)
                        .frame(width: 12)
                    Text(summary)
                        .lineLimit(1)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(isError ? Color.orange : style.faintText)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView(.vertical) {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(style.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(maxHeight: 200)
                .background(style.codeBackground, in: .rect(cornerRadius: 6))
            }
        }
    }
}

private struct FailureRow: View {
    let text: String
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
            if canRetry {
                Button(String(localized: "Retry"), action: retry)
                    // `.link` is macOS-only, and this panel builds for both.
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
