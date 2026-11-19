import UIKit
import SwiftUI
import UniformTypeIdentifiers
import InkstoneCore

/// The iOS share sheet's "Inkstone": a page, a link, some text — or files
/// (from Files, Photos, Mail or any app) — added to the vault: in a knowledge
/// base, into its inbox to be filed; otherwise to the Inbox note.
///
/// An extension cannot reach the vault (its folder is the app's, through a
/// security-scoped bookmark), so it drops the item into the app group's inbox
/// folder; the app moves it into Inbox.md the next time it is active.
final class ShareViewController: UIViewController {
    private let model = ShareModel()
    /// completeRequest / cancelRequest exactly once, however often Save or
    /// Cancel is tapped.
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // The form shows at once (with Cancel), and fills in when the shared
        // item has loaded — a slow provider no longer means a blank sheet.
        let host = UIHostingController(rootView: ShareView(
            model: model,
            save: { [weak self] in self?.save() },
            cancel: { [weak self] in self?.finish(cancelled: true) }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        Task { @MainActor in
            let inputs = extensionContext?.inputItems as? [NSExtensionItem] ?? []
            let item = await Self.collect(from: inputs)
            model.files = await Self.collectFiles(from: inputs, into: model.staging)
            model.item = item
            model.text = item.text ?? ""
            model.isLoading = false
        }
    }

    private func save() {
        guard !finished else { return }
        var item = model.item
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        item.text = text.isEmpty ? nil : model.text
        item.date = .now
        do {
            try SharedInbox.add(item, files: model.files)
            try? FileManager.default.removeItem(at: model.staging)
            finish(cancelled: false)
        } catch {
            // Shown, not swallowed: the user would otherwise think it was saved.
            model.error = error.localizedDescription
        }
    }

    private func finish(cancelled: Bool) {
        guard !finished else { return }
        finished = true
        if cancelled { try? FileManager.default.removeItem(at: model.staging) }
        if cancelled {
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// The files shared (not text or a web link), each copied out while the
    /// system's temporary copy still exists — it is removed as soon as the
    /// load callback returns.
    static func collectFiles(from items: [NSExtensionItem], into staging: URL) async -> [URL] {
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var out: [URL] = []
        for item in items {
            for provider in item.attachments ?? [] {
                // The most specific type that is a file's data — not plain
                // text or a web link, which `collect` handles.
                // A file handed over as a file (Files, Mail attachments) is a
                // file whatever it holds; otherwise only non-text data —
                // pictures, video, sound, PDF — is: text and web links are
                // what `collect` turns into the note.
                let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
                let isFile = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                guard let type = types.first(where: { t in
                    (t.conforms(to: .data) || t.conforms(to: .package)) && !t.conforms(to: .url)
                        && (isFile || !t.conforms(to: .text))
                }) else { continue }
                if let copied = await copyFile(from: provider, type: type, into: staging) { out.append(copied) }
            }
        }
        return out
    }

    private static func copyFile(from provider: NSItemProvider, type: UTType, into staging: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                var name = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension ?? Optional(url.pathExtension), !ext.isEmpty {
                    name += ".\(ext)"
                }
                let folder = staging.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                let dest = folder.appending(path: name)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: dest)
                    continuation.resume(returning: dest)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Text, a web link and the page title from whatever the host app shared.
    static func collect(from items: [NSExtensionItem]) async -> Capture.SharedItem {
        var text: String?
        var url: URL?
        var title: String?
        for item in items {
            if title == nil, let t = item.attributedContentText?.string, !t.isEmpty { title = t }
            for provider in item.attachments ?? [] {
                if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let found = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                   !found.isFileURL {
                    url = found
                } else if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    // Mail and Notes can hand over attributed text or raw data
                    // rather than a String.
                    let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
                    switch loaded {
                    case let s as String: text = s
                    case let a as NSAttributedString: text = a.string
                    case let d as Data: text = String(data: d, encoding: .utf8)
                    case let u as URL where u.isFileURL: text = try? String(contentsOf: u, encoding: .utf8)
                    default: break
                    }
                }
            }
        }
        // Safari shares the page title as the item's text; as a link title it
        // reads better than as the note's text.
        if let t = text, let u = url, t == u.absoluteString { text = nil }
        return Capture.SharedItem(text: text, url: url, title: title, date: .now)
    }
}

@MainActor
@Observable
final class ShareModel {
    var item = Capture.SharedItem(text: nil, url: nil, title: nil)
    var text = ""
    var isLoading = true
    var error: String?
    let hasVault = SharedInbox.appHasVault
    /// Files shared, copied out of the host app's hands.
    var files: [URL] = []
    let staging = FileManager.default.temporaryDirectory.appending(path: "share-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private struct ShareView: View {
    @Bindable var model: ShareModel
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if model.isLoading {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                } else {
                    if !model.files.isEmpty {
                        Section {
                            ForEach(model.files, id: \.self) { file in
                                Label(file.lastPathComponent, systemImage: "doc")
                                    .lineLimit(1)
                            }
                        } header: {
                            Text("\(model.files.count) files")
                        } footer: {
                            Text("Added to your knowledge base's inbox and filed the next time Inkstone opens (in another vault: its attachments folder).")
                        }
                    }
                    Section {
                        TextEditor(text: $model.text)
                            .frame(minHeight: model.files.isEmpty ? 120 : 60)
                    } footer: {
                        if model.files.isEmpty {
                            Text(model.hasVault
                                 ? "Saved the next time Inkstone opens: in a knowledge base, as a note in its inbox; otherwise in the vault's Inbox note."
                                 : "Open Inkstone and choose a vault: what you share waits here until then.")
                        }
                    }
                    if let url = model.item.url {
                        Section("Link") {
                            VStack(alignment: .leading, spacing: 4) {
                                if let title = model.item.title { Text(title).font(.headline) }
                                Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    if let error = model.error {
                        Section { Text(error).foregroundStyle(.red) } header: { Text("Not saved") }
                    }
                }
            }
            .navigationTitle("Inkstone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(model.isLoading
                                  || (model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      && model.item.url == nil && model.files.isEmpty))
                }
            }
        }
    }
}
