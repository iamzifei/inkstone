import Foundation

/// Finds vault-relative file paths written as plain text, so they can be turned
/// into links.
///
/// Notes that keep an index or a work log refer to other files by path all the
/// time — `01-原始素材区/知识库/10-Polanyi.md`, `_已发布/已发布内容库.md` — often
/// inside backticks, because that is how a path is written. Markdown has no
/// syntax for that, so none of them were clickable: the reader had to read the
/// path, remember it, and go and find the file by hand.
///
/// Only *candidates* are returned. Whether a path is a link is decided by whether
/// it resolves to a file that exists — a caller with the index does that. A
/// string that looks like a path but is not one stays plain text, which is the
/// right outcome: a link that goes nowhere is worse than no link.
public enum VaultPathDetector {
    /// Extensions worth linking. Deliberately not "anything with a dot": prose is
    /// full of `v3.2`, `1966.` and `google.com`, and every one of those would
    /// otherwise be offered as a file.
    public static let linkableExtensions: Set<String> = [
        "md", "markdown", "canvas",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "svg",
        "pdf", "mp4", "mov", "m4a", "mp3", "wav",
        "csv", "json", "yml", "yaml", "txt",
    ]

    /// Code units that end a path. CJK brackets and punctuation are in here
    /// because a Chinese sentence puts them straight up against the path with no
    /// space — `（见 a/b.md）` — and without them the closing bracket would be
    /// swallowed into the file name.
    ///
    /// UTF-16 code units rather than `Character`s, and that is a performance
    /// decision with a measurement behind it. Scanning the 8,865-note vault by
    /// `Array(text)` cost **2,279 ms** — 30% of the whole parse — because
    /// building a `Character` array means building grapheme clusters for 32
    /// million characters, and this scan needs none of that: every terminator is
    /// a single BMP code unit, so it can be compared directly.
    private static let terminators: Set<UInt16> = Set(
        [
            " ", "\t", "\n", "\r", "`", "\"", "'", "<", ">", "|", "*", "?",
            "(", ")", "[", "]", "{", "}", ",", ";",
            "（", "）", "「", "」", "《", "》", "【", "】", "、", "，", "；", "：", "。", "　",
        ].compactMap { (character: Character) -> UInt16? in
            let units = String(character).utf16
            return units.count == 1 ? units.first : nil
        })

    /// A dot, the only character a linkable path must contain. Used to skip
    /// whole notes cheaply: most notes contain no path at all, and finding that
    /// out should not cost a full scan.
    private static let dot = UInt16(UnicodeScalar(".").value)

    /// Every path-shaped run in `text`, as UTF-16 ranges so they can be used
    /// against an `NSAttributedString` directly.
    public static func candidates(in text: String) -> [NSRange] {
        let units = Array(text.utf16)
        var found: [NSRange] = []
        var index = 0

        while index < units.count {
            let start = index
            var sawDot = false
            while index < units.count, !terminators.contains(units[index]) {
                if units[index] == dot { sawDot = true }
                index += 1
            }

            // A run with no dot cannot carry an extension, so it cannot be a
            // path worth linking. Checked here rather than inside `isPathLike`
            // so the substring is never built.
            if sawDot, index > start {
                let range = NSRange(location: start, length: index - start)
                let word = String(decoding: units[start..<index], as: UTF16.self)
                if isPathLike(word) { found.append(range) }
            }

            if index < units.count { index += 1 }
        }
        return found
    }

    /// Whether one whitespace-delimited word is worth offering as a file path.
    public static func isPathLike(_ word: String) -> Bool {
        guard let dot = word.lastIndex(of: "."), dot != word.startIndex else { return false }
        let ext = String(word[word.index(after: dot)...]).lowercased()
        guard linkableExtensions.contains(ext) else { return false }

        let stem = word[word.startIndex..<dot]
        guard !stem.isEmpty else { return false }
        // A bare `README.md` is a path; so is `docs/README.md`. `http://x/y.md`
        // is a URL and belongs to whatever handles those.
        guard !word.contains("://") else { return false }
        return true
    }

    /// Turns a written path into one the index can resolve, or `nil` if it
    /// points outside the vault.
    ///
    /// Absolute paths used to be rejected outright, on the stated grounds that
    /// "leading `/` or `~` is an absolute path outside the vault". That is an
    /// assumption, not a fact, and it is wrong for the common case: a note that
    /// records where something lives writes the whole path —
    /// `/Users/…/vault/_published/index.md` — and that file is very much inside
    /// the vault. Those were the paths least likely to be guessable by hand and
    /// the only ones that could never be clicked.
    ///
    /// Whether a path is inside is a question about this vault, so it is asked
    /// here rather than guessed from the first character.
    public static func vaultRelative(_ written: String, vaultRoot: URL) -> String? {
        var path = written
        if path.hasPrefix("~") {
            path = NSString(string: path).expandingTildeInPath
        }
        guard path.hasPrefix("/") else { return path }  // already relative

        // `standardized` on both sides: a vault reached through a symlink and a
        // path written through the real one are the same file, and comparing the
        // raw strings would say otherwise.
        let root = vaultRoot.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        guard candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return String(candidate.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
    }
}
