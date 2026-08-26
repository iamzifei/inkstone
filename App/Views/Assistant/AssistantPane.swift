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
        .onAppear { attachCurrentNote() }
    }

    // MARK: - Header

    /// A thin strip, not a title bar.
    ///
    /// The model picker used to live here, which is where neither ChatGPT nor
    /// Claude puts it: the choice belongs beside the message it applies to, so
    /// it has moved into the composer. What is left is the one action that has
    /// nowhere else to go, and it appears only once there is a conversation to
    /// leave behind.
    @ViewBuilder
    private var header: some View {
        if !conversation.isEmpty {
            HStack(spacing: 6) {
                if let usage = conversation.lastUsage, usage.total > 0 {
                    Text("\(usage.total) tokens")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(style.faintText)
                }
                Spacer(minLength: 0)
                Button {
                    conversation.clear()
                    inputFocused = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(style.secondaryText)
                }
                .buttonStyle(.plain)
                .help(String(localized: "New conversation"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
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
                        MessageRow(message: message)
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

    /// Model and thinking effort, as one unobtrusive menu.
    ///
    /// Reads as a label until pointed at, the way the model name does in both
    /// ChatGPT and Claude — it is a setting people change rarely and read often,
    /// so it should be legible without drawing the eye.
    private var modelPicker: some View {
        Menu {
            Picker(String(localized: "Model"), selection: profileBinding) {
                ForEach(settings.data.assistant.profiles) { candidate in
                    Text(candidate.name).tag(candidate.id as UUID?)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Picker(String(localized: "Thinking"), selection: thinkingBinding) {
                ForEach(ThinkingEffort.allCases, id: \.self) { effort in
                    Text(Self.thinkingLabel(effort)).tag(effort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text(profile?.name ?? String(localized: "No model"))
                    .foregroundStyle(style.secondaryText)
                if let profile, profile.thinking != .off {
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

    private func send() {
        guard let profile else { return }
        let text = draft
        draft = ""
        conversation.send(text, using: profile)
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

/// One turn in the transcript.
private struct MessageRow: View {
    let message: ChatMessage
    @Environment(\.style) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch message.role {
            case .user:
                // A bubble, inset from the trailing edge so it does not run into
                // the panel's own border. Capped short of full width, because a
                // bubble that spans the column is indistinguishable from the
                // reply below it.
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
        }
    }
}

/// One block of an assistant turn.
private struct BlockView: View {
    let block: ContentBlock
    @State private var thinkingExpanded = false
    @State private var toolExpanded = false

    var body: some View {
        switch block {
        case .text(let markdown):
            // The same renderer as reading mode. Tables, code, formulas and
            // Mermaid diagrams all work without another line of code here.
            // The note renderer, without the page margins it uses when a note
            // fills the window.
            ReadingView(markdown: markdown, isCompact: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

        case .thinking(let text):
            DisclosureGroup(isExpanded: $thinkingExpanded) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(String(localized: "Thinking"), systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

        case .toolUse(_, let name, let input):
            DisclosureGroup(isExpanded: $toolExpanded) {
                Text(input.jsonString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(name, systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

        case .toolResult(_, let content, let isError):
            Label(content, systemImage: isError ? "xmark.circle" : "checkmark.circle")
                .font(.caption)
                .foregroundStyle(isError ? .orange : .secondary)
                .lineLimit(3)

        case .image:
            Label(String(localized: "Image"), systemImage: "photo")
                .font(.caption)
                .foregroundStyle(.tertiary)
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
