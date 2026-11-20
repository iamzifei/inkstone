import Foundation
import Testing
@testable import InkstoneCore

/// The Mac, the iPhone and GitHub itself all changing the same knowledge base
/// before anyone syncs (asked for 2026-11-20).
///
/// Two properties, checked after every scenario has settled:
///
/// 1. **Nothing is lost or wrong.** Every version that was the latest on some
///    side when the sync started is still there afterwards — as the note or
///    as a conflict copy — on every device and on GitHub, byte for byte.
/// 2. **Copies stay proportional.** A copy exists only for a real disagreement:
///    one per losing version, never two copies of the same text, and no new
///    copies on later runs. A vault of thousands of notes with a handful of
///    disagreements must end up with a handful of copies.
///
/// The fake remote is strict here: like GitHub, it refuses a write whose `sha`
/// is not the file's current one.
extension GitHubClientTests {

  @Suite("Conflict simulation: Mac, iPhone and GitHub at once", .serialized)
  struct SyncConflictSimulationTests {
    typealias Remote = TwoDeviceSyncTests.FakeRemote

    // MARK: - Harness

    private func makeVault(_ label: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inkstone-sim-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ path: String, in vault: URL) throws {
        let url = vault.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func delete(_ path: String, in vault: URL) throws {
        try FileManager.default.removeItem(at: vault.appending(path: path))
    }

    private func sync(_ vault: URL, _ remote: Remote) async throws -> SyncReport {
        try await SyncEngine(
            client: TwoDeviceSyncTests.client(remote), vaultRoot: vault, policy: SyncFilePolicy()
        ).run()
    }

    /// Every file that takes part in sync, path → text. Hidden paths (the
    /// `.inkstone` sync state) are not part of the knowledge base.
    private func files(_ vault: URL) -> [String: String] {
        var out: [String: String] = [:]
        let base = vault.standardizedFileURL.path + "/"
        let walker = FileManager.default.enumerator(
            at: vault, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(base.count))
            out[path] = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return out
    }

    /// Syncs each device in turn until a whole round moves nothing, the way
    /// the background schedule eventually does. Returns how many rounds that
    /// took; never settling is a failure.
    @discardableResult
    private func settle(_ devices: [URL], _ remote: Remote, refresh: Bool = false,
                        cap: Int = 6) async throws -> Int {
        for round in 1...cap {
            var moved = 0
            for device in devices {
                // The app refreshes the entry files after organizing and on
                // open; doing it before every sync is the worst case.
                if refresh { _ = try EntryFiles.refresh(in: device) }
                let report = try await sync(device, remote)
                #expect(report.failures.isEmpty, "\(report.failures)")
                moved += report.uploaded.count + report.downloaded.count + report.conflicted.count
                    + report.deletedLocally.count + report.deletedRemotely.count
            }
            if moved == 0 { return round }
        }
        Issue.record("Still moving files after \(cap) rounds")
        return cap
    }

    /// The note a file is a version of: `Note (conflict 2026-11-20 101500).md`
    /// and `Note (conflict …) 2.md` are versions of `Note.md`.
    static func original(of path: String) -> String {
        path.replacingOccurrences(
            of: #" \(conflict \d{4}-\d{2}-\d{2} \d{6}\)( \d+)?"#, with: "", options: .regularExpression)
    }

    /// The two properties, against what each note must hold: the set of texts
    /// that must survive for it (absent = the note must be gone).
    private func expectSettled(_ devices: [URL], _ remote: Remote,
                               expected: [String: Set<String>],
                               sourceLocation: SourceLocation = #_sourceLocation) {
        let onRemote = remote.snapshot
        for device in devices {
            #expect(files(device) == onRemote, "device and GitHub differ", sourceLocation: sourceLocation)
        }
        let groups = Dictionary(grouping: onRemote, by: { Self.original(of: $0.key) })
        for (note, texts) in expected {
            let found = groups[note]?.map(\.value) ?? []
            // No loss and nothing wrong: exactly the expected texts…
            #expect(Set(found) == texts, "\(note): \(found.sorted()) ≠ \(texts.sorted())",
                    sourceLocation: sourceLocation)
            // …the note itself still under its own name (a note that survives
            // only as "Note (conflict …).md" has been renamed by sync)…
            #expect(onRemote[note] != nil, "\(note) survives only as a copy", sourceLocation: sourceLocation)
            // …and each only once: a second copy of the same text is clutter.
            #expect(found.count == texts.count, "\(note): \(found.count) files for \(texts.count) versions",
                    sourceLocation: sourceLocation)
        }
        let unexpected = Set(groups.keys).subtracting(expected.keys)
        #expect(unexpected.isEmpty, "unexpected notes: \(unexpected.sorted().prefix(10))",
                sourceLocation: sourceLocation)
    }

    /// `files` limited to what the default policy syncs.
    private func synced(_ vault: URL) -> [String: String] {
        files(vault).filter { SyncFilePolicy().allows(URL(fileURLWithPath: $0.key)) }
    }

    /// The `.gitkeep` files in a vault, which `files` (skipping hidden files)
    /// cannot see.
    private func keepFiles(_ vault: URL) -> Set<String> {
        let base = vault.standardizedFileURL.path + "/"
        var out: Set<String> = []
        let walker = FileManager.default.enumerator(at: vault, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if url.lastPathComponent == ".inkstone" { walker?.skipDescendants(); continue }
            if url.lastPathComponent == SyncFilePolicy.keepFileName {
                out.insert(String(url.standardizedFileURL.path.dropFirst(base.count)))
            }
        }
        return out
    }

    private func copies(_ remote: Remote) -> Int {
        remote.paths.filter { $0.contains("(conflict ") }.count
    }

    // MARK: - One note, three versions

    enum Order: String, CaseIterable { case macFirst, phoneFirst }

    @Test("Mac, iPhone and GitHub each change one note: all three versions survive, once each",
          arguments: Order.allCases)
    func threeWay(order: Order) async throws {
        let remote = Remote(); remote.strictSHA = true
        let mac = try makeVault("mac"), phone = try makeVault("phone")
        defer { [mac, phone].forEach { try? FileManager.default.removeItem(at: $0) } }

        try write("v0\n", "Notes/Note.md", in: mac)
        _ = try await sync(mac, remote)
        _ = try await sync(phone, remote)

        try write("from the mac\n", "Notes/Note.md", in: mac)
        try write("from the phone\n", "Notes/Note.md", in: phone)
        remote.put("Notes/Note.md", "from github\n")

        let devices = order == .macFirst ? [mac, phone] : [phone, mac]
        try await settle(devices, remote)
        expectSettled([mac, phone], remote, expected: [
            "Notes/Note.md": ["from the mac\n", "from the phone\n", "from github\n"],
        ])
        #expect(copies(remote) == 2)

        // Settled means settled: more runs, no more copies.
        #expect(try await settle(devices, remote) == 1)
        #expect(copies(remote) == 2)
    }

    // MARK: - The race GitHub's sha check exists for

    @Test("A push landing between listing and upload is refused, then kept as a copy")
    func pushInTheGap() async throws {
        let remote = Remote(); remote.strictSHA = true
        let mac = try makeVault("mac"), phone = try makeVault("phone")
        defer { [mac, phone].forEach { try? FileManager.default.removeItem(at: $0) } }

        try write("v0\n", "Note.md", in: mac)
        _ = try await sync(mac, remote)
        _ = try await sync(phone, remote)

        // The Mac lists the remote, then — before its upload — the phone's
        // edit lands on GitHub.
        try write("from the mac\n", "Note.md", in: mac)
        remote.beforeNextWrite = { $0.put("Note.md", "from the phone\n") }
        let first = try await sync(mac, remote)

        #expect(remote.staleWritesRefused == 1)
        #expect(first.failures.map(\.path) == ["Note.md"])
        #expect(remote.contents("Note.md") == "from the phone\n")
        #expect(files(mac)["Note.md"] == "from the mac\n")

        // The phone, meanwhile, has that edit on disk as its own version.
        try write("from the phone\n", "Note.md", in: phone)
        try await settle([mac, phone], remote)
        expectSettled([mac, phone], remote, expected: [
            "Note.md": ["from the mac\n", "from the phone\n"],
        ])
    }

    // MARK: - A real-sized knowledge base

    @Test("2,000 notes, every kind of overlap: nothing lost, one copy per real disagreement")
    func largeVault() async throws {
        let remote = Remote(); remote.strictSHA = true
        let mac = try makeVault("mac"), phone = try makeVault("phone")
        defer { [mac, phone].forEach { try? FileManager.default.removeItem(at: $0) } }

        func note(_ i: Int) -> String { "Area \(i % 20)/Note \(i).md" }
        var expected: [String: Set<String>] = [:]
        for i in 0..<2000 {
            try write("original \(i)\n", note(i), in: mac)
            expected[note(i)] = ["original \(i)\n"]
        }
        _ = try await sync(mac, remote)
        let pulled = try await sync(phone, remote)
        #expect(pulled.downloaded.count == 2000)

        // Mac edits 0..<300, phone 200..<500 (100 overlap), GitHub 450..<550
        // (50 overlap with the phone).
        for i in 0..<300 { try write("mac \(i)\n", note(i), in: mac) }
        for i in 200..<500 { try write("phone \(i)\n", note(i), in: phone) }
        for i in 450..<550 { remote.put(note(i), "github \(i)\n") }
        for i in 0..<550 {
            var texts: Set<String> = []
            if i < 300 { texts.insert("mac \(i)\n") }
            if (200..<500).contains(i) { texts.insert("phone \(i)\n") }
            if (450..<550).contains(i) { texts.insert("github \(i)\n") }
            expected[note(i)] = texts
        }
        // Phone deletes 600..<700; the Mac edits 650..<700 of them. The edit
        // wins and the note comes back; the other 50 are gone everywhere.
        for i in 600..<700 { try delete(note(i), in: phone) }
        for i in 650..<700 { try write("mac kept \(i)\n", note(i), in: mac) }
        for i in 600..<650 { expected.removeValue(forKey: note(i)) }
        for i in 650..<700 { expected[note(i)] = ["mac kept \(i)\n"] }
        // Both create new notes; 20 of the names collide.
        for i in 0..<100 { try write("new on mac \(i)\n", "Inbox/Mac \(i).md", in: mac) }
        for i in 0..<100 { expected["Inbox/Mac \(i).md"] = ["new on mac \(i)\n"] }
        for i in 0..<20 {
            try write("new on phone \(i)\n", "Inbox/Mac \(i).md", in: phone)
            expected["Inbox/Mac \(i).md"]!.insert("new on phone \(i)\n")
        }

        let rounds = try await settle([mac, phone], remote)
        #expect(rounds <= 4)
        expectSettled([mac, phone], remote, expected: expected)
        // 100 Mac/phone + 50 phone/GitHub + 20 colliding new names. The 50
        // deleted-here-edited-there notes come back under their own names.
        #expect(copies(remote) == 170, "\(copies(remote)) copies")
        #expect(try await settle([phone, mac], remote) == 1)

        // A second disagreement on ten notes that already have copies: ten
        // more copies, and the earlier copies are left as they were.
        for i in 200..<210 {
            try write("mac again \(i)\n", note(i), in: mac)
            try write("phone again \(i)\n", note(i), in: phone)
            expected[note(i)] = ["mac \(i)\n", "phone \(i)\n", "mac again \(i)\n", "phone again \(i)\n"]
                .reduce(into: Set<String>()) { $0.insert($1) }
        }
        // The first round's winner on these notes was overwritten by the
        // second round's edits on the same device — that is an ordinary edit,
        // not a loss. Keep only what was the latest somewhere.
        let before = remote.snapshot
        for i in 200..<210 {
            let winner = before[note(i)]!
            expected[note(i)]!.remove(winner)
        }
        try await settle([mac, phone], remote)
        expectSettled([mac, phone], remote, expected: expected)
        #expect(copies(remote) == 180, "\(copies(remote)) copies")
    }

    // MARK: - The files Inkstone writes itself

    @Test("A new knowledge base's empty folders reach the other device")
    func emptySkeletonTravels() async throws {
        let remote = Remote(); remote.strictSHA = true
        let parent = try makeVault("parents")
        defer { try? FileManager.default.removeItem(at: parent) }
        let mac = try KnowledgeBaseCreator.create(named: "KB", in: parent, language: .simplifiedChinese)
        let phone = parent.appending(path: "phone-kb")
        try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
        let layout = try #require(KnowledgeBaseLayout.detect(in: mac))

        _ = try await sync(mac, remote)
        _ = try await sync(phone, remote)
        var isDir: ObjCBool = false
        for folder in [layout.inbox, layout.projects, layout.mediaImages] {
            #expect(FileManager.default.fileExists(
                atPath: phone.appending(path: folder).path, isDirectory: &isDir) && isDir.boolValue, "\(folder)")
        }
        #expect(keepFiles(phone) == keepFiles(mac))
        // Same folders, so the same entry files: nothing to rewrite on either.
        #expect(try EntryFiles.refresh(in: phone).isEmpty)
        #expect(try EntryFiles.refresh(in: mac).isEmpty)
    }

    /// Found in review (2026-11-20): a folder holding only files that do not
    /// sync — images with attachment sync off, ignored notes — counted as
    /// content on the device that has them and did not exist on the other, so
    /// the two listed different folders and rewrote the entry files forever.
    @Test("Folders whose files do not sync do not set the devices against each other")
    func unsyncedContentDoesNotChurn() async throws {
        let remote = Remote(); remote.strictSHA = true
        let parent = try makeVault("parents")
        defer { try? FileManager.default.removeItem(at: parent) }
        let mac = try KnowledgeBaseCreator.create(named: "KB", in: parent, language: .english)
        let phone = parent.appending(path: "phone-kb")
        try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
        let layout = try #require(KnowledgeBaseLayout.detect(in: mac))

        try write("Drafts/\n", ".gitignore", in: mac)
        try write("private\n", "Drafts/Secret.md", in: mac)
        try write("not a real png", "\(layout.resources)/Photos/pic.png", in: mac)
        _ = try EntryFiles.refresh(in: mac)
        _ = try await sync(mac, remote)
        _ = try await sync(phone, remote)
        #expect(!remote.paths.contains("Drafts/Secret.md"))

        try await settle([mac, phone], remote, refresh: true)
        #expect(try EntryFiles.refresh(in: mac).isEmpty)
        #expect(try EntryFiles.refresh(in: phone).isEmpty)
        #expect(synced(mac).filter { !$0.key.hasPrefix("Drafts/") } == synced(phone))
        // Nothing hidden is out of step either: the keep-files match too.
        #expect(keepFiles(mac) == keepFiles(phone))
        #expect(keepFiles(phone) == Set(remote.paths.filter { $0.hasSuffix("/.gitkeep") }))
    }

    @Test("A skeleton folder deleted on one device stays deleted on both")
    func deletedSkeletonFolderStaysDeleted() async throws {
        let remote = Remote(); remote.strictSHA = true
        let parent = try makeVault("parents")
        defer { try? FileManager.default.removeItem(at: parent) }
        let mac = try KnowledgeBaseCreator.create(named: "KB", in: parent, language: .english)
        let phone = parent.appending(path: "phone-kb")
        try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
        let layout = try #require(KnowledgeBaseLayout.detect(in: mac))
        _ = try await sync(mac, remote)
        _ = try await sync(phone, remote)
        #expect(FileManager.default.fileExists(atPath: phone.appending(path: layout.outputs).path))

        try FileManager.default.removeItem(at: mac.appending(path: layout.outputs))
        try await settle([mac, phone], remote, refresh: true)
        #expect(!FileManager.default.fileExists(atPath: phone.appending(path: layout.outputs).path))
        #expect(!FileManager.default.fileExists(atPath: mac.appending(path: layout.outputs).path))
    }

    @Test("A keep-file that is not an empty marker is not uploaded")
    func oversizedKeepFileStaysLocal() async throws {
        let remote = Remote(); remote.strictSHA = true
        let mac = try makeVault("mac")
        defer { try? FileManager.default.removeItem(at: mac) }
        try write("note\n", "Folder/Note.md", in: mac)
        try write(String(repeating: "x", count: 10_000), "Folder/.gitkeep", in: mac)
        try write("", "Empty/.gitkeep", in: mac)
        let report = try await sync(mac, remote)
        #expect(report.failures.isEmpty)
        #expect(remote.paths.sorted() == ["Empty/.gitkeep", "Folder/Note.md"])
    }

    @Test("Entry files regenerated on both devices do not pile up conflict copies")
    func entryFilesOnBothDevices() async throws {
        let remote = Remote(); remote.strictSHA = true
        let parent = try makeVault("parents")
        defer { try? FileManager.default.removeItem(at: parent) }
        let mac = try KnowledgeBaseCreator.create(named: "KB", in: parent, language: .english)
        let phone = parent.appending(path: "phone-kb")
        try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
        let layout = try #require(KnowledgeBaseLayout.detect(in: mac))

        _ = try await sync(mac, remote)
        _ = try await sync(phone, remote)
        // `_System/File Index.csv` stays behind: attachments sync only when
        // opted in, and the index is rebuilt on each device.
        #expect(synced(phone) == synced(mac),
                "\(Set(synced(mac).keys).symmetricDifference(synced(phone).keys).sorted())")

        // Each device adds a different project and refreshes its entry
        // files before syncing, so both rewrite the same automatic block.
        try write("alpha\n", "\(layout.projects)/Alpha/Plan.md", in: mac)
        try write("beta\n", "\(layout.projects)/Beta/Plan.md", in: phone)
        _ = try EntryFiles.refresh(in: mac)
        _ = try EntryFiles.refresh(in: phone)

        try await settle([mac, phone], remote, refresh: true)
        let entryCopies = remote.paths.filter { path in
            path.contains("(conflict ") && EntryFiles.names.contains(Self.original(of: path))
        }
        #expect(entryCopies.isEmpty, "\(entryCopies)")
        // Settled on the merged folders: both devices agree, and neither has
        // anything left to rewrite — so no further sync traffic either.
        #expect(synced(mac) == synced(phone))
        #expect(try EntryFiles.refresh(in: mac).isEmpty)
        #expect(try EntryFiles.refresh(in: phone).isEmpty)
        let entries = EntryFiles.names.compactMap { remote.contents($0) }.joined()
        #expect(entries.contains("Alpha") && entries.contains("Beta"))

        // A person's own words in an entry file are never discarded: edits
        // outside the block on both sides are a real conflict.
        let text = try #require(files(mac)["README.md"])
        try write(text + "\nMac note.\n", "README.md", in: mac)
        try write(text + "\nPhone note.\n", "README.md", in: phone)
        try await settle([mac, phone], remote, refresh: true)
        let readmes = remote.snapshot.filter { Self.original(of: $0.key) == "README.md" }.map(\.value)
        #expect(readmes.contains { $0.contains("Mac note.") })
        #expect(readmes.contains { $0.contains("Phone note.") })
    }
  }
}
