import SwiftUI
import InkstoneCore

/// Insert Template: the notes in the template folder, filtered as you type.
struct TemplatePickerView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Listed once when the sheet opens, not on every keystroke.
    @State private var all: [URL] = []

    private var templates: [URL] {
        guard !query.isEmpty else { return all }
        return all.filter { $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if all.isEmpty {
                    ContentUnavailableView(
                        "No templates",
                        systemImage: "doc.on.doc",
                        description: Text("Put notes in the “\(workspace.settings.data.templateFolder)” folder of this vault, or choose another folder in Settings › Files & Links.")
                    )
                } else {
                    ForEach(templates, id: \.self) { url in
                        Button {
                            workspace.insertTemplate(url)
                            dismiss()
                        } label: {
                            Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc.text")
                                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $query, prompt: Text("Find a template"))
            .onAppear { all = workspace.templateFiles }
            .navigationTitle("Insert Template")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 420)
        #endif
    }
}
