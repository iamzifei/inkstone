import Foundation
import ImageIO
import PDFKit
import AVFoundation
import Vision

/// What the organizer knows about one file, taken from the file itself —
/// nothing is guessed (policy rule 7).
public struct FileFacts: Sendable, Equatable {
    public var url: URL
    public var name: String              // without extension
    public var ext: String
    public var kind: FileKind
    public var size: Int64
    public var sha256: String?
    /// The date the content is from: EXIF capture time, document metadata,
    /// a date in the front matter, else the file's creation date.
    public var contentDate: Date
    public var contentDateSource: String
    /// Readable text (the start of it), when there is any.
    public var text: String
    public var title: String?
    public var pixelSize: CGSize?
    public var duration: Double?
    public var simHash: UInt64?
    public var perceptualHash: UInt64?

    public init(url: URL, name: String, ext: String, kind: FileKind, size: Int64, sha256: String?,
                contentDate: Date, contentDateSource: String, text: String, title: String?,
                pixelSize: CGSize?, duration: Double?, simHash: UInt64?, perceptualHash: UInt64?) {
        self.url = url; self.name = name; self.ext = ext; self.kind = kind; self.size = size; self.sha256 = sha256
        self.contentDate = contentDate; self.contentDateSource = contentDateSource; self.text = text; self.title = title
        self.pixelSize = pixelSize; self.duration = duration; self.simHash = simHash; self.perceptualHash = perceptualHash
    }
}

public enum FactsExtractor {
    static let excerptLength = 4000

    /// - Parameter ocr: read the text in images (Vision). Slower; the app
    ///   turns it on, tests leave it off.
    public static func facts(for url: URL, ocr: Bool = false) async -> FileFacts {
        let kind = FileKind.detect(url)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        let fileDate = values?.creationDate ?? values?.contentModificationDate ?? .now
        var date = fileDate, dateSource = "file"
        var text = "", title: String?, pixelSize: CGSize?, duration: Double?

        switch kind {
        case .markdown, .text:
            text = readText(url)
            let (fm, body) = FrontmatterParser.parse(text)
            for key in ["date", "created", "创建日期", "建立日期", "日期"] {
                if let d = fm.properties[key].flatMap(dateValue) { date = d; dateSource = "frontmatter"; break }
            }
            title = fm.properties["title"]?.stringValue
                ?? body.split(separator: "\n").first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) }
        case .html:
            let raw = readText(url)
            title = raw.range(of: #"(?is)<title[^>]*>(.*?)</title>"#, options: .regularExpression)
                .map { String(raw[$0]).replacingOccurrences(of: #"(?is)</?title[^>]*>"#, with: "", options: .regularExpression) }
            text = raw.replacingOccurrences(of: #"(?is)<(script|style)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        case .pdf:
            if let doc = PDFDocument(url: url) {
                text = String((doc.string ?? "").prefix(excerptLength))
                let attrs = doc.documentAttributes ?? [:]
                title = attrs[PDFDocumentAttribute.titleAttribute] as? String
                if let d = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date { date = d; dateSource = "pdf" }
            }
        case .image:
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                    pixelSize = CGSize(width: w, height: h)
                }
                let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
                if let s = exif?[kCGImagePropertyExifDateTimeOriginal] as? String, let d = exifDate(s) {
                    date = d; dateSource = "exif"
                }
            }
            if ocr { text = await recognizeText(url) }
        case .video, .audio:
            let asset = AVURLAsset(url: url)
            if let d = try? await asset.load(.duration), d.isNumeric { duration = d.seconds }
            if let created = try? await asset.load(.creationDate), let d = try? await created.load(.dateValue) {
                date = d; dateSource = "media"
            }
        default:
            break
        }
        text = String(text.prefix(excerptLength))
        return FileFacts(
            url: url, name: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension.lowercased(),
            kind: kind, size: Int64(values?.fileSize ?? 0), sha256: Fingerprint.sha256(url),
            contentDate: date, contentDateSource: dateSource, text: text, title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
            pixelSize: pixelSize, duration: duration,
            simHash: kind.isText || kind == .pdf ? Fingerprint.simHash(text) : nil,
            perceptualHash: kind == .image ? Fingerprint.perceptualHash(url) : nil)
    }

    static func readText(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func dateValue(_ value: PropertyValue) -> Date? {
        switch value {
        case .date(let d): return d
        case .text(let s):
            for format in ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy-MM-dd HH:mm", "yyyy年M月d日"] {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format
                if let d = f.date(from: s) { return d }
            }
            return nil
        default: return nil
        }
    }

    static func exifDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    static func recognizeText(_ url: URL) async -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            do { try VNImageRequestHandler(cgImage: image).perform([request]) }
            catch { continuation.resume(returning: "") }
        }
    }
}
