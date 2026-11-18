import Foundation
import WebKit
import InkstoneCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Export the open note as a self-contained HTML file or a paginated PDF.
///
/// The HTML comes from `HTMLExporter` (core). The PDF is that same HTML
/// printed by WebKit onto A4 pages — not `WKWebView.createPDF`, which makes
/// one very long page.
@MainActor
enum NoteExporter {
    enum Format { case html, pdf
        var fileExtension: String { self == .html ? "html" : "pdf" }
    }

    /// The note's HTML, with its embedded images inlined.
    static func html(for url: URL, in workspace: Workspace) -> String? {
        guard let text = workspace.documents[url]?.text ?? (try? workspace.store?.read(url)) else { return nil }
        return HTMLExporter.document(
            text, title: url.deletingPathExtension().lastPathComponent,
            resolveAttachment: { workspace.resolveEmbed($0, from: url) })
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
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return out
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
