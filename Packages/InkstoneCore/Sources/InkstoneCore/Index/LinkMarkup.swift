import Foundation

/// Builds the markup for a link or embed the app is about to insert.
///
/// Two settings decide what it writes, and until now neither was read by
/// anything: `newLinkFormat` (wikilink or Markdown) and `useShortestPathLinks`
/// (the shortest name that still resolves, or the full vault-relative path).
///
/// A pure function in the core rather than a few lines inside the workspace,
/// because "which name is short enough to still be unambiguous" is exactly the
/// kind of rule that is easy to get subtly wrong and impossible to check by
/// clicking around.
public enum LinkMarkup {
    /// The text to insert for `target`.
    ///
    /// - Parameters:
    ///   - target: the file being linked to.
    ///   - source: the note the link is being written into, which decides what
    ///     counts as "shortest" — a relative path is relative to something.
    ///   - isEmbed: `![[…]]` / `![…](…)` rather than a plain link.
    ///   - shortest: prefer the bare file name when it is unambiguous.
    public static func markup(
        for target: URL,
        from source: URL,
        vaultRoot: URL,
        format: SettingsData.LinkFormat,
        shortest: Bool,
        isEmbed: Bool,
        snapshot: IndexSnapshot? = nil
    ) -> String {
        let path = reference(
            for: target, from: source, vaultRoot: vaultRoot,
            shortest: shortest, snapshot: snapshot
        )
        switch format {
        case .wikilink:
            return isEmbed ? "![[\(path)]]" : "[[\(path)]]"
        case .markdown:
            // Spaces are legal in a wikilink and not in a bare Markdown URL, so
            // the destination is percent-encoded and the label is not.
            let label = target.deletingPathExtension().lastPathComponent
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return isEmbed ? "![\(label)](\(encoded))" : "[\(label)](\(encoded))"
        }
    }

    /// What the link should say the target is called.
    ///
    /// With `shortest` off this is always the vault-relative path, which can
    /// never be ambiguous. With it on, the bare file name is used *only* when
    /// nothing else in the vault answers to it — an ambiguous short name would
    /// resolve to whichever file happens to be nearest, which is a link that
    /// silently points somewhere else.
    public static func reference(
        for target: URL,
        from source: URL,
        vaultRoot: URL,
        shortest: Bool,
        snapshot: IndexSnapshot?
    ) -> String {
        let relative = vaultRelativePath(of: target, in: vaultRoot)

        guard shortest else { return relative }

        let name = target.deletingPathExtension().lastPathComponent
        // No index to ask — a drag-and-drop before the first scan finishes, say.
        // The full path is the answer that is never wrong.
        guard let snapshot else { return relative }

        let matches = snapshot.namesToNotes[name.lowercased()] ?? []
        // Nothing in the index answers to this name: it is a new file or an
        // attachment, and attachments are not in the note index at all. Its own
        // name is unambiguous by definition only if no *note* shares it.
        if matches.isEmpty { return name }
        // Exactly one, and it is the file being linked: safe to shorten.
        if matches.count == 1, matches[0] == target { return name }
        return relative
    }

    /// The path of `url` under `vaultRoot`, or its file name if it is outside.
    public static func vaultRelativePath(of url: URL, in vaultRoot: URL) -> String {
        let root = vaultRoot.path(percentEncoded: false)
        let path = url.path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        let relative = String(path.dropFirst(prefix.count))
        // A note is referred to without its extension; an attachment keeps it,
        // because `diagram` and `diagram.png` are not the same file.
        return url.pathExtension.lowercased() == "md"
            ? String(relative.dropLast(3))
            : relative
    }
}
