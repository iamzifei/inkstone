import Foundation

/// The hand-off between the share extension and the app: one JSON file per
/// shared item in the app group's container, moved into the vault by the app.
public enum SharedInbox {
    public static let appGroup = "group.com.orris.inkstone"

    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "Inbox", directoryHint: .isDirectory)
    }

    /// Called by the extension.
    public static func add(_ item: Capture.SharedItem, in directory: URL? = nil) throws {
        guard let folder = directory ?? folder else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(item)
        try data.write(to: folder.appending(path: "\(Int(item.date.timeIntervalSince1970 * 1000))-\(UUID().uuidString).json"),
                       options: .atomic)
    }

    /// Called by the app: hands each waiting item, oldest first, to `deliver`;
    /// an item is removed only once `deliver` returns true, so nothing is lost
    /// if the vault cannot take it now.
    public static func drain(in directory: URL? = nil, deliver: (Capture.SharedItem) -> Bool) {
        guard let folder = directory ?? folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file),
                  let item = try? JSONDecoder().decode(Capture.SharedItem.self, from: data) else {
                try? FileManager.default.removeItem(at: file)   // unreadable: never deliverable
                continue
            }
            guard deliver(item) else { return }
            try? FileManager.default.removeItem(at: file)
        }
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
