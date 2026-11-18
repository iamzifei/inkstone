import Foundation
import InkstoneCore
import PDFKit
import ImageIO

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
    /// Decoded bytes kept in memory. Count alone did not bound memory: 64
    /// full-width photos at 3x are hundreds of megabytes on a phone.
    private var costs: [Key: Int] = [:]
    private var totalCost = 0
    private let costLimit = 96 * 1024 * 1024

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
        let cost = Self.byteCost(of: decoded)
        costs[key] = cost
        totalCost += cost
        while order.count > 1, order.count > limit || totalCost > costLimit {
            let evicted = order.removeFirst()
            images.removeValue(forKey: evicted)
            totalCost -= costs.removeValue(forKey: evicted) ?? 0
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
        costs.removeAll()
        totalCost = 0
    }

    private static func byteCost(of image: PlatformImage) -> Int {
        #if os(macOS)
        let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        return max(pixels, Int(image.size.width * image.size.height)) * 4
        #else
        return Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        #endif
    }

    /// Pixels per point the picture will be drawn at. Not `UIScreen.main`
    /// (deprecated, and wrong on a device with two screens such as iPhone Duo);
    /// 3 is the densest iPhone screen and costs little over 2 at embed sizes.
    private static var displayScale: CGFloat {
        #if os(macOS)
        NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        #else
        3
        #endif
    }

    /// Decodes `url` straight to the size it will be shown at.
    ///
    /// The previous path decoded the full image and then redrew it smaller: a
    /// 48 MP photo meant ~190 MB of pixels on the main thread for a picture a
    /// few hundred points wide. ImageIO's thumbnail decoder downsamples while
    /// decoding, and applies the EXIF orientation as the old loaders did.
    ///
    /// The returned image keeps the old *point* size — the original's natural
    /// size, or `maxWidth` wide if that is smaller — so layout is unchanged;
    /// only the pixels behind it are fewer (or, on Retina, sharper).
    private func downsampled(_ url: URL, maxWidth: CGFloat) -> (CGImage, CGSize)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              var pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              pixelWidth > 0, pixelHeight > 0
        else { return nil }
        // Orientations 5–8 are rotated a quarter turn: width and height swap.
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
            swap(&pixelWidth, &pixelHeight)
        }
        #if os(macOS)
        // NSImage sized pictures by their DPI (a 144-dpi screenshot is half its
        // pixel width in points); kept so embeds lay out as before.
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let pointsPerPixel = dpi > 0 ? 72 / dpi : 1
        #else
        let pointsPerPixel = 1.0
        #endif
        let naturalWidth = pixelWidth * pointsPerPixel
        let pointWidth = min(naturalWidth, Double(maxWidth))
        let pointSize = CGSize(width: pointWidth, height: pixelHeight * pointsPerPixel * pointWidth / naturalWidth)
        let targetWidth = min(pixelWidth, pointWidth * Double(Self.displayScale))
        let maxPixel = max(1, Int((max(pixelWidth, pixelHeight) * targetWidth / pixelWidth).rounded(.up)))
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return (image, pointSize)
    }

    // ImageIO first; the original whole-image path only for what ImageIO
    // cannot decode (SVG — which NSImage renders on macOS — and anything else
    // it rejects), so no format that used to show stops showing.
    #if os(macOS)
    private func load(_ url: URL, maxWidth: CGFloat) -> NSImage? {
        if let (image, size) = downsampled(url, maxWidth: maxWidth) {
            return NSImage(cgImage: image, size: size)
        }
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
        if let (image, size) = downsampled(url, maxWidth: maxWidth) {
            return UIImage(cgImage: image, scale: CGFloat(image.width) / max(size.width, 1), orientation: .up)
        }
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
