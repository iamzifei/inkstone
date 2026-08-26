import Foundation

/// One skill: a folder holding a `SKILL.md` whose frontmatter names it.
///
/// The format is Claude Code's, so a library someone already has works here
/// without being copied or converted.
public struct SkillManifest: Sendable, Hashable, Identifiable, Codable {
    public var id: String { name }
    /// From the frontmatter, falling back to the folder name.
    public let name: String
    /// What the skill is for. This is the only thing shown while picking one,
    /// and in Claude Code it doubles as the trigger, so it is written to be read.
    public let description: String
    public let url: URL
    /// Whether the folder carries scripts.
    ///
    /// Recorded because they will not run. A sandboxed app cannot exec anything
    /// outside its own bundle — measured in this codebase under three signing
    /// configurations, including a Developer ID signature with a path-exact
    /// read-execute exception. So a skill whose instructions say "run
    /// `analyse.py`" can contribute its prose and nothing else, and saying so in
    /// the picker is better than letting it fail halfway through.
    public let hasScripts: Bool

    public init(name: String, description: String, url: URL, hasScripts: Bool = false) {
        self.name = name
        self.description = description
        self.url = url
        self.hasScripts = hasScripts
    }
}

/// Reads skill folders.
public enum SkillIndex {
    /// How much of a `SKILL.md` to read when only the frontmatter is wanted.
    ///
    /// The library measured here is 705 files totalling 41 MB, and a `/` menu
    /// needs two fields from each. Reading the head keeps opening the menu from
    /// touching forty megabytes.
    public static let manifestPrefixBytes = 4_096

    /// Parses the frontmatter at the top of a `SKILL.md`.
    ///
    /// Hand-parsed rather than passed to the YAML parser, because this runs over
    /// a partial file: the prefix almost always cuts mid-document, and a parser
    /// given a truncated document reports a syntax error rather than the two
    /// fields that were already complete.
    public static func manifest(fromHead head: String, folder: URL) -> SkillManifest? {
        let fallbackName = folder.lastPathComponent
        guard head.hasPrefix("---") else {
            // No frontmatter is not a reason to hide a skill; the folder name is
            // a usable label and the body is still instructions.
            return SkillManifest(name: fallbackName, description: "", url: folder)
        }

        var name: String?
        var description: String?
        var inFrontmatter = false

        for rawLine in head.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("---") {
                if inFrontmatter { break }
                inFrontmatter = true
                continue
            }
            guard inFrontmatter else { continue }
            // Only top-level keys. A nested `metadata:` block can contain a
            // `name:` of its own, and indentation is what tells them apart.
            guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }

            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "name": name = value
            case "description": description = value
            default: break
            }
        }

        return SkillManifest(
            name: name?.isEmpty == false ? name! : fallbackName,
            description: description ?? "",
            url: folder)
    }

    /// Filters and ranks skills for what has been typed after `/`.
    ///
    /// Matches the name first and the description second, because someone typing
    /// `/ad` means a skill called `ad-creative`, not the twelve whose
    /// descriptions mention advertising.
    public static func matching(_ query: String, in skills: [SkillManifest]) -> [SkillManifest] {
        let query = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return skills.sorted { $0.name < $1.name } }

        var exact: [SkillManifest] = []
        var prefixed: [SkillManifest] = []
        var contained: [SkillManifest] = []
        var described: [SkillManifest] = []

        for skill in skills {
            let name = skill.name.lowercased()
            if name == query { exact.append(skill) }
            else if name.hasPrefix(query) { prefixed.append(skill) }
            else if name.contains(query) { contained.append(skill) }
            else if skill.description.lowercased().contains(query) { described.append(skill) }
        }
        return exact
            + prefixed.sorted { $0.name < $1.name }
            + contained.sorted { $0.name < $1.name }
            + described.sorted { $0.name < $1.name }
    }

    /// Strips the frontmatter, leaving the instructions.
    ///
    /// The frontmatter is routing information for whatever picked the skill. By
    /// the time it is being sent it has done its job, and sending it spends
    /// tokens telling the model when to use something it is already using.
    public static func instructions(from text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 1
        while index < lines.count, !lines[index].hasPrefix("---") { index += 1 }
        guard index < lines.count else { return text }
        return lines[(index + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
