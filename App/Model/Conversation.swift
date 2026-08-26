import Foundation
import InkstoneCore

/// Builds a provider from a saved profile.
///
/// The one place that knows a profile's key lives in the Keychain, so nothing
/// else has to carry a secret around to make a request.
enum ProviderFactory {
    /// Why a profile cannot be used yet, in terms of what to do about it.
    enum Unusable: Error, Equatable {
        case noProfile
        case needsKey(profileName: String)
        case needsModel(profileName: String)
        case onDeviceUnavailable(reason: String)
    }

    static func provider(for profile: AssistantProfile) throws -> any ModelProvider {
        let key = AssistantCredentials.key(for: profile.credentialAccount) ?? ""
        if profile.kind.needsAPIKey, key.isEmpty {
            throw Unusable.needsKey(profileName: profile.name)
        }
        guard !profile.model.isEmpty || profile.kind == .appleOnDevice else {
            throw Unusable.needsModel(profileName: profile.name)
        }

        switch profile.kind {
        case .anthropic:
            guard let url = URL(string: profile.resolvedEndpoint) else {
                throw Unusable.needsKey(profileName: profile.name)
            }
            return AnthropicProvider(configuration: .init(apiKey: key, baseURL: url))

        case .openAICompatible:
            guard let url = URL(string: profile.resolvedEndpoint) else {
                throw Unusable.needsKey(profileName: profile.name)
            }
            return OpenAICompatibleProvider(
                configuration: .init(apiKey: key, baseURL: url, label: profile.name))

        case .appleOnDevice:
            return try AppleOnDeviceProvider.make()
        }
    }
}

/// One thread of conversation with a model.
///
/// Owns the transcript and the in-flight turn. Deliberately not a store of
/// several threads: phase 1 is one conversation per window, and adding a thread
/// list before the single case is right would be building the filing cabinet
/// before the document.
@MainActor
@Observable
final class Conversation {
    /// Finished turns, oldest first.
    private(set) var messages: [ChatMessage] = []
    /// The assistant turn currently streaming, if any. Kept apart from
    /// `messages` so the view can animate it without diffing the whole list.
    private(set) var streaming: ChatMessage?
    private(set) var isRunning = false
    /// Set when the last turn failed. Cleared when a new one starts.
    private(set) var failure: ProviderError?
    private(set) var lastUsage: TokenUsage?

    /// Markdown attached to every turn — the note on screen, when the setting
    /// is on. Held rather than folded into the first message so that switching
    /// notes changes what the next question sees.
    var attachedNote: (title: String, text: String)?

    private var task: Task<Void, Never>?

    var isEmpty: Bool { messages.isEmpty && streaming == nil }

    /// Everything the view should draw, in order.
    var visibleMessages: [ChatMessage] {
        streaming.map { messages + [$0] } ?? messages
    }

    // MARK: - Sending

    func send(_ text: String, using profile: AssistantProfile) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }

        failure = nil
        messages.append(ChatMessage(role: .user, text: trimmed))
        run(using: profile)
    }

    /// Re-runs the last turn after a failure, without duplicating the question.
    func retry(using profile: AssistantProfile) {
        guard !isRunning, messages.last?.role == .user else { return }
        failure = nil
        run(using: profile)
    }

    private func run(using profile: AssistantProfile, thinkingOverride: ThinkingEffort? = nil) {
        let provider: any ModelProvider
        do {
            provider = try ProviderFactory.provider(for: profile)
        } catch let error as ProviderFactory.Unusable {
            failure = Self.describe(error)
            return
        } catch {
            failure = .network(error.localizedDescription)
            return
        }

        let request = CompletionRequest(
            model: profile.model,
            system: systemPrompt(),
            messages: messages,
            maxTokens: 8_192,
            thinking: thinkingOverride ?? profile.thinking)

        isRunning = true
        streaming = ChatMessage(role: .assistant, blocks: [])

        task = Task { [weak self] in
            var accumulator = TurnAccumulator()
            do {
                for try await event in provider.stream(request) {
                    guard !Task.isCancelled else { break }
                    accumulator.consume(event)
                    self?.streaming = accumulator.message
                }
                self?.finish(accumulator, error: nil)
            } catch ProviderError.unsupportedThinking where thinkingOverride == nil {
                // The model refused the reasoning parameter. Guessing which
                // models take it is a pattern over names, and new models are
                // under no obligation to follow it — so a wrong guess retries
                // without it rather than costing the person their message.
                await self?.retryWithoutThinking(using: profile)
            } catch let error as ProviderError {
                self?.finish(accumulator, error: error)
            } catch {
                self?.finish(accumulator, error: .network(error.localizedDescription))
            }
        }
    }

    /// Moves the streamed turn into the transcript.
    ///
    /// A cancelled turn keeps whatever arrived rather than being discarded:
    /// pressing stop usually means "that is enough", not "throw it away", and
    /// the half-answer is often the useful part.
    private func finish(_ accumulator: TurnAccumulator, error: ProviderError?) {
        var message = accumulator.message
        if let error, error != .cancelled {
            message.failure = Self.describe(error)
            failure = error
        }
        if !accumulator.isEmpty || message.failure != nil {
            messages.append(message)
        } else if error == nil {
            // Nothing arrived and nothing failed. Silence is not an answer, so
            // it is reported rather than left as an empty bubble.
            failure = .decoding("the model returned nothing")
        }
        lastUsage = accumulator.usage
        streaming = nil
        isRunning = false
        task = nil
    }

    /// Re-runs the turn with thinking off, and remembers not to ask again.
    ///
    /// The note is per conversation rather than saved: a provider may add
    /// support at any time, and a preference file is a bad place to record a
    /// fact that expires.
    private func retryWithoutThinking(using profile: AssistantProfile) async {
        modelsRefusingThinking.insert(profile.model)
        streaming = ChatMessage(role: .assistant, blocks: [])
        run(using: profile, thinkingOverride: .off)
    }

    /// Models that answered a thinking request with a 400, this session.
    private(set) var modelsRefusingThinking: Set<String> = []

    func stop() {
        task?.cancel()
        task = nil
    }

    func clear() {
        stop()
        messages = []
        streaming = nil
        failure = nil
        lastUsage = nil
    }

    // MARK: - Prompt

    private func systemPrompt() -> String {
        var prompt = """
            You are an assistant inside Inkstone, a Markdown notes app. You are \
            helping with the user's own notes.

            Answer in the language the user writes in. Format replies as \
            Markdown — the app renders it with the same typesetter it uses for \
            notes, so tables, code blocks, and maths all display properly.

            Be concise. Prefer showing the relevant passage over summarising it \
            at length.
            """
        if let note = attachedNote {
            prompt += """


                The note currently open is "\(note.title)". Its full text follows \
                between the markers. Refer to it when the question is about \
                "this note" or "this", and otherwise treat it as background.

                --- BEGIN NOTE ---
                \(note.text)
                --- END NOTE ---
                """
        }
        return prompt
    }

    // MARK: - Errors

    /// Turns a failure into a sentence naming what to change.
    ///
    /// "401" tells a person nothing; "the key was rejected" tells them which of
    /// the four fields in front of them is wrong.
    static func describe(_ error: ProviderError) -> String {
        switch error {
        case .missingKey:
            return String(localized: "No API key. Add one in Settings › Assistant.")
        case .unauthorized:
            return String(localized: "The API key was rejected. Check it in Settings › Assistant.")
        case .rateLimited(let after):
            if let after {
                return String(localized: "Rate limited. Try again in \(Int(after)) seconds.")
            }
            return String(localized: "Rate limited by the provider. Try again shortly.")
        case .contextTooLong:
            return String(localized: "This conversation is too long for the model. Start a new one.")
        case .unsupportedThinking:
            // Reached only if the retry without thinking also failed, since the
            // first one is handled rather than reported.
            return String(localized: "This model does not support extended thinking. Turn it off in the model menu.")
        case .serverError(let status, let body):
            let detail = body.prefix(200)
            return detail.isEmpty
                ? String(localized: "The provider returned an error (\(status)).")
                : String(localized: "The provider returned an error (\(status)): \(String(detail))")
        case .network(let detail):
            return String(localized: "Could not reach the provider: \(detail)")
        case .decoding(let detail):
            return String(localized: "Unexpected response from the provider: \(detail)")
        case .cancelled:
            return String(localized: "Stopped.")
        }
    }

    static func describe(_ error: ProviderFactory.Unusable) -> ProviderError {
        switch error {
        case .noProfile, .needsKey, .needsModel:
            return .missingKey
        case .onDeviceUnavailable(let reason):
            return .network(reason)
        }
    }
}
