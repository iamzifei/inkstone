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
    /// not all there yet.
    public static func add(_ item: Capture.SharedItem, files: [URL] = [], in directory: URL? = nil) throws {
        guard let folder = directory ?? folder else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = "\(Int(item.date.timeIntervalSince1970 * 1000))-\(UUID().uuidString)"
        var item = item
        if !files.isEmpty {
            let box = folder.appending(path: stem, directoryHint: .isDirectory)
            try fm.createDirectory(at: box, withIntermediateDirectories: true)
            var names: [String] = []
            do {
                for file in files {
                    var name = file.lastPathComponent.isEmpty ? "file" : file.lastPathComponent
                    var n = 2
                    while names.contains(name) {
                        let ext = (file.lastPathComponent as NSString).pathExtension
                        let base = (file.lastPathComponent as NSString).deletingPathExtension
                        name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"; n += 1
                    }
                    try fm.copyItem(at: file, to: box.appending(path: name))
                    names.append(name)
                }
            } catch {
                try? fm.removeItem(at: box)         // nothing half-shared is left behind
                throw error
            }
            item.files = names
        }
        let data = try JSONEncoder().encode(item)
        try data.write(to: folder.appending(path: "\(stem).json"), options: .atomic)
    }

    /// Called by the app: hands each waiting item, oldest first, with its
    /// files, to `deliver`; an item and its files are removed only once
    /// `deliver` returns true, so nothing is lost if the vault cannot take it
    /// now.
    public static func drain(in directory: URL? = nil, deliver: (Capture.SharedItem, [URL]) -> Bool) {
        guard let folder = directory ?? folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // Not readable right now (file protection while locked, a read
            // error): leave it for the next time, never delete it — and do
            // not let it hold up the items behind it.
            guard let data = try? Data(contentsOf: file) else { continue }
            let box = file.deletingPathExtension()
            guard let item = try? JSONDecoder().decode(Capture.SharedItem.self, from: data) else {
                try? FileManager.default.removeItem(at: file)   // not an item at all: never deliverable
                continue
            }
            let attached = (item.files ?? []).map { box.appending(path: $0) }
            // A listed file missing (cleared by the system): deliver what is there.
            let present = attached.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
            guard deliver(item, present) else { return }
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: box)
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
