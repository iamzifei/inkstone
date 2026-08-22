#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The one drawing type that differs between AppKit and UIKit.
///
/// The editor paints bullets, checkboxes, rules and inline images by hand, and
/// that geometry is identical on both platforms — `NSLayoutManager` and
/// `NSTextContainer` exist on iOS too, so the layout maths ports unchanged. The
/// path class does not: `NSBezierPath` predates UIKit and never gained
/// `addLine(to:)` or a single-radius rounded-rect initialiser.
///
/// UIKit's spelling is the shared one, because AppKit is the side that needs
/// adapting.
#if os(macOS)
typealias PlatformBezierPath = NSBezierPath

extension NSBezierPath {
    convenience init(roundedRect rect: CGRect, cornerRadius: CGFloat) {
        self.init(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    }

    func addLine(to point: CGPoint) {
        line(to: point)
    }
}
#else
typealias PlatformBezierPath = UIBezierPath
#endif

/// The context the view is currently drawing into.
///
/// AppKit reaches it through `NSGraphicsContext.current`; UIKit has a free
/// function. Same `CGContext` either way.
var currentDrawingContext: CGContext? {
    #if os(macOS)
    NSGraphicsContext.current?.cgContext
    #else
    UIGraphicsGetCurrentContext()
    #endif
}

extension CGRect {
    /// Fills the rect with the current fill colour.
    ///
    /// `NSRect.fill()` is an AppKit addition with no UIKit counterpart, and the
    /// rules and fills the editor paints are all simple rectangles.
    func fillPlatform() {
        PlatformBezierPath(rect: self).fill()
    }
}

extension PlatformImage {
    /// The image as a `CGImage`, however the platform spells it.
    var platformCGImage: CGImage? {
        #if os(macOS)
        cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        cgImage
        #endif
    }
}

extension PlatformImage {
    /// A copy scaled to `size`, for drawing a picture among words.
    ///
    /// Scaling at draw time instead would work on macOS and be wrong on iOS,
    /// where the renderer asks the image for its own `size` to place it.
    func resizedForInline(to size: CGSize) -> PlatformImage {
        #if os(macOS)
        let copy = NSImage(size: size)
        copy.lockFocus()
        draw(in: CGRect(origin: .zero, size: size))
        copy.unlockFocus()
        return copy
        #else
        return UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        #endif
    }
}

#if os(macOS)
typealias PlatformTextView = NSTextView
#else
typealias PlatformTextView = UITextView
#endif

extension PlatformTextView {
    /// The view's text, however the platform spells the property.
    var inkstoneText: String {
        #if os(macOS)
        string
        #else
        text ?? ""
        #endif
    }

    /// Scrolls `range` into view and puts the caret at its start.
    func inkstoneReveal(_ range: NSRange) {
        let caret = NSRange(location: range.location, length: 0)
        #if os(macOS)
        setSelectedRange(caret)
        scrollRangeToVisible(range)
        #else
        selectedRange = caret
        scrollRangeToVisible(range)
        // Deliberately not `becomeFirstResponder()`: tapping an outline row to
        // look at a section should not throw the keyboard up over the section
        // you just jumped to.
        #endif
    }
}
