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
            Divider()
            transcript
            Divider()
            composer
        }
        .background(style.background)
        .onChange(of: workspace.activeTab?.url) { attachCurrentNote() }
        .onChange(of: settings.data.assistant.includesCurrentNote) { attachCurrentNote() }
        .onAppear { attachCurrentNote() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
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
                        .lineLimit(1)
                    Image(systemName: "chevron.down").imageScale(.small)
                }
                .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(settings.data.assistant.profiles.isEmpty)

            Spacer(minLength: 4)

            if let usage = conversation.lastUsage, usage.total > 0 {
                Text("\(usage.total) tokens")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    // The number is only useful next to what produced it, and
                    // the panel is narrow — so it yields to the buttons.
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

            Button {
                conversation.clear()
                inputFocused = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .disabled(conversation.isEmpty)
            .help(String(localized: "Start a new conversation"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
                .padding(12)
            }
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

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let profile, profile.kind == .appleOnDevice,
               let unavailable = AppleOnDeviceProvider.availabilityMessage {
                Label {
                    Text(unavailable)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else if settings.data.assistant.profiles.isEmpty {
                Text("Add a model in Settings › Assistant to begin.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Ask about this note, or about anything in the vault.")
                    .foregroundStyle(.secondary)
                if let note = conversation.attachedNote {
                    Label(note.title, systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
                TextField(String(localized: "Ask about your notes…"),
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .disabled(conversation.isRunning)

                if conversation.isRunning {
                    Button(action: conversation.stop) {
                        Image(systemName: "stop.circle.fill")
                            .imageScale(.large)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Stop"))
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .imageScale(.large)
                    }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || profile == nil)
                    .help(String(localized: "Send"))
                }
            }
            if settings.data.assistant.includesCurrentNote,
               let note = conversation.attachedNote, !conversation.isEmpty {
                Label(note.title, systemImage: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
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
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(style.selection.opacity(0.5),
                                in: .rect(cornerRadius: 10))
                    .frame(maxWidth: .infinity, alignment: .trailing)

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
            ReadingView(markdown: markdown)
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
