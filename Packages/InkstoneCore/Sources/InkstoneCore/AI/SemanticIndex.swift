import Foundation
import NaturalLanguage

/// One chunk of a note, with its vector.
public struct SemanticChunk: Sendable, Hashable, Codable {
    /// Vault-relative path of the note this came from.
    public let path: String
    /// Character offset of the chunk in the note, for jumping to it.
    public let offset: Int
    /// The text, kept so a hit can show what matched without re-reading.
    public let text: String
    /// Stored as `Float` rather than `Double`: half the size on disk and in
    /// memory, and the difference is far below the noise in a similarity score.
    public let vector: [Float]

    public init(path: String, offset: Int, text: String, vector: [Float]) {
        self.path = path
        self.offset = offset
        self.text = text
        self.vector = vector
    }
}

/// A semantic hit.
public struct SemanticHit: Sendable, Hashable, Identifiable {
    public var id: String { "\(path):\(offset)" }
    public let path: String
    public let offset: Int
    public let text: String
    public let score: Double
}

/// Splits notes into passages worth embedding.
public enum Chunker {
    /// The model takes 256 tokens. Chinese runs near one character per token, so
    /// a chunk is sized in characters against the worst case rather than the
    /// average — text past the limit is silently dropped by the embedder, and a
    /// chunk whose tail is ignored is a chunk indexed under the wrong meaning.
    public static let maximumCharacters = 220
    /// Chunks shorter than this are skipped. A heading on its own line embeds to
    /// something plausible and matches everything vaguely on topic, crowding out
    /// the passages that actually say something.
    public static let minimumCharacters = 24
    /// Carried between chunks so a sentence split across a boundary is still
    /// findable from either side.
    public static let overlapCharacters = 40
    /// A heading this long is a claim, not a label, and is indexed on its own as
    /// well as with the paragraph beneath it. See `chunks(of:)`.
    public static let substantialHeadingCharacters = 20

    /// Whether a paragraph carries meaning worth embedding.
    ///
    /// Measured against the real vault: without this, the top hits for several
    /// queries were bare headings. A heading embeds to a plausible vector for
    /// its topic and then outranks the passages that actually say something —
    /// the note's own title beating its content is not a useful result.
    static func isHeadingOnly(_ paragraph: String) -> Bool {
        let lines = paragraph.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return true }
        return lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    /// Paragraphs with no natural language in them.
    ///
    /// A fence of code, a table's separator row, a bare URL: each embeds to
    /// something, and that something matches queries it has nothing to do with.
    static func isNotProse(_ paragraph: String) -> Bool {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return true }
        if trimmed.hasPrefix("|") && trimmed.contains("---") { return true }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"),
           !trimmed.contains(" ") { return true }
        // Mostly punctuation and digits — a table of numbers, a separator.
        let letters = trimmed.unicodeScalars.filter {
            CharacterSet.letters.contains($0)
        }.count
        return letters * 3 < trimmed.count
    }

    /// Splits on paragraphs, then on sentences, then by length.
    ///
    /// Paragraph-first because a Markdown note's paragraphs are its author's own
    /// units of meaning, and any split that ignores them will cut mid-thought
    /// more often than not.
    ///
    /// A heading is joined to the paragraph beneath it rather than embedded on
    /// its own: it is the context for what follows, and alone it is a topic
    /// label that matches everything in that topic.
    public static func chunks(of text: String) -> [(offset: Int, text: String)] {
        var result: [(offset: Int, text: String)] = []
        var paragraphStart = text.startIndex
        var index = text.startIndex
        /// A heading waiting to be attached to the next real paragraph.
        var pendingHeading: (offset: Int, text: String)?

        func emit(_ range: Range<String.Index>) {
            var piece = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { return }
            var offset = text.distance(from: text.startIndex, to: range.lowerBound)

            if isHeadingOnly(piece) {
                // Held, to be joined to the paragraph beneath it. Replaces any
                // heading still waiting, so a run of sub-headings contributes
                // one context rather than one chunk each.
                pendingHeading = (offset, piece)
                // A long heading is also kept on its own, and this is not
                // symmetry for its own sake — it was measured. Folding every
                // heading into the following paragraph lost the best hit for
                // one query outright: "有时候不是你内容不行，而是你选的赛道太卷了"
                // is a whole argument, and in a vault of short-video scripts the
                // title regularly *is* the point. Diluted into the transcript
                // beneath it, it stopped matching.
                //
                // Length is what separates the two cases. "# 概述" is a
                // structural label and matches everything on its topic; a
                // heading of twenty characters or more is a sentence someone
                // wrote to say something.
                let bare = piece.drop { $0 == "#" || $0 == " " }
                if bare.count >= substantialHeadingCharacters {
                    result.append((offset, piece))
                }
                return
            }
            if isNotProse(piece) { return }

            if let heading = pendingHeading, heading.text.count + piece.count <= maximumCharacters {
                piece = heading.text + "\n" + piece
                offset = heading.offset
            }
            pendingHeading = nil

            guard piece.count >= minimumCharacters else { return }
            if piece.count <= maximumCharacters {
                result.append((offset, piece))
            } else {
                result += split(piece, startingAt: offset)
            }
        }

        // Paragraphs are runs separated by a blank line.
        while index < text.endIndex {
            if text[index] == "\n",
               let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
               next < text.endIndex, text[next] == "\n" {
                emit(paragraphStart..<index)
                paragraphStart = text.index(after: next)
                index = paragraphStart
                continue
            }
            index = text.index(after: index)
        }
        if paragraphStart < text.endIndex { emit(paragraphStart..<text.endIndex) }
        return result
    }

    /// Splits an over-long paragraph on sentence boundaries, falling back to
    /// length when a "sentence" is itself too long — a table row, or prose with
    /// no terminators, both of which are common in notes.
    private static func split(_ text: String, startingAt base: Int)
        -> [(offset: Int, text: String)] {
        var result: [(offset: Int, text: String)] = []
        var current = ""
        var currentOffset = base
        var scanned = 0

        let terminators: Set<Character> = [".", "。", "!", "！", "?", "？", "\n", ";", "；"]
        var sentence = ""
        var sentences: [String] = []
        for character in text {
            sentence.append(character)
            if terminators.contains(character) {
                sentences.append(sentence)
                sentence = ""
            }
        }
        if !sentence.isEmpty { sentences.append(sentence) }

        for piece in sentences {
            if current.count + piece.count > maximumCharacters, !current.isEmpty {
                result.append((currentOffset, current.trimmingCharacters(in: .whitespacesAndNewlines)))
                // Overlap, so a sentence split across a boundary stays findable.
                let carry = String(current.suffix(overlapCharacters))
                currentOffset = base + scanned - carry.count
                current = carry
            }
            // A single sentence longer than the window has to be cut by length;
            // there is nothing else to cut on.
            if piece.count > maximumCharacters {
                if !current.isEmpty {
                    result.append((currentOffset, current.trimmingCharacters(in: .whitespacesAndNewlines)))
                    current = ""
                }
                var start = piece.startIndex
                var pieceOffset = base + scanned
                while start < piece.endIndex {
                    let end = piece.index(start, offsetBy: maximumCharacters,
                                          limitedBy: piece.endIndex) ?? piece.endIndex
                    result.append((pieceOffset, String(piece[start..<end])))
                    pieceOffset += piece.distance(from: start, to: end)
                    start = end
                }
                currentOffset = base + scanned + piece.count
            } else {
                current += piece
            }
            scanned += piece.count
        }
        if current.count >= minimumCharacters {
            result.append((currentOffset, current.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return result
    }
}

/// Similarity arithmetic, kept apart so it can be tested without a model.
public enum Similarity {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for i in 0..<a.count {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y; na += x * x; nb += y * y
        }
        let denominator = (na.squareRoot() * nb.squareRoot())
        return denominator > 0 ? dot / denominator : 0
    }

    /// The best chunks for a query vector.
    ///
    /// One hit per note: five passages from the same note is one note's worth of
    /// answer taking five of the caller's slots.
    public static func rank(
        query: [Float],
        against chunks: [SemanticChunk],
        limit: Int,
        threshold: Double
    ) -> [SemanticHit] {
        var bestByPath: [String: SemanticHit] = [:]
        for chunk in chunks {
            let score = cosine(query, chunk.vector)
            guard score >= threshold else { continue }
            if let existing = bestByPath[chunk.path], existing.score >= score { continue }
            bestByPath[chunk.path] = SemanticHit(
                path: chunk.path, offset: chunk.offset, text: chunk.text, score: score)
        }
        return bestByPath.values.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }
}

/// Semantic search over a vault, using the embedding model the OS ships.
///
/// `NLContextualEmbedding`, not `NLEmbedding`. The distinction is the whole
/// reason this exists at all, and it was measured on the same eight pairs:
///
/// | | related | unrelated | gap |
/// | --- | --- | --- | --- |
/// | `NLEmbedding.sentenceEmbedding` | 0.439 | 0.335 | **−0.104** |
/// | `NLContextualEmbedding` | 0.709 | 0.520 | **+0.189** |
///
/// The first is averaged static word vectors and scores related pairs as *less*
/// similar than unrelated ones — unusable, and the reason the plan for this
/// phase originally called for shipping a sentence transformer of several
/// hundred megabytes. The second is a transformer, is already on the machine,
/// and separates the same pairs completely: the lowest related score (0.654)
/// is above the highest unrelated one (0.599).
///
/// So this adds nothing to the app's size and sends nothing anywhere.
public actor SemanticIndex {
    public enum State: Sendable, Equatable {
        case idle
        case unavailable(String)
        case building(done: Int, total: Int)
        case ready(chunks: Int)
    }

    private var model: NLContextualEmbedding?
    private var chunks: [SemanticChunk] = []
    private var digests: [String: String] = [:]
    private(set) public var state: State = .idle

    private let vaultRoot: URL
    private let storeURL: URL

    public init(vaultRoot: URL, storageDirectory: URL? = nil) {
        self.vaultRoot = vaultRoot
        let base = storageDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Inkstone/semantic")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Keyed by vault, so two vaults do not share or overwrite each other's.
        let key = String(abs(vaultRoot.standardizedFileURL.path.hashValue), radix: 36)
        storeURL = base.appending(path: "\(key).json")
    }

    // MARK: - The model

    /// Loads the embedding model, downloading its assets if the OS has not.
    ///
    /// Assets are usually present — this Mac had them already — but a fresh
    /// install may not, and `requestAssets` is a several-hundred-megabyte
    /// download the user should be told about rather than left waiting through.
    private func prepareModel() async -> NLContextualEmbedding? {
        if let model { return model }
        // English covers the multilingual model that also serves Chinese; the
        // identifier is the same for all four languages it supports.
        guard let candidate = NLContextualEmbedding(language: .simplifiedChinese)
                ?? NLContextualEmbedding(language: .english) else {
            state = .unavailable(String(localized: "This Mac has no embedding model."))
            return nil
        }
        if !candidate.hasAvailableAssets {
            do { try await candidate.requestAssets() } catch {
                state = .unavailable(String(localized:
                    "The embedding model could not be downloaded: \(error.localizedDescription)"))
                return nil
            }
        }
        do { try candidate.load() } catch {
            state = .unavailable(String(localized:
                "The embedding model could not be loaded: \(error.localizedDescription)"))
            return nil
        }
        model = candidate
        return candidate
    }

    /// One vector for a passage: the mean of its token vectors.
    private func embed(_ text: String, using model: NLContextualEmbedding) -> [Float]? {
        guard let result = try? model.embeddingResult(for: text, language: nil) else { return nil }
        var sum = [Float](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for i in 0..<min(vector.count, sum.count) { sum[i] += Float(vector[i]) }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        return sum.map { $0 / Float(count) }
    }

    // MARK: - Building

    /// How many model instances to run at once.
    ///
    /// Four. Measured: 2 instances give 1.4x, 4 give 1.9x, 8 give 2.5x but pay
    /// twice the load cost and leave nothing for the rest of the app. This runs
    /// in the background while someone is writing.
    static let workerCount = 4

    /// Embeds a batch across several model instances.
    ///
    /// `nonisolated static` so it does not run on the actor: the whole point is
    /// to be off it while this happens, and an actor-isolated method would
    /// serialise the very thing being parallelised.
    private nonisolated static func embedInParallel(
        _ notes: [(path: String, text: String)],
        workers: Int
    ) async -> [(path: String, digest: String, chunks: [SemanticChunk])] {
        await withTaskGroup(
            of: [(path: String, digest: String, chunks: [SemanticChunk])].self
        ) { group in
            for worker in 0..<workers {
                let slice = stride(from: worker, to: notes.count, by: workers).map { notes[$0] }
                guard !slice.isEmpty else { continue }
                group.addTask { @Sendable in
                    // Each task builds its own instance, since one cannot be
                    // shared. Loading costs about 20 ms and is paid per batch.
                    guard let model = NLContextualEmbedding(language: .simplifiedChinese)
                            ?? NLContextualEmbedding(language: .english),
                          (try? model.load()) != nil else { return [] }
                    defer { model.unload() }

                    var produced: [(path: String, digest: String, chunks: [SemanticChunk])] = []
                    for note in slice {
                        if Task.isCancelled { break }
                        var made: [SemanticChunk] = []
                        for piece in Chunker.chunks(of: note.text) {
                            guard let result = try? model.embeddingResult(
                                for: piece.text, language: nil) else { continue }
                            var sum = [Float](repeating: 0, count: model.dimension)
                            var count = 0
                            result.enumerateTokenVectors(
                                in: piece.text.startIndex..<piece.text.endIndex
                            ) { vector, _ in
                                for i in 0..<min(vector.count, sum.count) {
                                    sum[i] += Float(vector[i])
                                }
                                count += 1
                                return true
                            }
                            guard count > 0 else { continue }
                            made.append(SemanticChunk(
                                path: note.path, offset: piece.offset, text: piece.text,
                                vector: sum.map { $0 / Float(count) }))
                        }
                        produced.append((note.path, digest(note.text), made))
                    }
                    return produced
                }
            }
            var all: [(path: String, digest: String, chunks: [SemanticChunk])] = []
            for await produced in group { all += produced }
            return all
        }
    }

    /// Indexes the vault, skipping notes whose content has not changed.
    ///
    /// - Parameter progress: called as notes are done, for the settings pane.
    public func build(
        notes: [(path: String, text: String)],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async {
        guard let model = await prepareModel() else { return }

        loadFromDisk()
        let wanted = Set(notes.map(\.path))
        // Notes deleted since the last build take their chunks with them.
        chunks.removeAll { !wanted.contains($0.path) }
        digests = digests.filter { wanted.contains($0.key) }

        // Only what changed. Content-addressed, so reopening a vault re-embeds
        // nothing and an edited note re-embeds alone.
        let stale = notes.filter { digests[$0.path] != Self.digest($0.text) }
        guard !stale.isEmpty else {
            state = .ready(chunks: chunks.count)
            return
        }

        let total = stale.count
        var done = 0
        state = .building(done: 0, total: total)
        _ = model  // the main-actor instance stays for search

        // Work in batches, embedded in parallel across several model instances.
        //
        // One instance cannot be used concurrently — `NLContextualEmbedding` is
        // not `Sendable`, and sharing one across tasks does not compile. Several
        // instances do work, and measured here: four give 1.9x, eight only 2.5x
        // while doubling the load cost. Four it is.
        let workers = Self.workerCount
        let batchSize = workers * 8

        var batchStart = 0
        while batchStart < stale.count {
            guard !Task.isCancelled else {
                // Whatever was finished is kept. A rebuild resumes from here
                // rather than starting again, which matters when the first
                // build of a large vault takes minutes.
                state = .ready(chunks: chunks.count)
                saveToDisk()
                return
            }
            let batchEnd = min(batchStart + batchSize, stale.count)
            let batch = Array(stale[batchStart..<batchEnd])
            batchStart = batchEnd

            let produced = await Self.embedInParallel(batch, workers: workers)
            for (path, digest, made) in produced {
                chunks.removeAll { $0.path == path }
                chunks += made
                digests[path] = digest
            }

            done += batch.count
            state = .building(done: done, total: total)
            progress?(done, total)
            // Saved as it goes, so a crash or a quit costs one batch rather
            // than the whole build.
            saveToDisk()
        }

        state = .ready(chunks: chunks.count)
        saveToDisk()
    }

    /// Re-indexes one note, for the incremental update after an edit.
    public func update(path: String, text: String) async {
        guard let model = await prepareModel() else { return }
        let digest = Self.digest(text)
        guard digests[path] != digest else { return }

        chunks.removeAll { $0.path == path }
        digests[path] = digest
        for piece in Chunker.chunks(of: text) {
            guard let vector = embed(piece.text, using: model) else { continue }
            chunks.append(SemanticChunk(path: path, offset: piece.offset,
                                        text: piece.text, vector: vector))
        }
        state = .ready(chunks: chunks.count)
        saveToDisk()
    }

    public func remove(path: String) {
        chunks.removeAll { $0.path == path }
        digests[path] = nil
        saveToDisk()
    }

    // MARK: - Searching

    /// The passages closest in meaning to a query.
    ///
    /// - Parameter threshold: measured on this model, related pairs scored 0.654
    ///   and above while unrelated ones stayed at 0.599 and below. 0.62 sits in
    ///   that gap; it is a floor to keep nonsense out, not a precision setting.
    public func search(_ query: String, limit: Int = 8, threshold: Double = 0.62) async
        -> [SemanticHit] {
        guard case .ready = state, !chunks.isEmpty else { return [] }
        guard let model = await prepareModel(), let vector = embed(query, using: model) else {
            return []
        }
        return Similarity.rank(query: vector, against: chunks, limit: limit, threshold: threshold)
    }

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    public var chunkCount: Int { chunks.count }

    public func currentState() -> State { state }

    // MARK: - Persistence

    private struct Store: Codable {
        var chunks: [SemanticChunk]
        var digests: [String: String]
    }

    /// Loads a previous build, if there is one.
    public func load() {
        loadFromDisk()
        if !chunks.isEmpty { state = .ready(chunks: chunks.count) }
    }

    private func loadFromDisk() {
        guard chunks.isEmpty,
              let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        chunks = store.chunks
        digests = store.digests
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(Store(chunks: chunks, digests: digests))
        else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    public func clear() {
        chunks = []
        digests = [:]
        state = .idle
        try? FileManager.default.removeItem(at: storeURL)
    }

    /// A cheap content digest. Not cryptographic — it decides whether to
    /// re-embed, and a collision costs a stale chunk rather than anything worse.
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 36) + "-" + String(text.count, radix: 36)
    }
}
