import Foundation

/// A JSON value, for tool arguments and results.
///
/// Tool inputs arrive as whatever shape the model decided to send, and are sent
/// back to a different provider that expects the same shape. `Any` would make
/// the message types non-`Sendable`, and a per-tool `Decodable` struct cannot be
/// written until the tool exists. So the wire shape is modelled directly.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unrecognised JSON")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: - Reading

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Parses a JSON string, which is how tool input arrives over SSE — streamed
    /// as text fragments that only become valid JSON once the last one lands.
    public static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public var jsonString: String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}

/// One piece of a message.
///
/// A single assistant turn can hold prose *and* several tool calls, and a user
/// turn can hold text, images, and the results of tools the assistant asked for.
/// Both providers model this as a list of typed blocks, so this does too rather
/// than flattening to a string and re-parsing later.
public enum ContentBlock: Sendable, Hashable {
    case text(String)
    /// The model's reasoning, when the provider returns it separately from the
    /// answer. Displayed collapsed, and never sent back as ordinary text.
    case thinking(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(id: String, content: String, isError: Bool)
    case image(mimeType: String, data: Data)

    /// The readable text of this block, for display and for tests. Tool blocks
    /// describe themselves rather than returning nothing, so that a transcript
    /// rendered from these is never silently missing a step.
    public var plainText: String {
        switch self {
        case .text(let text), .thinking(let text): return text
        case .toolUse(_, let name, let input): return "\(name)(\(input.jsonString))"
        case .toolResult(_, let content, _): return content
        case .image(let mime, _): return "[image \(mime)]"
        }
    }
}

/// One turn in a conversation.
public struct ChatMessage: Sendable, Hashable, Identifiable {
    public enum Role: String, Sendable, Codable, Hashable {
        case user
        case assistant
    }

    public let id: UUID
    public var role: Role
    public var blocks: [ContentBlock]
    /// Set when the turn ended badly, so the transcript can show what happened
    /// in place rather than in a banner that outlives the message it refers to.
    public var failure: String?

    public init(id: UUID = UUID(), role: Role, blocks: [ContentBlock], failure: String? = nil) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.failure = failure
    }

    public init(id: UUID = UUID(), role: Role, text: String) {
        self.init(id: id, role: role, blocks: [.text(text)])
    }

    public var text: String {
        blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined()
    }

    public var toolUses: [(id: String, name: String, input: JSONValue)] {
        blocks.compactMap {
            if case .toolUse(let id, let name, let input) = $0 { return (id, name, input) }
            return nil
        }
    }

    /// Whether this turn asked for tools and is therefore waiting on results.
    public var awaitsToolResults: Bool { !toolUses.isEmpty }
}

/// What a tool looks like to a model. The schema is the model's only
/// documentation, so it carries the descriptions rather than a separate doc.
public struct ToolDefinition: Sendable, Hashable {
    public let name: String
    public let description: String
    /// A JSON Schema object describing the arguments.
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// How hard the model should think before answering.
///
/// The two providers spell this differently — Anthropic takes a token budget,
/// OpenAI takes a named effort — so the app carries the intent and each provider
/// translates. Keeping the app's own vocabulary means a third provider does not
/// force a migration of stored settings.
public enum ThinkingEffort: String, Sendable, Codable, CaseIterable, Hashable {
    case off
    case low
    case medium
    case high

    /// Anthropic's `thinking.budget_tokens`. `nil` disables extended thinking.
    public var tokenBudget: Int? {
        switch self {
        case .off: return nil
        case .low: return 4_000
        case .medium: return 10_000
        case .high: return 24_000
        }
    }

    /// OpenAI's `reasoning_effort`. `nil` omits the field entirely, which is
    /// required for models that reject it.
    public var openAIEffort: String? {
        switch self {
        case .off: return nil
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }
}

/// What the app asks a provider for.
public struct CompletionRequest: Sendable {
    public var model: String
    public var system: String?
    public var messages: [ChatMessage]
    public var tools: [ToolDefinition]
    public var maxTokens: Int
    public var thinking: ThinkingEffort

    public init(
        model: String,
        system: String? = nil,
        messages: [ChatMessage],
        tools: [ToolDefinition] = [],
        maxTokens: Int = 8_192,
        thinking: ThinkingEffort = .off
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.thinking = thinking
    }
}

/// Why a turn ended. `toolUse` is the one that drives the agent loop: it means
/// the model is waiting for results, not that it has finished.
public enum StopReason: String, Sendable, Hashable {
    case endTurn
    case toolUse
    case maxTokens
    case stopSequence
    case refusal
    /// The provider sent something this app does not know about. Kept rather
    /// than mapped to `endTurn` so an unexpected value cannot masquerade as a
    /// clean finish.
    case other
}

public struct TokenUsage: Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// Tokens served from the provider's prompt cache, when it reports them.
    public var cacheReadTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
    }

    public var total: Int { inputTokens + outputTokens }
}

/// One thing that happened while a turn streamed.
///
/// Deltas rather than snapshots: the UI appends, so a dropped event shows up as
/// missing text rather than as text that silently rewinds.
public enum StreamEvent: Sendable, Hashable {
    case textDelta(String)
    case thinkingDelta(String)
    /// A tool call has begun. Its arguments arrive as `toolInputDelta`s and are
    /// only parseable once `toolUseEnded` lands.
    case toolUseStarted(id: String, name: String)
    case toolInputDelta(id: String, json: String)
    case toolUseEnded(id: String)
    case finished(stopReason: StopReason, usage: TokenUsage)
}

/// A model the user can pick.
public struct ModelInfo: Sendable, Hashable, Identifiable, Comparable {
    public var id: String
    public var displayName: String

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName ?? id
    }

    public static func < (a: ModelInfo, b: ModelInfo) -> Bool { a.id < b.id }
}

/// What went wrong, in terms the panel can turn into something actionable.
///
/// Deliberately not a passthrough of the provider's message: "401" tells a
/// person nothing, while "the key was rejected" tells them which of the four
/// things in front of them to change.
public enum ProviderError: Error, Sendable, Equatable {
    case missingKey
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case contextTooLong
    /// The model refused the thinking/reasoning parameter.
    ///
    /// Its own case because it is the one 400 worth retrying: the request is
    /// otherwise fine and succeeds without that one field. Measured against
    /// `gpt-4.1-mini`, which answers `Unrecognized request argument supplied:
    /// reasoning_effort` rather than ignoring it.
    case unsupportedThinking
    case serverError(status: Int, body: String)
    case network(String)
    case decoding(String)
    /// The user pressed stop. Distinct from a failure so the transcript keeps
    /// what had already streamed instead of showing an error over it.
    case cancelled

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .network: return true
        case .serverError(let status, _): return status >= 500
        default: return false
        }
    }
}

/// A source of completions. Two implementations today, both over HTTP.
public protocol ModelProvider: Sendable {
    /// A stable identifier for settings storage, e.g. `anthropic`.
    var identifier: String { get }

    /// Streams one turn. The stream finishes after a `.finished` event, or
    /// throws a `ProviderError`.
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error>

    /// What this endpoint offers. Asked rather than hard-coded: a baked-in list
    /// is wrong the day a model ships, and custom endpoints (Ollama, a proxy)
    /// serve models this app has never heard of.
    func models() async throws -> [ModelInfo]
}
