import SwiftUI
import InkstoneCore

/// Settings for the assistant panel: which models, which keys, what it sees.
///
/// The whole feature is off until this pane turns it on. A new panel appearing
/// unbidden in the inspector of a notes app would be a surprise, and someone who
/// wants nothing to do with a model should not have to notice it exists.
struct AssistantSettingsPane: View {
    @Environment(Workspace.self) private var workspace
    @State private var editing: AssistantProfile.ID?

    var body: some View {
        @Bindable var settings = workspace.settings

        Form {
            Section {
                Toggle("Show the assistant", isOn: $settings.data.assistant.isEnabled)

                Text("Adds an Assistant tab to the inspector, beside the note's properties and backlinks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.data.assistant.isEnabled {
                Section("Models") {
                    ForEach($settings.data.assistant.profiles) { $profile in
                        ProfileRow(profile: $profile,
                                   isActive: settings.data.assistant.activeProfile?.id == profile.id,
                                   makeActive: {
                                       settings.data.assistant.activeProfileID = profile.id
                                   })
                    }
                    .onDelete { offsets in
                        // Forget the credential too. Removing a profile from a
                        // list while leaving its key in the Keychain would make
                        // deletion look complete when it was not.
                        for index in offsets {
                            let profile = settings.data.assistant.profiles[index]
                            AssistantCredentials.forget(account: profile.credentialAccount)
                        }
                        settings.data.assistant.profiles.remove(atOffsets: offsets)
                    }

                    Button("Add a model…") {
                        let profile = AssistantProfile(
                            name: String(localized: "New model"), kind: .openAICompatible)
                        settings.data.assistant.profiles.append(profile)
                    }
                }

                Section("Skills") {
                    SkillFolderRow()
                }

                Section("Context") {
                    Toggle("Attach the open note to each conversation",
                           isOn: $settings.data.assistant.includesCurrentNote)
                    Text("Lets you ask about \"this note\" without pasting it. The note's text is sent to the model you have chosen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("API keys are stored in your Mac's Keychain, not in the app's preferences, and are not synced to your other devices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One configured model: its name, endpoint, key, and which model to call.
private struct ProfileRow: View {
    @Binding var profile: AssistantProfile
    let isActive: Bool
    let makeActive: () -> Void

    @State private var expanded = false
    @State private var key = ""
    @State private var keyLoaded = false
    @State private var models: [ModelInfo] = []
    @State private var checkState: CheckState = .idle

    private enum CheckState: Equatable {
        case idle, checking, ok(Int), failed(String)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Name", text: $profile.name)

                Picker("Kind", selection: $profile.kind) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                if profile.kind != .appleOnDevice {
                    TextField("Endpoint", text: $profile.endpoint,
                              prompt: Text(profile.kind.defaultEndpoint))
                        .font(.callout.monospaced())

                    // Secure, and never shown once stored: reading a key back
                    // out of the Keychain to display it puts a live credential
                    // on screen for the length of a screen share.
                    SecureField(keyLoaded && !key.isEmpty ? "Stored" : "API key", text: $key)
                        .onChange(of: key) { _, new in
                            AssistantCredentials.setKey(new, for: profile.credentialAccount)
                        }

                    HStack {
                        TextField("Model", text: $profile.model)
                            .font(.callout.monospaced())
                        if !models.isEmpty {
                            Menu {
                                ForEach(models) { model in
                                    Button(model.displayName) { profile.model = model.id }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Check") { check() }
                            .disabled(checkState == .checking)
                        switch checkState {
                        case .idle:
                            EmptyView()
                        case .checking:
                            ProgressView().controlSize(.small)
                        case .ok(let count):
                            Label("Connected — \(count) models", systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .failed(let message):
                            Label(message, systemImage: "xmark.circle")
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .lineLimit(2)
                        }
                    }
                } else if let unavailable = AppleOnDeviceProvider.availabilityMessage {
                    // Not an error: the model exists, it just is not switched
                    // on. Saying where to switch it on is the whole message.
                    Label(unavailable, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Ready. Runs on this Mac; nothing is sent anywhere.",
                          systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Picker("Thinking", selection: $profile.thinking) {
                    ForEach(ThinkingEffort.allCases, id: \.self) { effort in
                        Text(AssistantPane.thinkingLabel(effort)).tag(effort)
                    }
                }
            }
            .padding(.vertical, 4)
            .task {
                // Only whether a key exists, never its value.
                keyLoaded = true
                if AssistantCredentials.key(for: profile.credentialAccount) != nil, key.isEmpty {
                    key = ""
                }
            }
        } label: {
            HStack {
                Button(action: makeActive) {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Use this model"))

                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                    Text(profile.kind == .appleOnDevice
                         ? String(localized: "On this Mac")
                         : profile.model.isEmpty ? String(localized: "No model chosen") : profile.model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Asks the endpoint what it offers. Doubles as a credential check, since a
    /// bad key fails here rather than in the middle of someone's first question.
    private func check() {
        checkState = .checking
        let snapshot = profile
        Task {
            do {
                let provider = try ProviderFactory.provider(for: snapshot)
                let found = try await provider.models()
                models = found.sorted()
                checkState = .ok(found.count)
                if profile.model.isEmpty, let first = found.first { profile.model = first.id }
            } catch let error as ProviderError {
                checkState = .failed(Conversation.describe(error))
            } catch let error as ProviderFactory.Unusable {
                checkState = .failed(Conversation.describe(Conversation.describe(error)))
            } catch {
                checkState = .failed(error.localizedDescription)
            }
        }
    }
}

/// Choosing the folder of skills.
///
/// A folder rather than a path field, because a sandboxed app cannot read
/// `~/.claude/skills` from a string — permission comes from the user handing the
/// folder over through an open panel, and a security-scoped bookmark is what
/// keeps it across launches. The same mechanism the vault uses.
private struct SkillFolderRow: View {
    @Environment(SkillLibrary.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let name = library.folderName {
                    Label(name, systemImage: "folder")
                        .lineLimit(1)
                    Spacer()
                    Text("\(library.skills.count) skills")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Change…")) { choose() }
                    Button(String(localized: "Remove")) { library.forget() }
                } else {
                    Text("No skills folder")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Choose…")) { choose() }
                }
            }
            if let problem = library.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Type / in the assistant to use one. Claude Code's format — point this at ~/.claude/skills. Skills that run scripts contribute their instructions only, since a sandboxed app cannot launch other programs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choose() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Use Folder")
        panel.message = String(localized: "Choose the folder holding your skills")
        // Start where they usually live, since it is a hidden folder and typing
        // the path into an open panel means knowing to press ⇧⌘G first.
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/skills")
        if panel.runModal() == .OK, let url = panel.url {
            library.adopt(url)
        }
        #endif
    }
}
