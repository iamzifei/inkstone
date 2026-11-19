import SwiftUI
import InkstoneCore

/// "Copy or move?" for files brought into the knowledge base. Copy is the
/// default (the original stays put); "always do this" makes it the answer
/// from now on — changeable in Settings › Knowledge Base.
struct DropChoiceSheet: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    let urls: [URL]
    @State private var remember = false

    var body: some View {
        let kb = workspace.knowledgeBase
        VStack(alignment: .leading, spacing: 16) {
            Text("Copy or move \(urls.count) items into your knowledge base?")
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Label("Copy: the originals stay where they are.", systemImage: "doc.on.doc")
                Label("Move: they live only in the knowledge base. The originals are removed after a complete copy.", systemImage: "arrow.right.doc.on.clipboard")
            }
            .font(.callout)
            .foregroundStyle(style.secondaryText)
            Toggle("Always do this", isOn: $remember)
            HStack {
                Button("Cancel", role: .cancel) { kb.pendingDrop = nil }
                Spacer()
                Button("Move Files") { kb.bringIn(urls, action: .move, remember: remember) }
                Button("Copy Files") { kb.bringIn(urls, action: .copy, remember: remember) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
    }
}

/// The hint over the window while files are dragged over it.
struct DropTargetOverlay: View {
    @Environment(\.style) private var style
    let inbox: String

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(style.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(style.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                Label("Drop to add to \(inbox)", systemImage: "tray.and.arrow.down.fill")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(12)
            .allowsHitTesting(false)
    }
}
