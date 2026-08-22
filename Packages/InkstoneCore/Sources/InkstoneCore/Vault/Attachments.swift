import Foundation

/// What kind of file an attachment is, derived from its extension.
///
/// The editor needs this to decide how to present an `![[embed]]`: an image is
/// drawn inline, a video or PDF gets a card you can click, and anything unknown
/// falls back to a plain file chip rather than pretending it can be rendered.
public enum AttachmentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case image
    case video
    case audio
    case pdf
    case other

    public init(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp", "svg":
            self = .image
        case "mp4", "mov", "m4v", "webm", "avi", "mkv":
            self = .video
        case "mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff":
            self = .audio
        case "pdf":
            self = .pdf
        default:
            self = .other
        }
    }

    public init(url: URL) {
        self.init(pathExtension: url.pathExtension)
    }

    /// True when the file can be shown inline in the editor rather than as a link.
    public var isInlineRenderable: Bool { self == .image }
}

/// Files a vault contains that are not notes, indexed for link resolution.
///
/// Wikilink resolution in `NoteIndex` assumes a `.md` target, so `![[diagram.png]]`
/// could never resolve. Rather than complicating that path, attachments get their
/// own index built from the same file tree the browser already scans — no extra
/// I/O, and resolution stays a pure in-memory lookup that can be unit tested.
public struct AttachmentIndex: Sendable {
    /// Every non-note file in the vault, keyed by lowercased file name.
    private var namesToURLs: [String: [URL]] = [:]
    public private(set) var all: [URL] = []

    public init() {}

    public init(tree: FileNode) {
        insert(tree)
        all.sort { $0.path < $1.path }
    }

    private mutating func insert(_ node: FileNode) {
        if node.isDirectory {
            for child in node.children ?? [] { insert(child) }
            return
        }
        // Notes and canvases are the note index's business, not ours.
        let ext = node.url.pathExtension.lowercased()
        guard !["md", "markdown", "canvas"].contains(ext) else { return }

        namesToURLs[node.name.lowercased(), default: []].append(node.url)
        all.append(node.url)
    }

    public var count: Int { all.count }

    /// Resolves an embed target such as `diagram.png` or `Attachments/clip.mp4`.
    ///
    /// Mirrors how Obsidian resolves attachments: an exact path first, then a
    /// path relative to the linking note, then a unique file name anywhere in the
    /// vault, and finally — when the name is ambiguous — the copy nearest the
    /// note doing the linking.
    public func resolve(_ target: String, from source: URL, vaultRoot: URL) -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let byPath = vaultRoot.appending(path: trimmed)
        if contains(byPath) { return byPath }

        let relative = source.deletingLastPathComponent().appending(path: trimmed)
        if contains(relative) { return relative }

        let key = (trimmed as NSString).lastPathComponent.lowercased()
        guard let candidates = namesToURLs[key], !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }

        let folder = source.deletingLastPathComponent()
        return candidates.min { distance(from: folder, to: $0) < distance(from: folder, to: $1) }
    }

    private func contains(_ url: URL) -> Bool {
        namesToURLs[url.lastPathComponent.lowercased()]?.contains { $0.path == url.path } ?? false
    }

    /// Path components separating a folder from a file — the same proximity
    /// heuristic `NoteIndex` uses to disambiguate same-named notes.
    private func distance(from folder: URL, to file: URL) -> Int {
        let a = folder.pathComponents
        let b = file.deletingLastPathComponent().pathComponents
        var shared = 0
        while shared < min(a.count, b.count), a[shared] == b[shared] { shared += 1 }
        return (a.count - shared) + (b.count - shared)
    }
}

/// Which files a vault is allowed to sync.
///
/// Requested explicitly: "同步可以选择同步的文件类型". Notes are never optional —
/// a vault that syncs its attachments but not its notes is nonsense — so only
/// the attachment kinds are switchable, plus a size ceiling, which in practice
/// is what stops a stray 4GB screen recording from saturating someone's iCloud.
public struct SyncFilePolicy: Codable, Hashable, Sendable {
    public var syncsImages = true
    public var syncsAudio = true
    public var syncsPDFs = true
    public var syncsVideos = false
    public var syncsOtherFiles = false
    /// Files larger than this are skipped regardless of kind. Zero means no limit.
    /// 38 MB, which is what GitHub's API will actually accept — measured, not
    /// looked up: a 38 MB file uploads and a 44 MB one is refused, by both the
    /// Contents and the Git Data endpoints, because the bytes travel base64 at
    /// four thirds their size.
    ///
    /// It was 100 MB, the figure for a git blob pushed over the wire. That
    /// default guaranteed failure for every file between the two numbers, on
    /// every run, forever — three of them in one real vault.
    public var maximumFileSizeMB = 38

    public init() {}

    public func syncs(_ kind: AttachmentKind) -> Bool {
        switch kind {
        case .image: return syncsImages
        case .audio: return syncsAudio
        case .pdf: return syncsPDFs
        case .video: return syncsVideos
        case .other: return syncsOtherFiles
        }
    }

    public mutating func setSyncs(_ kind: AttachmentKind, _ enabled: Bool) {
        switch kind {
        case .image: syncsImages = enabled
        case .audio: syncsAudio = enabled
        case .pdf: syncsPDFs = enabled
        case .video: syncsVideos = enabled
        case .other: syncsOtherFiles = enabled
        }
    }

    /// Whether a file should be included in a sync run.
    /// - Parameter sizeBytes: pass `nil` when the size is not known yet.
    /// The file whose whole job is saying what this vault does not carry.
    public static let ignoreFileName = ".gitignore"

    public func allows(_ url: URL, sizeBytes: Int? = nil) -> Bool {
        // The vault's own rules travel with the vault.
        //
        // Without this the file is invisible twice over: it is hidden, so the
        // enumerator skips it, and it has no extension, so the policy files it
        // under "other" — which is off by default. The result is a second device
        // holding the same notes and none of the rules about which of them to
        // carry, so it happily uploads everything the first device deliberately
        // excludes. Not a hypothetical: one vault's `.gitignore` excludes a
        // folder of source recordings, and they sit in its repository anyway.
        if url.lastPathComponent == SyncFilePolicy.ignoreFileName { return true }

        let ext = url.pathExtension.lowercased()
        // Notes, canvases and the app's own state always sync.
        if ["md", "markdown", "canvas"].contains(ext) { return true }

        guard syncs(AttachmentKind(pathExtension: ext)) else { return false }
        if maximumFileSizeMB > 0, let sizeBytes {
            return sizeBytes <= maximumFileSizeMB * 1_048_576
        }
        return true
    }
}
