import SwiftUI

#if os(macOS)
import AppKit

/// Reports scroll-wheel and two-finger-scroll deltas over a SwiftUI view.
///
/// SwiftUI has no scroll-wheel event of its own outside a `ScrollView`, and a
/// `ScrollView` is exactly what a pan-and-zoom canvas must not be.
///
/// A transparent `NSView` on top does not work: `scrollWheel` goes to the view
/// `hitTest` returns and then up the *responder chain*, so a view that makes
/// itself click-through by returning nil from `hitTest` stops receiving wheel
/// events too, and one that does not stops the drag gestures underneath. A local
/// event monitor sidesteps the whole question — it sees the event before it is
/// dispatched, and the view is used only to work out whether the pointer is
/// inside it.
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelProbe {
        let view = ScrollWheelProbe()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: ScrollWheelProbe, context: Context) {
        view.onScroll = onScroll
    }

    static func dismantleNSView(_ view: ScrollWheelProbe, coordinator: ()) {
        view.stopMonitoring()
    }
}

/// The probe itself: click-through, and alive only to say where it is.
private final class ScrollWheelProbe: NSView {
    var onScroll: ((CGFloat) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stopMonitoring() : startMonitoring()
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }

            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(local) else { return event }

            // A trackpad reports fractional "precise" deltas many times a
            // second; a mouse wheel reports whole lines. Scaling the coarse one
            // up keeps a wheel click and a trackpad swipe roughly comparable.
            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.scrollingDeltaY * 6
            guard delta != 0 else { return event }

            self.onScroll?(delta)
            // Swallowed, so nothing behind the graph scrolls as well.
            return nil
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // No `deinit` teardown: `viewDidMoveToWindow(nil)` and `dismantleNSView`
    // between them cover every way this view leaves the screen, and a nonisolated
    // deinit cannot touch a non-`Sendable` `Any?` under strict concurrency.
}
#endif

extension View {
    /// Calls `action` with the vertical scroll delta, on platforms that have one.
    func onScrollWheel(_ action: @escaping (CGFloat) -> Void) -> some View {
        #if os(macOS)
        overlay(ScrollWheelCatcher(onScroll: action))
        #else
        // iOS and iPadOS zoom by pinching, which SwiftUI reports directly.
        self
        #endif
    }
}
