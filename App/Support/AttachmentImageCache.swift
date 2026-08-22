import Foundation
import InkstoneCore
import PDFKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Decoded, downscaled attachment images kept in memory for the editor.
///
/// The highlighter re-runs on every keystroke, so decoding an image from disk in
/// that path would stall typing as soon as a note embedded a photo. Images are
/// therefore decoded once per (file, width, modification date) and reused; the
/// modification date is part of the key so editing a file elsewhere still shows
/// the new version rather than a stale one.
@MainActor
final class AttachmentImageCache {
    static let shared = AttachmentImageCache()

    private struct Key: Hashable {
        let path: String
        let width: Int
        let modified: TimeInterval
    }

    private var images: [Key: PlatformImage] = [:]
    /// Files that failed to decode, so a corrupt image is not retried every frame.
    private var failures: Set<Key> = []
    private var order: [Key] = []
    private let limit = 64

    private init() {}

    /// Returns a picture for `url`, scaled to fit `maxWidth`, or nil if there is
    /// none to be had.
    ///
    /// A PDF gets its first page rendered, which is the page a reader is looking
    /// for when they embed a document into a note. Everything else — video,
    /// audio, an unknown type — has no still to show and keeps its chip.
    func image(for url: URL, maxWidth: CGFloat) -> PlatformImage? {
        let kind = AttachmentKind(url: url)
        guard kind == .image || kind == .pdf else { return nil }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        // Bucket the width so a live window resize does not decode on every pixel.
        let bucket = max(1, Int(maxWidth / 32))
        let key = Key(path: url.path, width: bucket, modified: modified)

        if let cached = images[key] { return cached }
        if failures.contains(key) { return nil }

        let width = CGFloat(bucket * 32)
        guard let decoded = kind == .pdf
            ? firstPage(of: url, maxWidth: width)
            : load(url, maxWidth: width)
        else {
            failures.insert(key)
            return nil
        }

        images[key] = decoded
        order.append(key)
        if order.count > limit {
            let evicted = order.removeFirst()
            images.removeValue(forKey: evicted)
        }
        return decoded
    }

    /// The first page of a PDF, drawn at `maxWidth`.
    ///
    /// Rendered rather than handed to a `PDFView`: the editor draws its embeds
    /// by hand into space it reserved, and a live view would have to be a real
    /// subview positioned on top of text that scrolls and reflows.
    private func firstPage(of url: URL, maxWidth: CGFloat) -> PlatformImage? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            return nil
        }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let scale = min(1, maxWidth / bounds.width)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        #if os(macOS)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        if let context = NSGraphicsContext.current?.cgContext {
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .cropBox, to: context)
        }
        image.unlockFocus()
        return image
        #else
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            // PDF pages are drawn bottom-up; UIKit's context is top-down.
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .cropBox, to: cg)
        }
        #endif
    }

    func removeAll() {
        images.removeAll()
        failures.removeAll()
        order.removeAll()
    }

    #if os(macOS)
    private func load(_ url: URL, maxWidth: CGFloat) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        guard size.width > maxWidth else { return image }

        let scaled = NSSize(width: maxWidth, height: size.height * maxWidth / size.width)
        let output = NSImage(size: scaled)
        output.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: scaled))
        output.unlockFocus()
        return output
    }
    #else
    private func load(_ url: URL, maxWidth: CGFloat) -> UIImage? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0, size.width > maxWidth else { return image }

        let scaled = CGSize(width: maxWidth, height: size.height * maxWidth / size.width)
        return UIGraphicsImageRenderer(size: scaled).image { _ in
            image.draw(in: CGRect(origin: .zero, size: scaled))
        }
    }
    #endif
}
