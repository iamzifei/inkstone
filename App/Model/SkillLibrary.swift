import Foundation
import InkstoneCore

/// A folder of Claude Code skills, read with the user's permission.
///
/// The permission is the whole reason this is not simply a path. A sandboxed app
/// cannot read `~/.claude/skills` by default — measured: `NSCocoaErrorDomain
/// Code=257, "you don't have permission to view it"`. What it can do is read a
/// folder the user has handed it through an open panel, and keep that access
/// across launches with a security-scoped bookmark. That is the same mechanism
/// the vault itself uses.
///
/// What still cannot happen is running a skill's scripts: a sandboxed process
/// cannot exec anything outside its bundle, measured under three signing
/// configurations. In the library this was built against that affects 3 of 297
/// skills, because scripts sit in `references/` far more often than they are
/// invoked. Those three are marked in the picker rather than left to fail
/// halfway through.
@MainActor
@Observable
final class SkillLibrary {
    private(set) var skills: [SkillManifest] = []
    private(set) var folderName: String?
    /// Set when the folder was chosen but cannot be read now — a moved folder,
    /// or a bookmark that no longer resolves.
    private(set) var problem: String?

    private let defaultsKey = "com.orris.inkstone.skills.bookmark"
    private var accessing: URL?

    init() { restore() }

    var isConfigured: Bool { folderName != nil }

    // MARK: - Choosing

    /// Records a folder the user picked and reads it.
    func adopt(_ url: URL) {
        do {
            // `withSecurityScope` is macOS-only. On iOS a document-picker URL
            // is already scoped and a plain bookmark keeps it, so the option is
            // simply absent rather than replaced.
            #if os(macOS)
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
            #else
            let bookmark = try url.bookmarkData()
            #endif
            UserDefaults.standard.set(bookmark, forKey: defaultsKey)
            open(url)
        } catch {
            problem = String(localized: "Could not keep access to that folder: \(error.localizedDescription)")
        }
    }

    func forget() {
        stopAccessing()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        skills = []
        folderName = nil
        problem = nil
    }

    private func restore() {
        guard let bookmark = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        var stale = false
        #if os(macOS)
        let resolved = try? URL(resolvingBookmarkData: bookmark,
                                options: .withSecurityScope,
                                relativeTo: nil,
                                bookmarkDataIsStale: &stale)
        #else
        let resolved = try? URL(resolvingBookmarkData: bookmark,
                                relativeTo: nil,
                                bookmarkDataIsStale: &stale)
        #endif
        guard let url = resolved else {
            problem = String(localized: "The skills folder could not be found. Choose it again in Settings.")
            return
        }
        open(url)
        // A stale bookmark still resolves but will not survive much longer;
        // rewriting it now avoids losing access silently later.
        if stale { adopt(url) }
    }

    // MARK: - Reading

    private func open(_ url: URL) {
        stopAccessing()
        guard url.startAccessingSecurityScopedResource() else {
            problem = String(localized: "Permission to read the skills folder was refused.")
            return
        }
        accessing = url
        folderName = url.lastPathComponent
        problem = nil
        reload()
    }

    private func stopAccessing() {
        accessing?.stopAccessingSecurityScopedResource()
        accessing = nil
    }

    /// Re-reads the folder. Only the head of each file, since a `/` menu needs
    /// two fields and the library measured here is 41 MB across 705 files.
    func reload() {
        guard let root = accessing else { return }
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            problem = String(localized: "The skills folder could not be read.")
            return
        }

        var found: [SkillManifest] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let file = entry.appending(path: "SKILL.md")
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let head = try? handle.read(upToCount: SkillIndex.manifestPrefixBytes),
                  let text = String(data: head, encoding: .utf8),
                  var manifest = SkillIndex.manifest(fromHead: text, folder: entry)
            else { continue }

            // Only the top level. A script under `references/` is material the
            // skill cites, not something it runs.
            let names = (try? manager.contentsOfDirectory(atPath: entry.path)) ?? []
            let hasScripts = names.contains {
                $0.hasSuffix(".py") || $0.hasSuffix(".sh") || $0.hasSuffix(".js")
            }
            manifest = SkillManifest(name: manifest.name, description: manifest.description,
                                     url: manifest.url, hasScripts: hasScripts)
            found.append(manifest)
        }
        skills = found.sorted { $0.name < $1.name }
    }

    /// The instructions to send, or nil if the file has gone.
    func instructions(for skill: SkillManifest) -> String? {
        guard let text = try? String(contentsOf: skill.url.appending(path: "SKILL.md"),
                                     encoding: .utf8) else { return nil }
        return SkillIndex.instructions(from: text)
    }

    func matching(_ query: String) -> [SkillManifest] {
        SkillIndex.matching(query, in: skills)
    }
}
