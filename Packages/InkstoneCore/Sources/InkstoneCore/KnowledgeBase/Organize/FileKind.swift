import Foundation
import UniformTypeIdentifiers

/// What a file is, for organizing: decided by its header first (extensions
/// lie — a photo saved as `.txt` is still a photo), then its extension.
public enum FileKind: String, Codable, Sendable {
    case markdown, text, html, pdf, document, presentation, spreadsheet
    case image, video, audio, archive, other

    /// Text the organizer can read directly.
    public var isText: Bool { [.markdown, .text, .html].contains(self) }
    public var isMedia: Bool { [.image, .video, .audio].contains(self) }

    public static func detect(_ url: URL) -> FileKind {
        if let byHeader = fromHeader(url) { return byHeader }
        return fromExtension(url.pathExtension.lowercased())
    }

    static func fromExtension(_ ext: String) -> FileKind {
        switch ext {
        case "md", "markdown", "mdown": return .markdown
        case "txt", "text", "log", "csv", "tsv", "json", "yaml", "yml", "rtf": return .text
        case "html", "htm", "xhtml", "webarchive": return .html
        case "pdf": return .pdf
        case "doc", "docx", "pages", "odt": return .document
        case "ppt", "pptx", "key", "odp": return .presentation
        case "xls", "xlsx", "numbers", "ods": return .spreadsheet
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg": return .archive
        default: break
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .plainText) { return .text }
        return .other
    }

    /// The first bytes of well-known formats.
    static func fromHeader(_ url: URL) -> FileKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count >= 4 else { return nil }
        let b = [UInt8](head)
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            b.count >= offset + bytes.count && Array(b[offset..<offset + bytes.count]) == bytes
        }
        if starts([0x25, 0x50, 0x44, 0x46]) { return .pdf }                       // %PDF
        if starts([0x89, 0x50, 0x4E, 0x47]) { return .image }                     // PNG
        if starts([0xFF, 0xD8, 0xFF]) { return .image }                           // JPEG
        if starts([0x47, 0x49, 0x46, 0x38]) { return .image }                     // GIF8
        if starts([0x52, 0x49, 0x46, 0x46]), b.count >= 12 {                      // RIFF
            if starts([0x57, 0x45, 0x42, 0x50], at: 8) { return .image }          // WEBP
            if starts([0x57, 0x41, 0x56, 0x45], at: 8) { return .audio }          // WAVE
            if starts([0x41, 0x56, 0x49, 0x20], at: 8) { return .video }          // AVI
        }
        if starts([0x66, 0x74, 0x79, 0x70], at: 4), b.count >= 12 {               // ISO BMFF "ftyp"
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if ["heic", "heix", "mif1", "avif", "heim", "heis"].contains(brand) { return .image }
            if ["M4A ", "M4B ", "M4P "].contains(brand) { return .audio }
            return .video                                                          // mp4, mov, 3gp …
        }
        if starts([0x49, 0x44, 0x33]) || starts([0xFF, 0xFB]) || starts([0xFF, 0xF3]) { return .audio }   // MP3
        if starts([0x66, 0x4C, 0x61, 0x43]) || starts([0x4F, 0x67, 0x67, 0x53]) { return .audio }          // FLAC, Ogg
        if starts([0x1A, 0x45, 0xDF, 0xA3]) { return .video }                     // Matroska / WebM
        if starts([0x50, 0x4B, 0x03, 0x04]) {                                     // ZIP — or an Office/iWork file inside one
            let ext = url.pathExtension.lowercased()
            let office = fromExtension(ext)
            return [.document, .presentation, .spreadsheet].contains(office) ? office : .archive
        }
        if starts([0x52, 0x61, 0x72, 0x21]) || starts([0x37, 0x7A, 0xBC, 0xAF]) || starts([0x1F, 0x8B]) { return .archive }
        return nil
    }
}
