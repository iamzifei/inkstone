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
/// and the reading view style again.
///
/// While a block is being typed in, each version is new code and a cache miss.
/// Rather than flash back to plain for a beat on every keystroke, the block
/// keeps the colours of its last version (`block:`) until the new ones land,
/// and only its newest version waits in the queue.
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
    /// Large enough that a long note's blocks do not evict one another and
    /// colour round and round.
    private let limit = 4_096
    private var pending: Set<Key> = []
    /// Languages highlight.js does not know; asked once, then left plain.
    private var unknown: Set<String> = []
    /// The latest version asked for, per block, while it waits: a newer one
    /// replaces it rather than queueing behind it.
    private var latest: [Int: Key] = [:]
    /// Each block's last coloured version, shown while its next one is worked out.
    private var recent: [Int: (code: String, spans: [Span])] = [:]

    private let queue = DispatchQueue(label: "com.orris.inkstone.code-highlighter", qos: .userInitiated)
    /// Created on `queue` and only ever used there.
    private var engine: CodeHighlighting.Engine?
    private var engineFailed = false

    private init() {}

    /// The coloured runs of a block of code, or nil while they are being worked
    /// out (or for a language with none). Cheap enough to call on every pass.
    ///
    /// - Parameter block: a stable identity for the block on screen (where it
    ///   starts), so a block being edited keeps its colours between versions.
    func spans(code: String, language: String?, block: Int? = nil) -> [Span]? {
        guard let language = CodeHighlighting.normalised(language), !code.isEmpty,
              (code as NSString).length <= Self.maximumLength else { return nil }
        let key = Key(language: language, code: code)
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] {
            if let block { recent[block] = (code, hit) }
            return hit
        }
        if unknown.contains(language) { return nil }
        if let block { latest[block] = key }
        if !pending.contains(key) {
            pending.insert(key)
            queue.async { [weak self] in self?.work(key, block: block) }
        }
        // The previous version's colours, cut to this version's length.
        guard let block, let last = recent[block] else { return nil }
        let length = (code as NSString).length
        return last.spans.filter { NSMaxRange($0.range) <= length }
    }

    /// For export: the block coloured now, on the calling thread's wait. Within
    /// the same length cap; the result is cached, and no restyle is posted.
    func spansNow(code: String, language: String?) -> [Span]? {
        guard let language = CodeHighlighting.normalised(language), !code.isEmpty,
              (code as NSString).length <= Self.maximumLength else { return nil }
        let key = Key(language: language, code: code)
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        let known = !unknown.contains(language)
        lock.unlock()
        guard known else { return nil }
        let spans = queue.sync { loadedEngine()?.spans(code: code, language: language) }
        store(spans, for: key)
        return spans
    }

    // MARK: - Work (on `queue`)

    private func work(_ key: Key, block: Int?) {
        // A newer version of the same block arrived while this one waited:
        // skip it; the newer one has its own job.
        lock.lock()
        let superseded = block.map { latest[$0] != nil && latest[$0] != key } ?? false
        lock.unlock()
        if superseded {
            lock.lock(); pending.remove(key); lock.unlock()
            return
        }
        let spans = loadedEngine()?.spans(code: key.code, language: key.language)
        store(spans, for: key)
        lock.lock()
        pending.remove(key)
        if let block, latest[block] == key { latest[block] = nil }
        lock.unlock()
        guard spans != nil else { return }
        DispatchQueue.main.async {
            // The same "something drawn asynchronously is ready, style again"
            // signal decoded pictures send: the editor and the reading view
            // already debounce it into one restyle.
            NotificationCenter.default.post(name: AttachmentImageCache.didDecode, object: nil)
        }
    }

    private func store(_ spans: [Span]?, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        guard let spans else {
            // Only a language highlight.js does not know comes back nil.
            unknown.insert(key.language)
            return
        }
        if cache[key] == nil { order.append(key) }
        cache[key] = spans
        if order.count > limit { cache.removeValue(forKey: order.removeFirst()) }
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
