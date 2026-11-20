import Foundation
import InkstoneCore
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Renders Mermaid diagrams to images for the editor to draw inline.
///
/// Mermaid is a JavaScript library with no native equivalent, so this is the one
/// place the app runs a web view. It is deliberately quarantined: offscreen
/// pages, loaded from a vendored copy of the library with no network access,
/// that produce bitmaps. Nothing of the web stack reaches the editor, which
/// receives an image like any other.
///
/// Long-lived engines (2026-11-21). It used to be one web view per diagram,
/// each parsing the 3.4 MB library from scratch, all at the same time: a note
/// with ten diagrams parsed it ten times in parallel, and the main thread
/// stalled for 300–420 ms opening it. Now the library loads once into a page
/// and diagrams render through it in turn (MiaoYan keeps one page per preview
/// the same way). A second page starts only when diagrams are waiting — one
/// page alone drew ten diagrams a third slower on iPhone than ten pages did —
/// and both are torn down when idle or when memory runs short. Results are
/// kept on disk too, so a diagram drawn once is not drawn again after a
/// relaunch.
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
    /// Diagrams Mermaid itself refused, with its message. Kept for good: the
    /// same source fails the same way, and retrying it on every keystroke
    /// would only cost time.
    private var failures: [Key: String] = [:]
    /// Failures that may not recur (a timeout, a page that died, a snapshot
    /// that came back empty), counted: the diagram is tried again on the next
    /// pass, and only after this many is it given up on.
    private var transientFailures: [Key: Int] = [:]
    private let transientLimit = 3
    /// Waiting to render, in the order they were asked for.
    private var queue: [Key] = []
    private var nextID = 0

    // MARK: - Engines

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
    /// Restarts after a page died, so one that cannot stay up does not loop.
    private var restarts = 0
    /// When the last diagram finished; the engines go after a quiet minute.
    private var lastActivity = Date.now
    private var idleCheck: Task<Void, Never>?
    private var retryScheduled = false
    #if !os(macOS)
    private var memoryObserver: (any NSObjectProtocol)?
    #endif

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

    /// What drew a cached picture: the app build and the library. An update to
    /// either draws again rather than showing what an older one drew.
    private lazy var stamp: String = {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
        let size = libraryURL.flatMap { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize } ?? 0
        return "\(version)|\(size)"
    }()

    private lazy var diskCache: RenderedImageCache? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first
        // Under the bundle id: outside the sandbox (an unsigned debug build),
        // the caches directory is the user's own ~/Library/Caches.
        .map { $0.appending(path: Bundle.main.bundleIdentifier ?? "com.orris.inkstone", directoryHint: .isDirectory)
            .appending(path: "Mermaid", directoryHint: .isDirectory) }
        .map { RenderedImageCache(folder: $0) }

    private init() {
        #if !os(macOS)
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tearDownIdleEngines() }
        }
        #endif
    }

    #if !os(macOS)
    /// A view to park offscreen engines in: the key window, or nil before
    /// there is one (at launch), in which case no engine is started yet.
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

    /// Mermaid's message for a diagram it could not draw, or nil.
    func error(for source: String, isDark: Bool) -> String? {
        failures[Key(source: source.trimmingCharacters(in: .whitespacesAndNewlines), isDark: isDark)]
    }

    func removeAll() {
        cache.removeAll()
        failures.removeAll()
        transientFailures.removeAll()
        order.removeAll()
    }

    // MARK: - Queue

    /// Starts the next diagrams on whichever pages are free. The first page is
    /// used for one waiting diagram; the second only while more are waiting.
    private func pump() {
        for engine in engines where engine.current == nil {
            guard !queue.isEmpty else { return }
            let busy = engines.filter { $0.current != nil }.count
            if engine.index > 0, engine.webView == nil, queue.count <= busy { return }
            guard let webView = webView(for: engine) else {
                // No window to host a page in yet (iOS, at launch): try again
                // shortly rather than fail what is waiting.
                retrySoon()
                return
            }
            guard engine.ready else { continue }       // `ready(_:webView:)` pumps again

            let key = queue.removeFirst()
            nextID += 1
            let id = nextID
            engine.current = (key, id)
            lastActivity = .now
            // JSON-encode the source so backticks, backslashes and newlines
            // survive the trip into JavaScript intact.
            let encoded = (try? JSONEncoder().encode(key.source)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            let theme = key.isDark ? "dark" : "default"
            let index = engine.index
            webView.evaluateJavaScript("renderDiagram(\(id), \(encoded), \"\(theme)\")") { [weak self] _, error in
                guard let error, let self else { return }
                self.trace("evaluate failed: \(error)")
                self.failTransiently(index, id: id, restart: false)
            }

            // A diagram that never calls back must not hold up the rest: the
            // page is restarted (Mermaid renders one diagram at a time, so a
            // stuck one blocks everything behind it).
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.engines[index].current?.id == id else { return }
                self.trace("timed out")
                self.failTransiently(index, id: id, restart: true)
            }
        }
    }

    private func retrySoon() {
        guard !retryScheduled else { return }
        retryScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.retryScheduled = false
            self?.pump()
        }
    }

    /// Mermaid refused the diagram: remembered for good.
    fileprivate func fail(_ index: Int, id: Int, message: String) {
        let engine = engines[index]
        guard let current = engine.current, current.id == id else { return }
        trace("failed: \(message)")
        failures[current.key] = message
        engine.current = nil
        finished()
    }

    /// Something went wrong that may not happen again: the diagram is tried on
    /// a later pass, up to `transientLimit` times.
    private func failTransiently(_ index: Int, id: Int, restart: Bool) {
        let engine = engines[index]
        guard let current = engine.current, current.id == id else { return }
        let count = (transientFailures[current.key] ?? 0) + 1
        transientFailures[current.key] = count
        if count >= transientLimit { failures[current.key] = "Could not draw the diagram" }
        engine.current = nil
        if restart { stop(engine) }
        finished()
    }

    /// A page reported a diagram drawn and measured: snapshot it.
    fileprivate func drawn(_ index: Int, id: Int, size: CGSize) {
        let engine = engines[index]
        guard let current = engine.current, current.id == id, let webView = engine.webView else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self, self.engines[index].current?.id == id else { return }
            guard let image else {
                self.trace("snapshot returned no image")
                self.failTransiently(index, id: id, restart: false)
                return
            }
            self.engines[index].current = nil
            self.trace("rendered \(image.size)")
            self.transientFailures[current.key] = nil
            self.remember(image, for: current.key)
            self.saveToDisk(image, for: current.key)
            #if DEBUG
            MainStallMonitor.shared.event()
            #endif
            self.onRendered?()
            self.finished()
        }
    }

    private func finished() {
        lastActivity = .now
        scheduleIdleCheck()
        pump()
    }

    private func remember(_ image: PlatformImage, for key: Key) {
        cache[key] = image
        order.append(key)
        if order.count > limit { cache.removeValue(forKey: order.removeFirst()) }
    }

    // MARK: - Engine lifecycle

    /// The folder the engine page, its script and its copy of the library live
    /// in. The web views may read this folder and nothing else.
    private static var engineFolder: URL {
        FileManager.default.temporaryDirectory.appending(path: "inkstone-mermaid", directoryHint: .isDirectory)
    }

    /// The page in the folder, written once per launch with a fresh copy of
    /// the library (a copy left by another build may be another version).
    private lazy var enginePage: URL? = {
        guard let libraryURL else {
            trace("library missing from bundle")
            return nil
        }
        // Read by WebKit from a file, not copied into a Swift string and
        // marshalled across as 3.4 MB of inline script.
        let folder = Self.engineFolder
        let page = folder.appending(path: "engine.html")
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let library = folder.appending(path: "mermaid.min.js")
            try? fm.removeItem(at: library)
            try fm.copyItem(at: libraryURL, to: library)
            try Data(Self.script.utf8).write(to: folder.appending(path: "engine.js"), options: .atomic)
            try Data(Self.page.utf8).write(to: page, options: .atomic)
            return page
        } catch {
            trace("engine page could not be written: \(error)")
            return nil
        }
    }()

    /// The engine's web view, started (or re-hosted) as needed. nil when there
    /// is nowhere to host it yet, or the page could not be written.
    private func webView(for engine: Engine) -> WKWebView? {
        #if os(macOS)
        if let webView = engine.webView { return webView }
        #else
        guard let host = Self.hostView() else { return nil }
        if let webView = engine.webView {
            // Its window went (a scene closed): a page outside a window never
            // lays out, so it moves to the current one.
            if webView.window == nil { host.addSubview(webView) }
            return webView
        }
        #endif
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
        webView.frame.origin = CGPoint(x: -20_000, y: -20_000 - CGFloat(engine.index) * 1_500)
        webView.isUserInteractionEnabled = false
        host.addSubview(webView)
        #endif
        webView.navigationDelegate = handler
        handler.webView = webView
        engine.handler = handler
        engine.webView = webView
        engine.ready = false
        webView.loadFileURL(page, allowingReadAccessTo: Self.engineFolder)
        trace("engine \(engine.index) starting")
        return webView
    }

    /// Takes a page down; whatever it was drawing is the caller's to settle.
    private func stop(_ engine: Engine) {
        engine.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "engine")
        engine.webView?.removeFromSuperview()
        engine.webView = nil
        engine.handler = nil
        engine.ready = false
    }

    /// A page died (WebKit's content process is killed under memory pressure,
    /// or crashed): its diagram counts as a transient failure, and a fresh page
    /// starts if there is more to draw.
    fileprivate func engineDied(_ index: Int, webView: WKWebView?) {
        let engine = engines[index]
        guard webView == nil || webView === engine.webView else { return }   // an old page's last word
        trace("engine \(index) terminated")
        restarts += 1
        if let current = engine.current {
            failTransiently(index, id: current.id, restart: true)
        } else {
            stop(engine)
        }
        guard restarts <= 3 * Self.engineCount else {
            for key in queue { failures[key] = "The diagram renderer stopped" }
            queue.removeAll()
            return
        }
        pump()
    }

    fileprivate func ready(_ index: Int, webView: WKWebView?) {
        let engine = engines[index]
        guard webView === engine.webView else { return }
        trace("engine \(index) ready")
        engine.ready = true
        pump()
    }

    /// The pages go after a quiet minute: each holds a WebKit process with the
    /// library loaded, which is wasted on a note with no diagrams.
    private func scheduleIdleCheck() {
        idleCheck?.cancel()
        idleCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled, Date.now.timeIntervalSince(self.lastActivity) >= 59 else { return }
            self.tearDownIdleEngines()
        }
    }

    private func tearDownIdleEngines() {
        guard queue.isEmpty else { return }
        for engine in engines where engine.current == nil && engine.webView != nil {
            trace("engine \(engine.index) idle, stopped")
            stop(engine)
        }
    }

    // MARK: - Disk cache

    private var screenScale: CGFloat {
        #if os(macOS)
        // The host window's screen: the backing scale the snapshot is taken at.
        host.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        #else
        // A window's traits, not `UITraitCollection.current`, which is only
        // meaningful while drawing and reads 0 elsewhere.
        let scale = Self.hostView()?.traitCollection.displayScale ?? 0
        return scale > 0 ? scale : 3
        #endif
    }

    private func loadFromDisk(_ key: Key) -> PlatformImage? {
        guard let diskCache else { return nil }
        let scale = screenScale
        let file = diskCache.file(source: key.source, isDark: key.isDark, scale: scale, stamp: stamp)
        guard let data = diskCache.load(file) else { return nil }
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

    /// Encoded and written off the main thread: PNG encoding a large diagram is
    /// the kind of work this renderer exists to keep away from it.
    private func saveToDisk(_ image: PlatformImage, for key: Key) {
        guard let diskCache else { return }
        #if os(macOS)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // The scale it was actually drawn at, so it reads back at its size.
        let scale = (CGFloat(cg.width) / max(image.size.width, 1)).rounded()
        let file = diskCache.file(source: key.source, isDark: key.isDark, scale: scale, stamp: stamp)
        Task.detached(priority: .utility) {
            guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
            diskCache.store(data, at: file)
        }
        #else
        let file = diskCache.file(source: key.source, isDark: key.isDark, scale: image.scale, stamp: stamp)
        let sendable = SendableImage(image: image)
        Task.detached(priority: .utility) {
            guard let data = sendable.image.pngData() else { return }
            diskCache.store(data, at: file)
        }
        #endif
    }

    #if !os(macOS)
    /// UIImage is immutable; handing one to a background encode is safe.
    private struct SendableImage: @unchecked Sendable { let image: UIImage }
    #endif

    // MARK: - Page

    /// The engine page. Its one script is a file of its own (`engine.js`), so
    /// the policy can refuse inline script entirely; nothing may load from the
    /// network, navigate, or submit anywhere. Mermaid styles its SVG inline,
    /// hence inline styles.
    private static let page = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src data:; font-src data:; base-uri 'none'; form-action 'none'">
    <style>html,body{margin:0;padding:0;background:transparent}
    #out{display:inline-block;padding:8px}</style>
    <script src="mermaid.min.js"></script><script src="engine.js"></script></head>
    <body><div id="out"></div></body></html>
    """

    /// Draws a diagram into `#out`, measures it, and reports back.
    private static let script = """
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
            // Mermaid gives the SVG width="100%" and its real width as a
            // max-width. In a shrink-to-fit box 100% of nothing falls back to
            // 300 px, so every diagram came out 300 wide: wide ones (a Gantt
            // chart, a sequence) shrunk to unreadable, tall narrow ones blown
            // up. Its own size, from max-width or else the viewBox, instead.
            var box = svg.viewBox && svg.viewBox.baseVal;
            var natural = parseFloat(svg.style.maxWidth) || (box && box.width) || 600;
            svg.setAttribute("width", String(Math.min(natural, 1360)));
            svg.removeAttribute("height");
            svg.style.maxWidth = "none";
            // setTimeout, not requestAnimationFrame: the host is parked
            // offscreen and rAF does not fire when it is not visible.
            setTimeout(function () {
              var rect = out.getBoundingClientRect();
              post({ kind: "done", id: id, width: rect.width, height: rect.height });
            }, 0);
          }).catch(function (e) {
            // Mermaid can leave its scratch element behind on a failed render.
            var stray = document.getElementById("d" + id);
            if (stray && stray.parentNode) { stray.parentNode.removeChild(stray); }
            post({ kind: "error", id: id, message: String((e && e.message) || e) });
          });
        } catch (e) { post({ kind: "error", id: id, message: String((e && e.message) || e) }); }
      };
      post({ kind: typeof mermaid === "undefined" ? "missing" : "ready" });
    })();
    """

    /// Bridges a page's messages back into Swift.
    private final class EngineHandler: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var owner: MermaidRenderer?
        /// The page this handler serves, to tell its messages from a previous
        /// page's last ones.
        weak var webView: WKWebView?
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
            MainActor.assumeIsolated { owner?.engineDied(index, webView: webView) }
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
                guard let owner, message.webView === webView else { return }
                switch kind {
                case "ready": owner.ready(index, webView: message.webView)
                case "missing":
                    owner.trace("library failed to load")
                    owner.engineDied(index, webView: message.webView)
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
