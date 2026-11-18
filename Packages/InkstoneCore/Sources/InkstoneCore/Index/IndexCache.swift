import Foundation
import CryptoKit

/// The index kept on disk between launches, so opening a vault does not
/// re-read and re-parse every note.
///
/// Measured on a 9,894-note vault: the index used to be ready ~1.3 s after
/// the window; with the cache, the snapshot from the last session is shown at
/// once and an incremental build re-parses only the files changed since.
///
/// Stored in the system caches folder, keyed by the vault's path, never
/// inside the vault: a vault is synced (iCloud, GitHub) and a cache is not
/// the user's data. Safe to delete at any time. A cache written by another
/// app version is ignored, since the parser may have changed.
///
/// Correctness comes from `IndexBuilder.build(vaultRoot:reusing:)`: a cached
/// note is reused only if its file's modification date is unchanged and
/// older than the cached build's start minus a margin — the same rule the
/// in-memory incremental index uses (`IncrementalIndexTests`).
public enum IndexCache {
    private struct Payload: Codable {
        var format: Int
        var appVersion: String
        var vaultPath: String
        var buildStarted: Date
        var notes: [NoteMetadata]
    }
    private static let format = 1

    /// Where the cache for `vaultRoot` lives. `directory` is injectable for tests.
    public static func url(for vaultRoot: URL, in directory: URL? = nil) -> URL {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "IndexCache", directoryHint: .isDirectory)
        let digest = SHA256.hash(data: Data(vaultRoot.standardizedFileURL.path(percentEncoded: false).utf8))
        let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return base.appending(path: "\(name).plist")
    }

    /// Writes `snapshot`. Silent on failure: a missing cache only costs time.
    public static func save(_ snapshot: IndexSnapshot, vaultRoot: URL, appVersion: String, in directory: URL? = nil) {
        guard let started = snapshot.buildStarted else { return }
        let payload = Payload(format: format, appVersion: appVersion,
                              vaultPath: vaultRoot.standardizedFileURL.path(percentEncoded: false),
                              buildStarted: started, notes: Array(snapshot.notes.values))
        let target = url(for: vaultRoot, in: directory)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(payload).write(to: target, options: .atomic)
        } catch {}
    }

    /// The cached snapshot, or nil when there is none usable for this vault
    /// and app version.
    public static func load(vaultRoot: URL, appVersion: String, in directory: URL? = nil) -> IndexSnapshot? {
        guard let data = try? Data(contentsOf: url(for: vaultRoot, in: directory)),
              let payload = try? PropertyListDecoder().decode(Payload.self, from: data),
              payload.format == format, payload.appVersion == appVersion,
              payload.vaultPath == vaultRoot.standardizedFileURL.path(percentEncoded: false)
        else { return nil }
        var snapshot = IndexBuilder.assemble(payload.notes, vaultRoot: vaultRoot)
        snapshot.buildStarted = payload.buildStarted
        return snapshot
    }
}
