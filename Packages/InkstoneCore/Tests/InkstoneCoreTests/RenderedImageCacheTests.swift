import Foundation
import Testing
@testable import InkstoneCore

@Suite("Rendered image cache")
struct RenderedImageCacheTests {
    private func folder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "ric-\(UUID().uuidString)")
    }

    @Test("Every input that changes the picture changes the file")
    func keys() {
        let cache = RenderedImageCache(folder: folder())
        let base = cache.file(source: "graph TD; A-->B", isDark: false, scale: 2, stamp: "1.0 (16)|3566058")
        #expect(cache.file(source: "graph TD; A-->B", isDark: false, scale: 2, stamp: "1.0 (16)|3566058") == base)
        #expect(cache.file(source: "graph TD; A-->C", isDark: false, scale: 2, stamp: "1.0 (16)|3566058") != base)
        #expect(cache.file(source: "graph TD; A-->B", isDark: true, scale: 2, stamp: "1.0 (16)|3566058") != base)
        #expect(cache.file(source: "graph TD; A-->B", isDark: false, scale: 3, stamp: "1.0 (16)|3566058") != base)
        #expect(cache.file(source: "graph TD; A-->B", isDark: false, scale: 2, stamp: "1.0 (17)|3566058") != base)
        #expect(base.lastPathComponent.hasSuffix("@2x.png"))
    }

    @Test("The folder keeps the most recently used pictures up to its limit")
    func trims() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = RenderedImageCache(folder: dir, limit: 3)
        var files: [URL] = []
        for i in 0..<5 {
            let file = cache.file(source: "s\(i)", isDark: false, scale: 2, stamp: "x")
            cache.store(Data([UInt8(i)]), at: file)
            // Distinct, ordered modification dates without sleeping.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + i))], ofItemAtPath: file.path)
            files.append(file)
        }
        // Reading the oldest makes it recent again.
        _ = cache.load(files[2])
        cache.trim()
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left.count == 3)
        #expect(left.contains(files[2].lastPathComponent))
        #expect(left.contains(files[4].lastPathComponent))
        #expect(!left.contains(files[0].lastPathComponent))
    }
}
