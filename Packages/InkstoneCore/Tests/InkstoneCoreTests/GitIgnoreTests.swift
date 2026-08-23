import Foundation
import Testing
@testable import InkstoneCore

@Suite("Gitignore")
struct GitIgnoreTests {

    /// Modelled on a real vault's `.gitignore` — CJK folder names, a trailing
    /// slash, a glob and a rooted path — rather than on an imagined one. The
    /// names are neutral: this repository is public, and a test fixture is no
    /// place to publish someone's folder structure.
    private let realVault = GitIgnore(contents: """
        _pdf/
        .DS_Store
        *.tmp
        /tmp/
        _归档PDF/
        _日志/
        _录音/
        """)

    @Test("A directory pattern covers everything under it")
    func directoryPattern() {
        #expect(realVault.ignores("_归档PDF/06-Drucker-Practice-of-Management.pdf"))
        #expect(realVault.ignores("_录音/课程/2026-06-27 09:44:51.wav"))
        #expect(realVault.ignores("_日志/a/b/c.md"))
    }

    @Test("Notes outside those folders are untouched")
    func keepsEverythingElse() {
        #expect(!realVault.ignores("00_首页.md"))
        #expect(!realVault.ignores("01-素材/知识库/06-Drucker.md"))
        // Similar name, different folder.
        #expect(!realVault.ignores("_归档PDF-notes/summary.md"))
    }

    @Test("A bare name matches at any depth")
    func bareName() {
        #expect(realVault.ignores(".DS_Store"))
        #expect(realVault.ignores("a/b/.DS_Store"))
    }

    @Test("A glob matches within one component")
    func glob() {
        #expect(realVault.ignores("draft.tmp"))
        #expect(realVault.ignores("a/b/draft.tmp"))
        #expect(!realVault.ignores("draft.tmp.md"))
    }

    /// `/tmp/` is rooted, so it must not swallow a `tmp` folder further down —
    /// which is the whole reason git has the distinction.
    @Test("A rooted pattern only matches at the root")
    func rootedPattern() {
        #expect(realVault.ignores("tmp/scratch.md"))
        #expect(!realVault.ignores("notes/tmp/scratch.md"))
    }

    @Test("A later rule wins, so ! un-ignores")
    func negation() {
        let ignore = GitIgnore(contents: """
            *.log
            !keep.log
            """)
        #expect(ignore.ignores("run.log"))
        #expect(!ignore.ignores("keep.log"))
    }

    @Test("Comments and blank lines are skipped")
    func commentsAndBlanks() {
        let ignore = GitIgnore(contents: """
            # a comment
            
            *.bak
            """)
        #expect(ignore.ignores("x.bak"))
        #expect(!ignore.ignores("# a comment"))
    }

    @Test("No file means no rules, and nothing is ignored")
    func empty() {
        let ignore = GitIgnore(contents: "")
        #expect(ignore.isEmpty)
        #expect(!ignore.ignores("anything.md"))
    }

    /// Patterns this subset does not implement must leave files alone rather
    /// than half-matching them.
    @Test("An unsupported pattern does not ignore by accident")
    func unsupportedPatternIsInert() {
        let ignore = GitIgnore(contents: "docs/**/private")
        #expect(!ignore.ignores("docs/a/private/secret.md"))
    }
}

/// The scan has to treat an ignored file as excluded, not as absent.
@Suite("Gitignore in the vault scan")
struct GitIgnoreScanTests {

    @Test("An ignored file is reported as excluded, not missing")
    func ignoredIsExcludedNotMissing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-ignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appending(path: "_归档PDF"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ignore me\n".utf8).write(to: root.appending(path: "_归档PDF/big.pdf"))
        try Data("keep me\n".utf8).write(to: root.appending(path: "Note.md"))
        try Data("_归档PDF/\n".utf8).write(to: root.appending(path: ".gitignore"))

        let engine = SyncEngine(
            client: GitHubClient(configuration: .init(repository: "a/b", branch: "main"), token: "t"),
            vaultRoot: root,
            policy: SyncFilePolicy()
        )
        let (files, excluded) = engine.localFiles()

        #expect(files.keys.contains("Note.md"))
        #expect(!files.keys.contains("_归档PDF/big.pdf"))
        // The distinction that matters: excluded, so the planner skips it in both
        // directions rather than reading its absence as a deletion.
        #expect(excluded.contains("_归档PDF/big.pdf"))
        #expect(
            SyncPlanner.plan(
                entries: [SyncEntry(path: "_归档PDF/big.pdf", local: nil, remote: "abc", base: "abc")],
                excludedLocally: excluded
            ) == [.skip(path: "_归档PDF/big.pdf", reason: .filtered)]
        )
    }

    /// `.gitignore` itself is an ordinary file and should still sync.
    @Test("The .gitignore file is not ignored by itself")
    func gitignoreItselfSyncs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-ignore2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("*.tmp\n".utf8).write(to: root.appending(path: ".gitignore"))
        try Data("x\n".utf8).write(to: root.appending(path: "Note.md"))

        let engine = SyncEngine(
            client: GitHubClient(configuration: .init(repository: "a/b", branch: "main"), token: "t"),
            vaultRoot: root,
            policy: SyncFilePolicy()
        )
        let (files, _) = engine.localFiles()
        #expect(files.keys.contains("Note.md"))
    }
}
