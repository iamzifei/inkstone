import Testing
import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import InkstoneCore

/// 0.5.0 P4: the organizer files what lands in the inbox — and keeps the two
/// hard rules: nothing is ever deleted or lost (only moved), and every round
/// can be undone exactly.
@Suite("Organizer")
struct OrganizerTests {
    // MARK: fixtures

    func vault(_ language: KnowledgeBaseLanguage = .simplifiedChinese) throws -> (URL, KnowledgeBaseLayout) {
        // Resolved: the temporary folder is behind a symlink (/var → /private/var),
        // and the helpers below compare paths textually.
        var root = FileManager.default.temporaryDirectory.appending(path: "org-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: CanonicalPath.of(root))
        try VaultBlueprint.apply(to: root, language: language)
        return (root, KnowledgeBaseLayout(language: language))
    }
    func put(_ root: URL, _ path: String, _ data: Data) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    func png(width: Int, height: Int, seed: UInt8) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<8 { for x in 0..<8 {
            let v = CGFloat((Int(seed) * 37 + x * 31 + y * 17) % 255) / 255
            ctx.setFillColor(red: v, green: 1 - v, blue: CGFloat((x + y) % 2), alpha: 1)
            ctx.fill(CGRect(x: x * width / 8, y: y * height / 8, width: width / 8 + 1, height: height / 8 + 1))
        } }
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
    func pdf(_ text: String) -> Data {
        // A minimal valid PDF with one text object.
        let content = "BT /F1 12 Tf 72 720 Td (\(text)) Tj ET"
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>",
                       "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
                       "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
                       "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() { offsets.append(out.utf8.count); out += "\(i + 1) 0 obj\n\(o)\nendobj\n" }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        objects.removeAll()
        return Data(out.utf8)
    }
    /// A path below the root (the root URL may or may not end in "/").
    func relative(_ url: URL, _ root: URL) -> String {
        var base = root.path(percentEncoded: false)
        if !base.hasSuffix("/") { base += "/" }
        return String(url.path(percentEncoded: false).dropFirst(base.count))
    }
    /// Every file under the vault (system and hidden folders excluded) by
    /// content hash — what must survive any organizing unchanged.
    func contents(_ root: URL, layout: KnowledgeBaseLayout, skipSystem: Bool = true) -> [String: Int] {
        var out: [String: Int] = [:]
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])!
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let rel = relative(url, root)
            if skipSystem, rel.hasPrefix(layout.system + "/") || EntryFiles.names.contains(rel) { continue }
            let data = (try? Data(contentsOf: url)) ?? Data()
            let h = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            out[h, default: 0] += 1
        }
        return out
    }
    func allFiles(_ root: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])!
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            out["/" + relative(url, root)] = try? Data(contentsOf: url)
        }
        return out
    }
    let fixedDate = ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z")!

    // MARK: type detection

    @Test func detectsTypesByHeaderNotJustExtension() throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "\(layout.inbox)/photo.txt", png(width: 40, height: 30, seed: 1))   // a PNG with the wrong extension
        try put(root, "\(layout.inbox)/report.pdf", pdf("Quarterly report"))
        try put(root, "\(layout.inbox)/note.md", Data("# Hello\n".utf8))
        let kinds = Dictionary(uniqueKeysWithValues: try Organizer.inboxFiles(root: root, layout: layout).map {
            ($0.lastPathComponent, FileKind.detect($0))
        })
        #expect(kinds["photo.txt"] == .image)
        #expect(kinds["report.pdf"] == .pdf)
        #expect(kinds["note.md"] == .markdown)
    }

    // MARK: the hard rules

    @Test func organizingOnlyMovesNeverLosesAFile() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "\(layout.inbox)/IMG_0001.png", png(width: 64, height: 48, seed: 2))
        try put(root, "\(layout.inbox)/IMG_0001 copy.png", png(width: 64, height: 48, seed: 2))   // exact duplicate
        try put(root, "\(layout.inbox)/新建 文本文档 (1).md", Data("今天读了一本书。\n".utf8))
        try put(root, "\(layout.inbox)/身份证扫描.pdf", pdf("ID"))
        try put(root, "\(layout.inbox)/song.mp3", Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 0] + Array(repeating: 0, count: 64)))
        let before = contents(root, layout: layout)
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let plan = try await organizer.plan()
        _ = try organizer.execute(plan)
        #expect(contents(root, layout: layout) == before)                // same files, same bytes, same counts
        #expect(try Organizer.inboxFiles(root: root, layout: layout).isEmpty)   // inbox emptied
    }

    @Test func undoRestoresTheVaultExactly() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "10-项目/花园"), withIntermediateDirectories: true)
        try put(root, "\(layout.inbox)/a.png", png(width: 32, height: 32, seed: 3))
        try put(root, "\(layout.inbox)/花园笔记.md", Data("---\ntitle: 花园\n---\nRoses.\n".utf8))   // gets front matter
        try put(root, "\(layout.inbox)/dropped/inner/dup.png", png(width: 32, height: 32, seed: 3))  // a dropped folder
        _ = try EntryFiles.refresh(in: root)      // the folders made by hand above, already in the entry files
        let before = allFiles(root)
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let result = try organizer.execute(try await organizer.plan())
        #expect(result.failures.isEmpty)
        #expect(result.moved == 3)
        #expect(allFiles(root) != before)
        let undone = try organizer.undo(batch: result.batch)
        #expect(undone.restored == 3)
        #expect(undone.skipped.isEmpty)
        // Every file back where it was with its exact bytes — index and
        // duplicates record included; only the log records the round.
        var after = allFiles(root), expected = before
        after["/" + layout.logFile] = nil; expected["/" + layout.logFile] = nil
        #expect(after == expected)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "\(layout.inbox)/dropped/inner").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "40-素材/图片").appending(path: FileNaming.month(.now)).path))
        // Twice is refused.
        #expect(throws: OrganizeError.alreadyUndone) { try organizer.undo(batch: result.batch) }
    }

    @Test func undoNeverOverwritesANoteEditedSince() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "10-项目/花园"), withIntermediateDirectories: true)
        try put(root, "\(layout.inbox)/花园笔记.md", Data("Roses.\n".utf8))
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let result = try organizer.execute(try await organizer.plan())
        let filed = root.appending(path: try #require(result.plan.moves.first).to)
        let edited = try String(contentsOf: filed, encoding: .utf8) + "My new paragraph.\n"
        try edited.write(to: filed, atomically: false, encoding: .utf8)
        let undone = try organizer.undo(batch: result.batch)
        #expect(undone.skipped.contains { $0.contains("edited since") })
        // Moved back, with the edit.
        #expect(try String(contentsOf: root.appending(path: "\(layout.inbox)/花园笔记.md"), encoding: .utf8) == edited)
    }

    @Test func aMoveThatCannotBeMadeIsReportedAndTheRestGoAhead() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "\(layout.inbox)/a.png", png(width: 20, height: 20, seed: 40))
        try put(root, "\(layout.inbox)/b.mp3", Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 0] + Array(repeating: 1, count: 64)))
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let plan = try await organizer.plan()
        // A file where the image month folder must go.
        let imageFolder = (try #require(plan.moves.first { $0.from.hasSuffix("a.png") }).to as NSString).deletingLastPathComponent
        try put(root, imageFolder, Data("in the way".utf8))
        let result = try organizer.execute(plan)
        #expect(result.failures.map(\.from) == ["\(layout.inbox)/a.png"])
        #expect(result.moved == 1)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "\(layout.inbox)/a.png").path))
        let undone = try organizer.undo(batch: result.batch)
        #expect(undone.restored == 1)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "\(layout.inbox)/b.mp3").path))
    }

    @Test func aFileChangedAfterPlanningIsLeftAlone() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "\(layout.inbox)/a.png", png(width: 20, height: 20, seed: 41))
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let plan = try await organizer.plan()
        try put(root, "\(layout.inbox)/a.png", png(width: 22, height: 20, seed: 42))
        let result = try organizer.execute(plan)
        #expect(result.moved == 0)
        #expect(result.failures.first?.reason == "changed since planned")
    }

    @Test func aChangedPlanCannotMoveIntoTheMachineryOrOutOfTheInbox() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "\(layout.inbox)/a.png", png(width: 20, height: 20, seed: 43))
        try put(root, "30-资料/keep.md", Data("mine\n".utf8))
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        var plan = try await organizer.plan()
        plan.moves[0].to = "_系统/a.png"
        plan.moves.append(OrganizeMove(from: "30-资料/keep.md", to: "30-资料/x/keep.md", kind: .file, reason: ""))
        plan.moves.append(OrganizeMove(from: "\(layout.inbox)/../30-资料/keep.md", to: "30-资料/y.md", kind: .file, reason: ""))
        let result = try organizer.execute(plan)
        #expect(result.moved == 0)
        #expect(result.failures.count == 3)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "30-资料/keep.md").path))
    }

    @Test func namesWithLineBreaksAndEdgeSpacesUndoExactly() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        let names = ["a\nb.png", " lead.png", "trail .png", "back\\slash|pipe.png"]
        for (i, n) in names.enumerated() { try put(root, "\(layout.inbox)/\(n)", png(width: 20, height: 20, seed: UInt8(50 + i))) }
        let before = allFiles(root)
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let result = try organizer.execute(try await organizer.plan())
        #expect(result.moved == names.count)
        try organizer.undo(batch: result.batch)
        for n in names { #expect(allFiles(root)["/\(layout.inbox)/\(n)"] == before["/\(layout.inbox)/\(n)"], "\(n)") }
    }

    @Test func aTamperedLogCannotReachOutsideTheVault() throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appending(path: "outside-\(UUID().uuidString).txt")
        try Data("victim".utf8).write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
        let log = OrganizeLog(root: root, layout: layout)
        try log.append(batch: "b1", action: .move, from: "../\(outside.lastPathComponent)", to: "30-资料/x.txt", reason: "", now: .now)
        try put(root, "30-资料/x.txt", Data("decoy".utf8))
        try log.append(batch: "b2", action: .move, from: "30-资料/y.txt", to: "../\(outside.lastPathComponent)", reason: "", now: .now)
        let organizer = Organizer(root: root, layout: layout, advisor: nil)
        _ = try organizer.undo(batch: "b1")
        _ = try organizer.undo(batch: "b2")
        #expect(try String(contentsOf: outside, encoding: .utf8) == "victim")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "30-资料/x.txt").path))
    }

    @Test func aSymlinkedFolderCannotCarryAFileOutOfTheVault() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.deletingLastPathComponent().appending(path: "elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "20-领域/link"), withDestinationURL: elsewhere)
        try put(root, "\(layout.inbox)/n.md", Data("x\n".utf8))
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let plan = ChangePlan(moves: [OrganizeMove(from: "\(layout.inbox)/n.md", to: "20-领域/link/n.md", kind: .file, reason: "")], suggestions: [])
        let result = try organizer.execute(plan)
        #expect(result.moved == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test func machineryIsRefusedWhateverTheCase() {
        let en = KnowledgeBaseLayout(language: .english)
        let organizer = Organizer(root: URL(fileURLWithPath: "/tmp/x"), layout: en, advisor: nil)
        for bad in ["_archive/To-Delete", "_SYSTEM", "_review/x", "00-inbox"] { #expect(organizer.sanitize(bad) == nil, "\(bad)") }
        #expect(organizer.sanitize("10-Projects/Garden") == "10-Projects/Garden")
    }

    @Test func aLookAlikePictureGoesToReviewNotToTheBin() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "40-素材/图片/2026-11/20261119-原图.png", png(width: 400, height: 300, seed: 13))
        try put(root, "\(layout.inbox)/小图.png", png(width: 120, height: 90, seed: 13))
        let plan = try await Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate }).plan()
        #expect(plan.moves.first?.to.hasPrefix(layout.review + "/") == true)
        #expect(plan.suggestions.first?.b == "40-素材/图片/2026-11/20261119-原图.png")
    }

    @Test func aNearlyIdenticalNoteGoesToReviewAndTheFiledOneStays() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        let base = (0..<400).map { "Sentence number \($0) talks about gardens, roses and pruning in winter." }.joined(separator: "\n")
        try put(root, "30-资料/园艺/20260101-玫瑰.md", Data(base.utf8))       // long: past the 4,000-character window
        try put(root, "\(layout.inbox)/玫瑰 新.md", Data((base.replacingOccurrences(of: "number 7 talks", with: "number 7 speaks") + "\nOne more.").utf8))
        let plan = try await Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate }).plan()
        #expect(plan.moves.count == 1)
        #expect(plan.moves.first?.to.hasPrefix(layout.review + "/") == true)
        #expect(plan.suggestions.first?.b == "30-资料/园艺/20260101-玫瑰.md")
    }

    @Test func packagesAndProjectFoldersAreKeptWhole() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "\(layout.inbox)/doc.rtfd/TXT.rtf", Data("{\\rtf1 hi}".utf8))
        try put(root, "\(layout.inbox)/repo/.git/HEAD", Data("ref".utf8))
        try put(root, "\(layout.inbox)/repo/main.swift", Data("print(1)".utf8))
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let plan = try await organizer.plan()
        #expect(Set(plan.moves.map(\.from)) == ["\(layout.inbox)/doc.rtfd", "\(layout.inbox)/repo"])
        #expect(plan.moves.allSatisfy { $0.kind == .review })
        let result = try organizer.execute(plan)
        #expect(result.moved == 2)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "\(layout.review)/repo/.git/HEAD").path))
    }

    @Test func privacyWinsOverTheRules() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        let rules = root.appending(path: layout.rulesFile)
        let text = try String(contentsOf: rules, encoding: .utf8).replacingOccurrences(of: "## 我的规则\n", with: "## 我的规则\n\n- 发票 → 20-领域/财务\n")
        try text.write(to: rules, atomically: true, encoding: .utf8)
        try put(root, "\(layout.inbox)/发票和身份证.pdf", pdf("x"))
        let plan = try await Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate }).plan()
        #expect(plan.moves.first?.kind == .privateFile)
    }

    @Test func frontmatterThatFailsToParseOrHasABOMIsLeftAlone() {
        let layout = KnowledgeBaseLayout(language: .simplifiedChinese)
        for text in ["---\ntitle: {{title}}: x: [\n---\nbody\n", "\u{FEFF}---\na: 1\n---\nbody\n", "---\nopen: only\n"] {
            #expect(Metadata.withFrontmatter(text, origin: "x", date: .now, tags: [], summary: nil, layout: layout) == nil, "\(text)")
        }
        // Windows line endings: the front matter parser does not read them,
        // so the note is left alone rather than given a second block.
        let crlf = "---\r\na: 1\r\n---\r\nbody\r\n"
        #expect(Metadata.withFrontmatter(crlf, origin: "x", date: .now, tags: [], summary: nil, layout: layout) == nil)
    }

    @Test func addingPropertiesKeepsTheFilesCreationDate() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "10-项目/花园"), withIntermediateDirectories: true)
        try put(root, "\(layout.inbox)/花园.md", Data("Roses.\n".utf8))
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: root.appending(path: "\(layout.inbox)/花园.md").path)
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let result = try organizer.execute(try await organizer.plan())
        let filed = root.appending(path: try #require(result.plan.moves.first).to)
        #expect(try String(contentsOf: filed, encoding: .utf8).contains("来源:"))
        #expect((try filed.resourceValues(forKeys: [.creationDateKey])).creationDate == old)
    }

    @Test func noiseWordsGoOnlyAsWholeWords() {
        let date = ISO8601DateFormatter().date(from: "2026-11-19T00:00:00Z")!
        #expect(FileNaming.name(keywords: "copyright notice copy", ext: "txt", date: date, timeZone: TimeZone(identifier: "UTC")!) == "20261119-copyright-notice.txt")
        #expect(FileNaming.name(keywords: "最终用户手册", ext: "md", date: date, timeZone: TimeZone(identifier: "UTC")!) == "20261119-最终用户手册.md")
    }

    @Test func everyMoveIsLogged() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "\(layout.inbox)/x.png", png(width: 20, height: 20, seed: 4))
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let result = try organizer.execute(try await organizer.plan())
        let log = try String(contentsOf: root.appending(path: layout.logFile), encoding: .utf8)
        #expect(log.contains(result.batch))
        #expect(log.contains("\(layout.inbox)/x.png"))
    }

    // MARK: placement

    @Test func mediaGoesToItsTypeAndMonth() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "\(layout.inbox)/IMG_0007.png", png(width: 50, height: 40, seed: 5))
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let plan = try await organizer.plan()
        let move = try #require(plan.moves.first)
        #expect(move.to.hasPrefix(layout.mediaImages + "/"))
        #expect(move.to.contains("2026-11") || move.to.range(of: #"/\d{4}-\d{2}/"#, options: .regularExpression) != nil)
    }

    @Test func privateFilesGoToPrivate() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "\(layout.inbox)/护照扫描件.pdf", pdf("passport"))
        let plan = try await Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate }).plan()
        #expect(plan.moves.first?.to.hasPrefix(layout.privateFolder + "/") == true)
    }

    @Test func unsureFilesGoToReviewNotForced() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "\(layout.inbox)/随便写写.md", Data("一些想法。\n".utf8))
        let plan = try await Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate }).plan()
        #expect(plan.moves.first?.to.hasPrefix(layout.review + "/") == true)
    }

    @Test func theRulesFileWins() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        let rules = root.appending(path: layout.rulesFile)
        var text = try String(contentsOf: rules, encoding: .utf8)
        text = text.replacingOccurrences(of: "## 我的规则\n", with: "## 我的规则\n\n- 发票 → 20-领域/财务/发票/\n")
        try text.write(to: rules, atomically: true, encoding: .utf8)
        try put(root, "\(layout.inbox)/11月发票.pdf", pdf("invoice"))
        let plan = try await Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate }).plan()
        #expect(plan.moves.first?.to.hasPrefix("20-领域/财务/发票/") == true)
    }

    @Test func anExistingProjectNamedInTheFileCatchesIt() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "10-项目/装修"), withIntermediateDirectories: true)
        try put(root, "\(layout.inbox)/装修报价单.md", Data("客厅吊顶。\n".utf8))
        let plan = try await Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate }).plan()
        #expect(plan.moves.first?.to.hasPrefix("10-项目/装修/") == true)
    }

    @Test func anAdvisorDecidesWhenItIsConfident() async throws {
        struct Fixed: PlacementAdvisor {
            func advise(_ facts: FileFacts, context: AdvisorContext) async throws -> PlacementAdvice? {
                PlacementAdvice(folder: "30-资料/园艺", confidence: 0.92, title: "玫瑰修剪", tags: ["园艺"], summary: "冬季修剪玫瑰。", isPrivate: false, reason: "讲园艺")
            }
        }
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "\(layout.inbox)/note.md", Data("冬天怎么剪玫瑰。\n".utf8))
        let plan = try await Organizer(root: root, layout: layout, advisor: Fixed(), now: { self.fixedDate }).plan()
        let move = try #require(plan.moves.first)
        #expect(move.to.hasPrefix("30-资料/园艺/"))
        #expect(move.to.contains("玫瑰修剪"))
    }

    @Test func anAdvisorCannotFileIntoTheMachineryOrOutsideTheVault() async throws {
        struct Evil: PlacementAdvisor {
            let folder: String
            func advise(_ facts: FileFacts, context: AdvisorContext) async throws -> PlacementAdvice? {
                PlacementAdvice(folder: folder, confidence: 0.99, title: nil, tags: [], summary: nil, isPrivate: false, reason: "")
            }
        }
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        for bad in ["../outside", "_系统", "/etc", "_归档/待删除", "a/b/c/d/e"] {
            try put(root, "\(layout.inbox)/n.md", Data("x\n".utf8))
            let plan = try await Organizer(root: root, layout: layout, advisor: Evil(folder: bad), now: { self.fixedDate }).plan()
            #expect(plan.moves.first?.to.hasPrefix(layout.review + "/") == true, "\(bad)")
        }
    }

    // MARK: duplicates and naming

    @Test func exactDuplicatesGoToTrashAndAreRecorded() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        let image = png(width: 40, height: 40, seed: 6)
        try put(root, "40-素材/图片/2026-11/20261119-已有.png", image)
        try put(root, "\(layout.inbox)/又一份.png", image)
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let plan = try await organizer.plan()
        #expect(plan.moves.first?.to.hasPrefix(layout.trash + "/") == true)
        #expect(plan.needsConfirmation)                                   // deduplication is always confirmed
        _ = try organizer.execute(plan)
        let record = try String(contentsOf: root.appending(path: layout.duplicatesFile), encoding: .utf8)
        #expect(record.contains("20261119-已有.png"))
    }

    @Test func namesFollowThePolicy() {
        let date = ISO8601DateFormatter().date(from: "2026-11-19T00:00:00Z")!
        #expect(FileNaming.name(keywords: "季度复盘 最终版最终", ext: "md", date: date) == "20261119-季度复盘.md")
        #expect(FileNaming.name(keywords: "新建 文本文档 (1)", ext: "md", date: date) == "20261119-文本文档.md")
        #expect(FileNaming.name(keywords: "a/b:c*d?\"e<f>g|h", ext: "txt", date: date) == "20261119-a-b-c-d-e-f-g-h.txt")
        #expect(FileNaming.name(keywords: "report v2", ext: "pdf", date: date) == "20261119-report-v2.pdf")
        #expect(FileNaming.name(keywords: "   ", ext: "png", date: date) == "20261119.png")
    }

    @Test func nameCollisionsGetASuffixNeverOverwrite() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "\(layout.inbox)/x/a.png", png(width: 30, height: 30, seed: 7))
        try put(root, "\(layout.inbox)/y/A.png", png(width: 30, height: 30, seed: 8))   // same name to APFS
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let plan = try await organizer.plan()
        #expect(Set(plan.moves.map(\.to)).count == plan.moves.count)
        _ = try organizer.execute(plan)
        #expect(contents(root, layout: layout).values.reduce(0, +) == 2)
    }

    // MARK: change plan

    @Test func aBigBatchNeedsConfirmation() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<21 { try put(root, "\(layout.inbox)/n\(i).png", png(width: 16, height: 16, seed: UInt8(i + 20))) }
        let plan = try await Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate }).plan()
        #expect(plan.needsConfirmation)
    }

    @Test func aSmallBatchCanGoAhead() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "\(layout.inbox)/IMG.png", png(width: 16, height: 16, seed: 60))
        let plan = try await Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate }).plan()
        #expect(!plan.needsConfirmation)
    }

    // MARK: metadata

    @Test func markdownGetsFrontmatterButKeepsItsText() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "10-项目/装修"), withIntermediateDirectories: true)
        try put(root, "\(layout.inbox)/装修清单.md", Data("---\ntags: [家]\n---\n# 清单\n\n- 吊顶\n".utf8))
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let plan = try await organizer.plan()
        _ = try organizer.execute(plan)
        let moved = try #require(plan.moves.first)
        let text = try String(contentsOf: root.appending(path: moved.to), encoding: .utf8)
        #expect(text.contains("tags: [家]"))                 // existing keys untouched
        #expect(text.hasSuffix("# 清单\n\n- 吊顶\n"))          // body untouched
        #expect(text.contains("来源:"))                       // provenance added
    }

    @Test func nonTextFilesAreIndexed() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "\(layout.inbox)/IMG_9.png", png(width: 24, height: 24, seed: 9))
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let plan = try await organizer.plan()
        _ = try organizer.execute(plan)
        let index = try String(contentsOf: root.appending(path: layout.indexFile), encoding: .utf8)
        #expect(index.contains(try #require(plan.moves.first).to))
    }

    // MARK: fingerprints and the log

    @Test func theSamePictureResizedIsNear() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try png(width: 400, height: 300, seed: 11).write(to: dir.appending(path: "big.png"))
        try png(width: 120, height: 90, seed: 11).write(to: dir.appending(path: "small.png"))
        let a = try #require(Fingerprint.perceptualHash(dir.appending(path: "big.png")))
        let b = try #require(Fingerprint.perceptualHash(dir.appending(path: "small.png")))
        #expect(Fingerprint.distance(a, b) <= 5)
    }

    @Test func nearlyTheSameTextIsCloserThanOtherText() throws {
        let base = (0..<40).map { "Sentence number \($0) talks about gardens, roses and pruning in winter." }.joined(separator: " ")
        let edited = base.replacingOccurrences(of: "number 7 talks", with: "number 7 speaks")
        let other = (0..<40).map { "Line \($0) explains database indexes, query plans and locking." }.joined(separator: " ")
        let h = try #require(Fingerprint.simHash(base))
        let near = Fingerprint.distance(h, try #require(Fingerprint.simHash(edited)))
        let far = Fingerprint.distance(h, try #require(Fingerprint.simHash(other)))
        #expect(near <= 3)
        #expect(far > 12)
        #expect(Fingerprint.simHash("too short") == nil)
    }

    @Test func logCellsSurvivePipesAndBackslashes() {
        let row = "| t | b | move | \(OrganizeLog.escape("a|b\\c.md")) | \(OrganizeLog.escape("x/y|z.md")) | r |"
        let cells = OrganizeLog.cells(row)
        #expect(cells == ["t", "b", "move", "a|b\\c.md", "x/y|z.md", "r"])
    }

    @Test func undoWorksForAFileWithAPipeInItsName() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try put(root, "\(layout.inbox)/a|b.png", png(width: 20, height: 20, seed: 12))
        let before = allFiles(root)["/\(layout.inbox)/a|b.png"]
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let result = try organizer.execute(try await organizer.plan())
        try organizer.undo(batch: result.batch)
        #expect(allFiles(root)["/\(layout.inbox)/a|b.png"] == before)
    }

    @Test func frontmatterThatDoesNotParseIsLeftAlone() async throws {
        let (root, layout) = try vault(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "10-项目/装修"), withIntermediateDirectories: true)
        let text = "---\nthis is: [not closed\n# 装修\n"
        try put(root, "\(layout.inbox)/装修笔记.md", Data(text.utf8))
        let organizer = Organizer(root: root, layout: layout, advisor: nil, now: { self.fixedDate })
        let plan = try await organizer.plan()
        _ = try organizer.execute(plan)
        #expect(try String(contentsOf: root.appending(path: try #require(plan.moves.first).to), encoding: .utf8) == text)
    }
}
