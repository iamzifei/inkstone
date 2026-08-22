import Foundation

/// The vault's own `.gitignore`, applied to sync.
///
/// A vault synced to a GitHub repository is very often a clone of it, and then
/// the user has already written down what does not belong there — in the file
/// invented for saying exactly that, sitting in the folder being synced. Ignoring
/// it means uploading what they excluded, and in one real vault that meant three
/// files that GitHub's API cannot accept at all, failing on every run forever.
///
/// A deliberate subset of git's rules, because the rest are not worth the risk of
/// getting subtly wrong:
///
///   - `#` comments and blank lines
///   - `name` — matches that name anywhere in the tree
///   - `dir/` — matches a directory and everything under it
///   - `/rooted` — matches only at the vault root
///   - `*.ext`, `pre*fix` — `*` within one path component
///   - `!pattern` — un-ignores something an earlier line ignored
///
/// Not supported, and left un-ignored rather than guessed at: `**`, character
/// classes, and nested `.gitignore` files below the root.
public struct GitIgnore: Sendable {

    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let isNegated: Bool
        let directoryOnly: Bool
        /// Anchored patterns match from the root; unanchored ones match any
        /// component or trailing segment.
        let isAnchored: Bool
    }

    private let rules: [Rule]

    public var isEmpty: Bool { rules.isEmpty }

    public init(contents: String) {
        var rules: [Rule] = []
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let isNegated = line.hasPrefix("!")
            if isNegated { line.removeFirst() }

            let directoryOnly = line.hasSuffix("/")
            if directoryOnly { line.removeLast() }

            let isAnchored = line.hasPrefix("/") || line.dropLast().contains("/")
            if line.hasPrefix("/") { line.removeFirst() }
            guard !line.isEmpty else { continue }

            guard let regex = try? NSRegularExpression(pattern: "^" + Self.glob(line) + "$")
            else { continue }
            rules.append(
                Rule(regex: regex, isNegated: isNegated,
                     directoryOnly: directoryOnly, isAnchored: isAnchored)
            )
        }
        self.rules = rules
    }

    /// Reads `.gitignore` from the vault root. Absent is simply no rules.
    public static func load(from vaultRoot: URL) -> GitIgnore {
        let url = vaultRoot.appending(path: ".gitignore")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return GitIgnore(contents: "")
        }
        return GitIgnore(contents: contents)
    }

    /// - Parameter path: vault-relative, `/`-separated.
    public func ignores(_ path: String) -> Bool {
        guard !rules.isEmpty else { return false }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return false }

        var ignored = false
        for rule in rules {
            // Later rules win, which is how `!` un-ignores.
            if matches(rule, path: path, components: components) {
                ignored = !rule.isNegated
            }
        }
        return ignored
    }

    private func matches(_ rule: Rule, path: String, components: [String]) -> Bool {
        // A directory rule covers everything beneath it, so every leading
        // sub-path counts, not just the whole thing.
        if rule.isAnchored {
            if rule.directoryOnly {
                for end in 1..<max(components.count, 1) {
                    let prefix = components[0..<end].joined(separator: "/")
                    if isMatch(rule, prefix) { return true }
                }
                return false
            }
            return isMatch(rule, path)
        }

        if rule.directoryOnly {
            // Any component being that directory ignores what is under it.
            return components.dropLast().contains { isMatch(rule, $0) }
        }
        // A bare name matches any component, which is what makes `.DS_Store`
        // and `*.tmp` work at any depth.
        return components.contains { isMatch(rule, $0) }
    }

    private func isMatch(_ rule: Rule, _ candidate: String) -> Bool {
        let range = NSRange(candidate.startIndex..., in: candidate)
        return rule.regex.firstMatch(in: candidate, range: range) != nil
    }

    /// Glob to regex, with `*` stopping at a path separator the way git's does.
    private static func glob(_ pattern: String) -> String {
        var out = ""
        for character in pattern {
            switch character {
            case "*": out += "[^/]*"
            case "?": out += "[^/]"
            default: out += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return out
    }
}
