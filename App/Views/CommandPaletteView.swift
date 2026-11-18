import SwiftUI
import InkstoneCore

/// ⇧⌘P: every menu command, found by typing a few letters of its name.
struct CommandPaletteView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFieldFocused: Bool

    /// Shortcuts mean nothing on an iPhone, which has no hardware keyboard
    /// to press them on; iPad and Mac show them.
    private var showsShortcuts: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
        #else
        true
        #endif
    }

    private var results: [AppCommand] {
        let available = AppCommand.all.filter { $0.isAvailable(workspace) }
        return CommandMatcher.rank(query, available) { $0.localizedTitle }
    }

    var body: some View {
        #if os(iOS)
        // The system's own search-and-list layout: it keeps clear of the
        // sheet's corners and of the iPhone Duo outer screen's masked edge,
        // which a hand-built header did not.
        let results = results
        NavigationStack {
            List(Array(results.enumerated()), id: \.element.id) { index, command in
                Button {
                    highlighted = index
                    run(results)
                } label: {
                    HStack(spacing: 10) {
                        Label(command.localizedTitle, systemImage: command.systemImage)
                        Spacer()
                        if showsShortcuts, let shortcut = command.shortcut {
                            Text(shortcut).font(.callout.monospaced()).foregroundStyle(style.faintText)
                        }
                    }
                    .frame(minHeight: 36)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if results.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text("Type a command…"))
            .onSubmit(of: .search) { run(results) }
            .autocorrectionDisabled()
            .navigationTitle("Command Palette")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .onChange(of: query) { highlighted = 0 }
        #else
        macBody
        #endif
    }

    #if os(macOS)
    private var macBody: some View {
        let results = results
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(style.faintText)
                TextField(localized("Type a command…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($isFieldFocused)
                    .autocorrectionDisabled()
                    .onSubmit { run(results) }
                    .onKeyPress(.upArrow) {
                        highlighted = max(0, highlighted - 1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        highlighted = max(0, min(results.count - 1, highlighted + 1))
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().overlay(style.divider)

            ScrollViewReader { proxy in
                List(Array(results.enumerated()), id: \.element.id) { index, command in
                    HStack(spacing: 10) {
                        Image(systemName: command.systemImage)
                            .frame(width: 20)
                            .foregroundStyle(style.faintText)
                        Text(command.localizedTitle)
                            .font(style.uiFont.weight(index == highlighted ? .semibold : .regular))
                        Spacer()
                        if showsShortcuts, let shortcut = command.shortcut {
                            Text(shortcut)
                                .font(.callout.monospaced())
                                .foregroundStyle(style.faintText)
                        }
                    }
                    .frame(minHeight: 30)
                    .listRowBackground(index == highlighted ? style.selection : Color.clear)
                    .contentShape(.rect)
                    .onTapGesture {
                        highlighted = index
                        run(results)
                    }
                    .id(index)
                }
                .listStyle(.plain)
                .onChange(of: highlighted) { _, new in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
                }
            }

            if results.isEmpty {
                Text("No matching command")
                    .font(style.uiFont)
                    .foregroundStyle(style.faintText)
                    .padding(14)
            }
        }
        .frame(minWidth: 440, minHeight: 380)
        .background(style.background)
        .onAppear { isFieldFocused = true }
        .onChange(of: query) { highlighted = 0 }
    }
    #endif

    /// Closes the palette; RootView runs the command from the sheet's
    /// onDismiss, once it is gone.
    private func run(_ results: [AppCommand]) {
        guard results.indices.contains(highlighted) else { return }
        workspace.pendingPaletteCommand = results[highlighted]
        dismiss()
    }
}
