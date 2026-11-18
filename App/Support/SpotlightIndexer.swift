import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import CryptoKit
import os
import InkstoneCore

/// Keeps the open vault's notes in Spotlight (system search): title, a plain
/// text summary, the text itself and tags, so a note is found from the home
/// screen / ⌘Space and opens in the app. Everything stays on the device.
///
/// After each index build only the notes that changed since the last push are
/// written (a launch does not rewrite an 8,000-note vault); what was pushed
/// is remembered per vault in Application Support.
actor SpotlightIndexer {
    static let shared = SpotlightIndexer()
    private let log = Logger(subsystem: "com.orris.inkstone", category: "Spotlight")
    /// Notes larger than this are indexed by their first part only.
    private let maxTextBytes = 200_000

    /// Identifier of a note's item: its file path. Also what a tapped
    /// result hands back, to open the note.
    static func identifier(for url: URL) -> String { url.standardizedFileURL.path(percentEncoded: false) }

    /// The app's own index. On iOS with complete file protection: the note
    /// text in it is unreadable while the device is locked, as the notes are.
    private let index: CSSearchableIndex = {
        #if os(iOS)
        CSSearchableIndex(name: "notes", protectionClass: .complete)
        #else
        CSSearchableIndex(name: "notes")
        #endif
    }()

    // Only the latest request matters: each index build sends the whole vault,
    // so a request still waiting when a newer one arrives is dropped, not queued.
    private var pending: (root: URL?, notes: [URL: Date], enabled: Bool)?
    private var running = false
    /// Requests are numbered on the main actor; separate tasks can reach this
    /// actor out of order, and an older one must not replace a newer one.
    private var newest = 0

    /// Brings the index up to date with `notes` (nil root: no vault open).
    func submit(sequence: Int, root: URL?, notes: [URL: Date], enabled: Bool) async {
        guard sequence > newest else { return }
        newest = sequence
        pending = (root, notes, enabled)
        guard !running else { return }
        running = true
        while let next = pending {
            pending = nil
            if !next.enabled {
                await removeEverything()
            } else if let root = next.root {
                await update(root: root, notes: next.notes)
            }
        }
        running = false
    }

    /// Switched off: every vault's items go, and the records of them.
    private func removeEverything() async {
        do {
            try await index.deleteAllSearchableItems()
            if let dir = stateDirectory() { try? FileManager.default.removeItem(at: dir) }
        } catch {
            log.error("spotlight clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func update(root: URL, notes: [URL: Date]) async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let domain = Self.identifier(for: root)
        // Keyed by the same normalised path as the stored record, or a
        // /var vs /private/var difference would rewrite every note each time.
        let notes = Dictionary(notes.map { (URL(filePath: Self.identifier(for: $0.key)), $0.value) },
                               uniquingKeysWith: { a, _ in a })
        var pushed = loadPushed(domain)
        let changes = SpotlightPlan.diff(pushed: pushed, current: notes)
        guard !changes.isEmpty else { return }

        if !changes.delete.isEmpty {
            do {
                try await index.deleteSearchableItems(withIdentifiers: changes.delete.map(Self.identifier(for:)))
                for url in changes.delete { pushed[url] = nil }
            } catch {
                log.error("spotlight delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // In batches, so a first push of a big vault neither holds every
        // note's text in memory at once nor loses everything to one failure.
        for batch in stride(from: 0, to: changes.upsert.count, by: 200).map({ Array(changes.upsert[$0..<min($0 + 200, changes.upsert.count)]) }) {
            // Only what was actually read is recorded as pushed; a note that
            // could not be read (vault closed meanwhile, an iCloud file not
            // downloaded) is tried again next time.
            let items = batch.compactMap { url in item(for: url, domain: domain, modified: notes[url]).map { (url, $0) } }
            guard !items.isEmpty else { continue }
            do {
                try await index.indexSearchableItems(items.map(\.1))
                for (url, _) in items { pushed[url] = notes[url] }
            } catch {
                log.error("spotlight index failed: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
        savePushed(pushed, domain)
        log.info("spotlight +\(changes.upsert.count) -\(changes.delete.count)")
    }

    private func item(for url: URL, domain: String, modified: Date?) -> CSSearchableItem? {
        // Never read an iCloud file that is not on the device: that would
        // download it (or block until it is) — the whole vault, for an index.
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus == .notDownloaded {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxTextBytes)) ?? Data()
        // A cut in the middle of a character decodes as one replacement mark.
        let text = String(decoding: data, as: UTF8.self)
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = url.deletingPathExtension().lastPathComponent
        attributes.contentDescription = SpotlightPlan.summary(of: text, limit: 300)
        attributes.textContent = String(FrontmatterParser.parse(text).body)
        attributes.contentModificationDate = modified
        let tags = FrontmatterParser.parse(text).frontmatter.tags
        if !tags.isEmpty { attributes.keywords = tags }
        let item = CSSearchableItem(uniqueIdentifier: Self.identifier(for: url), domainIdentifier: domain, attributeSet: attributes)
        item.expirationDate = .distantFuture
        return item
    }

    // MARK: - What was pushed, per vault

    private func stateDirectory() -> URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appending(path: "Spotlight", directoryHint: .isDirectory)
    }

    /// One file per vault, named by a hash of its path (a prefix of the path
    /// made two deep iCloud vaults share one file).
    private func stateURL(_ domain: String) -> URL? {
        let hash = SHA256.hash(data: Data(domain.utf8)).map { String(format: "%02x", $0) }.joined()
        return stateDirectory()?.appending(path: hash + ".json")
    }

    private func loadPushed(_ domain: String) -> [URL: Date] {
        guard let url = stateURL(domain), let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.map { (URL(filePath: $0.key), $0.value) })
    }

    private func savePushed(_ pushed: [URL: Date], _ domain: String) {
        guard let url = stateURL(domain) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stored = Dictionary(uniqueKeysWithValues: pushed.map { ($0.key.path(percentEncoded: false), $0.value) })
        try? JSONEncoder().encode(stored).write(to: url, options: .atomic)
    }
}
