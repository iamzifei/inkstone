import Foundation
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Renders Mermaid diagrams to images for the editor to draw inline.
///
/// Mermaid is a JavaScript library with no native equivalent, so this is the one
/// place the app runs a web view. It is deliberately quarantined: an offscreen
/// view, loaded from a vendored copy of the library with no network access, that
/// exists only long enough to produce a bitmap. Nothing of the web stack reaches
/// the editor, which receives an image like any other.
///
/// Rendering is asynchronous while highlighting is synchronous, so `image(for:)`
/// returns nil the first time it sees a diagram, starts the work, and calls
/// `onRendered` when the result lands. The editor re-highlights then. A diagram
/// therefore appears as its source for one pass and as a picture afterwards.
@MainActor
final class MermaidRenderer {
    static let shared = MermaidRenderer()

    /// Called when a diagram finishes rendering, so the editor can re-run.
    var onRendered: (() -> Void)?

    private struct Key: Hashable {
        let source: String
        let isDark: Bool
    }

    private var cache: [Key: PlatformImage] = [:]
    /// Diagrams that failed to parse; kept so a broken diagram is not retried on
    /// every keystroke.
    private var failures: Set<Key> = []
    private var inFlight: Set<Key> = []
    private var order: [Key] = []
    private let limit = 64

    /// Held for the lifetime of a render; released as soon as the snapshot is taken.
    private var activeWebViews: [Key: WKWebView] = [:]

    #if os(macOS)
    /// A borderless window parked far offscreen.
    ///
    /// A WKWebView that belongs to no window does not lay out, so JavaScript that
    /// waits on layout never completes and the snapshot has nothing to capture —
    /// every render simply timed out. Giving it a real (if invisible) host fixes
    /// that without anything appearing on screen.
    private lazy var host: NSWindow = {
        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: 1400, height: 1400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        return window
    }()
    #endif

    private lazy var library: String? = {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private init() {}

    /// Debug trace; the render path crosses a web view and three callbacks, so
    /// when nothing appears it is otherwise impossible to tell which step failed.
    private func trace(_ message: String) {
        #if DEBUG
        let url = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())).appending(path: "inkstone-debug.log")
        let line = "[mermaid] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else { try? Data(line.utf8).write(to: url) }
        #endif
    }

    /// - Returns: the rendered diagram, or nil while it is still being produced
    ///   (or if it could not be produced at all).
    func image(for source: String, isDark: Bool) -> PlatformImage? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let key = Key(source: trimmed, isDark: isDark)
        if let cached = cache[key] { return cached }
        guard !failures.contains(key), !inFlight.contains(key) else { return nil }

        inFlight.insert(key)
        render(key)
        return nil
    }

    func removeAll() {
        cache.removeAll()
        failures.removeAll()
        order.removeAll()
    }

    // MARK: - Rendering

    private func render(_ key: Key) {
        guard let library else {
            trace("library missing from bundle")
            failures.insert(key)
            return
        }
        trace("render start, \(library.count) bytes of library")

        let configuration = WKWebViewConfiguration()
        let handler = SnapshotHandler { [weak self] size, error in
            self?.finish(key, size: size, error: error)
        }
        configuration.userContentController.add(handler, name: "done")

        // Generous canvas: the diagram is measured after layout and the snapshot
        // cropped to it, so this only has to be big enough not to clip.
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1400, height: 1400),
            configuration: configuration
        )
        webView.setValue(false, forKey: "drawsBackground")
        // The page is a local string with no baseURL, so it cannot reach the
        // network; this stops it navigating anywhere either.
        webView.navigationDelegate = handler
        handler.webView = webView
        activeWebViews[key] = webView
        #if os(macOS)
        host.contentView?.addSubview(webView)
        #endif

        webView.loadHTMLString(html(for: key, library: library), baseURL: nil)

        // A diagram that never calls back must not leak its web view.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.inFlight.contains(key) else { return }
            self.finish(key, size: nil, error: "timed out")
        }
    }

    private func html(for key: Key, library: String) -> String {
        // JSON-encode the source so backticks, backslashes and newlines survive
        // the trip into JavaScript intact.
        let encoded = (try? JSONEncoder().encode(key.source))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;padding:0;background:transparent}
        #out{display:inline-block;padding:8px}</style>
        <script>\(library)</script></head>
        <body><div id="out"></div><script>
        (function () {
          function done(payload) { window.webkit.messageHandlers.done.postMessage(payload); }
          try {
            // securityLevel "strict" makes Mermaid sanitise the SVG it builds,
            // stripping script and event handlers. Diagram source arrives from a
            // note, which may have been pasted from anywhere, so it is treated as
            // untrusted even though the view is offscreen and has no network.
            mermaid.initialize({
              startOnLoad: false,
              securityLevel: "strict",
              theme: "\(key.isDark ? "dark" : "default")"
            });
            mermaid.render("d", \(encoded)).then(function (result) {
              var out = document.getElementById("out");
              out.innerHTML = result.svg;
              var svg = out.querySelector("svg");
              svg.removeAttribute("height");
              svg.style.maxWidth = "none";
              // setTimeout, not requestAnimationFrame: the host window is
              // parked offscreen and rAF does not fire when it is not visible,
              // which made every render time out.
              setTimeout(function () {
                var box = out.getBoundingClientRect();
                done({ width: box.width, height: box.height });
              }, 0);
            }).catch(function (e) { done({ error: String(e) }); });
          } catch (e) { done({ error: String(e) }); }
        })();
        </script></body></html>
        """
    }

    private func finish(_ key: Key, size: CGSize?, error: String?) {
        trace("finish size=\(String(describing: size)) error=\(error ?? "nil")")
        guard inFlight.contains(key) else { return }

        // Keyed rather than "the most recent one": two diagrams in one note
        // render concurrently, and taking the latest web view would snapshot the
        // wrong diagram.
        guard let size, size.width > 1, size.height > 1, error == nil,
              let webView = activeWebViews[key]
        else {
            inFlight.remove(key)
            failures.insert(key)
            activeWebViews.removeValue(forKey: key)
            return
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self else { return }
            self.inFlight.remove(key)
            #if os(macOS)
            self.activeWebViews[key]?.removeFromSuperview()
            #endif
            self.activeWebViews.removeValue(forKey: key)

            guard let image else {
                self.trace("snapshot returned no image")
                self.failures.insert(key)
                return
            }
            self.trace("rendered \(image.size)")
            self.cache[key] = image
            self.order.append(key)
            if self.order.count > self.limit {
                self.cache.removeValue(forKey: self.order.removeFirst())
            }
            self.onRendered?()
        }
    }

    /// Bridges the page's `done` message back into Swift.
    private final class SnapshotHandler: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        private let completion: @MainActor (CGSize?, String?) -> Void

        init(completion: @escaping @MainActor (CGSize?, String?) -> Void) {
            self.completion = completion
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Only the initial in-memory load is permitted.
            decisionHandler(action.navigationType == .other && action.request.url == nil ? .allow : .cancel)
        }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            let body = message.body as? [String: Any]
            let error = body?["error"] as? String
            let size = (body?["width"] as? Double).flatMap { width in
                (body?["height"] as? Double).map { CGSize(width: width, height: $0) }
            }
            MainActor.assumeIsolated { completion(size, error) }
        }
    }
}
