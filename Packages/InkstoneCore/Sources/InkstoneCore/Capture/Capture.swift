import Foundation

/// Text that arrives from outside the app — a Shortcuts action, the iOS share
/// sheet — and how it is written into the vault.
public enum Capture {
    /// One thing shared into Inkstone (from the share extension, through the
    /// app group's inbox folder).
    public struct SharedItem: Codable, Equatable, Sendable {
        public var text: String?
        public var url: URL?
        public var title: String?
        public var date: Date
        /// Files shared along with it (names in the item's own folder in the
        /// app group, see `SharedInbox`). Optional so items written by an
        /// earlier version, which had none, still decode.
        public var files: [String]?

        public init(text: String?, url: URL?, title: String?, date: Date = Date(timeIntervalSince1970: 0)) {
            self.text = text; self.url = url; self.title = title; self.date = date
        }

        /// The item as Markdown: the text, then the link (titled when the page
        /// gave a title, else an autolink).
        public var markdown: String {
            var lines: [String] = []
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { lines.append(text) }
            if let url {
                if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    let escaped = title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                    lines.append("[\(escaped)](\(url.absoluteString))")
                } else {
                    lines.append("<\(url.absoluteString)>")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    /// `note` with `text` added on a line of its own at the end.
    public static func appending(_ text: String, to note: String) -> String {
        var out = note
        if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        out += text
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// A file name for a note titled `title`: path separators, control
    /// characters and characters not allowed in file names (or that break wiki
    /// links) replaced; no leading dot (a hidden file); at most 120 characters
    /// and 200 UTF-8 bytes (file names are limited to 255 bytes, and 120 CJK
    /// characters are 360), leaving room for the extension and a " 2".
    public static func noteName(from title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|#^[]").union(.controlCharacters).union(.newlines)
        var cleaned = String(title.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return "Untitled" }
        var name = ""
        for character in cleaned.prefix(120) {
            guard name.utf8.count + String(character).utf8.count <= 200 else { break }
            name.append(character)
        }
        return name
    }
}
