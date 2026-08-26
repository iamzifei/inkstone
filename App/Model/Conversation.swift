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
    /// Called whenever the transcript changes, so the store can persist it.
    var onChange: ([ChatMessage]) -> Void = { _ in }
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
    /// A skill's instructions, for the next message only.
    ///
    /// Cleared once sent. A skill is a way of answering one question; leaving it
    /// in place would silently colour every answer after it, and there would be
    /// nothing on screen saying why.
    var skillInstructions: String?

    /// Attached by hand, for the next message only.
    var attachments: [ChatAttachment] = []
    /// Reads an attached note at send time, so a note edited between attaching
    /// and sending goes as it is now.
    var readAttachedNote: (String) -> String? = { _ in nil }
    var listAttachedFolder: (String) -> [String] = { _ in [] }

    /// The vault, as tools. Nil until a vault is open, in which case the model
    /// is given no tools rather than tools that fail.
    var toolbox: NoteToolbox?
    /// Where the assistant's proposed changes accumulate.
    var editStore: PendingEditStore?
    /// Mirrors the store for the view. Kept here rather than read on demand
    /// because SwiftUI cannot await an actor while building a body.
    private(set) var pendingEdits = EditQueue()

    /// How many times one question may go round the loop.
    ///
    /// A limit, not a target: a model that keeps searching without converging
    /// spends money and time on a question it is not answering. Twelve is well
    /// past what a real question takes — following a chain of links four notes
    /// deep is about six — and short enough that a loop is noticed in seconds.
    private let maximumRounds = 12
    /// Rounds used by the question in flight, for the limit and for the UI.
    private(set) var round = 0

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

        // Attachments become part of the message rather than of the system
        // prompt: they belong to this question, and a later question about
        // something else should not still be carrying them.
        var blocks: [ContentBlock] = []
        if let text = AttachmentRenderer.textBlock(
            for: attachments, readNote: readAttachedNote, listFolder: listAttachedFolder) {
            blocks.append(.text(text))
        }
        blocks += AttachmentRenderer.imageBlocks(for: attachments)
        blocks.append(.text(trimmed))

        messages.append(ChatMessage(role: .user, blocks: blocks))
        publish()
        run(using: profile)
        skillInstructions = nil
        attachments = []
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
            system: systemPrompt(for: profile),
            messages: messages,
            tools: toolbox == nil ? [] : NoteToolbox.definitions,
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
                await self?.finish(accumulator, error: nil, profile: profile)
            } catch ProviderError.unsupportedThinking where thinkingOverride == nil {
                // The model refused the reasoning parameter. Guessing which
                // models take it is a pattern over names, and new models are
                // under no obligation to follow it — so a wrong guess retries
                // without it rather than costing the person their message.
                await self?.retryWithoutThinking(using: profile)
            } catch let error as ProviderError {
                await self?.finish(accumulator, error: error, profile: profile)
            } catch {
                await self?.finish(accumulator, error: .network(error.localizedDescription),
                                   profile: profile)
            }
        }
    }

    /// Moves the streamed turn into the transcript, and runs its tools.
    ///
    /// A turn that ends in `toolUse` has not finished — it is waiting. So this
    /// is where the agent loop lives: append what the model said, run what it
    /// asked for, append the results, and go round again. The loop ends when the
    /// model answers without asking for anything, which is the only signal that
    /// it considers the question dealt with.
    ///
    /// A cancelled turn keeps whatever arrived rather than being discarded:
    /// pressing stop usually means "that is enough", not "throw it away", and
    /// the half-answer is often the useful part.
    private func finish(
        _ accumulator: TurnAccumulator,
        error: ProviderError?,
        profile: AssistantProfile
    ) async {
        var message = accumulator.message
        if let error, error != .cancelled {
            message.failure = Self.describe(error)
            failure = error
        }
        if !accumulator.isEmpty || message.failure != nil {
            messages.append(message)
        } else if error == nil {
            failure = .decoding("the model returned nothing")
        }
        lastUsage = accumulator.usage
        streaming = nil

        // Tools run only when the turn asked for them and nothing went wrong.
        // A cancelled turn does not run its tools: stop means stop, and a
        // half-streamed call is the least likely one to have been meant.
        guard error == nil, accumulator.needsToolResults, let toolbox else {
            if let editStore { pendingEdits = await editStore.snapshot() }
            isRunning = false
            task = nil
            round = 0
            publish()
            return
        }

        guard round < maximumRounds else {
            // Reported in the transcript, not swallowed. A question that hit
            // the ceiling produced work worth seeing, and silence here looks
            // like the model simply stopped.
            messages.append(ChatMessage(
                role: .assistant, blocks: [],
                failure: String(localized: "Stopped after \(maximumRounds) rounds of tool use without an answer.")))
            isRunning = false
            task = nil
            round = 0
            publish()
            return
        }

        round += 1
        publish()

        var results: [ContentBlock] = []
        for call in message.toolUses {
            guard !Task.isCancelled else { break }
            let outcome = await toolbox.run(call.name, input: call.input)
            results.append(.toolResult(id: call.id, content: outcome.content,
                                       isError: outcome.isError))
        }
        guard !Task.isCancelled, !results.isEmpty else {
            isRunning = false
            task = nil
            round = 0
            publish()
            return
        }

        if let editStore { pendingEdits = await editStore.snapshot() }

        // Results go back as a user turn, which is what both APIs expect: the
        // model's turn asked, and the reply to it is ours to give.
        messages.append(ChatMessage(role: .user, blocks: results))
        publish()
        streaming = ChatMessage(role: .assistant, blocks: [])
        run(using: profile)
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

    /// Replaces an earlier question and re-runs from there.
    ///
    /// Everything after it is dropped, because it was an answer to a question
    /// that no longer exists. Keeping the later turns would leave a transcript
    /// that reads as a conversation nobody had.
    func edit(_ id: UUID, to text: String, using profile: AssistantProfile) {
        guard !isRunning,
              let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].role == .user else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages[index] = ChatMessage(id: id, role: .user, text: trimmed)
        messages.removeSubrange((index + 1)...)
        failure = nil
        publish()
        run(using: profile)
    }

    /// Asks the same question again, discarding the answer given.
    ///
    /// The previous answer is removed rather than kept alongside: two answers to
    /// one question in a linear transcript is a branch drawn as a list, and the
    /// clients that offer this all replace rather than append.
    func regenerate(using profile: AssistantProfile) {
        guard !isRunning, messages.last?.role == .assistant else { return }
        messages.removeLast()
        failure = nil
        publish()
        run(using: profile)
    }

    /// Whether the last turn can be asked again.
    var canRegenerate: Bool { !isRunning && messages.last?.role == .assistant }

    /// Loads a stored transcript, abandoning anything in flight.
    func load(_ stored: [ChatMessage]) {
        stop()
        messages = stored
        streaming = nil
        failure = nil
        lastUsage = nil
        isRunning = false
    }

    private func publish() { onChange(messages) }

    // MARK: - Pending changes

    func refreshPendingEdits() async {
        guard let editStore else { return }
        pendingEdits = await editStore.snapshot()
    }

    /// Pushes the reviewer's decisions back into the store.
    ///
    /// Needed because the sheet edits a copy: without this, unchecking a hunk
    /// and then asking a follow-up question would show the assistant a file it
    /// had been told was accepted.
    func syncPendingEdits(_ queue: EditQueue) async {
        pendingEdits = queue
        await editStore?.replace(with: queue)
    }

    func discardPendingEdits() async {
        pendingEdits = EditQueue()
        await editStore?.clear()
    }

    func stop() {
        task?.cancel()
        task = nil
        round = 0
        isRunning = false
    }

    func clear() {
        stop()
        messages = []
        streaming = nil
        failure = nil
        lastUsage = nil
        round = 0
        publish()
    }

    // MARK: - Prompt

    private func systemPrompt(for profile: AssistantProfile) -> String {
        var prompt = """
            You are an assistant inside Inkstone, a Markdown notes app. You are \
            helping with the user's own notes.

            Answer in the language the user writes in. Format replies as \
            Markdown — the app renders it with the same typesetter it uses for \
            notes, so tables, code blocks, and maths all display properly.

            Be concise. Prefer showing the relevant passage over summarising it \
            at length.
            """
        if let skill = skillInstructions, !skill.isEmpty {
            prompt += """


                The user invoked a skill. Follow these instructions for this \
                request. Anything in them about running scripts or shell \
                commands cannot be done here — do that part yourself, with the \
                information you have.

                --- BEGIN SKILL ---
                \(skill)
                --- END SKILL ---
                """
        }
        if var note = attachedNote {
            // The on-device model holds about 4,000 tokens, so a note of any
            // size has to be cut to fit. Cut rather than refused: someone who
            // asks about the note in front of them should get an answer about
            // its opening, with a line saying what was left out, instead of an
            // error telling them to change model.
            if profile.kind == .appleOnDevice {
                let budget = AppleOnDeviceProvider.characterBudget - 600
                if note.text.count > budget {
                    note.text = String(note.text.prefix(budget))
                        + "\n\n[Cut here — this model can only hold the first part of the note.]"
                }
            }
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
        case .onDeviceCannotUseTools:
            return String(localized: """
                The on-device model cannot search your notes. It holds about \
                4,000 tokens and one note is usually larger than that. Use a \
                cloud model for questions about the vault, or ask this one to \
                rewrite or summarise the text in front of you.
                """)
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
