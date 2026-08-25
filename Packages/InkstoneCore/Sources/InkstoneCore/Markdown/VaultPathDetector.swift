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

    /// Characters that end a path. CJK brackets and punctuation are in here
    /// because a Chinese sentence puts them straight up against the path with no
    /// space — `（见 a/b.md）` — and without them the closing bracket would be
    /// swallowed into the file name.
    private static let terminators: Set<Character> = [
        " ", "\t", "\n", "\r", "`", "\"", "'", "<", ">", "|", "*", "?",
        "(", ")", "[", "]", "{", "}", ",", ";",
        "（", "）", "「", "」", "《", "》", "【", "】", "、", "，", "；", "：", "。", "　",
    ]

    /// Every path-shaped run in `text`, as UTF-16 ranges so they can be used
    /// against an `NSAttributedString` directly.
    public static func candidates(in text: String) -> [NSRange] {
        let scalars = Array(text)
        var found: [NSRange] = []
        var index = 0
        // UTF-16 offset tracked alongside the character index: `NSRange` is in
        // UTF-16 units, and a vault full of CJK and emoji is exactly where
        // assuming otherwise goes wrong.
        var utf16Offset = 0

        while index < scalars.count {
            let startCharacter = index
            let startOffset = utf16Offset

            // Walk to the next terminator.
            while index < scalars.count, !terminators.contains(scalars[index]) {
                utf16Offset += String(scalars[index]).utf16.count
                index += 1
            }

            if index > startCharacter {
                let word = String(scalars[startCharacter..<index])
                if isPathLike(word) {
                    found.append(NSRange(location: startOffset, length: utf16Offset - startOffset))
                }
            }

            if index < scalars.count {
                utf16Offset += String(scalars[index]).utf16.count
                index += 1
            }
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
        // Leading `/` or `~` is an absolute path outside the vault.
        guard !word.hasPrefix("/"), !word.hasPrefix("~") else { return false }
        return true
    }
}
