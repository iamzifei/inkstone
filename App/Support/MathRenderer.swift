import Foundation
import SwiftMath

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Typesets LaTeX into images for the editor to draw inline.
///
/// SwiftMath rather than MathJax or KaTeX: those would mean shipping a
/// JavaScript engine and a WebView to render `$x^2$` in a note, with all the
/// startup cost and sandboxing that implies. SwiftMath is pure Swift with its
/// own bundled maths fonts and renders straight to an image.
///
/// Results are cached. The highlighter re-runs on every keystroke, and
/// typesetting is far too slow to repeat per frame — a page of equations would
/// make typing unusable without this.
@MainActor
final class MathRenderer {
    static let shared = MathRenderer()

    struct Key: Hashable {
        let latex: String
        let fontSize: Int
        let isDisplay: Bool
        let colour: String
    }

    /// A successful render, or a recorded failure so invalid LaTeX is not retried
    /// on every keystroke.
    private enum Entry {
        case rendered(PlatformImage)
        case failed(String)
    }

    private var cache: [Key: Entry] = [:]
    private var order: [Key] = []
    private let limit = 256

    private init() {}

    /// - Returns: the typeset image, or nil when the LaTeX does not parse.
    func image(latex: String, fontSize: CGFloat, isDisplay: Bool, colour: PlatformColor) -> PlatformImage? {
        entry(latex: latex, fontSize: fontSize, isDisplay: isDisplay, colour: colour).map {
            if case .rendered(let image) = $0 { return image }
            return nil
        } ?? nil
    }

    /// The parse error for a formula, if it failed. Lets the editor show the raw
    /// source in a warning colour rather than silently rendering nothing.
    func error(latex: String, fontSize: CGFloat, isDisplay: Bool, colour: PlatformColor) -> String? {
        guard case .failed(let message)? = entry(
            latex: latex, fontSize: fontSize, isDisplay: isDisplay, colour: colour
        ) else { return nil }
        return message
    }

    private func entry(
        latex: String, fontSize: CGFloat, isDisplay: Bool, colour: PlatformColor
    ) -> Entry? {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let key = Key(
            latex: trimmed,
            fontSize: Int(fontSize.rounded()),
            isDisplay: isDisplay,
            colour: colour.description
        )
        if let cached = cache[key] { return cached }

        let renderer = MTMathImage(
            latex: trimmed,
            fontSize: fontSize,
            textColor: colour,
            labelMode: isDisplay ? .display : .text,
            textAlignment: .left
        )
        let (error, image) = renderer.asImage()

        let entry: Entry
        if let image, error == nil {
            entry = .rendered(image)
        } else {
            entry = .failed(error?.localizedDescription ?? "Could not typeset this formula.")
        }

        cache[key] = entry
        order.append(key)
        if order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
        return entry
    }

    func removeAll() {
        cache.removeAll()
        order.removeAll()
    }
}
