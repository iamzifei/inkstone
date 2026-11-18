import Foundation

/// The parsed index, kept on disk between launches.
///
/// Opening a vault used to parse every note again: 2.2 s for a 9,852-note
/// vault on a Mac, 3-4 s on an iPhone. With the previous parse to hand, the
/// builder re-reads only notes whose modification date changed (and any
/// touched within 3 s of the previous build) — measured 0.33 s for the same
/// vault. Only the per-note metadata is stored; links, backlinks and tag
/// counts are assembled from it as on every build.
///
/// `parserVersion` should change whenever parsing might: a cache written by a
/// different version is ignored rather than trusted. A file that cannot be
/// read or decoded is ignored too — the cost of a bad cache is one full build.
public enum IndexCache {
    private static let format = 2

    /// Notes are stored as independently encoded chunks so they can be decoded
    /// in parallel: decoding 9,852 notes in one piece took 520 ms (binary
    /// plist) or 294 ms (JSON), longer than the rebuild it saves.
    private struct Stored: Codable {
        var format: Int
        var parserVersion: String
        var buildStarted: Date
        var chunks: [Data]
    }
    private static let chunkCount = 8

    public static func save(_ snapshot: IndexSnapshot, to url: URL, parserVersion: String) throws {
        guard let started = snapshot.buildStarted else { return }
        let notes = Array(snapshot.notes.values)
        let size = max(1, (notes.count + chunkCount - 1) / chunkCount)
        let encoder = JSONEncoder()
        // YAML can say .nan or .inf; JSON cannot, and a throw here meant that
        // vault never got a cache.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
        let chunks = try stride(from: 0, to: notes.count, by: size).map {
            try encoder.encode(Array(notes[$0..<min($0 + size, notes.count)]))
        }
        let stored = Stored(format: format, parserVersion: parserVersion, buildStarted: started, chunks: chunks)
        let plist = PropertyListEncoder()
        plist.outputFormat = .binary
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.encode(stored).write(to: url, options: .atomic)
    }

    /// A snapshot carrying only the notes and when they were read — enough
    /// for `IndexBuilder.build(vaultRoot:reusing:)`, not to be published.
    public static func load(from url: URL, parserVersion: String) async -> IndexSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let stored = try? PropertyListDecoder().decode(Stored.self, from: data),
              stored.format == format, stored.parserVersion == parserVersion else { return nil }
        let decoded: [[NoteMetadata]?] = await withTaskGroup(of: (Int, [NoteMetadata]?).self) { group in
            for (index, chunk) in stored.chunks.enumerated() {
                group.addTask {
                    let decoder = JSONDecoder()
                    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                        positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
                    return (index, try? decoder.decode([NoteMetadata].self, from: chunk))
                }
            }
            var parts = [[NoteMetadata]?](repeating: nil, count: stored.chunks.count)
            for await (index, notes) in group { parts[index] = notes }
            return parts
        }
        // One bad chunk means the whole cache is untrustworthy.
        guard !decoded.contains(where: { $0 == nil }) else { return nil }
        var snapshot = IndexSnapshot()
        snapshot.notes = Dictionary(decoded.flatMap { $0! }.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        snapshot.buildStarted = stored.buildStarted
        return snapshot
    }
}
