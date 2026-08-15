import Foundation
import InkstoneCore

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

    /// Returns the image for `url`, scaled to fit `maxWidth`, or nil if it is not
    /// an image or cannot be read.
    func image(for url: URL, maxWidth: CGFloat) -> PlatformImage? {
        guard AttachmentKind(url: url) == .image else { return nil }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        // Bucket the width so a live window resize does not decode on every pixel.
        let bucket = max(1, Int(maxWidth / 32))
        let key = Key(path: url.path, width: bucket, modified: modified)

        if let cached = images[key] { return cached }
        if failures.contains(key) { return nil }

        guard let decoded = load(url, maxWidth: CGFloat(bucket * 32)) else {
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
