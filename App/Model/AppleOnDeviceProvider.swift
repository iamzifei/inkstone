import Foundation
import FoundationModels
import InkstoneCore

/// Apple's on-device model, behind the same protocol as the network providers.
///
/// Free, offline, and nothing leaves the Mac — the only option here that costs
/// the user nothing per call. It is also much smaller than the cloud models, so
/// it is offered as a second tier rather than a default: good for rewriting a
/// paragraph, naming a note, or summarising one file, and out of its depth on a
/// task that needs several rounds of tool use.
///
/// Availability is a real state, not an assumption. The framework ships with
/// macOS 26 but reports `appleIntelligenceNotEnabled` until the user turns Apple
/// Intelligence on in System Settings, which is the state this machine was in
/// when the provider was written. So `make()` fails with something a person can
/// act on rather than the panel appearing to hang.
struct AppleOnDeviceProvider: ModelProvider {
    var identifier: String { "apple-on-device" }

    /// Checks availability and builds a provider, or explains what is missing.
    static func make() throws -> AppleOnDeviceProvider {
        switch SystemLanguageModel.default.availability {
        case .available:
            return AppleOnDeviceProvider()
        case .unavailable(let reason):
            throw ProviderFactory.Unusable.onDeviceUnavailable(reason: describe(reason))
        @unknown default:
            throw ProviderFactory.Unusable.onDeviceUnavailable(
                reason: String(localized: "The on-device model is unavailable."))
        }
    }

    /// What to tell someone, and where to go.
    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return String(localized: """
                Apple Intelligence is off. Turn it on in System Settings › \
                Apple Intelligence & Siri, then try again.
                """)
        case .modelNotReady:
            return String(localized: """
                The on-device model is still downloading. This finishes in the \
                background; try again in a few minutes.
                """)
        case .deviceNotEligible:
            return String(localized: """
                This Mac does not support Apple Intelligence. Use a cloud model \
                instead.
                """)
        @unknown default:
            return String(localized: "The on-device model is unavailable.")
        }
    }

    /// Whether the on-device model can be used right now, for the settings pane.
    static var availabilityMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(let reason): return describe(reason)
        @unknown default: return String(localized: "The on-device model is unavailable.")
        }
    }

    /// The context window, in characters, with room left to answer.
    ///
    /// Measured on this machine: the window is **4,096 tokens**, and the model
    /// refuses outright past it —
    /// `exceededContextWindowSize … Provided 11,156 tokens, but the maximum
    /// allowed is 4,096`. Mixed Chinese and English ran about 1.8 characters per
    /// token, so 4,096 tokens is roughly 7,300 characters. Half of that is the
    /// budget for everything sent, leaving the rest for the reply.
    ///
    /// This is the number that makes the on-device model a different kind of
    /// tool rather than a cheaper one: a cloud model takes a 40,000-character
    /// note without noticing, and this one cannot take a tenth of it.
    static let characterBudget = 3_600

    /// Whether a request fits, and can therefore be attempted.
    ///
    /// Checked before sending rather than after failing, because the failure is
    /// a rejected request rather than a truncated answer, and "nothing happened"
    /// is what that looks like from the panel.
    static func isTooLong(_ request: CompletionRequest) -> Bool {
        let system = request.system?.count ?? 0
        let conversation = request.messages.reduce(0) { total, message in
            total + message.blocks.reduce(0) { $0 + $1.plainText.count }
        }
        return system + conversation > characterBudget
    }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if !request.tools.isEmpty {
                        // Tools are declined rather than ignored. One
                        // search_notes result runs to a thousand characters and
                        // one read_note to twelve thousand, against a budget of
                        // 3,600 — a loop here would fail on its first result,
                        // after spending the round. The panel says so instead.
                        throw ProviderError.onDeviceCannotUseTools
                    }
                    if Self.isTooLong(request) {
                        throw ProviderError.contextTooLong
                    }
                    let instructions = request.system ?? ""
                    let session = instructions.isEmpty
                        ? LanguageModelSession()
                        : LanguageModelSession(instructions: instructions)

                    // The framework takes a single prompt rather than a message
                    // list, so the transcript is flattened into one. Roles are
                    // labelled because dropping them would leave a wall of text
                    // in which the model cannot tell its own words from ours.
                    let prompt = Self.flatten(request.messages)

                    var delivered = ""
                    for try await snapshot in session.streamResponse(to: prompt) {
                        try Task.checkCancellation()
                        // `streamResponse` yields the whole answer so far, while
                        // this protocol is built on deltas. Sending snapshots as
                        // deltas would repeat the text on every tick, so only
                        // the new suffix goes out.
                        let full = snapshot.content
                        guard full.count > delivered.count,
                              full.hasPrefix(delivered) else {
                            // A snapshot that is not an extension of the last
                            // one means the model revised what it had said.
                            // Rare, and the honest response is to send the
                            // difference as a fresh block rather than to
                            // silently show stale text.
                            if full != delivered {
                                continuation.yield(.textDelta(full))
                                delivered = full
                            }
                            continue
                        }
                        let suffix = String(full.dropFirst(delivered.count))
                        delivered = full
                        continuation.yield(.textDelta(suffix))
                    }
                    // No token accounting: nothing is billed, and reporting
                    // zeroes would look like a provider that failed to report.
                    continuation.yield(.finished(stopReason: .endTurn, usage: TokenUsage()))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch let error as ProviderError {
                    // Passed through, not re-wrapped. Without this the errors
                    // thrown a few lines above — the tool refusal and the
                    // context check — were caught by the clause below and
                    // wrapped in `.network(error.localizedDescription)`, which
                    // for an enum with no `LocalizedError` conformance reads
                    // "The operation couldn't be completed (error 8)". The two
                    // most likely failures of this provider were the two that
                    // said nothing.
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(
                        throwing: ProviderError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func flatten(_ messages: [ChatMessage]) -> String {
        messages.map { message in
            let body = message.blocks.compactMap { block -> String? in
                if case .text(let text) = block { return text }
                if case .toolResult(_, let content, _) = block { return content }
                return nil
            }.joined(separator: "\n")
            switch message.role {
            case .user: return body
            case .assistant: return "Assistant: \(body)"
            }
        }.joined(separator: "\n\n")
    }

    /// One entry, because the on-device model is not a choice of models.
    func models() async throws -> [ModelInfo] {
        [ModelInfo(id: "apple-on-device", displayName: String(localized: "Apple on-device"))]
    }
}
