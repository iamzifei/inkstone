import Foundation

/// A `SyntaxScanner` that remembers its last result.
///
/// The editor asks for a highlight pass far more often than the text changes:
/// moving the caret to another line, scrolling into unstyled text, resizing the
/// window, and an asynchronous diagram finishing all re-run it, and none of them
/// alter a character. Each of those used to pay for a full scan of the document
/// on the main thread — measured at 45.9ms median on a 56KB note — for a result
/// that could not have differed from the one just discarded.
///
/// One entry is enough. The editor styles one document at a time; switching tabs
/// costs a single miss and then hits again.
public struct CachingScanner: Sendable {
    private let scanner: SyntaxScanner
    private var text: String?
    private var cached: [SyntaxToken] = []

    /// How many scans were actually performed. The point of this type is to make
    /// that number smaller than the number of calls, so it is worth being able to
    /// assert on.
    public private(set) var scanCount = 0

    public init(engine: SyntaxScanner.Engine = .parser) {
        scanner = SyntaxScanner(engine: engine)
    }

    public mutating func tokens(for text: String) -> [SyntaxToken] {
        // String equality, not a hash. A hash would have to read every byte too,
        // and would still need this comparison afterwards to rule out a
        // collision. For an unchanged document the comparison usually
        // short-circuits on a shared buffer, and at worst it is a memcmp —
        // microseconds against the milliseconds it saves.
        if let previous = self.text, previous == text { return cached }
        scanCount += 1
        let tokens = scanner.scan(text)
        self.text = text
        self.cached = tokens
        return tokens
    }
}
