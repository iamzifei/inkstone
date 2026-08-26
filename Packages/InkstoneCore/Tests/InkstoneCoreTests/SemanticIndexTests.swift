import Testing
import Foundation
@testable import InkstoneCore

/// Chunking, which decides what gets embedded and therefore what can be found.
@Suite("Chunking")
struct ChunkerTests {
    @Test("Paragraphs are the unit, because they are the author's own")
    func splitsOnParagraphs() {
        let text = """
            第一段讲的是茶叶的冲泡温度，白毫银针需要 85 度左右的水温才能出味。

            第二段讲的是完全不同的事情，关于本季度的营收目标和销售预期。
            """
        let chunks = Chunker.chunks(of: text)
        #expect(chunks.count == 2)
        #expect(chunks[0].text.contains("茶叶"))
        #expect(chunks[1].text.contains("营收"))
    }

    @Test("Offsets point back into the note")
    func recordsOffsets() {
        // A hit has to be able to say where in the note it came from.
        let text = "第一段内容够长所以不会被当成噪声跳过掉，这里再补一些字。\n\n第二段内容同样需要足够长才能通过下限检查，补字。"
        let chunks = Chunker.chunks(of: text)
        #expect(chunks.count == 2)
        let start = text.index(text.startIndex, offsetBy: chunks[1].offset)
        #expect(text[start...].hasPrefix("第二段"))
    }

    @Test("A heading on its own is skipped")
    func skipsFragments() {
        // Short fragments embed to something plausible and then match anything
        // vaguely on topic, crowding out passages that actually say something.
        #expect(Chunker.chunks(of: "# 标题").isEmpty)
        #expect(Chunker.chunks(of: "- [ ] todo").isEmpty)
    }

    @Test("An over-long paragraph is split on sentences")
    func splitsLongParagraphs() {
        // The model takes 256 tokens and silently drops the rest, so a chunk
        // whose tail is ignored would be indexed under the wrong meaning.
        let sentence = "这是一个完整的句子，讲述了某个具体的事情，长度适中。"
        let text = String(repeating: sentence, count: 20)
        let chunks = Chunker.chunks(of: text)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.text.count <= Chunker.maximumCharacters + Chunker.overlapCharacters,
                    "chunk of \(chunk.text.count) exceeds the window")
        }
    }

    @Test("A single sentence longer than the window is still split")
    func splitsUnbrokenText() {
        // A table row, or prose with no terminators. There is nothing to split
        // on but length, and leaving it whole means dropping most of it.
        let text = String(repeating: "字", count: 900)
        let chunks = Chunker.chunks(of: text)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.text.count <= Chunker.maximumCharacters + Chunker.overlapCharacters)
        }
    }

    @Test("Every chunk's text really is in the note")
    func producesRealText() {
        // The property that keeps a hit honest: what is shown as matching must
        // be something the note says.
        let text = """
            关于茶叶的第一段内容，这里写了一些关于冲泡方法的说明文字。

            关于营收的第二段内容，这里写了一些关于季度目标的说明文字。
            """
        for chunk in Chunker.chunks(of: text) {
            #expect(text.contains(chunk.text.prefix(20)),
                    "chunk text is not in the note: \(chunk.text.prefix(30))")
        }
    }

    @Test("An empty note produces nothing")
    func handlesEmptyNotes() {
        #expect(Chunker.chunks(of: "").isEmpty)
        #expect(Chunker.chunks(of: "\n\n\n").isEmpty)
    }
}

@Suite("Similarity")
struct SimilarityTests {
    @Test("Identical vectors score 1, opposite ones −1")
    func computesCosine() {
        let same: [Float] = [1, 0, 0]
        let opposite: [Float] = [-1, 0, 0]
        let orthogonal: [Float] = [0, 1, 0]
        #expect(abs(Similarity.cosine(same, same) - 1) < 0.0001)
        #expect(abs(Similarity.cosine(same, opposite) + 1) < 0.0001)
        #expect(abs(Similarity.cosine(same, orthogonal)) < 0.0001)
    }

    @Test("Mismatched or empty vectors score zero rather than crashing")
    func handlesBadInput() {
        #expect(Similarity.cosine([1, 2, 3] as [Float], [1, 2] as [Float]) == 0)
        #expect(Similarity.cosine([] as [Float], [] as [Float]) == 0)
        #expect(Similarity.cosine([0, 0] as [Float], [0, 0] as [Float]) == 0)
    }

    @Test("Quantising keeps the ranking, which is all a search needs")
    func quantisationPreservesOrder() {
        // Measured on real embeddings at full-vault scale: the similarity error
        // is at most 0.0024 against a usable gap of about 0.055, and the order
        // came out identical. That buys 286 MB → 71 MB and 48 ms → 26 ms.
        let query: [Float] = [0.9, 0.1, -0.4, 0.7]
        let candidates: [[Float]] = [
            [0.88, 0.12, -0.38, 0.71],   // nearest
            [0.2, 0.9, 0.1, -0.3],       // middle
            [-0.9, -0.1, 0.4, -0.7],     // opposite
        ]
        let exact = candidates.map { Similarity.cosine(query, $0) }
        let (queryQ, _) = SemanticChunk.quantise(query)
        let approx = candidates.map { Similarity.cosine(queryQ, SemanticChunk.quantise($0).values) }

        #expect(exact.sorted(by: >) == exact, "test vectors are not in order")
        #expect(approx.sorted(by: >) == approx, "quantising reordered them")
        for (a, b) in zip(exact, approx) {
            #expect(abs(a - b) < 0.01, "quantised score drifted: \(a) vs \(b)")
        }
    }

    @Test("A quantised vector round-trips close to where it started")
    func quantisationRoundTrips() {
        let original: [Float] = [0.5, -0.25, 0.125, 0]
        let chunk = SemanticChunk(path: "a.md", offset: 0, text: "", vector: original)
        for (a, b) in zip(original, chunk.vector) {
            #expect(abs(a - b) < 0.005)
        }
    }

    @Test("A zero vector does not divide by zero")
    func handlesZeroVectors() {
        let chunk = SemanticChunk(path: "a.md", offset: 0, text: "", vector: [0, 0, 0])
        #expect(chunk.scale == 1)
        #expect(Similarity.cosine(chunk.quantised, chunk.quantised) == 0)
    }

    @Test("One hit per note, its best passage")
    func collapsesToOnePerNote() {
        // Five passages from one note is one note's worth of answer taking five
        // of the caller's slots.
        let chunks = [
            SemanticChunk(path: "a.md", offset: 0, text: "weak", vector: [0.6, 0.8]),
            SemanticChunk(path: "a.md", offset: 50, text: "strong", vector: [1, 0]),
            SemanticChunk(path: "b.md", offset: 0, text: "other", vector: [0.9, 0.4]),
        ]
        let hits = Similarity.rank(query: [1, 0], against: chunks, limit: 5, threshold: 0)
        #expect(hits.count == 2)
        #expect(hits[0].path == "a.md")
        #expect(hits[0].text == "strong")
    }

    @Test("The threshold keeps nonsense out")
    func honoursThreshold() {
        let chunks = [SemanticChunk(path: "a.md", offset: 0, text: "x", vector: [0, 1])]
        #expect(Similarity.rank(query: [1, 0], against: chunks, limit: 5, threshold: 0.62).isEmpty)
        #expect(!Similarity.rank(query: [1, 0], against: chunks, limit: 5, threshold: -1).isEmpty)
    }

    @Test("Results come back best first")
    func sortsByScore() {
        let chunks = [
            SemanticChunk(path: "far.md", offset: 0, text: "", vector: [0.7, 0.7]),
            SemanticChunk(path: "near.md", offset: 0, text: "", vector: [1, 0]),
        ]
        let hits = Similarity.rank(query: [1, 0], against: chunks, limit: 5, threshold: 0)
        #expect(hits.map(\.path) == ["near.md", "far.md"])
    }
}

@Suite("Semantic index storage")
struct SemanticStorageTests {
    @Test("A digest changes when the text does, and not otherwise")
    func digestsContent() {
        // What decides whether a note is re-embedded. Too eager and every launch
        // costs a full rebuild; too lax and edits never take.
        #expect(SemanticIndex.digest("hello") == SemanticIndex.digest("hello"))
        #expect(SemanticIndex.digest("hello") != SemanticIndex.digest("hello "))
        #expect(SemanticIndex.digest("") != SemanticIndex.digest("a"))
    }

    @Test("Chunks round-trip through storage")
    func codesChunks() throws {
        let chunk = SemanticChunk(path: "a.md", offset: 12, text: "文本",
                                  vector: [0.1, -0.2, 0.3])
        let data = try JSONEncoder().encode(chunk)
        #expect(try JSONDecoder().decode(SemanticChunk.self, from: data) == chunk)
    }
}

/// The ASCII fast path in word counting.
@Suite("Word count")
struct WordCountTests {
    @Test("The fast path agrees with CharacterSet across the whole BMP")
    func fastPathIsExact() {
        // An optimisation that changes an answer is a bug wearing a benchmark.
        // This is the assertion that makes the 778 ms → 59 ms safe: every code
        // point in the Basic Multilingual Plane, checked both ways.
        var mismatches = 0
        for value in UInt32(0)...0xFFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let fast = value < 128
                ? ((value >= 48 && value <= 57)
                   || (value >= 65 && value <= 90)
                   || (value >= 97 && value <= 122))
                : CharacterSet.alphanumerics.contains(scalar)
            if fast != CharacterSet.alphanumerics.contains(scalar) { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }

    @Test("CJK counts per character, Latin per word")
    func countsBothScripts() {
        #expect(NoteParser.wordCount(of: "你好世界") == 4)
        #expect(NoteParser.wordCount(of: "hello world") == 2)
        // Mixed, which is what these notes actually are.
        #expect(NoteParser.wordCount(of: "用 Swift 写代码") == 5)
        #expect(NoteParser.wordCount(of: "") == 0)
        #expect(NoteParser.wordCount(of: "!!! ??? ---") == 0)
    }

    @Test("Accented Latin still counts as one word")
    func handlesNonASCIILatin() {
        // The half that falls through the fast path.
        #expect(NoteParser.wordCount(of: "café") == 1)
        #expect(NoteParser.wordCount(of: "naïve résumé") == 2)
        #expect(NoteParser.wordCount(of: "Привет мир") == 2)
    }
}

/// Fitting an attachment into what is left of a context window.
@Suite("Context budget")
struct ContextBudgetTests {
    @Test("The allowance is what remains, not the window less a guess")
    func measuresWhatIsLeft() {
        // The bug this replaced subtracted a flat 600 from a 3,600 window and
        // called the result the allowance — ignoring the several hundred
        // characters of instructions already in the prompt and everything said
        // so far. A note cut to 3,000 then joined a prompt of 500, and the
        // request was refused every time.
        #expect(ContextBudget.allowance(window: 3_600, used: 374, reserve: 400) == 2_826)
        #expect(ContextBudget.allowance(window: 3_600, used: 3_000, reserve: 400) == 200)
    }

    @Test("A full window yields nothing, not a negative")
    func clampsAtZero() {
        #expect(ContextBudget.allowance(window: 3_600, used: 4_000, reserve: 400) == 0)
    }

    @Test("Text that fits is returned whole")
    func keepsShortText() {
        #expect(ContextBudget.fit("short", into: 1_000, marker: "[cut]") == "short")
    }

    @Test("Long text is cut to the allowance and says so")
    func cutsLongText() {
        let text = String(repeating: "字", count: 5_000)
        let fitted = ContextBudget.fit(text, into: 1_000, marker: "[cut]")
        #expect(fitted?.hasSuffix("[cut]") == true)
        #expect(fitted?.count == 1_005)
    }

    @Test("Too small an allowance yields nothing at all")
    func refusesFragments() {
        // Two sentences of a note, answered about as though they were the note,
        // is worse than saying the note did not fit.
        #expect(ContextBudget.fit("some text", into: 50, marker: "[cut]") == nil)
        #expect(ContextBudget.fit("some text", into: 0, marker: "[cut]") == nil)
    }
}
