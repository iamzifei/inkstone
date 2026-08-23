import CryptoKit
import Foundation

/// Local snapshots of a note, so a bad edit or a bad sync is not the end of it.
///
/// Not git. A vault may or may not be a git working copy, and the shipping app
/// is sandboxed: a spawned `git` does not inherit the security-scoped grant that
/// lets the app read a folder the user picked, so shelling out would work in a
/// development build and fail in the one people install. Snapshots need nothing
/// but the vault itself and work the same on both platforms.
///
/// Kept inside the vault's `.inkstone` folder, which sync excludes, so history
/// stays local to the device that made it. That is the honest scope: this
/// recovers *your* edits on *this* device, and does not pretend to be a shared
/// history.
public struct FileHistory: Sendable {

    /// A single saved state of one file.
    public struct Version: Identifiable, Hashable, Sendable {
        public let id: String
        public let date: Date
        public let size: Int
        /// Where the snapshot itself lives.
        public let url: URL
    }

    /// How many snapshots a file keeps. Beyond this the oldest go.
    public static let maximumPerFile = 25

    /// And how long. Whichever limit bites first wins.
    public static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    /// The shortest gap between two snapshots of one file.
    ///
    /// Notes are saved as you type, debounced to a second or two. Snapshotting
    /// every save would fill the limit above within a paragraph and leave the
    /// history covering the last four minutes — the opposite of the point.
    public static let minimumInterval: TimeInterval = 3 * 60

    /// Files above this are not snapshotted. History is for notes; a vault can
    /// hold a video, and twenty-five copies of one is not a safety net.
    public static let maximumFileSize = 4 * 1024 * 1024

    private let vaultRoot: URL

    public init(vaultRoot: URL) {
        self.vaultRoot = vaultRoot
    }

    private var root: URL {
        vaultRoot.appending(path: ".inkstone", directoryHint: .isDirectory)
            .appending(path: "history", directoryHint: .isDirectory)
    }

    /// A file's folder, named by a hash of its vault-relative path.
    ///
    /// A hash rather than the path itself: paths contain slashes, colons and
    /// characters no file system agrees about, and mirroring the vault's tree
    /// inside the history folder would mean moving history around every time a
    /// note moves. The trade is that the folder name is unreadable, which is
    /// why the path is written beside the snapshots.
    private func folder(for path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(20)
        return root.appending(path: String(name), directoryHint: .isDirectory)
    }

    /// Snapshots the file at `path` if enough has changed and enough time has
    /// passed.
    ///
    /// - Returns: the snapshot written, or `nil` when there was no reason to.
    @discardableResult
    public func record(_ path: String, contents: Data, now: Date = Date()) throws -> Version? {
        guard contents.count <= Self.maximumFileSize else { return nil }

        let existing = versions(of: path)
        if let latest = existing.first {
            // Identical content is not a version. Two saves of the same bytes
            // happen constantly — a focus change, an autosave after a cursor
            // move — and each one would push a real edit out of the window.
            if let previous = try? Data(contentsOf: latest.url), previous == contents {
                return nil
            }
            guard now.timeIntervalSince(latest.date) >= Self.minimumInterval else { return nil }
        }

        let directory = folder(for: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Written beside the snapshots so a history folder can say which file it
        // belongs to without the vault having to be walked.
        try? Data(path.utf8).write(to: directory.appending(path: "path"), options: .atomic)

        let stamp = String(Int(now.timeIntervalSince1970))
        let target = directory.appending(path: "\(stamp).snapshot")
        try contents.write(to: target, options: .atomic)

        prune(directory, now: now)
        return Version(id: stamp, date: now, size: contents.count, url: target)
    }

    /// Every snapshot of `path`, newest first.
    public func versions(of path: String) -> [Version] {
        let directory = folder(for: path)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names.compactMap { name -> Version? in
            guard name.hasSuffix(".snapshot") else { return nil }
            let stamp = String(name.dropLast(".snapshot".count))
            guard let seconds = TimeInterval(stamp) else { return nil }
            let url = directory.appending(path: name)
            let size = (try? FileManager.default.attributesOfItem(
                atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0
            return Version(id: stamp, date: Date(timeIntervalSince1970: seconds),
                           size: size ?? 0, url: url)
        }
        .sorted { $0.date > $1.date }
    }

    public func contents(of version: Version) -> Data? {
        try? Data(contentsOf: version.url)
    }

    /// Drops what is over the count or over the age. Age first, so a file edited
    /// heavily one afternoon a year ago does not keep twenty-five snapshots of
    /// itself forever.
    private func prune(_ directory: URL, now: Date) {
        var kept = versions(ofDirectory: directory)
            .filter { now.timeIntervalSince($0.date) <= Self.maximumAge }
        // Never leave nothing behind: an old file that is still being edited
        // should keep its newest snapshot even if every one is past the age.
        if kept.isEmpty, let newest = versions(ofDirectory: directory).first { kept = [newest] }

        let survivors = Set(kept.prefix(Self.maximumPerFile).map(\.url))
        for version in versions(ofDirectory: directory) where !survivors.contains(version.url) {
            try? FileManager.default.removeItem(at: version.url)
        }
    }

    private func versions(ofDirectory directory: URL) -> [Version] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names.compactMap { name -> Version? in
            guard name.hasSuffix(".snapshot"),
                  let seconds = TimeInterval(name.dropLast(".snapshot".count))
            else { return nil }
            return Version(id: String(name.dropLast(9)), date: Date(timeIntervalSince1970: seconds),
                           size: 0, url: directory.appending(path: name))
        }
        .sorted { $0.date > $1.date }
    }

    /// Forgets a file's history, for when the file itself is deleted.
    public func forget(_ path: String) {
        try? FileManager.default.removeItem(at: folder(for: path))
    }

    /// Follows a file that was renamed or moved, so its history goes with it.
    public func rename(_ path: String, to newPath: String) {
        let from = folder(for: path), to = folder(for: newPath)
        guard FileManager.default.fileExists(atPath: from.path(percentEncoded: false)) else { return }
        try? FileManager.default.removeItem(at: to)
        try? FileManager.default.moveItem(at: from, to: to)
        try? Data(newPath.utf8).write(to: to.appending(path: "path"), options: .atomic)
    }
}
