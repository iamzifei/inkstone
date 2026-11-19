import Foundation

/// The hand-off between the share extension and the app: one JSON file per
/// shared item in the app group's container, moved into the vault by the app.
public enum SharedInbox {
    public static let appGroup = "group.com.orris.inkstone"

    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "Inbox", directoryHint: .isDirectory)
    }

    /// Called by the extension. Files shared with the item are copied into a
    /// folder of its own beside its JSON (`<stem>/`), and listed in it; the
    /// JSON is written last, so the app never sees an item whose files are
    /// not all there yet. Anything half-made is removed if a step fails.
    public static func add(_ item: Capture.SharedItem, files: [URL] = [], in directory: URL? = nil) throws {
        guard let folder = directory ?? folder else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = "\(Int(item.date.timeIntervalSince1970 * 1000))-\(UUID().uuidString)"
        let box = folder.appending(path: stem, directoryHint: .isDirectory)
        var item = item
        do {
            if !files.isEmpty {
                try fm.createDirectory(at: box, withIntermediateDirectories: true)
                var names: [String] = []
                for file in files {
                    let original = safeName(file.lastPathComponent)
                    var name = original
                    var n = 2
                    // As the file system compares names: ignoring case.
                    while names.contains(where: { $0.lowercased() == name.lowercased() }) {
                        let ext = (original as NSString).pathExtension
                        let base = (original as NSString).deletingPathExtension
                        name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"; n += 1
                    }
                    try fm.copyItem(at: file, to: box.appending(path: name))
                    names.append(name)
                }
                item.files = names
            }
            let data = try JSONEncoder().encode(item)
            try data.write(to: folder.appending(path: "\(stem).json"), options: .atomic)
        } catch {
            try? fm.removeItem(at: box)             // nothing half-shared is left behind
            throw error
        }
    }

    /// A name that stays one path component: no `/`, not `.`/`..`, not empty.
    public static func safeName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = "file" }
        if name.hasPrefix(".") { name = "file" + name }
        return name
    }

    /// One waiting item and how far its delivery got, kept in its folder
    /// (`progress.json`), so a retry does only what is left: no file copied
    /// twice, no note written twice.
    public final class Delivery {
        public let item: Capture.SharedItem
        let box: URL
        struct Progress: Codable { var delivered: [String: String] = [:]; var noteDone = false }
        var progress: Progress

        init(item: Capture.SharedItem, box: URL) {
            self.item = item; self.box = box
            progress = (try? JSONDecoder().decode(Progress.self, from: Data(contentsOf: box.appending(path: "progress.json")))) ?? Progress()
        }

        /// The item's files not delivered yet (names checked: one path
        /// component each, so a record can't point outside its folder).
        public var pendingFiles: [URL] {
            (item.files ?? []).filter { name in
                name == (name as NSString).lastPathComponent && name != "." && name != ".." && progress.delivered[name] == nil
            }.map { box.appending(path: $0) }
             .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        }
        /// Where each delivered file went (what the app recorded).
        public var deliveredPlaces: [String] { (item.files ?? []).compactMap { progress.delivered[$0] } }
        public var noteDone: Bool { progress.noteDone }

        /// A file is in the vault (at `place`): recorded, and its copy here removed.
        public func markDelivered(_ file: URL, as place: String) {
            progress.delivered[file.lastPathComponent] = place
            save()
            try? FileManager.default.removeItem(at: file)
        }
        public func markNoteDone() { progress.noteDone = true; save() }

        private func save() {
            try? FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(progress) { try? data.write(to: box.appending(path: "progress.json"), options: .atomic) }
        }
    }

    /// Called by the app: hands each waiting item, oldest first, to
    /// `deliver`; an item (and its folder) is removed once `deliver` returns
    /// true. One that can't be delivered now stays for next time — and does
    /// not hold up the items behind it.
    public static func drain(in directory: URL? = nil, deliver: (Delivery) -> Bool) {
        guard let folder = directory ?? folder,
              let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let jsons = entries.filter { $0.pathExtension == "json" }
        for file in jsons.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // Not readable right now (file protection while locked, a read
            // error): leave it for the next time, never delete it.
            guard let data = try? Data(contentsOf: file) else { continue }
            let box = file.deletingPathExtension()
            guard let item = try? JSONDecoder().decode(Capture.SharedItem.self, from: data) else {
                try? FileManager.default.removeItem(at: file)   // not an item at all: never deliverable
                continue
            }
            guard deliver(Delivery(item: item, box: box)) else { continue }
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: box)
        }
        // A folder whose record never got written (the extension stopped
        // half-way) and is a day old: nothing will ever deliver it.
        let stems = Set(jsons.map { $0.deletingPathExtension().lastPathComponent })
        for entry in entries where entry.pathExtension.isEmpty && !stems.contains(entry.lastPathComponent) {
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
            if Date.now.timeIntervalSince(date) > 86_400 { try? FileManager.default.removeItem(at: entry) }
        }
    }

    /// Whether the app has opened a vault yet (written by the app, read by the
    /// extension, so the share sheet can say where an item will go).
    private static let vaultKey = "hasVault"
    public static var appHasVault: Bool {
        get { UserDefaults(suiteName: appGroup)?.bool(forKey: vaultKey) ?? false }
        set { UserDefaults(suiteName: appGroup)?.set(newValue, forKey: vaultKey) }
    }

    /// A shared item as a note of its own (for a knowledge base's inbox):
    /// named by when it was shared, the shared text as its body.
    public static func note(for item: Capture.SharedItem, timeZone: TimeZone = .current) -> (name: String, text: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return ("Shared \(formatter.string(from: item.date)).md", item.markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
    }

    /// The block appended to the Inbox note for one item.
    public static func entry(for item: Capture.SharedItem, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\n### \(formatter.string(from: item.date))\n\n\(item.markdown)\n"
    }
}
