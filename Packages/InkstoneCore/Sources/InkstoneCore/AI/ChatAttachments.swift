import Foundation

/// Something added to a message by hand.
///
/// Distinct from what the assistant finds for itself. A note it searched out is
/// evidence; a note the user attached is the subject, and the difference is
/// worth keeping because the model should treat them differently.
public struct ChatAttachment: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: Sendable, Hashable, Codable {
        /// A note in the vault. Carried by path, and read when the message is
        /// sent — so a note edited between attaching and sending goes as it is
        /// now, not as it was when the chip appeared.
        case note(path: String)
        /// A folder in the vault: every note under it, named but not read.
        case folder(path: String)
        /// A picture, for models that can see.
        case image(mimeType: String, data: Data)
        /// A file from outside the vault, read as text.
        case file(name: String, text: String)
        /// A passage the user selected in the editor.
        case selection(from: String, text: String)
    }

    public let id: UUID
    public let kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// What the chip says.
    public var label: String {
        switch kind {
        case .note(let path): return (path as NSString).lastPathComponent
        case .folder(let path): return (path as NSString).lastPathComponent + "/"
        case .image: return String(localized: "Image")
        case .file(let name, _): return name
        case .selection(let from, _): return String(localized: "Selection from \(from)")
        }
    }

    public var symbol: String {
        switch kind {
        case .note: return "doc.text"
        case .folder: return "folder"
        case .image: return "photo"
        case .file: return "doc"
        case .selection: return "text.quote"
        }
    }

    public var isImage: Bool {
        if case .image = kind { return true }
        return false
    }
}

/// Turns attachments into what actually goes to the model.
public enum AttachmentRenderer {
    /// How much of an attached file to send.
    ///
    /// Generous compared to a tool result, because this was chosen deliberately
    /// — someone who attaches a note means it — but still bounded: three long
    /// notes attached at once would otherwise be the entire context.
    public static let characterLimit = 24_000

    /// The text block describing everything attached, or nil if there is none.
    ///
    /// Images are not here; they go as their own blocks so a vision model
    /// receives them as pictures.
    public static func textBlock(
        for attachments: [ChatAttachment],
        readNote: (String) -> String?,
        listFolder: (String) -> [String]
    ) -> String? {
        let textual = attachments.filter { !$0.isImage }
        guard !textual.isEmpty else { return nil }

        var parts: [String] = [
            "The user attached the following. Treat these as the subject of the "
            + "question rather than as search results."
        ]

        for attachment in textual {
            switch attachment.kind {
            case .note(let path):
                guard let text = readNote(path) else {
                    parts.append("\n--- \(path) (could not be read) ---")
                    continue
                }
                parts.append("\n--- \(path) ---\n" + clip(text))

            case .folder(let path):
                let notes = listFolder(path)
                // Named, not read. A folder can hold hundreds of notes, and the
                // point of attaching one is usually "look in here", which the
                // assistant can then do with its own tools.
                let listing = notes.prefix(200).map { "- \($0)" }.joined(separator: "\n")
                let more = notes.count > 200 ? "\n… and \(notes.count - 200) more." : ""
                parts.append("\n--- \(path)/ contains \(notes.count) notes ---\n\(listing)\(more)")

            case .file(let name, let text):
                parts.append("\n--- \(name) (attached file) ---\n" + clip(text))

            case .selection(let from, let text):
                parts.append("\n--- selected passage from \(from) ---\n" + clip(text))

            case .image:
                continue
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func clip(_ text: String) -> String {
        guard text.count > characterLimit else { return text }
        return String(text.prefix(characterLimit))
            + "\n\n[Attachment truncated at \(characterLimit) characters.]"
    }

    /// The image blocks, in the order they were attached.
    public static func imageBlocks(for attachments: [ChatAttachment]) -> [ContentBlock] {
        attachments.compactMap { attachment in
            guard case .image(let mime, let data) = attachment.kind else { return nil }
            return .image(mimeType: mime, data: data)
        }
    }
}

/// Matching notes for an `@` mention.
public enum MentionIndex {
    /// Notes and folders matching what has been typed after `@`.
    ///
    /// Reuses the quick switcher's ranking, so `@dnw` finds
    /// `Daily Notes/Weekly` here exactly as ⌘O does. Two places that both match
    /// note names should not disagree about what matches.
    public static func matching(
        _ query: String,
        in snapshot: IndexSnapshot,
        vaultRoot: URL,
        limit: Int = 8
    ) -> [ChatAttachment] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        var results: [ChatAttachment] = []

        // Folders first when the query looks like one: someone typing `@06-` in
        // a vault of numbered folders means the folder.
        if !trimmed.isEmpty {
            let folders = Set(snapshot.orderedNotes.compactMap { url -> String? in
                let path = relativePath(url, vaultRoot: vaultRoot)
                guard let slash = path.lastIndex(of: "/") else { return nil }
                return String(path[path.startIndex..<slash])
            })
            for folder in folders.sorted()
            where folder.lowercased().contains(trimmed.lowercased()) {
                results.append(ChatAttachment(kind: .folder(path: folder)))
                if results.count >= 3 { break }
            }
        }

        let notes = SearchEngine.quickSwitch(
            query: trimmed, in: snapshot, vaultRoot: vaultRoot, limit: limit)
        for hit in notes where hit.exists {
            results.append(ChatAttachment(kind: .note(
                path: relativePath(hit.url, vaultRoot: vaultRoot))))
            if results.count >= limit { break }
        }
        return results
    }

    public static func relativePath(_ url: URL, vaultRoot: URL) -> String {
        let root = vaultRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return url.lastPathComponent }
        return String(path.dropFirst(root.count).drop(while: { $0 == "/" }))
    }
}
