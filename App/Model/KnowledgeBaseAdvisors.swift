import Foundation
import FoundationModels
import InkstoneCore

/// Where a file goes, decided by Apple's on-device model with guided
/// generation: the answer is a typed value, never free text to parse, and
/// nothing leaves the device.
///
/// The organizer only asks when its own rules found no place, checks every
/// answer (a folder outside the vault or in its machinery is refused, and below
/// 0.7 the file goes to review), so a wrong answer costs a file in review,
/// never a lost one.
struct OnDevicePlacementAdvisor: PlacementAdvisor {
    @Generable
    struct Answer {
        @Guide(description: "The folder to file it in: one of the listed folders, or a new subfolder one level below a projects, areas or resources folder")
        var folder: String
        @Guide(description: "How sure, from 0 to 1. Below 0.7 means unsure", .range(0...1))
        var confidence: Double
        @Guide(description: "2 to 6 words naming the topic, no date, no extension")
        var title: String
        @Guide(description: "Up to 5 short tags", .maximumCount(5))
        var tags: [String]
        @Guide(description: "One sentence on what the file is")
        var summary: String
        @Guide(description: "True for ID documents, bank, medical, salary or password content")
        var isPrivate: Bool
        @Guide(description: "A few words on why this folder")
        var reason: String
    }

    /// Nil when the on-device model cannot be used (off, downloading, not
    /// supported): the organizer then files by its rules alone.
    static func makeIfAvailable() -> OnDevicePlacementAdvisor? {
        if case .available = SystemLanguageModel.default.availability { return OnDevicePlacementAdvisor() }
        return nil
    }

    func advise(_ facts: FileFacts, context: AdvisorContext) async throws -> PlacementAdvice? {
        let session = LanguageModelSession(instructions: AdvisorPrompt.instructions(context.layout))
        // Under the 3,600-character budget measured for this model's window,
        // leaving room for the schema the framework adds.
        let prompt = AdvisorPrompt.prompt(facts, context: context, budget: 2_400)
        let answer = try await session.respond(to: prompt, generating: Answer.self).content
        return PlacementAdvice(folder: answer.folder, confidence: answer.confidence, title: answer.title,
                               tags: answer.tags, summary: answer.summary, isPrivate: answer.isPrivate,
                               reason: answer.reason)
    }
}

/// Where a file goes, asked of a model the person set up themselves (their
/// own key). Only used when they turned it on for organizing: the file's
/// excerpt is sent to that provider.
struct ProviderPlacementAdvisor: PlacementAdvisor {
    let provider: any ModelProvider
    let model: String

    func advise(_ facts: FileFacts, context: AdvisorContext) async throws -> PlacementAdvice? {
        // Nothing that looks private leaves the device: it is filed as
        // private without asking.
        guard AdvisorPrompt.maySendOffDevice(facts, context: context) else {
            return PlacementAdvice(folder: context.layout.privateFolder, confidence: 1, title: nil, tags: [],
                                   summary: nil, isPrivate: true, reason: "private words; not sent")
        }
        let system = AdvisorPrompt.instructions(context.layout)
            + "\n\nAnswer with JSON only, in this shape: " + AdvisorPrompt.jsonShape
        let request = CompletionRequest(
            model: model, system: system,
            messages: [ChatMessage(role: .user, text: AdvisorPrompt.prompt(facts, context: context, budget: 6_000))],
            maxTokens: 400)
        var text = ""
        for try await event in provider.stream(request) {
            if case .textDelta(let delta) = event { text += delta }
        }
        return AdvisorPrompt.parse(text)
    }
}
