import Foundation
import OSLog

/// Keeps an iCloud-backed vault's files actually present on disk.
///
/// iCloud Drive evicts files it thinks you aren't using: the bytes go to the
/// cloud and what stays behind is a placeholder named `.Note.md.icloud` — a
/// *hidden* file, under a different name. A directory scan that skips hidden
/// files therefore sees nothing at all, and the note simply disappears from the
/// sidebar on whichever machine hasn't touched it lately.
///
/// That is the difference between "the vault is stored in iCloud" and "iCloud
/// sync works". Two things fix it: showing a placeholder under the name it will
/// have once it arrives, and asking iCloud to bring it back.
public enum ICloudFiles {

    private static let logger = Logger(subsystem: "com.orris.inkstone", category: "icloud")

    private static let placeholderSuffix = ".icloud"

    /// Whether a directory entry is an eviction placeholder rather than a file.
    public static func isPlaceholder(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(placeholderSuffix)
            && name.count > placeholderSuffix.count + 1
    }

    /// The name the file will have once it has been downloaded.
    ///
    ///     ".Meeting notes.md.icloud" -> "Meeting notes.md"
    ///
    /// - Returns: nil when `name` is not a placeholder.
    public static func materialisedName(for name: String) -> String? {
        guard isPlaceholder(name) else { return nil }
        return String(name.dropFirst().dropLast(placeholderSuffix.count))
    }

    /// Asks iCloud to download everything under `root` that has been evicted.
    ///
    /// Fire and forget: the request only starts the transfer, and the vault is
    /// rescanned when the files land (the file-system watcher sees them appear).
    /// Notes are small, so pulling the whole vault down is the right trade —
    /// a vault whose notes are missing is not a vault.
    ///
    /// - Returns: how many downloads were requested.
    @discardableResult
    public static func requestDownloads(in root: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return 0 }

        var requested = 0
        for case let url as URL in enumerator {
            guard isPlaceholder(url.lastPathComponent) else { continue }
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                requested += 1
            } catch {
                logger.error("Could not start download for \(url.lastPathComponent, privacy: .public)")
            }
        }
        if requested > 0 {
            logger.notice("Requested \(requested) iCloud download(s)")
        }
        return requested
    }

    /// Brings a single file down and waits for it, for when the user opens a
    /// note that happens to be evicted.
    ///
    /// Polls rather than using an `NSMetadataQuery`: the query would need a run
    /// loop and a delegate to observe one file that is normally already present.
    ///
    /// - Returns: whether the file is on disk by the time this returns.
    public static func ensureDownloaded(_ url: URL, timeout: TimeInterval = 5) -> Bool {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return true }

        let placeholder = url.deletingLastPathComponent()
            .appending(path: "." + url.lastPathComponent + placeholderSuffix)
        guard FileManager.default.fileExists(atPath: placeholder.path(percentEncoded: false)) else {
            return false   // genuinely missing, not evicted
        }

        try? FileManager.default.startDownloadingUbiquitousItem(at: placeholder)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        logger.notice("Timed out waiting for \(url.lastPathComponent, privacy: .public)")
        return false
    }
}
