import Foundation

/// Talks to the Anthropic Messages API.
///
/// Shaped after `GitHubClient`: a `Sendable` struct holding configuration and a
/// session, with the wire types nested privately at their point of use rather
/// than declared as app-wide models. Nothing else in the app should know what
/// Anthropic's JSON looks like.
public struct AnthropicProvider: ModelProvider {
    public struct Configuration: Sendable, Hashable {
        public var apiKey: String
        public var baseURL: URL
        /// Pinned deliberately. The API is versioned by header, and letting this
        /// float would mean a server-side change could alter parsing under us.
        public var version: String

        public init(
            apiKey: String,
            baseURL: URL = URL(string: "https://api.anthropic.com")!,
            version: String = "2023-06-01"
        ) {
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.version = version
        }
    }

    public var identifier: String { "anthropic" }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    // MARK: - Request building

    /// Builds the request body.
    ///
    /// `internal` rather than private so tests can assert on the JSON without a
    /// network. The shape of this dictionary is the contract with the provider,
    /// and it is the part most likely to break silently — a misspelled key is
    /// accepted by `JSONSerialization` and rejected only by the server.
    func requestBody(for request: CompletionRequest) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "stream": true,
            "messages": request.messages.map(Self.wireMessage),
        ]
        if let system = request.system, !system.isEmpty {
            body["system"] = system
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.inputSchema.anyValue,
                ]
            }
        }
        if let budget = request.thinking.tokenBudget {
            // Extended thinking requires max_tokens to exceed the budget, and
            // the server rejects the request otherwise. Raising max_tokens here
            // rather than validating and throwing: the caller asked for both,
            // and the only sensible reconciliation is to leave room to answer.
            body["thinking"] = ["type": "enabled", "budget_tokens": budget]
            if request.maxTokens <= budget {
                body["max_tokens"] = budget + 4_096
            }
        }
        return body
    }

    private static func wireMessage(_ message: ChatMessage) -> [String: Any] {
        var blocks: [[String: Any]] = []
        for block in message.blocks {
            switch block {
            case .text(let text):
                blocks.append(["type": "text", "text": text])
            case .thinking:
                // Not sent back. Replaying thinking as ordinary text would both
                // confuse the model about what it said and burn tokens on
                // reasoning it does not need to re-read.
                continue
            case .toolUse(let id, let name, let input):
                blocks.append(["type": "tool_use", "id": id, "name": name, "input": input.anyValue])
            case .toolResult(let id, let content, let isError):
                var result: [String: Any] = [
                    "type": "tool_result", "tool_use_id": id, "content": content,
                ]
                if isError { result["is_error"] = true }
                blocks.append(result)
            case .image(let mime, let data):
                blocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64", "media_type": mime,
                        "data": data.base64EncodedString(),
                    ],
                ])
            }
        }
        return ["role": message.role.rawValue, "content": blocks]
    }

    // MARK: - Streaming

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch {
                    continuation.finish(throwing: ProviderError.network(error.localizedDescription))
                }
            }
            // Stop means stop: without this the URLSession task keeps streaming
            // (and keeps being billed) after the panel has stopped listening.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: CompletionRequest,
        into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        guard !configuration.apiKey.isEmpty else { throw ProviderError.missingKey }

        var urlRequest = URLRequest(url: configuration.baseURL.appending(path: "v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(configuration.version, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: try requestBody(for: request))

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network("no HTTP response")
        }
        guard http.statusCode == 200 else {
            // The error body arrives on the same stream, so it has to be drained
            // to be read. Bounded, because a proxy that returns an HTML error
            // page could otherwise stream a very large "message".
            var body = ""
            for try await line in SSELines(bytes) where body.count < 4_000 { body += line }
            throw Self.error(status: http.statusCode, body: body, headers: http.allHeaderFields)
        }

        var parser = SSEParser()
        var decoder = StreamDecoder()
        for try await line in SSELines(bytes) {
            try Task.checkCancellation()
            guard let event = parser.consume(line: line) else { continue }
            for produced in decoder.decode(event) { continuation.yield(produced) }
        }
        if let event = parser.finish() {
            for produced in decoder.decode(event) { continuation.yield(produced) }
        }
        // A stream that stops without `message_stop` is a truncated answer, not
        // a finished one. Reporting a synthetic finish here would tell the panel
        // the turn ended cleanly and lose the distinction.
        if !decoder.sawMessageStop {
            throw ProviderError.network("the stream ended before the message did")
        }
    }

    /// Maps a failed response onto something the panel can act on.
    static func error(status: Int, body: String, headers: [AnyHashable: Any]) -> ProviderError {
        switch status {
        case 401, 403:
            return .unauthorized
        case 429:
            let retry = (headers["retry-after"] as? String).flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retry)
        case 400 where body.contains("prompt is too long") || body.contains("context"):
            return .contextTooLong
        default:
            return .serverError(status: status, body: body)
        }
    }

    // MARK: - Event decoding

    /// Turns Anthropic's SSE events into this app's events.
    ///
    /// Separated from the network so the mapping can be tested against recorded
    /// event sequences, which is the only way to cover the ordering rules —
    /// `content_block_start` for a tool arrives before any of its arguments.
    struct StreamDecoder {
        private var toolIDsByIndex: [Int: String] = [:]
        private var usage = TokenUsage()
        private var stopReason: StopReason = .other
        private(set) var sawMessageStop = false

        mutating func decode(_ event: SSEEvent) -> [StreamEvent] {
            guard let json = JSONValue.parse(event.data) else { return [] }
            // The `type` inside the payload is authoritative. The `event:` line
            // repeats it, but only the payload is guaranteed present when a
            // provider proxies the stream without preserving event names.
            switch json["type"]?.stringValue {
            case "content_block_start":
                guard let index = json["index"]?.intValue,
                      let block = json["content_block"] else { return [] }
                if block["type"]?.stringValue == "tool_use",
                   let id = block["id"]?.stringValue,
                   let name = block["name"]?.stringValue {
                    toolIDsByIndex[index] = id
                    return [.toolUseStarted(id: id, name: name)]
                }
                return []

            case "content_block_delta":
                guard let delta = json["delta"] else { return [] }
                switch delta["type"]?.stringValue {
                case "text_delta":
                    guard let text = delta["text"]?.stringValue else { return [] }
                    return [.textDelta(text)]
                case "thinking_delta":
                    guard let text = delta["thinking"]?.stringValue else { return [] }
                    return [.thinkingDelta(text)]
                case "input_json_delta":
                    guard let index = json["index"]?.intValue,
                          let id = toolIDsByIndex[index],
                          let fragment = delta["partial_json"]?.stringValue else { return [] }
                    return [.toolInputDelta(id: id, json: fragment)]
                default:
                    return []
                }

            case "content_block_stop":
                guard let index = json["index"]?.intValue,
                      let id = toolIDsByIndex.removeValue(forKey: index) else { return [] }
                return [.toolUseEnded(id: id)]

            case "message_start":
                if let u = json["message"]?["usage"] { absorb(u) }
                return []

            case "message_delta":
                if let reason = json["delta"]?["stop_reason"]?.stringValue {
                    stopReason = Self.stopReason(reason)
                }
                if let u = json["usage"] { absorb(u) }
                return []

            case "message_stop":
                sawMessageStop = true
                return [.finished(stopReason: stopReason, usage: usage)]

            case "error":
                // Anthropic reports mid-stream failures as an event on a 200
                // response, so this is the only place a rate limit can surface
                // once bytes have started flowing.
                let message = json["error"]?["message"]?.stringValue ?? "unknown error"
                sawMessageStop = true
                return [.finished(stopReason: .other, usage: usage)]
                    + [.textDelta("\n\n⚠︎ \(message)")]

            default:
                return []
            }
        }

        private mutating func absorb(_ u: JSONValue) {
            // Input tokens arrive on message_start, output on message_delta;
            // each event carries only what it knows, so this merges rather than
            // replaces. Overwriting would leave input at zero.
            if let input = u["input_tokens"]?.intValue { usage.inputTokens = input }
            if let output = u["output_tokens"]?.intValue { usage.outputTokens = output }
            if let cached = u["cache_read_input_tokens"]?.intValue { usage.cacheReadTokens = cached }
        }

        static func stopReason(_ raw: String) -> StopReason {
            switch raw {
            case "end_turn": return .endTurn
            case "tool_use": return .toolUse
            case "max_tokens": return .maxTokens
            case "stop_sequence": return .stopSequence
            case "refusal": return .refusal
            default: return .other
            }
        }
    }

    // MARK: - Models

    public func models() async throws -> [ModelInfo] {
        guard !configuration.apiKey.isEmpty else { throw ProviderError.missingKey }
        var request = URLRequest(url: configuration.baseURL.appending(path: "v1/models"))
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(configuration.version, forHTTPHeaderField: "anthropic-version")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network("no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw Self.error(status: http.statusCode,
                             body: String(data: data, encoding: .utf8) ?? "",
                             headers: http.allHeaderFields)
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let entries = json["data"]?.arrayValue else {
            throw ProviderError.decoding("unexpected model list")
        }
        return entries.compactMap { entry in
            guard let id = entry["id"]?.stringValue else { return nil }
            return ModelInfo(id: id, displayName: entry["display_name"]?.stringValue)
        }
    }
}

extension JSONValue {
    /// The `JSONSerialization`-compatible form, for building request bodies.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) : n
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }
}
