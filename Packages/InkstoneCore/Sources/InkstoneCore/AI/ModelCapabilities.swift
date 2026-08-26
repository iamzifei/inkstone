import Foundation

/// What a model can be asked to do, inferred from its identifier.
///
/// Neither provider reports this. `/v1/models` returns names and nothing else,
/// so the only ways to know whether a model reasons are to guess from the name
/// or to ask and see. Both are used here, in that order, because each covers the
/// other's failure:
///
/// - Guessing keeps the UI honest before any request is made, so an effort
///   control is not offered on a model that will reject it.
/// - Asking is the ground truth, and the guess is a pattern over names that new
///   models are under no obligation to follow.
///
/// The cost of getting it wrong is not cosmetic. Sending `reasoning_effort` to a
/// model that does not take it is a **400, not a silently ignored field** —
/// measured against `gpt-4.1-mini`, which answers
/// `Unrecognized request argument supplied: reasoning_effort`. So a wrong guess
/// means the message does not send at all.
public enum ModelCapabilities {
    /// Whether asking this model to think is likely to be accepted.
    ///
    /// Deliberately a prediction and not a promise: `ProviderError` carries
    /// `unsupportedThinking` so a caller can retry without it, and that retry is
    /// what makes a wrong answer here survivable.
    public static func supportsThinking(model: String, kind: ProviderKind) -> Bool {
        let id = model.lowercased()
        switch kind {
        case .anthropic:
            // Extended thinking arrived with the 4-series. The 3-series does
            // not take a `thinking` block at all.
            if id.contains("claude-3") { return false }
            return id.contains("claude")

        case .openAICompatible:
            // The reasoning families take `reasoning_effort`; the chat families
            // reject it outright.
            if id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") { return true }
            if id.hasPrefix("gpt-5") { return true }
            if id.contains("deepseek-r") || id.contains("reasoner") { return true }
            if id.contains("qwq") || id.contains("thinking") { return true }
            // Everything else, including every gpt-4 variant and every local
            // model, is assumed not to. Assumed *off* rather than on because
            // the failure is asymmetric: a model that would have reasoned
            // simply answers plainly, while one that would not have reasoned
            // refuses the whole request.
            return false

        case .appleOnDevice:
            return false
        }
    }

    /// A readable name for a model identifier.
    ///
    /// `claude-opus-4-5-20251101` is a fine key and a poor label, and the
    /// picker is read far more often than it is used.
    public static func displayName(for id: String) -> String {
        var name = id

        // Trailing date stamps carry no information a person browsing a list
        // needs, and they push the part that matters out of a narrow menu.
        if let match = name.range(of: "-20[0-9]{6}$", options: .regularExpression) {
            name.removeSubrange(match)
        }

        if name.hasPrefix("claude-") {
            // `claude-opus-4-5` → `Claude Opus 4.5`
            let parts = name.dropFirst("claude-".count).split(separator: "-").map(String.init)
            var words: [String] = ["Claude"]
            var numbers: [String] = []
            for part in parts {
                if part.allSatisfy(\.isNumber) { numbers.append(part) }
                else { words.append(part.capitalized) }
            }
            if !numbers.isEmpty { words.append(numbers.joined(separator: ".")) }
            return words.joined(separator: " ")
        }
        if name.hasPrefix("gpt-") || name.hasPrefix("o1") || name.hasPrefix("o3") {
            return name.uppercased()
                .replacingOccurrences(of: "GPT-", with: "GPT-")
        }
        return name
    }

    /// Whether a model is worth offering at all.
    ///
    /// An OpenAI-compatible endpoint lists everything it can serve, which for
    /// the official one is 130 entries including image, audio, embedding and
    /// moderation models. A picker containing `whisper-1` and `dall-e-3` is a
    /// picker nobody can find a chat model in.
    public static func isChatModel(_ id: String) -> Bool {
        let id = id.lowercased()
        let excluded = [
            "embedding", "whisper", "tts", "dall-e", "moderation", "audio",
            "image", "realtime", "transcribe", "search", "codex-mini",
            "babbage", "davinci", "instruct",
        ]
        return !excluded.contains { id.contains($0) }
    }
}
