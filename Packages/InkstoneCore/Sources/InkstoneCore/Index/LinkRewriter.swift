import Foundation

/// Rewrites `[[wikilinks]]` across a vault when a note is renamed or moved.
///
/// Without this, renaming a note silently breaks every reference to it — the
/// single most damaging paper cut a linked-notes app can have.
public struct LinkRewriter: Sendable {
    public let store: NoteStore

    public init(store: NoteStore) {
        self.store = store
    }

    /// Updates links pointing at `oldName` so they point at `newName`.
    ///
    /// Preserves any `#fragment` and `|alias`, and leaves links inside code
    /// blocks alone by reusing the same scanner the editor uses.
    /// - Returns: the URLs of notes that were modified.
    @discardableResult
    public func rename(from oldName: String, to newName: String, in noteURLs: [URL]) -> [URL] {
        guard oldName != newName else { return [] }
        let scanner = SyntaxScanner()
        var changed: [URL] = []

        for url in noteURLs {
            guard let text = try? store.read(url) else { continue }
            let nsText = text as NSString
            let tokens = scanner.scan(text)

            // Rewrite back-to-front so earlier ranges stay valid.
            var updated = text
            var didChange = false
            for token in tokens.reversed() {
                let link: WikiLink
                let isEmbed: Bool
                switch token.kind {
                case .wikiLink(let value): link = value; isEmbed = false
                case .embed(let value): link = value; isEmbed = true
                default: continue
                }

                guard matches(link.target, name: oldName) else { continue }

                let replacement = render(
                    link: WikiLink(target: newName, fragment: link.fragment, alias: link.alias),
                    isEmbed: isEmbed
                )
                guard let range = Range(token.range, in: updated) else { continue }
                updated.replaceSubrange(range, with: replacement)
                didChange = true
            }

            if didChange, (try? store.write(updated, to: url)) != nil {
                changed.append(url)
            }
            _ = nsText
        }
        return changed
    }

    /// A link target may be a bare name or a path; both should be rewritten when
    /// the final path component matches.
    private func matches(_ target: String, name: String) -> Bool {
        let lastComponent = (target as NSString).lastPathComponent
        return lastComponent.compare(name, options: .caseInsensitive) == .orderedSame
            || target.compare(name, options: .caseInsensitive) == .orderedSame
    }

    private func render(link: WikiLink, isEmbed: Bool) -> String {
        var result = isEmbed ? "![[" : "[["
        result += link.target
        if let fragment = link.fragment, !fragment.isEmpty { result += "#\(fragment)" }
        if let alias = link.alias, !alias.isEmpty { result += "|\(alias)" }
        result += "]]"
        return result
    }
}
