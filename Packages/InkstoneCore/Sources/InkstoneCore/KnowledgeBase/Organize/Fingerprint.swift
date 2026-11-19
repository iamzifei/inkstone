import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import Accelerate

/// Fingerprints for finding duplicates: SHA-256 for exact copies, a 64-bit
/// SimHash for near-identical text, a 64-bit perceptual hash for the same
/// picture saved differently.
public enum Fingerprint {
    /// SHA-256 of the file, read in 1 MB chunks (videos can be large).
    public static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 64-bit SimHash over word shingles (and character bigrams for Chinese,
    /// which has no spaces). Near-identical texts differ in few bits.
    public static func simHash(_ text: String) -> UInt64? {
        var features: [String] = []
        var word = ""
        var previousHan: Character?
        for ch in text.lowercased() {
            if ch.isLetter && !ch.isHan || ch.isNumber {
                word.append(ch); previousHan = nil
            } else {
                if !word.isEmpty { features.append(word); word = "" }
                if ch.isHan {
                    if let p = previousHan { features.append(String([p, ch])) }
                    previousHan = ch
                } else { previousHan = nil }
            }
        }
        if !word.isEmpty { features.append(word) }
        guard features.count >= 8 else { return nil }      // too little text to compare
        var weights = [Int](repeating: 0, count: 64)
        for f in features {
            let digest = SHA256.hash(data: Data(f.utf8))
            let h = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            for i in 0..<64 { weights[i] += (h >> UInt64(i)) & 1 == 1 ? 1 : -1 }
        }
        return (0..<64).reduce(UInt64(0)) { weights[$1] > 0 ? $0 | (1 << UInt64($1)) : $0 }
    }

    /// 64-bit perceptual hash (DCT of a 32x32 greyscale thumbnail, top-left
    /// 8x8 against their median). Resizing or re-encoding barely moves it.
    public static func perceptualHash(_ url: URL) -> UInt64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let n = 32
        var pixels = [UInt8](repeating: 0, count: n * n)
        guard let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        let values = pixels.map(Double.init)
        // 2-D DCT-II, only the 8x8 low-frequency corner is needed.
        var coefficients: [Double] = []
        for u in 0..<8 {
            for v in 0..<8 {
                var sum = 0.0
                for x in 0..<n {
                    let cx = cos(Double((2 * x + 1) * u) * .pi / Double(2 * n))
                    for y in 0..<n {
                        sum += values[y * n + x] * cx * cos(Double((2 * y + 1) * v) * .pi / Double(2 * n))
                    }
                }
                coefficients.append(sum)
            }
        }
        let ac = Array(coefficients.dropFirst())        // without the DC term
        let median = ac.sorted()[ac.count / 2]
        return coefficients.enumerated().reduce(UInt64(0)) { $1.element > median ? $0 | (1 << UInt64($1.offset)) : $0 }
    }

    public static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
}

extension Character {
    var isHan: Bool {
        unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }
}
