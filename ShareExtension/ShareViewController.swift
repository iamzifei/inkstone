import UIKit
import SwiftUI
import UniformTypeIdentifiers
import InkstoneCore

/// The iOS share sheet's "Inkstone": a page, a link or some text, saved to the
/// vault's Inbox note.
///
/// An extension cannot reach the vault (its folder is the app's, through a
/// security-scoped bookmark), so it drops the item into the app group's inbox
/// folder; the app moves it into Inbox.md the next time it is active.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { @MainActor in
            let item = await Self.collect(from: extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            let host = UIHostingController(rootView: ShareView(
                item: item,
                save: { [weak self] edited in self?.save(edited) },
                cancel: { [weak self] in
                    self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
                }))
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
    }

    private func save(_ item: Capture.SharedItem) {
        do {
            try SharedInbox.add(item)
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            extensionContext?.cancelRequest(withError: error)
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
                } else if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let found = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    text = found
                }
            }
        }
        // Safari shares the page title as the item's text; as a link title it
        // reads better than as the note's text.
        if let t = text, let u = url, t == u.absoluteString { text = nil }
        return Capture.SharedItem(text: text, url: url, title: title, date: .now)
    }
}

private struct ShareView: View {
    @State var item: Capture.SharedItem
    let save: (Capture.SharedItem) -> Void
    let cancel: () -> Void
    @State private var text: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                } footer: {
                    Text("Saved to the Inbox note of your vault the next time Inkstone opens.")
                }
                if let url = item.url {
                    Section("Link") {
                        VStack(alignment: .leading, spacing: 4) {
                            if let title = item.title { Text(title).font(.headline) }
                            Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .navigationTitle("Inkstone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var edited = item
                        edited.text = text.isEmpty ? nil : text
                        save(edited)
                    }
                    .disabled(text.isEmpty && item.url == nil)
                }
            }
        }
        .onAppear { text = item.text ?? "" }
    }
}
