import Foundation

/// Talks to any OpenAI-compatible `/chat/completions` endpoint.
///
/// Deliberately not called `OpenAI`: the same wire format is spoken by Ollama,
/// LM Studio, OpenRouter, and every proxy in between, and supporting the format
/// rather than the vendor is what lets someone point this at a cheaper or
/// entirely local endpoint without the app knowing.
///
/// That generality costs something, and it is worth naming: this cannot assume
/// any capability. `reasoning_effort` is rejected outright by models that do not
/// reason, and a local 7B may ignore `tools` while still returning 200. So
/// optional fields are omitted rather than defaulted, and the code reads what
/// came back instead of trusting what was asked for.
public struct OpenAICompatibleProvider: ModelProvider {
    public struct Configuration: Sendable, Hashable {
        public var apiKey: String
        /// The API root, without the trailing `/chat/completions`.
        /// Official: `https://api.openai.com/v1`. Ollama: `http://localhost:11434/v1`.
        public var baseURL: URL
        /// A name for settings and error messages, e.g. "Ollama".
        public var label: String
        /// Some gateways want extra headers (OpenRouter asks for a referer).
        public var extraHeaders: [String: String]

        public init(
            apiKey: String,
            baseURL: URL = URL(string: "https://api.openai.com/v1")!,
            label: String = "OpenAI",
            extraHeaders: [String: String] = [:]
        ) {
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.label = label
            self.extraHeaders = extraHeaders
        }
    }

    public var identifier: String { "openai" }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    // MARK: - Request building

    func requestBody(for request: CompletionRequest) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "messages": Self.wireMessages(request),
            // Ask for usage on the final chunk. Harmless where unsupported —
            // an endpoint that does not know the field simply omits the totals,
            // and the panel shows nothing rather than a wrong number.
            "stream_options": ["include_usage": true],
        ]
        // `max_completion_tokens` replaced `max_tokens`, but older and
        // third-party endpoints only accept the old name. The new one is sent
        // because reasoning models reject the old one outright, which is a hard
        // failure, whereas an endpoint that only knows the old name ignores an
        // unknown field.
        body["max_completion_tokens"] = request.maxTokens

        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema.anyValue,
                    ],
                ]
            }
        }
        if let effort = request.thinking.openAIEffort {
            body["reasoning_effort"] = effort
        }
        return body
    }

    /// Flattens the conversation into OpenAI's shape.
    ///
    /// The formats disagree structurally, and this is where that is absorbed:
    /// Anthropic carries tool results as blocks inside a user turn, while OpenAI
    /// wants each result as its own top-level message with `role: "tool"`. One
    /// of our messages can therefore become several.
    static func wireMessages(_ request: CompletionRequest) -> [[String: Any]] {
        var wire: [[String: Any]] = []
        if let system = request.system, !system.isEmpty {
            wire.append(["role": "system", "content": system])
        }
        for message in request.messages {
            switch message.role {
            case .user:
                var parts: [[String: Any]] = []
                for block in message.blocks {
                    switch block {
                    case .text(let text):
                        parts.append(["type": "text", "text": text])
                    case .image(let mime, let data):
                        parts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(mime);base64,\(data.base64EncodedString())"],
                        ])
                    case .toolResult(let id, let content, _):
                        // Flushed before this user turn's own content so results
                        // stay adjacent to the call they answer.
                        wire.append(["role": "tool", "tool_call_id": id, "content": content])
                    case .thinking, .toolUse:
                        continue
                    }
                }
                if !parts.isEmpty {
                    // A lone text part is sent as a plain string: some
                    // OpenAI-compatible servers only accept the array form for
                    // multimodal input and reject it for text.
                    if parts.count == 1, let text = parts[0]["text"] as? String {
                        wire.append(["role": "user", "content": text])
                    } else {
                        wire.append(["role": "user", "content": parts])
                    }
                }

            case .assistant:
                var text = ""
                var calls: [[String: Any]] = []
                for block in message.blocks {
                    switch block {
                    case .text(let piece): text += piece
                    case .toolUse(let id, let name, let input):
                        calls.append([
                            "id": id, "type": "function",
                            "function": ["name": name, "arguments": input.jsonString],
                        ])
                    case .thinking, .toolResult, .image: continue
                    }
                }
                var entry: [String: Any] = ["role": "assistant"]
                // `content` must be present even when empty, or strict endpoints
                // reject an assistant message that only calls tools.
                entry["content"] = text
                if !calls.isEmpty { entry["tool_calls"] = calls }
                wire.append(entry)
            }
        }
        return wire
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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: CompletionRequest,
        into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        // A local endpoint legitimately needs no key, so emptiness is only an
        // error for a host that requires one. Ollama with a demanded key would
        // be a worse bug than a 401 the user can read.
        if configuration.apiKey.isEmpty, configuration.baseURL.host()?.contains("openai.com") == true {
            throw ProviderError.missingKey
        }

        var urlRequest = URLRequest(url: configuration.baseURL.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in configuration.extraHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: try requestBody(for: request))

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network("no HTTP response")
        }
        guard http.statusCode == 200 else {
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
        // Unlike Anthropic there is no terminal event beyond `[DONE]`, and not
        // every compatible server sends even that. So a stream that simply ends
        // is normal here, and the decoder synthesises the finish.
        for produced in decoder.finish() { continuation.yield(produced) }
    }

    static func error(status: Int, body: String, headers: [AnyHashable: Any]) -> ProviderError {
        switch status {
        case 401, 403:
            return .unauthorized
        case 429:
            let retry = (headers["retry-after"] as? String).flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retry)
        case 400 where body.contains("reasoning_effort") && (body.contains("Unrecognized") || body.contains("unsupported") || body.contains("not supported") || body.contains("does not support")):
            return .unsupportedThinking
        case 400 where body.contains("context_length") || body.contains("maximum context"):
            return .contextTooLong
        default:
            return .serverError(status: status, body: body)
        }
    }

    // MARK: - Event decoding

    struct StreamDecoder {
        /// Tool calls accumulate by index, because after the first chunk a call
        /// is identified only by its position — later fragments carry `index`
        /// and `arguments` with no `id`.
        private struct PartialCall {
            var id: String
            var name: String
            var announced = false
        }
        private var calls: [Int: PartialCall] = [:]
        private var usage = TokenUsage()
        private var stopReason: StopReason = .endTurn
        private var finished = false

        mutating func decode(_ event: SSEEvent) -> [StreamEvent] {
            if event.data == "[DONE]" { return [] }
            guard let json = JSONValue.parse(event.data) else { return [] }

            if let u = json["usage"], u != .null { absorb(u) }

            guard let choice = json["choices"]?.arrayValue?.first else { return [] }
            var produced: [StreamEvent] = []

            if let delta = choice["delta"] {
                if let text = delta["content"]?.stringValue, !text.isEmpty {
                    produced.append(.textDelta(text))
                }
                // Non-standard but widely used: DeepSeek-style endpoints put
                // chain-of-thought here. Read because it costs nothing and the
                // alternative is silently dropping half of what the user paid for.
                if let think = delta["reasoning_content"]?.stringValue ?? delta["reasoning"]?.stringValue,
                   !think.isEmpty {
                    produced.append(.thinkingDelta(think))
                }
                if let toolCalls = delta["tool_calls"]?.arrayValue {
                    for call in toolCalls {
                        let index = call["index"]?.intValue ?? 0
                        if calls[index] == nil {
                            calls[index] = PartialCall(
                                id: call["id"]?.stringValue ?? "call_\(index)",
                                name: call["function"]?["name"]?.stringValue ?? "")
                        }
                        if let name = call["function"]?["name"]?.stringValue, !name.isEmpty {
                            calls[index]?.name = name
                        }
                        if let id = call["id"]?.stringValue, !id.isEmpty {
                            calls[index]?.id = id
                        }
                        // Announced only once the name is known: a start event
                        // with an empty name would render as a blank tool row.
                        if var partial = calls[index], !partial.announced, !partial.name.isEmpty {
                            partial.announced = true
                            calls[index] = partial
                            produced.append(.toolUseStarted(id: partial.id, name: partial.name))
                        }
                        if let fragment = call["function"]?["arguments"]?.stringValue,
                           !fragment.isEmpty, let partial = calls[index], partial.announced {
                            produced.append(.toolInputDelta(id: partial.id, json: fragment))
                        }
                    }
                }
            }

            if let reason = choice["finish_reason"]?.stringValue, reason != "null" {
                stopReason = Self.stopReason(reason)
            }
            return produced
        }

        /// Emits the tool-call ends and the finish, once the stream is over.
        mutating func finish() -> [StreamEvent] {
            guard !finished else { return [] }
            finished = true
            var produced: [StreamEvent] = calls.keys.sorted().compactMap { index in
                guard let partial = calls[index], partial.announced else { return nil }
                return .toolUseEnded(id: partial.id)
            }
            produced.append(.finished(stopReason: stopReason, usage: usage))
            return produced
        }

        private mutating func absorb(_ u: JSONValue) {
            if let input = u["prompt_tokens"]?.intValue { usage.inputTokens = input }
            if let output = u["completion_tokens"]?.intValue { usage.outputTokens = output }
            if let cached = u["prompt_tokens_details"]?["cached_tokens"]?.intValue {
                usage.cacheReadTokens = cached
            }
        }

        static func stopReason(_ raw: String) -> StopReason {
            switch raw {
            case "stop": return .endTurn
            case "tool_calls", "function_call": return .toolUse
            case "length": return .maxTokens
            case "content_filter": return .refusal
            default: return .other
            }
        }
    }

    // MARK: - Models

    public func models() async throws -> [ModelInfo] {
        var request = URLRequest(url: configuration.baseURL.appending(path: "models"))
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in configuration.extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

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
            return ModelInfo(id: id)
        }
    }
}
