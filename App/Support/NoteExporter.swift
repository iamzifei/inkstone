import Foundation
import WebKit
import InkstoneCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Export the open note as a self-contained HTML file, a paginated PDF, or one
/// long PNG image (for sharing where a document will not go — a chat, a post).
///
/// The HTML comes from `HTMLExporter` (core), with code coloured by language.
/// The PDF is that same HTML printed by WebKit onto A4 pages — not
/// `WKWebView.createPDF`, which makes one very long page. The image is that
/// same HTML laid out at reading width and snapshotted whole.
@MainActor
enum NoteExporter {
    enum Format { case html, pdf, png
        var fileExtension: String {
            switch self { case .html: "html"; case .pdf: "pdf"; case .png: "png" }
        }
    }

    /// Whether the last image export was cut short to fit (a very long note).
    static var lastImageWasCut = false

    /// The note's HTML, with its embedded images inlined.
    static func html(for url: URL, in workspace: Workspace) -> String? {
        guard let text = workspace.documents[url]?.text ?? (try? workspace.store?.read(url)) else { return nil }
        return HTMLExporter.document(
            text, title: url.deletingPathExtension().lastPathComponent,
            resolveAttachment: { workspace.resolveEmbed($0, from: url) },
            highlight: { CodeHighlighter.shared.spansNow(code: $0, language: $1) })
    }

    /// Prints HTML to a paginated PDF file (also used by the smoke test).
    static func printPDF(_ html: String, to url: URL) async throws {
        try await PDFPrinter().print(html, to: url)
    }

    /// Removes an export's temporary folder (it holds the whole note).
    static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    /// Removes export folders over an hour old — ones a share sheet handed
    /// on and has long finished with. Not newer ones: an extension may still
    /// be reading a file after its sheet closed.
    static func sweepOldExports() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory,
                                                   includingPropertiesForKeys: [.creationDateKey])) ?? []
        let cutoff = Date.now.addingTimeInterval(-3600)
        for dir in folders where dir.lastPathComponent.hasPrefix("Export-") {
            let created = (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: dir) }
        }
    }

    /// Writes the export to a temporary file named after the note.
    static func export(_ url: URL, as format: Format, in workspace: Workspace) async throws -> URL {
        guard let html = html(for: url, in: workspace) else { throw CocoaError(.fileReadUnknown) }
        sweepOldExports()
        let dir = FileManager.default.temporaryDirectory.appending(path: "Export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appending(path: url.deletingPathExtension().lastPathComponent + "." + format.fileExtension)
        do {
            switch format {
            case .html: try Data(html.utf8).write(to: out)
            case .pdf: try await PDFPrinter().print(html, to: out)
            case .png: lastImageWasCut = try await ImageRenderer().render(html, to: out)
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return out
    }
}

/// Lays HTML out in an off-screen web view at reading width and writes the
/// whole page as one PNG.
@MainActor
private final class ImageRenderer: NSObject, WKNavigationDelegate {
    private var loaded: CheckedContinuation<Void, Error>?
    /// The article's own width (the stylesheet caps it) plus its margins.
    private let width: CGFloat = 760
    /// The most pixels one image may hold — about 100 MB as RGBA while it is
    /// made. A taller note is cut there; the user is told, and the PDF has it
    /// all. In pixels, not points: a 3x phone holds 2.25 times a 2x Mac's.
    private let maximumPixels: CGFloat = 25_000_000

    /// - Returns: whether the note was cut short to fit.
    func render(_ html: String, to url: URL) async throws -> Bool {
        let config = WKWebViewConfiguration()
        // As for PDF: notes can hold raw HTML, so no scripts; the document's
        // CSP blocks every network load.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 800), configuration: config)
        webView.navigationDelegate = self
        #if os(macOS)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: width, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { window.close() }
        #else
        // A web view outside a window does not lay out (or snapshot).
        guard let host = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: { $0.isKeyWindow }) else { throw CocoaError(.fileWriteUnknown) }
        let scale = host.traitCollection.displayScale > 0 ? host.traitCollection.displayScale : 3
        webView.frame.origin = CGPoint(x: -20_000, y: -20_000)
        host.addSubview(webView)
        defer { webView.removeFromSuperview() }
        #endif

        // One deadline for the whole of it: a load, a measurement or a
        // snapshot that never answers must not leave export stuck for good.
        // Whichever of the work and the deadline settles first wins.
        let once = Once<Bool>()
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<Bool, Error>) in
            once.continuation = done
            let work = Task { @MainActor in
                do {
                    #if os(macOS)
                    let cut = try await self.produce(webView, html: html, scale: scale, to: url) { window.setContentSize($0) }
                    #else
                    let cut = try await self.produce(webView, html: html, scale: scale, to: url) { _ in }
                    #endif
                    once.finish(.success(cut))
                } catch {
                    once.finish(.failure(error))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                work.cancel()
                self.finishLoad(.failure(CocoaError(.fileWriteUnknown)))
                once.finish(.failure(CocoaError(.fileWriteUnknown)))
            }
        }
    }

    /// Loads, measures, resizes, snapshots and writes. Returns whether the
    /// note was cut short to fit.
    private func produce(_ webView: WKWebView, html: String, scale: CGFloat, to url: URL,
                         resize: (CGSize) -> Void) async throws -> Bool {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loaded = c
            webView.loadHTMLString(html, baseURL: nil)
        }
        // Scripts are off for the page, not for the app asking its height.
        // The article's bottom edge plus the page's own margin, not the page's
        // scroll height: that is never less than the viewport, so a short note
        // came out padded to the viewport's height. (A tiny viewport to avoid
        // that measured before layout and produced an empty strip.)
        let measured = try await webView.evaluateJavaScript("""
            (function () {
              var article = document.querySelector("article") || document.body;
              var bottom = article.getBoundingClientRect().bottom + window.scrollY;
              var margin = parseFloat(getComputedStyle(document.body).marginBottom) || 0;
              return Math.ceil(bottom + margin + 32);
            })()
            """) as? Double
        guard let measured, measured > 0 else { throw CocoaError(.fileWriteUnknown) }
        let limit = maximumPixels / (width * scale * scale)
        let size = CGSize(width: width, height: min(CGFloat(measured), limit))
        webView.frame.size = size
        resize(size)
        try await Task.sleep(for: .milliseconds(150))   // one layout after the resize
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        let image = try await webView.takeSnapshot(configuration: configuration)
        #if os(macOS)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        #else
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        #endif
        try data.write(to: url)
        return CGFloat(measured) > limit
    }

    private func finishLoad(_ result: Result<Void, Error>) {
        guard let loaded else { return }
        self.loaded = nil
        loaded.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoad(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoad(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(error))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finishLoad(.failure(CocoaError(.fileReadUnknown))) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // The document itself and nothing else, as for PDF: a raw
        // `<meta http-equiv=refresh>` in a note must not take the export away.
        action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }
}

/// Resumes a continuation once, however many parties try.
@MainActor
private final class Once<Value: Sendable> {
    var continuation: CheckedContinuation<Value, Error>?
    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// Loads HTML into an off-screen web view and prints it to a PDF file.
@MainActor
private final class PDFPrinter: NSObject, WKNavigationDelegate {
    private var loaded: CheckedContinuation<Void, Error>?
    // A4 in points, with 2 cm margins.
    private let paper = CGSize(width: 595.2, height: 841.8)
    private let margin: CGFloat = 56.7

    func print(_ html: String, to url: URL) async throws {
        let config = WKWebViewConfiguration()
        // Notes can hold raw HTML (and arrive by sync from elsewhere): no
        // scripts. The document's CSP also blocks every network load.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: CGRect(origin: .zero, size: paper), configuration: config)
        webView.navigationDelegate = self
        // A load that never finishes (a stalled subresource) must not hang the
        // export forever.
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.finishLoad(.failure(CocoaError(.fileReadUnknown)))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loaded = c
            webView.loadHTMLString(html, baseURL: nil)
        }
        #if os(macOS)
        let info = NSPrintInfo()
        info.paperSize = paper
        info.topMargin = margin; info.bottomMargin = margin
        info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // WebKit needs the view to have a size it can lay pages out against.
        operation.view?.frame = CGRect(origin: .zero, size: paper)
        // An off-screen window: WebKit prints nothing from a view in no window.
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: paper.width, height: paper.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { window.close() }
        // Not `run()`: WebKit lays pages out asynchronously, and a synchronous
        // run waits on itself forever. The modal form calls back when done.
        let succeeded = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let done = PrintCallback { c.resume(returning: $0) }
            operation.runModal(for: window, delegate: done,
                               didRun: #selector(PrintCallback.printOperationDidRun(_:success:contextInfo:)),
                               contextInfo: nil)
        }
        guard succeeded else { throw CocoaError(.fileWriteUnknown) }
        #else
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let page = CGRect(origin: .zero, size: paper)
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(page.insetBy(dx: margin, dy: margin), forKey: "printableRect")
        // A blank PDF reported as success is worse than an error.
        guard renderer.numberOfPages > 0 else { throw CocoaError(.fileWriteUnknown) }
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for index in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        try data.write(to: url)
        #endif
    }

    /// Resumes the load wait once, whichever of finish / fail / crash /
    /// timeout comes first.
    private func finishLoad(_ result: Result<Void, Error>) {
        guard let c = loaded else { return }
        loaded = nil
        c.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(.success(()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(error))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(error))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishLoad(.failure(CocoaError(.fileReadUnknown)))
    }
    /// Only the note itself loads; a link or meta refresh in it does not
    /// navigate the print view to another page.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }
}

#if os(macOS)
/// Target for NSPrintOperation's Objective-C completion callback. Keeps
/// itself alive until called (the operation does not retain its delegate).
private final class PrintCallback: NSObject {
    private let completion: (Bool) -> Void
    private var keepAlive: PrintCallback?

    init(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
        super.init()
        keepAlive = self
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        completion(success)
        keepAlive = nil
    }
}
#endif
