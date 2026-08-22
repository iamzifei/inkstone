import Testing
import Foundation
@testable import InkstoneCore

@Suite("Attachments")
struct AttachmentTests {
    private let root = URL(fileURLWithPath: "/vault")

    /// A small vault: two notes, an attachments folder, and a same-named image
    /// in two places so ambiguity resolution gets exercised.
    private func tree() -> FileNode {
        func file(_ path: String) -> FileNode {
            FileNode(url: root.appending(path: path), isDirectory: false)
        }
        return FileNode(url: root, isDirectory: true, children: [
            file("Home.md"),
            FileNode(url: root.appending(path: "Attachments"), isDirectory: true, children: [
                file("Attachments/diagram.png"),
                file("Attachments/clip.mp4"),
                file("Attachments/shared.png"),
            ]),
            FileNode(url: root.appending(path: "Ideas"), isDirectory: true, children: [
                file("Ideas/Product Ideas.md"),
                file("Ideas/shared.png"),
            ]),
        ])
    }

    // MARK: - Kind

    @Test("Extensions map to the right kind")
    func kinds() {
        #expect(AttachmentKind(pathExtension: "PNG") == .image)
        #expect(AttachmentKind(pathExtension: "heic") == .image)
        #expect(AttachmentKind(pathExtension: "mov") == .video)
        #expect(AttachmentKind(pathExtension: "m4a") == .audio)
        #expect(AttachmentKind(pathExtension: "pdf") == .pdf)
        #expect(AttachmentKind(pathExtension: "zip") == .other)
        #expect(AttachmentKind(pathExtension: "") == .other)
    }

    @Test("Only images render inline")
    func inlineRenderable() {
        #expect(AttachmentKind.image.isInlineRenderable)
        #expect(!AttachmentKind.video.isInlineRenderable)
        #expect(!AttachmentKind.pdf.isInlineRenderable)
    }

    // MARK: - Index

    @Test("Notes and canvases are not attachments")
    func excludesNotes() {
        let index = AttachmentIndex(tree: tree())
        #expect(index.count == 4)
        #expect(!index.all.contains { $0.pathExtension == "md" })
    }

    @Test("Resolves a bare file name from anywhere in the vault")
    func resolvesByName() {
        let index = AttachmentIndex(tree: tree())
        let from = root.appending(path: "Home.md")
        #expect(index.resolve("diagram.png", from: from, vaultRoot: root)?.lastPathComponent == "diagram.png")
    }

    @Test("Resolves an explicit vault-relative path")
    func resolvesByPath() {
        let index = AttachmentIndex(tree: tree())
        let from = root.appending(path: "Home.md")
        let resolved = index.resolve("Attachments/clip.mp4", from: from, vaultRoot: root)
        #expect(resolved?.path == "/vault/Attachments/clip.mp4")
    }

    @Test("An ambiguous name resolves to the nearest copy")
    func resolvesNearest() {
        let index = AttachmentIndex(tree: tree())
        // Linking from inside Ideas/ should prefer Ideas/shared.png over the one
        // in Attachments/, the same way note links disambiguate.
        let fromIdeas = root.appending(path: "Ideas/Product Ideas.md")
        #expect(index.resolve("shared.png", from: fromIdeas, vaultRoot: root)?.path == "/vault/Ideas/shared.png")
    }

    @Test("An unknown target resolves to nothing")
    func unresolved() {
        let index = AttachmentIndex(tree: tree())
        let from = root.appending(path: "Home.md")
        #expect(index.resolve("missing.png", from: from, vaultRoot: root) == nil)
        #expect(index.resolve("", from: from, vaultRoot: root) == nil)
    }

    // MARK: - Sync policy

    @Test("Notes always sync, whatever the policy says")
    func notesAlwaysSync() {
        var policy = SyncFilePolicy()
        policy.syncsImages = false
        policy.syncsOtherFiles = false
        #expect(policy.allows(root.appending(path: "Home.md")))
        #expect(policy.allows(root.appending(path: "Map.canvas")))
    }

    @Test("Attachment kinds follow their switches")
    func kindSwitches() {
        var policy = SyncFilePolicy()
        #expect(policy.allows(root.appending(path: "a.png")))
        #expect(!policy.allows(root.appending(path: "a.mp4")))  // video off by default

        policy.setSyncs(.video, true)
        policy.setSyncs(.image, false)
        #expect(policy.allows(root.appending(path: "a.mp4")))
        #expect(!policy.allows(root.appending(path: "a.png")))
    }

    @Test("The size ceiling excludes large files")
    func sizeCeiling() {
        var policy = SyncFilePolicy()
        policy.maximumFileSizeMB = 10
        let image = root.appending(path: "big.png")
        #expect(policy.allows(image, sizeBytes: 5 * 1_048_576))
        #expect(!policy.allows(image, sizeBytes: 20 * 1_048_576))
        // Unknown size cannot be excluded on size alone.
        #expect(policy.allows(image, sizeBytes: nil))

        policy.maximumFileSizeMB = 0  // no limit
        #expect(policy.allows(image, sizeBytes: 900 * 1_048_576))
    }

    @Test("A size ceiling never overrides notes")
    func ceilingSpareNotes() {
        var policy = SyncFilePolicy()
        policy.maximumFileSizeMB = 1
        #expect(policy.allows(root.appending(path: "Huge.md"), sizeBytes: 50 * 1_048_576))
    }

    @Test("Policy round-trips through Codable")
    func codable() throws {
        var policy = SyncFilePolicy()
        policy.setSyncs(.video, true)
        policy.maximumFileSizeMB = 42
        let data = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(SyncFilePolicy.self, from: data) == policy)
    }
}

/// Settings are loaded with `try?`, so a decode failure silently resets every
/// preference the user has. Adding a required field is therefore a breaking
/// change disguised as a one-line edit. This suite guards that boundary.
@Suite("Settings compatibility")
struct SettingsCompatibilityTests {

    @Test("Settings written before sync policy existed still decode")
    func decodesLegacySettings() throws {
        // Exactly what an older build would have written: every field it knew
        // about, and nothing for the key added since.
        var current = SettingsData()
        current.attachmentFolder = "Files"
        current.dailyNoteFolder = "Journal"

        var object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(current)
        ) as! [String: Any]
        object.removeValue(forKey: "syncPolicy")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SettingsData.self, from: legacy)
        // The user's existing choices survive...
        #expect(decoded.attachmentFolder == "Files")
        #expect(decoded.dailyNoteFolder == "Journal")
        // ...and the new setting comes back as its default rather than throwing,
        // which would have reset every preference on first launch.
        #expect(decoded.syncPolicy == SyncFilePolicy())
    }

    @Test("Any single missing key falls back to its default")
    func toleratesAnyMissingKey() throws {
        // Guards the whole struct, not just the newest field: dropping any one
        // key must not take the other preferences down with it.
        var current = SettingsData()
        current.attachmentFolder = "Files"
        current.tabSize = 8
        let encoded = try JSONEncoder().encode(current)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]

        for key in object.keys {
            var stripped = object
            stripped.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: stripped)
            let decoded = try? JSONDecoder().decode(SettingsData.self, from: data)
            #expect(decoded != nil, "removing \(key) made the whole settings file undecodable")
        }
    }

    @Test("Sync policy survives a settings round-trip")
    func roundTripsSyncPolicy() throws {
        var data = SettingsData()
        data.syncPolicy.setSyncs(.video, true)
        data.syncPolicy.maximumFileSizeMB = 250

        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(SettingsData.self, from: encoded)
        #expect(decoded.syncPolicy.syncsVideos)
        #expect(decoded.syncPolicy.maximumFileSizeMB == 250)
    }
}
