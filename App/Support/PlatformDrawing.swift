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
