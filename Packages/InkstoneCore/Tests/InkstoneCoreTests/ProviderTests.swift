import Testing
import Foundation
@testable import InkstoneCore

/// The SSE rules, which are the part of streaming worth getting right and the
/// only part testable without a network.
@Suite("Server-sent events")
struct ServerSentEventTests {
    /// Feeds lines and collects whatever dispatched, including at close.
    private func events(_ lines: [String]) -> [SSEEvent] {
        var parser = SSEParser()
        var out = lines.compactMap { parser.consume(line: $0) }
        if let last = parser.finish() { out.append(last) }
        return out
    }

    @Test("A blank line dispatches the event")
    func dispatchesOnBlankLine() {
        let found = events(["event: ping", "data: {\"a\":1}", ""])
        #expect(found.count == 1)
        #expect(found[0].name == "ping")
        #expect(found[0].data == "{\"a\":1}")
    }

    @Test("Exactly one leading space is stripped, and only one")
    func stripsOneSpace() {
        // Two spaces means the payload legitimately starts with a space, and
        // eating both would corrupt any provider that pads its JSON.
        #expect(events(["data:  x", ""])[0].data == " x")
        #expect(events(["data:x", ""])[0].data == "x")
    }

    @Test("Comment lines are not data")
    func ignoresComments() {
        // Providers send `:` lines as keep-alives. Treating one as data would
        // put an empty fragment into the transcript.
        let found = events([": keep-alive", "data: real", ""])
        #expect(found.count == 1)
        #expect(found[0].data == "real")
    }

    @Test("Several data lines join with a newline")
    func joinsDataLines() {
        #expect(events(["data: one", "data: two", ""])[0].data == "one\ntwo")
    }

    @Test("A trailing CR is not part of the payload")
    func toleratesCRLF() {
        // `AsyncBytes.lines` splits on LF, so a CRLF server leaves a stray CR
        // that would otherwise land inside the JSON and fail to parse.
        #expect(events(["data: {\"a\":1}\r", "\r"])[0].data == "{\"a\":1}")
    }

    @Test("A stream that ends without a blank line still delivers its last event")
    func dispatchesAtClose() {
        // This is the one that loses real text: the final chunk of an answer is
        // exactly what goes missing when a connection closes abruptly.
        let found = events(["data: last"])
        #expect(found.count == 1)
        #expect(found[0].data == "last")
    }

    @Test("A blank line with nothing buffered dispatches nothing")
    func ignoresEmptyDispatch() {
        #expect(events(["", "", ""]).isEmpty)
    }
}

@Suite("Anthropic provider")
struct AnthropicProviderTests {
    private let provider = AnthropicProvider(
        configuration: .init(apiKey: "test-key"))

    private func body(_ request: CompletionRequest) throws -> [String: Any] {
        try provider.requestBody(for: request)
    }

    @Test("Thinking raises max_tokens above the budget")
    func leavesRoomToAnswer() throws {
        // The server rejects a request whose budget meets or exceeds max_tokens.
        // Both were asked for, and the only sensible reconciliation is room to
        // actually answer after thinking.
        let json = try body(CompletionRequest(
            model: "m", messages: [.init(role: .user, text: "hi")],
            maxTokens: 1_000, thinking: .high))
        let budget = (json["thinking"] as? [String: Any])?["budget_tokens"] as? Int
        #expect(budget == 24_000)
        #expect((json["max_tokens"] as? Int ?? 0) > budget!)
    }

    @Test("Thinking off sends no thinking field at all")
    func omitsThinkingWhenOff() throws {
        let json = try body(CompletionRequest(
            model: "m", messages: [.init(role: .user, text: "hi")], thinking: .off))
        #expect(json["thinking"] == nil)
        #expect(json["max_tokens"] as? Int == 8_192)
    }

    @Test("Thinking blocks are never sent back")
    func dropsThinkingFromHistory() throws {
        // Replaying reasoning as ordinary text both confuses the model about
        // what it said and pays for tokens it does not need to re-read.
        let history = ChatMessage(role: .assistant, blocks: [
            .thinking("私は考えている"), .text("answer"),
        ])
        let json = try body(CompletionRequest(model: "m", messages: [history]))
        let messages = json["messages"] as! [[String: Any]]
        let blocks = messages[0]["content"] as! [[String: Any]]
        #expect(blocks.count == 1)
        #expect(blocks[0]["text"] as? String == "answer")
    }

    @Test("A tool result carries its error flag")
    func marksFailedToolResults() throws {
        let turn = ChatMessage(role: .user, blocks: [
            .toolResult(id: "t1", content: "no such note", isError: true),
        ])
        let json = try body(CompletionRequest(model: "m", messages: [turn]))
        let blocks = (json["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        #expect(blocks[0]["is_error"] as? Bool == true)
        #expect(blocks[0]["tool_use_id"] as? String == "t1")
    }

    // MARK: - Decoding

    /// Runs recorded events through the decoder, the way the network would.
    private func decode(_ payloads: [String]) -> (events: [StreamEvent], sawStop: Bool) {
        var decoder = AnthropicProvider.StreamDecoder()
        var out: [StreamEvent] = []
        for payload in payloads {
            out += decoder.decode(SSEEvent(name: "", data: payload))
        }
        return (out, decoder.sawMessageStop)
    }

    @Test("Text deltas come out in order")
    func decodesText() {
        let (events, stopped) = decode([
            #"{"type":"message_start","message":{"usage":{"input_tokens":12}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"He"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"llo"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
            #"{"type":"message_stop"}"#,
        ])
        #expect(stopped)
        #expect(events.prefix(2) == [.textDelta("He"), .textDelta("llo")])
        guard case .finished(let reason, let usage) = events.last else {
            Issue.record("no finish"); return
        }
        #expect(reason == .endTurn)
        // Input arrives on message_start and output on message_delta; a decoder
        // that replaced usage instead of merging would report zero input.
        #expect(usage.inputTokens == 12)
        #expect(usage.outputTokens == 5)
    }

    @Test("A tool call is announced before its arguments arrive")
    func decodesToolUse() {
        // The ordering rule: `content_block_start` names the tool, and the
        // arguments then stream as fragments that are only valid JSON at the end.
        let (events, _) = decode([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"search_notes"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"tea\"}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            #"{"type":"message_stop"}"#,
        ])
        #expect(events[0] == .toolUseStarted(id: "tu_1", name: "search_notes"))
        let fragments = events.compactMap { event -> String? in
            if case .toolInputDelta(_, let json) = event { return json }
            return nil
        }
        #expect(JSONValue.parse(fragments.joined())?["query"]?.stringValue == "tea")
        #expect(events.contains(.toolUseEnded(id: "tu_1")))
        guard case .finished(let reason, _) = events.last else { Issue.record("no finish"); return }
        // The reason the agent loop exists: the turn is waiting, not done.
        #expect(reason == .toolUse)
    }

    @Test("Two tool calls in one turn keep their own arguments")
    func separatesConcurrentToolCalls() {
        // Fragments are addressed by block index, not by id, so a decoder that
        // tracked only the most recent call would splice the two together.
        let (events, _) = decode([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"a","name":"read"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"b","name":"read"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"B"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"A"}}"#,
        ])
        let byID = events.reduce(into: [String: String]()) { acc, event in
            if case .toolInputDelta(let id, let json) = event { acc[id, default: ""] += json }
        }
        #expect(byID == ["a": "A", "b": "B"])
    }

    @Test("A truncated stream is not reported as a clean finish")
    func detectsTruncation() {
        let (_, stopped) = decode([
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"half"}}"#,
        ])
        // The provider turns this into an error rather than letting the panel
        // believe the answer ended where the connection did.
        #expect(!stopped)
    }

    @Test("HTTP failures become something a person can act on")
    func mapsErrors() {
        #expect(AnthropicProvider.error(status: 401, body: "", headers: [:]) == .unauthorized)
        #expect(AnthropicProvider.error(status: 429, body: "", headers: ["retry-after": "30"])
                == .rateLimited(retryAfter: 30))
        #expect(AnthropicProvider.error(status: 400, body: "prompt is too long", headers: [:])
                == .contextTooLong)
        #expect(AnthropicProvider.error(status: 500, body: "boom", headers: [:]).isRetryable)
        #expect(!AnthropicProvider.error(status: 401, body: "", headers: [:]).isRetryable)
    }
}

@Suite("OpenAI-compatible provider")
struct OpenAICompatibleProviderTests {
    private let provider = OpenAICompatibleProvider(
        configuration: .init(apiKey: "test-key"))

    @Test("Tool results become their own messages, before the turn they answer")
    func flattensToolResults() {
        // The structural disagreement between the two APIs: Anthropic nests a
        // result inside a user turn, OpenAI wants a top-level `role: "tool"`.
        let messages = OpenAICompatibleProvider.wireMessages(CompletionRequest(
            model: "m",
            messages: [
                ChatMessage(role: .assistant, blocks: [
                    .toolUse(id: "t1", name: "search", input: .object(["q": .string("x")])),
                ]),
                ChatMessage(role: .user, blocks: [
                    .toolResult(id: "t1", content: "found", isError: false),
                    .text("thanks"),
                ]),
            ]))
        #expect(messages.map { $0["role"] as! String } == ["assistant", "tool", "user"])
        #expect(messages[1]["tool_call_id"] as? String == "t1")
        #expect(messages[2]["content"] as? String == "thanks")
    }

    @Test("An assistant turn that only calls tools still carries content")
    func alwaysSendsContent() {
        // Strict endpoints reject an assistant message with no `content` key.
        let messages = OpenAICompatibleProvider.wireMessages(CompletionRequest(
            model: "m",
            messages: [ChatMessage(role: .assistant, blocks: [
                .toolUse(id: "t1", name: "search", input: .object([:])),
            ])]))
        #expect(messages[0]["content"] as? String == "")
        #expect((messages[0]["tool_calls"] as? [[String: Any]])?.count == 1)
    }

    @Test("Plain text is sent as a string, not a one-element array")
    func sendsPlainTextPlainly() {
        // Some compatible servers only accept the array form for multimodal
        // input and reject it for ordinary text.
        let messages = OpenAICompatibleProvider.wireMessages(CompletionRequest(
            model: "m", messages: [.init(role: .user, text: "hi")]))
        #expect(messages[0]["content"] as? String == "hi")
    }

    @Test("An image turn uses the array form")
    func sendsImagesAsParts() {
        let messages = OpenAICompatibleProvider.wireMessages(CompletionRequest(
            model: "m",
            messages: [ChatMessage(role: .user, blocks: [
                .text("what is this"),
                .image(mimeType: "image/png", data: Data([0x89, 0x50])),
            ])]))
        let parts = messages[0]["content"] as! [[String: Any]]
        #expect(parts.count == 2)
        let url = (parts[1]["image_url"] as! [String: Any])["url"] as! String
        #expect(url.hasPrefix("data:image/png;base64,"))
    }

    @Test("A system prompt leads the message list")
    func putsSystemFirst() {
        let messages = OpenAICompatibleProvider.wireMessages(CompletionRequest(
            model: "m", system: "be brief", messages: [.init(role: .user, text: "hi")]))
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "be brief")
    }

    @Test("reasoning_effort is omitted unless asked for")
    func omitsEffortWhenOff() throws {
        // A model that does not reason rejects the field outright, and every
        // local endpoint is such a model.
        let off = try provider.requestBody(for: CompletionRequest(
            model: "m", messages: [.init(role: .user, text: "hi")], thinking: .off))
        #expect(off["reasoning_effort"] == nil)

        let high = try provider.requestBody(for: CompletionRequest(
            model: "m", messages: [.init(role: .user, text: "hi")], thinking: .high))
        #expect(high["reasoning_effort"] as? String == "high")
    }

    // MARK: - Decoding

    private func decode(_ payloads: [String]) -> [StreamEvent] {
        var decoder = OpenAICompatibleProvider.StreamDecoder()
        var out: [StreamEvent] = []
        for payload in payloads {
            out += decoder.decode(SSEEvent(name: "", data: payload))
        }
        return out + decoder.finish()
    }

    @Test("Text and usage decode, and [DONE] is not data")
    func decodesText() {
        let events = decode([
            #"{"choices":[{"delta":{"content":"Hi"}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":2}}"#,
            "[DONE]",
        ])
        #expect(events.first == .textDelta("Hi"))
        guard case .finished(let reason, let usage) = events.last else {
            Issue.record("no finish"); return
        }
        #expect(reason == .endTurn)
        #expect(usage.inputTokens == 9)
        #expect(usage.outputTokens == 2)
    }

    @Test("A tool call is assembled from fragments that only carry an index")
    func decodesToolCalls() {
        // After the first chunk OpenAI identifies a call by position alone —
        // no id, no name, just `index` and more `arguments`.
        let events = decode([
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"search_notes","arguments":""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"q\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"tea\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ])
        #expect(events.first == .toolUseStarted(id: "call_1", name: "search_notes"))
        let assembled = events.compactMap { event -> String? in
            if case .toolInputDelta(_, let json) = event { return json }
            return nil
        }.joined()
        #expect(JSONValue.parse(assembled)?["q"]?.stringValue == "tea")
        #expect(events.contains(.toolUseEnded(id: "call_1")))
        guard case .finished(let reason, _) = events.last else { Issue.record("no finish"); return }
        #expect(reason == .toolUse)
    }

    @Test("A tool call is not announced before its name is known")
    func waitsForToolName() {
        // A start event with an empty name renders as a blank row in the panel.
        let events = decode([
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"arguments":""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"read_note"}}]}}]}"#,
        ])
        #expect(events.first == .toolUseStarted(id: "c1", name: "read_note"))
    }

    @Test("Reasoning on non-standard fields is kept, not dropped")
    func decodesReasoningContent() {
        // DeepSeek-style endpoints put chain-of-thought here. Dropping it would
        // silently discard half of what the user paid for.
        #expect(decode([#"{"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#]).first
                == .thinkingDelta("hmm"))
        #expect(decode([#"{"choices":[{"delta":{"reasoning":"hmm"}}]}"#]).first
                == .thinkingDelta("hmm"))
    }

    @Test("A stream that just stops still finishes exactly once")
    func synthesisesFinish() {
        // Unlike Anthropic there is no terminal event, and not every compatible
        // server even sends [DONE]. Ending is normal; ending twice is not.
        var decoder = OpenAICompatibleProvider.StreamDecoder()
        let first = decoder.finish()
        let second = decoder.finish()
        #expect(first.count == 1)
        #expect(second.isEmpty)
    }
}

@Suite("JSON values")
struct JSONValueTests {
    @Test("Round-trips through a string")
    func roundTrips() {
        let value = JSONValue.object([
            "s": .string("x"), "n": .number(3), "b": .bool(true),
            "a": .array([.number(1), .null]),
        ])
        #expect(JSONValue.parse(value.jsonString) == value)
    }

    @Test("Whole numbers survive as integers in a request body")
    func keepsIntegersIntegral() {
        // `JSONSerialization` writes a Double 3.0 as `3.0`, and a schema that
        // says `"maxLength": 3.0` is rejected by at least one provider.
        let body = JSONValue.object(["limit": .number(20)]).anyValue as! [String: Any]
        #expect(body["limit"] as? Int == 20)
    }

    @Test("Fragments that are not yet valid JSON parse as nil, not as junk")
    func rejectsPartialJSON() {
        #expect(JSONValue.parse("{\"q\":") == nil)
    }
}

/// Line splitting, which is where the first real bug lived.
///
/// Every unit test above passed while no provider could complete a single call,
/// because they all fed the parser lines by hand and the real code got its lines
/// from `URLSession.AsyncBytes.lines` — which never yields an empty line. SSE
/// dispatches on empty lines, so nothing was ever dispatched. These tests hold
/// the seam that had no test at all.
@Suite("SSE line splitting")
struct SSELineTests {
    /// An async byte sequence over a fixed buffer, standing in for the network.
    private struct Bytes: AsyncSequence, Sendable {
        typealias Element = UInt8
        let data: [UInt8]
        struct AsyncIterator: AsyncIteratorProtocol {
            var remaining: ArraySlice<UInt8>
            mutating func next() async throws -> UInt8? {
                guard let first = remaining.first else { return nil }
                remaining = remaining.dropFirst()
                return first
            }
        }
        func makeAsyncIterator() -> AsyncIterator { AsyncIterator(remaining: data[...]) }
    }

    private func split(_ text: String) async throws -> [String] {
        var lines: [String] = []
        for try await line in SSELines(Bytes(data: Array(text.utf8))) { lines.append(line) }
        return lines
    }

    @Test("Empty lines survive, which is the whole point")
    func keepsEmptyLines() async throws {
        let lines = try await split("event: a\ndata: 1\n\nevent: b\ndata: 2\n\n")
        #expect(lines == ["event: a", "data: 1", "", "event: b", "data: 2", ""])
    }

    @Test("A real two-event stream reaches the parser as two events")
    func endToEndThroughTheParser() async throws {
        // The assertion that would have caught the bug: not "are the lines
        // right" but "does anything come out the far end".
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for try await line in SSELines(Bytes(data: Array(
            "event: message_start\ndata: {\"a\":1}\n\nevent: message_stop\ndata: {\"b\":2}\n\n".utf8))) {
            if let event = parser.consume(line: line) { events.append(event) }
        }
        #expect(events.count == 2)
        #expect(events[0].name == "message_start")
        #expect(events[1].data == "{\"b\":2}")
    }

    @Test("A trailing line with no newline is still delivered")
    func keepsUnterminatedTail() async throws {
        #expect(try await split("data: x") == ["data: x"])
    }

    @Test("Consecutive blank lines are all reported")
    func keepsRepeatedBlanks() async throws {
        #expect(try await split("\n\n\n") == ["", "", ""])
    }

    @Test("Multi-byte characters are not split across the buffer")
    func handlesUTF8() async throws {
        // Byte-at-a-time splitting has to reassemble before decoding, or a CJK
        // answer arrives as replacement characters.
        #expect(try await split("data: 墨砚\n") == ["data: 墨砚"])
    }

    @Test("An empty stream yields nothing rather than one empty line")
    func handlesEmptyInput() async throws {
        #expect(try await split("").isEmpty)
    }
}
