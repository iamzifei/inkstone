import CryptoKit
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
/// view, loaded from a vendored copy of the library with no network access,
/// that produces bitmaps. Nothing of the web stack reaches the editor, which
/// receives an image like any other.
///
/// Two engines for the whole app (2026-11-21). It used to be one web view per
/// diagram, each parsing the 3.4 MB library from scratch, all at the same time:
/// a note with ten diagrams parsed it ten times in parallel, and the main
/// thread stalled for 300–420 ms opening it. Now the library loads once into
/// each of two long-lived pages and diagrams render through them in turn
/// (MiaoYan keeps one page per preview the same way). One page halved the
/// stall but drew ten diagrams a third slower on iPhone than ten pages did;
/// two pages keep the stall down and the drawing time where it was.
/// Results are kept on disk too, so a diagram drawn once is not drawn again
/// after a relaunch.
///
/// Rendering is asynchronous while highlighting is synchronous, so `image(for:)`
/// returns nil the first time it sees a diagram, queues the work, and calls
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
    private var order: [Key] = []
    private let limit = 64
    /// Diagrams that failed, with Mermaid's message; kept so a broken diagram is
    /// not retried on every keystroke, and so the editor can say what is wrong.
    private var failures: [Key: String] = [:]
    /// Waiting to render, in the order they were asked for.
    private var queue: [Key] = []
    private var nextID = 0

    // MARK: - Engine state

    /// One long-lived page with the library loaded, and what it is drawing.
    private final class Engine {
        let index: Int
        var webView: WKWebView?
        var handler: EngineHandler?
        /// Whether the page has finished loading the library.
        var ready = false
        /// The diagram this page is drawing now.
        var current: (key: Key, id: Int)?
        init(index: Int) { self.index = index }
    }

    private static let engineCount = 2
    private let engines = (0..<MermaidRenderer.engineCount).map { Engine(index: $0) }
    /// Restarts after a crash, so a page that cannot stay up does not loop.
    private var restarts = 0

    #if os(macOS)
    /// A borderless window parked far offscreen.
    ///
    /// A WKWebView that belongs to no window does not lay out, so JavaScript that
    /// waits on layout never completes and the snapshot has nothing to capture.
    /// Giving it a real (if invisible) host fixes that without anything
    /// appearing on screen.
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

    private lazy var libraryURL: URL? = Bundle.main.url(forResource: "mermaid.min", withExtension: "js")

    /// Part of every disk-cache key: a new copy of the library may draw a
    /// diagram differently, and its cached images must not outlive it.
    private lazy var libraryStamp: String = {
        guard let url = libraryURL,
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return "none" }
        return String(size)
    }()

    private init() {}

    #if !os(macOS)
    /// A view to park the offscreen engine in.
    private static func hostView() -> UIView? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
    #endif

    /// Debug trace; the render path crosses a web view and several callbacks, so
    /// when nothing appears it is otherwise impossible to tell which step failed.
    fileprivate func trace(_ message: String) {
        #if DEBUG
        let url = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())).appending(path: "inkstone-debug.log")
        let line = "[mermaid] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else { try? Data(line.utf8).write(to: url) }
        #endif
    }

    // MARK: - Public

    /// - Returns: the rendered diagram, or nil while it is still being produced
    ///   (or if it could not be produced at all — see `error(for:isDark:)`).
    func image(for source: String, isDark: Bool) -> PlatformImage? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let key = Key(source: trimmed, isDark: isDark)
        if let cached = cache[key] { return cached }
        guard failures[key] == nil else { return nil }
        if let stored = loadFromDisk(key) {
            remember(stored, for: key)
            return stored
        }
        guard !engines.contains(where: { $0.current?.key == key }), !queue.contains(key) else { return nil }
        queue.append(key)
        pump()
        return nil
    }

    /// Mermaid's message for a diagram that could not be drawn, or nil.
    func error(for source: String, isDark: Bool) -> String? {
        failures[Key(source: source.trimmingCharacters(in: .whitespacesAndNewlines), isDark: isDark)]
    }

    func removeAll() {
        cache.removeAll()
        failures.removeAll()
        order.removeAll()
    }

    // MARK: - Queue

    /// Starts the next diagrams on whichever pages are free.
    private func pump() {
        for engine in engines where engine.current == nil {
            guard !queue.isEmpty else { return }
            guard let webView = webView(for: engine) else { return }
            guard engine.ready else { continue }       // `ready(_:)` pumps again

            let key = queue.removeFirst()
            nextID += 1
            let id = nextID
            engine.current = (key, id)
            // JSON-encode the source so backticks, backslashes and newlines
            // survive the trip into JavaScript intact.
            let encoded = (try? JSONEncoder().encode(key.source)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            let theme = key.isDark ? "dark" : "default"
            webView.evaluateJavaScript("renderDiagram(\(id), \(encoded), \"\(theme)\")") { [weak self] _, error in
                if let error { self?.trace("evaluate failed: \(error)") }
            }

            // A diagram that never calls back must not hold up the rest.
            Task { [weak self, weak engine] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, let engine, engine.current?.id == id else { return }
                self.trace("timed out")
                self.fail(engine.index, id: id, message: "Timed out")
            }
        }
    }

    fileprivate func fail(_ index: Int, id: Int, message: String) {
        let engine = engines[index]
        guard let current = engine.current, current.id == id else { return }
        trace("failed: \(message)")
        failures[current.key] = message
        engine.current = nil
        pump()
    }

    /// A page reported a diagram drawn and measured: snapshot it.
    fileprivate func drawn(_ index: Int, id: Int, size: CGSize) {
        let engine = engines[index]
        guard let current = engine.current, current.id == id, let webView = engine.webView else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        webView.takeSnapshot(with: configuration) { [weak self, weak engine] image, _ in
            guard let self, let engine, engine.current?.id == id else { return }
            engine.current = nil
            if let image {
                self.trace("rendered \(image.size)")
                self.remember(image, for: current.key)
                self.saveToDisk(image, for: current.key)
                #if DEBUG
                MainStallMonitor.shared.event()
                #endif
                self.onRendered?()
            } else {
                self.trace("snapshot returned no image")
                self.failures[current.key] = "Could not draw the diagram"
            }
            self.pump()
        }
    }

    private func remember(_ image: PlatformImage, for key: Key) {
        cache[key] = image
        order.append(key)
        if order.count > limit { cache.removeValue(forKey: order.removeFirst()) }
    }

    // MARK: - Engine lifecycle

    /// The folder the engine page and its copy of the library live in. The web
    /// views may read this folder and nothing else.
    private static var engineFolder: URL {
        FileManager.default.temporaryDirectory.appending(path: "inkstone-mermaid", directoryHint: .isDirectory)
    }

    /// The page in the folder, written (with its copy of the library) once.
    private lazy var enginePage: URL? = {
        guard let libraryURL else {
            trace("library missing from bundle")
            return nil
        }
        // The library is read by WebKit from a file, not copied into a Swift
        // string and marshalled across as 3.4 MB of inline script. Copied next
        // to the page so the web views' read access can be that one folder.
        let folder = Self.engineFolder
        let page = folder.appending(path: "engine.html")
        let library = folder.appending(path: "mermaid.min.js")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let size = { (url: URL) in (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
            if size(library) != size(libraryURL) {
                try? FileManager.default.removeItem(at: library)
                try FileManager.default.copyItem(at: libraryURL, to: library)
            }
            try Data(Self.page.utf8).write(to: page, options: .atomic)
            return page
        } catch {
            trace("engine page could not be written: \(error)")
            return nil
        }
    }()

    /// The engine's web view, started if it is not running.
    private func webView(for engine: Engine) -> WKWebView? {
        if let webView = engine.webView { return webView }
        guard let page = enginePage else {
            // Nothing will ever render: fail what is waiting rather than hold it.
            for key in queue { failures[key] = "Could not start the diagram renderer" }
            queue.removeAll()
            return nil
        }
        let configuration = WKWebViewConfiguration()
        let handler = EngineHandler(owner: self, index: engine.index)
        configuration.userContentController.add(handler, name: "engine")
        // Generous canvas: each diagram is measured after layout and the
        // snapshot cropped to it, so this only has to be big enough not to clip.
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1400, height: 1400), configuration: configuration)
        #if os(macOS)
        // Private KVC, and AppKit-only: `drawsBackground` does not exist on a
        // UIKit WKWebView (it threw and crashed iOS on any note with a diagram).
        webView.setValue(false, forKey: "drawsBackground")
        host.contentView?.addSubview(webView)
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // Same reason as the offscreen window on macOS: a WKWebView outside a
        // hierarchy never lays out. Parked off the edge of the key window.
        if let host = Self.hostView() {
            webView.frame.origin = CGPoint(x: -20_000, y: -20_000 - CGFloat(engine.index) * 1_500)
            webView.isUserInteractionEnabled = false
            host.addSubview(webView)
        }
        #endif
        webView.navigationDelegate = handler
        engine.handler = handler
        engine.webView = webView
        engine.ready = false
        webView.loadFileURL(page, allowingReadAccessTo: Self.engineFolder)
        trace("engine \(engine.index) starting")
        return webView
    }

    /// A page died (WebKit's content process is killed under memory pressure,
    /// or crashed): start a fresh one, retrying the diagram it had in hand.
    fileprivate func engineDied(_ index: Int) {
        trace("engine \(index) terminated")
        let engine = engines[index]
        engine.webView?.removeFromSuperview()
        engine.webView = nil
        engine.ready = false
        if let current = engine.current { queue.insert(current.key, at: 0) }
        engine.current = nil
        restarts += 1
        guard restarts <= 3 * Self.engineCount else {
            for key in queue { failures[key] = "The diagram renderer stopped" }
            queue.removeAll()
            return
        }
        pump()
    }

    fileprivate func ready(_ index: Int) {
        trace("engine \(index) ready")
        engines[index].ready = true
        pump()
    }

    // MARK: - Disk cache

    private func diskURL(for key: Key) -> URL? {
        // Under the bundle id: outside the sandbox (an unsigned debug build),
        // the caches directory is the user's own ~/Library/Caches.
        guard let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: Bundle.main.bundleIdentifier ?? "com.orris.inkstone", directoryHint: .isDirectory)
            .appending(path: "Mermaid", directoryHint: .isDirectory) else { return nil }
        let scale = Self.screenScale
        let digest = SHA256.hash(data: Data("\(libraryStamp)|\(key.isDark)|\(scale)|\(key.source)".utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: "\(name)@\(Int(scale))x.png")
    }

    private static var screenScale: CGFloat {
        #if os(macOS)
        NSScreen.main?.backingScaleFactor ?? 2
        #else
        UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 3
        #endif
    }

    private func loadFromDisk(_ key: Key) -> PlatformImage? {
        guard let url = diskURL(for: key), let data = try? Data(contentsOf: url) else { return nil }
        let scale = Self.screenScale
        #if os(macOS)
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        let image = NSImage(size: CGSize(width: CGFloat(rep.pixelsWide) / scale,
                                         height: CGFloat(rep.pixelsHigh) / scale))
        image.addRepresentation(rep)
        return image
        #else
        return UIImage(data: data, scale: scale)
        #endif
    }

    private func saveToDisk(_ image: PlatformImage, for key: Key) {
        guard let url = diskURL(for: key) else { return }
        #if os(macOS)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        #else
        let data = image.pngData()
        #endif
        guard let data else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Page

    /// The engine page: the library, and one function that draws a diagram
    /// into `#out`, measures it, and reports back. Nothing on it may load from
    /// the network.
    private static let page = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:">
    <style>html,body{margin:0;padding:0;background:transparent}
    #out{display:inline-block;padding:8px}</style>
    <script src="mermaid.min.js"></script></head>
    <body><div id="out"></div><script>
    (function () {
      function post(payload) { window.webkit.messageHandlers.engine.postMessage(payload); }
      window.renderDiagram = function (id, source, theme) {
        var out = document.getElementById("out");
        out.innerHTML = "";
        try {
          // securityLevel "strict" makes Mermaid sanitise the SVG it builds,
          // stripping script and event handlers. Diagram source arrives from a
          // note, which may have been pasted from anywhere.
          mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: theme });
          mermaid.render("d" + id, source).then(function (result) {
            out.innerHTML = result.svg;
            var svg = out.querySelector("svg");
            svg.removeAttribute("height");
            svg.style.maxWidth = "none";
            // setTimeout, not requestAnimationFrame: the host is parked
            // offscreen and rAF does not fire when it is not visible.
            setTimeout(function () {
              var box = out.getBoundingClientRect();
              post({ kind: "done", id: id, width: box.width, height: box.height });
            }, 0);
          }).catch(function (e) { post({ kind: "error", id: id, message: String((e && e.message) || e) }); });
        } catch (e) { post({ kind: "error", id: id, message: String((e && e.message) || e) }); }
      };
      post({ kind: typeof mermaid === "undefined" ? "missing" : "ready" });
    })();
    </script></body></html>
    """

    /// Bridges the page's messages back into Swift.
    private final class EngineHandler: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var owner: MermaidRenderer?
        let index: Int
        init(owner: MermaidRenderer, index: Int) { self.owner = owner; self.index = index }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            // The engine page itself, and nothing it might try to navigate to.
            let isPage = action.request.url?.isFileURL == true
                && action.request.url?.lastPathComponent == "engine.html"
            decisionHandler(isPage ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            let index = index
            MainActor.assumeIsolated { owner?.engineDied(index) }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body as? [String: Any] ?? [:]
            let kind = body["kind"] as? String
            let id = (body["id"] as? Int) ?? (body["id"] as? Double).map(Int.init) ?? -1
            let width = body["width"] as? Double ?? 0
            let height = body["height"] as? Double ?? 0
            let text = body["message"] as? String
            let index = index
            MainActor.assumeIsolated {
                guard let owner else { return }
                switch kind {
                case "ready": owner.ready(index)
                case "missing":
                    owner.trace("library failed to load")
                    owner.engineDied(index)
                case "done":
                    if width > 1, height > 1 {
                        owner.drawn(index, id: id, size: CGSize(width: width, height: height))
                    } else {
                        owner.fail(index, id: id, message: "The diagram is empty")
                    }
                case "error": owner.fail(index, id: id, message: text ?? "Could not draw the diagram")
                default: break
                }
            }
        }
    }
}
