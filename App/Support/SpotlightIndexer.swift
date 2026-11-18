import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
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

    func update(root: URL, notes: [URL: Date], enabled: Bool) async {
        let domain = Self.identifier(for: root)
        let index = CSSearchableIndex.default()
        guard enabled, CSSearchableIndex.isIndexingAvailable() else {
            if !(loadPushed(domain).isEmpty) {
                try? await index.deleteSearchableItems(withDomainIdentifiers: [domain])
                savePushed([:], domain)
            }
            return
        }
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
            if Task.isCancelled { break }
            let items = batch.compactMap { item(for: $0, domain: domain, modified: notes[$0]) }
            do {
                try await index.indexSearchableItems(items)
                for url in batch { pushed[url] = notes[url] }
            } catch {
                log.error("spotlight index failed: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
        savePushed(pushed, domain)
        log.info("spotlight +\(changes.upsert.count) -\(changes.delete.count)")
    }

    private func item(for url: URL, domain: String, modified: Date?) -> CSSearchableItem? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxTextBytes)) ?? Data()
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

    private func stateURL(_ domain: String) -> URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        let name = Data(domain.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return dir.appending(path: "Spotlight", directoryHint: .isDirectory).appending(path: name.prefix(120) + ".json")
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
