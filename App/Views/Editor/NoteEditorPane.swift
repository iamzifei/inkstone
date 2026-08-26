import SwiftUI
import InkstoneCore

/// The note editing surface: title bar, editor, and status line.
struct NoteEditorPane: View {
    let url: URL

    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        if let document = workspace.document(for: url) {
            @Bindable var document = document

            VStack(spacing: 0) {
                header(for: document)
                Divider().overlay(style.divider)

                if workspace.settings.data.editorMode == .reading {
                    // A separate view, not the editor with editing switched off.
                    // The editor's text storage *is* the file, so rendering into
                    // it would rewrite the note on disk.
                    ReadingView(
                        markdown: document.text,
                        resolveAttachment: { workspace.resolveEmbed($0, from: url) }
                    )
                } else {
                    MarkdownEditorView(
                    text: $document.text,
                    style: style,
                    mode: workspace.settings.data.editorMode,
                    actions: EditorActions(
                        followWikiLink: { link in
                            workspace.follow(link: link, from: url)
                        },
                        followTag: { tag in
                            workspace.sidebarSection = .tags
                            workspace.searchQuery = "tag:" + tag
                        },
                        openExternal: { openURL($0) },
                        resolveAttachment: { target in
                            workspace.resolveEmbed(target, from: url)
                        },
                        resolveNoteEmbed: { link in
                            workspace.embeddedNoteText(for: link, from: url)
                        },
                        importAttachment: { source in
                            guard let imported = workspace.importAttachment(from: source) else { return nil }
                            return workspace.embedMarkup(for: imported)
                        },
                        importAttachmentData: { data, name in
                            guard let imported = workspace.importAttachment(data: data, name: name) else {
                                return nil
                            }
                            return workspace.embedMarkup(for: imported)
                        },
                        openAttachment: { openURL($0) },
                        openVaultFile: { file in workspace.openFile(at: file) },
                        resolveVaultPath: { path in workspace.resolveVaultPath(path, from: url) }
                    ),
                    spellCheck: workspace.settings.data.spellCheck,
                    showProperties: workspace.settings.data.showFrontmatterAsProperties,
                    editing: EditingBehaviour(workspace.settings.data),
                    reveal: workspace.revealTarget?.url == url ? workspace.revealTarget : nil,
                    indexGeneration: workspace.indexGeneration
                    )
                }

                Divider().overlay(style.divider)
                statusLine(for: document)
            }
            .onDisappear { document.save() }
        } else {
            ContentUnavailableView("Couldn't open note", systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private func header(for document: NoteDocument) -> some View {
        HStack(spacing: 8) {
            Text(url.deletingPathExtension().lastPathComponent)
                .font(style.uiFont.weight(.semibold))
                .foregroundStyle(style.text)
                .lineLimit(1)

            if document.isDirty {
                Circle()
                    .fill(style.accent.opacity(0.6))
                    .frame(width: 6, height: 6)
                    .help(String(localized: "Unsaved changes"))
            }

            Spacer()

            // Not at a compact width. There is no sidebar on screen to reveal
            // anything *into* — the file tree is a separate screen you navigate
            // back to — so the button would look like it did nothing.
            if canRevealInTree {
                revealButton
            }

            // A segmented picker shows one tooltip for the whole control, not
            // one per segment, so these are three buttons that look like a
            // picker. Three unlabelled glyphs with nothing explaining them was
            // the complaint — and the third, reading mode, is the one nobody
            // guesses.
            HStack(spacing: 0) {
                modeButton(.livePreview, symbol: "eye",
                           help: "Live preview — formatting shown, syntax only on the line you're editing")
                modeButton(.source, symbol: "chevron.left.forwardslash.chevron.right",
                           help: "Source — the raw Markdown exactly as it is on disk")
                modeButton(.reading, symbol: "book",
                           help: "Reading — the same as live preview but locked, so nothing is changed by a stray keystroke")
            }
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(style.secondaryBackground)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Whether the file tree is on screen beside the editor at all.
    private var canRevealInTree: Bool {
        #if os(iOS)
        sizeClass != .compact
        #else
        true
        #endif
    }

    private var revealButton: some View {
        Button {
            workspace.revealInTree(url)
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 12))
                .frame(width: 26, height: 22)
                .foregroundStyle(style.secondaryText)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Find this note in the sidebar (⌥⌘R)")
        .accessibilityLabel(Text("Reveal in sidebar"))
    }

    private func modeButton(
        _ target: EditorMode,
        symbol: String,
        help: LocalizedStringKey
    ) -> some View {
        let isActive = workspace.settings.data.editorMode == target
        return Button {
            workspace.settings.data.editorMode = target
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 38, height: 22)
                .foregroundStyle(isActive ? Color.white : style.secondaryText)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? style.accent : .clear)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(label(for: target)))
    }

    private func label(for mode: EditorMode) -> LocalizedStringKey {
        switch mode {
        case .livePreview: "Live preview"
        case .source: "Source"
        case .reading: "Reading"
        }
    }

    private var editorModeBinding: Binding<EditorMode> {
        Binding(
            get: { workspace.settings.data.editorMode },
            set: { workspace.settings.data.editorMode = $0 }
        )
    }

    @ViewBuilder
    private func statusLine(for document: NoteDocument) -> some View {
        let backlinkCount = workspace.index.incoming(to: url).count
        HStack(spacing: 14) {
            Text("\(document.wordCount) words")
            if backlinkCount > 0 {
                Text("\(backlinkCount) backlinks")
            }
            Spacer()
            if let saved = document.lastSaved {
                Text("Saved \(saved.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.caption)
        .foregroundStyle(style.faintText)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

/// Right column: note properties, backlinks, and unlinked mentions.
struct InspectorView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    /// See the note in `AssistantPane`: only the workspace is in the
    /// environment, and asking for anything else traps at launch.
    private var settings: AppSettings { workspace.settings }

    /// Which half of the inspector is showing.
    ///
    /// A segmented switch rather than another `Section` in the list: the
    /// assistant needs the full height and a text field pinned to the bottom,
    /// neither of which a row inside a scrolling `List` can have.
    private enum Tab: Hashable { case inspector, assistant }
    @State private var tab: Tab = .inspector

    var body: some View {
        // The switch appears only once the assistant is turned on, so the
        // inspector is unchanged for anyone not using it.
        if settings.data.assistant.isEnabled {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Note").tag(Tab.inspector)
                    Text("Assistant").tag(Tab.assistant)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)

                Divider()

                switch tab {
                case .inspector: inspectorContent
                case .assistant: AssistantPane()
                }
            }
        } else {
            inspectorContent
        }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let url = workspace.activeTab?.url, let note = workspace.index.metadata(for: url) {
            List {
                if !note.frontmatter.properties.isEmpty {
                    Section(String(localized: "Properties")) {
                        ForEach(note.frontmatter.properties.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .top) {
                                Text(key)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(style.secondaryText)
                                Spacer()
                                Text(displayValue(note.frontmatter.properties[key]))
                                    .font(.caption)
                                    .foregroundStyle(style.text)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }

                if !note.tags.isEmpty {
                    Section(String(localized: "Tags")) {
                        FlowLayout(spacing: 6) {
                            ForEach(note.tags, id: \.self) { tag in
                                Text("#" + tag)
                                    .font(.caption)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(style.tagColor.opacity(0.15)))
                                    .foregroundStyle(style.tagColor)
                            }
                        }
                    }
                }

                if !note.headings.isEmpty {
                    Section(String(localized: "Outline")) {
                        // Also reachable from the sidebar's outline tab. It lives
                        // here too because this is the panel that answers
                        // "what is in the note I am looking at", and that is
                        // where James went looking for it.
                        ForEach(note.headings, id: \.range.location) { heading in
                            Button {
                                workspace.reveal(heading.range, in: url)
                            } label: {
                                Text(heading.text)
                                    .font(style.uiFont)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, CGFloat(min(heading.level, 6) - 1) * 10)
                                    .foregroundStyle(
                                        heading.level <= 2 ? style.text : style.secondaryText
                                    )
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section(String(localized: "Backlinks")) {
                    let backlinks = workspace.index.incoming(to: url)
                    if backlinks.isEmpty {
                        Text("No backlinks yet")
                            .font(.caption)
                            .foregroundStyle(style.faintText)
                    }
                    ForEach(Array(Set(backlinks.map(\.source))), id: \.self) { source in
                        Text(workspace.index.metadata(for: source)?.title ?? source.lastPathComponent)
                            .font(style.uiFont)
                            .contentShape(.rect)
                            .onTapGesture { workspace.openNote(at: source) }
                    }
                }

                Section(String(localized: "Outgoing links")) {
                    ForEach(Array(workspace.index.outgoing(from: url).enumerated()), id: \.offset) { _, edge in
                        HStack {
                            Image(systemName: edge.destination == nil ? "link.badge.plus" : "link")
                                .font(.caption2)
                                .foregroundStyle(edge.destination == nil ? style.unresolvedLink : style.link)
                            Text(edge.destination.map { workspace.index.metadata(for: $0)?.title ?? $0.lastPathComponent }
                                 ?? edge.unresolvedTarget)
                                .font(style.uiFont)
                        }
                        .contentShape(.rect)
                        .onTapGesture {
                            if let destination = edge.destination { workspace.openNote(at: destination) }
                        }
                    }
                }

                Section(String(localized: "Local graph")) {
                    LocalGraphThumbnail(url: url)
                        .frame(height: 200)
                }
            }
            .listStyle(.sidebar)
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "sidebar.trailing")
        }
    }

    private func displayValue(_ value: PropertyValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .list(let items): return items.compactMap(\.stringValue).joined(separator: ", ")
        default: return value.stringValue ?? ""
        }
    }
}

/// Simple wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
