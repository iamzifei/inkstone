import Foundation
import Testing
@testable import InkstoneCore

@Suite("Vault-relative paths")
struct VaultPathTests {

    @Test("A file inside the vault comes back with its folders and extension")
    func insideTheVault() {
        let root = URL(fileURLWithPath: "/Users/someone/Vault")
        let file = URL(fileURLWithPath: "/Users/someone/Vault/Notes/Daily/2026-08-23.md")
        #expect(VaultPath.relative(of: file, in: root) == "Notes/Daily/2026-08-23.md")
    }

    @Test("A trailing slash on the root changes nothing")
    func rootWithTrailingSlash() {
        let root = URL(fileURLWithPath: "/Users/someone/Vault/", isDirectory: true)
        let file = URL(fileURLWithPath: "/Users/someone/Vault/Note.md")
        #expect(VaultPath.relative(of: file, in: root) == "Note.md")
    }

    /// The bug this guards against is a string prefix match that does not care
    /// about folder boundaries: `/Vault-backup/…` starts with `/Vault`.
    @Test("A sibling folder with the vault's name as a prefix is not inside it")
    func siblingIsNotInside() {
        let root = URL(fileURLWithPath: "/Users/someone/Vault")
        let file = URL(fileURLWithPath: "/Users/someone/Vault-backup/Note.md")
        #expect(VaultPath.relative(of: file, in: root) == "Note.md")
    }

    @Test("A file outside the vault falls back to its own name, never an absolute path")
    func outsideFallsBackToName() {
        let root = URL(fileURLWithPath: "/Users/someone/Vault")
        let file = URL(fileURLWithPath: "/etc/hosts")
        let result = VaultPath.relative(of: file, in: root)
        #expect(result == "hosts")
        #expect(!result.hasPrefix("/"))
    }

    /// `/var` is a symlink to `/private/var`, and the two forms do not compare
    /// equal as strings. A vault in a temporary directory is stored as
    /// `/var/folders/…` while the file system hands its contents back as
    /// `/private/var/folders/…`, so the plain prefix test misses every file in
    /// the vault.
    ///
    /// Built from real directories rather than made-up paths, because
    /// `resolvingSymlinksInPath` only resolves what exists — and it normalises
    /// toward `/var`, not away from it, which is the opposite of what this test
    /// asserted when it was first written from memory.
    @Test("A vault reached through a symlink still resolves")
    func symlinkedRoot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-vp-\(UUID().uuidString)")
        let folder = root.appending(path: "Ideas")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appending(path: "Note.md")
        try Data("hi\n".utf8).write(to: file)

        // The form the file system hands back for a temporary directory.
        let asReturned = URL(fileURLWithPath: "/private" + file.path)
        #expect(FileManager.default.fileExists(atPath: asReturned.path))

        #expect(VaultPath.relative(of: asReturned, in: root) == "Ideas/Note.md")
    }

    @Test("The vault root itself has no relative path, so it reports its own name")
    func rootItself() {
        let root = URL(fileURLWithPath: "/Users/someone/Vault")
        #expect(VaultPath.relative(of: root, in: root) == "Vault")
    }
}
