import Foundation

/// How a vault file should be opened.
public enum FileOpening: Hashable, Sendable {
    /// A canvas document.
    case canvas
    /// Editable text — Markdown, but also anything else that turns out to be
    /// text: a `.txt` beside a note, a `.csv` of figures, a script.
    case text
    /// Something to look at rather than edit, with the kind it turned out to be.
    case preview(AttachmentKind)

    /// Decides from the extension, and from the bytes when the extension does
    /// not settle it.
    ///
    /// The extension alone is not enough, and assuming it was is what made a
    /// JPEG open as a screenful of mojibake: everything that was not `.canvas`
    /// was treated as text. Going the other way — trusting a fixed list of
    /// "text extensions" — fails the same way in reverse, because a vault holds
    /// whatever the person put in it: `.py`, `.srt`, `.env`, `.tex`, extensions
    /// nobody thought to list.
    ///
    /// So: kinds that are never text are settled by extension, and everything
    /// else is asked. `contents` may be a prefix of the file — the answer does
    /// not change with more of it.
    public static func decide(for url: URL, sampling contents: @autoclosure () -> Data?) -> FileOpening {
        let ext = url.pathExtension.lowercased()
        if ext == "canvas" { return .canvas }

        let kind = AttachmentKind(pathExtension: ext)
        if kind != .other { return .preview(kind) }
        // Markdown is text by definition, and skipping the sniff means the
        // common case never reads the file twice.
        if ["md", "markdown"].contains(ext) { return .text }

        guard let data = contents() else { return .preview(.other) }
        return looksLikeText(data) ? .text : .preview(.other)
    }

    /// How much of a file is enough to tell. A binary that opens with a long
    /// run of ASCII — a header, a magic string — is still a binary, and the NUL
    /// that gives it away is rarely in the first few bytes.
    public static let sniffLength = 8192

    /// Whether `data` reads as text.
    ///
    /// Two tests, and the first is the one that matters. A NUL byte does not
    /// occur in text and does occur in almost every binary format, so it
    /// settles most files on its own. The decode catches the rest — arbitrary
    /// bytes are unlikely to form valid UTF-8 for long.
    ///
    /// An empty file is text: a new, untouched note is empty, and opening it in
    /// a viewer that says "no preview" would be absurd.
    public static func looksLikeText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        let sample = data.prefix(sniffLength)
        if sample.contains(0) { return false }
        if String(data: sample, encoding: .utf8) != nil { return true }
        // A truncated sample can cut a multi-byte character in half, which fails
        // to decode through no fault of the file. Retry without the tail.
        for trim in 1...3 where sample.count > trim {
            if String(data: sample.dropLast(trim), encoding: .utf8) != nil { return true }
        }
        return false
    }
}
