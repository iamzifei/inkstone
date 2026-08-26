import SwiftUI
import InkstoneCore

/// What the on-device model is actually for.
///
/// It holds about 4,000 tokens, so it cannot search a vault or hold a
/// conversation about one — measured, and the reason the assistant panel
/// declines to give it tools. What it can do is work on the passage in front of
/// you, free, offline, and without a key. That is a real feature, and it needs
/// somewhere to happen that is not a chat panel.
///
/// So: select text, press ⌥⌘K, pick what to do with it, see the result, replace
/// or discard. No conversation, no history, no cost.
struct QuickRewriteView: View {
    let original: String
    /// Replaces the selection in the editor.
    let onReplace: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.style) private var style
    @Environment(Workspace.self) private var workspace

    @State private var action: Action = .polish
    @State private var custom = ""
    @State private var result = ""
    @State private var isRunning = false
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    /// The things worth having one keystroke away.
    ///
    /// Short and concrete, because that is what a 4,000-token model is good at
    /// and because a long list is a menu to read rather than a shortcut.
    enum Action: String, CaseIterable, Identifiable {
        case polish, shorten, expand, bullets, translate, title, custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .polish: return String(localized: "Polish")
            case .shorten: return String(localized: "Make shorter")
            case .expand: return String(localized: "Expand")
            case .bullets: return String(localized: "As bullet points")
            case .translate: return String(localized: "Translate")
            case .title: return String(localized: "Suggest a title")
            case .custom: return String(localized: "Custom…")
            }
        }

        /// The instruction sent. Written to be followed by a small model:
        /// one sentence, one job, and an explicit "return only the text",
        /// because without it these models preface everything with "Sure!".
        func instruction(for text: String) -> String {
            let common = "Return only the rewritten text, with no preface, "
                + "explanation or quotation marks. Keep the original language."
            switch self {
            case .polish:
                return "Improve the wording and flow of this passage without changing what it says. \(common)"
            case .shorten:
                return "Rewrite this passage to be significantly shorter, keeping every point. \(common)"
            case .expand:
                return "Expand this passage with more detail, keeping its voice. \(common)"
            case .bullets:
                return "Rewrite this passage as a short Markdown bullet list. \(common)"
            case .translate:
                return "Translate this passage: into English if it is Chinese, into Chinese if it is English. \(common)"
            case .title:
                return "Suggest one short title for this passage. Return only the title."
            case .custom:
                return common
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 420)
        .background(style.background)
        .onDisappear { task?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: $action) {
                ForEach(Action.allCases) { candidate in
                    Text(candidate.label).tag(candidate)
                }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: action) { run() }

            if action == .custom {
                TextField(String(localized: "What should it do?"), text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { run() }
            }
            Spacer(minLength: 0)
            if isRunning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !result.isEmpty {
                    Text(result)
                        .font(style.uiFont)
                        .foregroundStyle(style.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !isRunning && failure == nil {
                    Text("Runs on this Mac. Nothing is sent anywhere and nothing is billed.")
                        .font(.callout)
                        .foregroundStyle(style.secondaryText)
                }

                DisclosureGroup {
                    Text(original)
                        .font(.callout)
                        .foregroundStyle(style.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Original")
                        .font(.caption)
                        .foregroundStyle(style.faintText)
                }
            }
            .padding(12)
        }
    }

    private var footer: some View {
        HStack {
            Button(String(localized: "Try again"), action: run)
                .disabled(isRunning)
            Spacer()
            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Replace selection")) {
                onReplace(result)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(result.isEmpty || isRunning)
        }
        .padding(12)
    }

    private func run() {
        task?.cancel()
        failure = nil
        result = ""

        // Over budget before sending, rather than a refused request that looks
        // like nothing happening. 4,000 tokens is roughly 3,600 characters, and
        // the instruction and the answer both come out of it.
        let budget = AppleOnDeviceProvider.characterBudget - 800
        guard original.count <= budget else {
            failure = String(localized: """
                That selection is too long for the on-device model — it holds \
                about \(budget) characters and this is \(original.count). Select \
                less, or use a cloud model in the assistant panel.
                """)
            return
        }

        let provider: AppleOnDeviceProvider
        do {
            provider = try AppleOnDeviceProvider.make()
        } catch let error as ProviderFactory.Unusable {
            failure = Conversation.describe(Conversation.describe(error))
            return
        } catch {
            failure = error.localizedDescription
            return
        }

        var instruction = action.instruction(for: original)
        if action == .custom {
            let asked = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !asked.isEmpty else { return }
            instruction = asked + " " + instruction
        }

        isRunning = true
        task = Task {
            let request = CompletionRequest(
                model: "apple-on-device",
                system: instruction,
                messages: [.init(role: .user, text: original)],
                maxTokens: 1_024)
            do {
                for try await event in provider.stream(request) {
                    guard !Task.isCancelled else { break }
                    if case .textDelta(let piece) = event { result += piece }
                }
            } catch let error as ProviderError {
                failure = Conversation.describe(error)
            } catch {
                failure = error.localizedDescription
            }
            isRunning = false
        }
    }
}
