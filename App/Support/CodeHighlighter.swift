import Foundation
import InkstoneCore

/// Colours fenced code blocks by language.
///
/// highlight.js (the vendored "common" build: 36 languages) running in
/// JavaScriptCore — no web view, no network, no page (`CodeHighlighting` in
/// InkstoneCore). MiaoYan colours code the same way (Highlightr is highlight.js
/// in JavaScriptCore); this keeps only the part that turns code into scoped
/// ranges, and paints them in the editor's own colours.
///
/// Like `MermaidRenderer`, it answers synchronously from a cache and works
/// asynchronously otherwise: the first pass over a block gets nil and queues
/// the work on a background queue; when the result lands, the "draw again"
/// notification (`AttachmentImageCache.didDecode`) is posted and the editor
/// and the reading view style again. A block therefore shows as plain code for
/// one pass and in colour afterwards — including while it is being typed in,
/// each new version once.
final class CodeHighlighter: @unchecked Sendable {
    static let shared = CodeHighlighter()

    typealias Span = CodeHighlighting.Span

    /// Longer blocks are left plain: highlighting cost grows with the block, and
    /// a block this long is data or a log more often than code anyone reads.
    static let maximumLength = 20_000

    private struct Key: Hashable {
        let language: String
        let code: String
    }

    private let lock = NSLock()
    private var cache: [Key: [Span]] = [:]
    private var order: [Key] = []
    private let limit = 512
    private var pending: Set<Key> = []
    /// Languages highlight.js does not know; asked once, then left plain.
    private var unknown: Set<String> = []

    private let queue = DispatchQueue(label: "com.orris.inkstone.code-highlighter", qos: .userInitiated)
    /// Created on `queue` and only ever used there.
    private var engine: CodeHighlighting.Engine?
    private var engineFailed = false

    private init() {}

    /// The coloured runs of a block of code, or nil while they are being worked
    /// out (or for a language with none). Cheap enough to call on every pass.
    func spans(code: String, language: String?) -> [Span]? {
        guard let language = CodeHighlighting.normalised(language), !code.isEmpty,
              (code as NSString).length <= Self.maximumLength else { return nil }
        let key = Key(language: language, code: code)
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        if unknown.contains(language) || pending.contains(key) { lock.unlock(); return nil }
        pending.insert(key)
        lock.unlock()

        queue.async { [weak self] in self?.work(key) }
        return nil
    }

    /// Synchronous, for export: highlights on the calling thread's turn of
    /// the queue and caches the result.
    func spansNow(code: String, language: String?) -> [Span]? {
        if let hit = spans(code: code, language: language) { return hit }
        guard let language = CodeHighlighting.normalised(language) else { return nil }
        return queue.sync { loadedEngine()?.spans(code: code, language: language) }
    }

    // MARK: - Work (on `queue`)

    private func work(_ key: Key) {
        let spans = loadedEngine()?.spans(code: key.code, language: key.language)
        lock.lock()
        pending.remove(key)
        if let spans {
            cache[key] = spans
            order.append(key)
            if order.count > limit { cache.removeValue(forKey: order.removeFirst()) }
        } else {
            unknown.insert(key.language)
        }
        lock.unlock()
        guard spans != nil else { return }
        DispatchQueue.main.async {
            // The same "something drawn asynchronously is ready, style again"
            // signal decoded pictures send: the editor and the reading view
            // already debounce it into one restyle.
            NotificationCenter.default.post(name: AttachmentImageCache.didDecode, object: nil)
        }
    }

    private func loadedEngine() -> CodeHighlighting.Engine? {
        if let engine { return engine }
        guard !engineFailed else { return nil }
        guard let url = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let engine = CodeHighlighting.Engine(source: source) else {
            engineFailed = true
            return nil
        }
        self.engine = engine
        return engine
    }
}

// MARK: - Colours

extension CodeHighlighter {
    /// The colour for a scope, in GitHub's light or dark code palette, or nil
    /// for scopes left in the text colour (operators, punctuation, plain).
    static func color(for scope: String, isDark: Bool) -> PlatformColor? {
        CodeHighlighting.hex(for: scope, isDark: isDark).map { ThemeColor($0).platformColor }
    }
}
