import Foundation

/// One dispatched server-sent event.
public struct SSEEvent: Sendable, Hashable {
    /// The `event:` field. Anthropic sets it; OpenAI does not, leaving it empty.
    public let name: String
    /// The accumulated `data:` fields, newline-joined per the SSE spec.
    public let data: String
}

/// Line-at-a-time SSE parser.
///
/// Split out from both providers because it is the part with rules worth
/// getting right, and the only part testable without a network. The rules are
/// from the WHATWG spec rather than from what one API happened to send:
///
/// - a blank line dispatches whatever has accumulated
/// - a line starting `:` is a comment, and some providers send them as
///   keep-alives; treating one as data would inject junk into the transcript
/// - multiple `data:` lines join with a newline, which matters for any provider
///   that wraps long payloads
/// - a single leading space after the colon is stripped, and only one
public struct SSEParser: Sendable {
    private var name = ""
    private var data: [String] = []

    public init() {}

    /// Feeds one line. Returns an event when that line completes one.
    public mutating func consume(line: String) -> SSEEvent? {
        // Tolerate CRLF: `AsyncBytes.lines` splits on LF, so a server using
        // CRLF leaves a stray CR that would otherwise end up inside the JSON.
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line

        if line.isEmpty {
            defer { name = ""; data = [] }
            guard !data.isEmpty else { return nil }
            return SSEEvent(name: name, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }

        let field: String
        let value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            let after = line.index(after: colon)
            let body = line[after...]
            value = String(body.hasPrefix(" ") ? body.dropFirst() : body)
        } else {
            // A field with no colon is a field with an empty value.
            field = line
            value = ""
        }

        switch field {
        case "event": name = value
        case "data": data.append(value)
        default: break  // `id` and `retry` mean nothing to a request-scoped stream.
        }
        return nil
    }

    /// Dispatches anything still buffered when the connection closes.
    ///
    /// Streams that end without a trailing blank line are common enough that
    /// dropping the last event would lose real text — the final chunk of an
    /// answer is exactly what would go missing.
    public mutating func finish() -> SSEEvent? {
        consume(line: "")
    }
}

/// Splits a byte stream into lines, **including empty ones**.
///
/// `URLSession.AsyncBytes.lines` cannot be used for SSE, and the reason is worth
/// stating because the symptom points somewhere else entirely. Foundation's
/// `AsyncLineSequence` splits on newlines but never yields an empty line — and
/// a blank line is precisely what dispatches an SSE event. Parsing with `lines`
/// therefore accumulates every event of the whole response into one buffer that
/// is dispatched only at close, so a caller sees no text at all and concludes
/// the request failed.
///
/// It was verified as Foundation's behaviour and not the server's: the raw
/// response contains eight `\n\n` sequences that `lines` does not surface.
public struct SSELines<Source: AsyncSequence & Sendable>: AsyncSequence, Sendable
where Source.Element == UInt8, Source.AsyncIterator: Sendable {
    public typealias Element = String

    private let source: Source

    public init(_ source: Source) { self.source = source }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var upstream: Source.AsyncIterator
        var buffer: [UInt8] = []
        var finished = false

        public mutating func next() async throws -> String? {
            guard !finished else { return nil }
            while let byte = try await upstream.next() {
                if byte == 0x0A {  // \n
                    defer { buffer.removeAll(keepingCapacity: true) }
                    return String(decoding: buffer, as: UTF8.self)
                }
                buffer.append(byte)
            }
            finished = true
            // Whatever is left had no trailing newline. Returned rather than
            // dropped, so a stream that ends mid-line still delivers it.
            guard !buffer.isEmpty else { return nil }
            defer { buffer.removeAll(keepingCapacity: true) }
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(upstream: source.makeAsyncIterator())
    }
}
