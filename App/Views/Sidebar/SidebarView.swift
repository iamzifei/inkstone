import SwiftUI
import InkstoneCore

/// Left column: vault switcher, section picker, and the active section's content.
struct SidebarView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    #if os(iOS)
    #if DEBUG
    /// Opens Settings at launch, so the sheet can be looked at without driving a
    /// tap — the same reason the other debug hooks exist, and the only way to
    /// check that a sheet inherits the workspace and the theme rather than
    /// assuming it does.
    ///
    ///     SIMCTL_CHILD_INKSTONE_OPEN_SETTINGS=1 xcrun simctl launch <sim> com.orris.inkstone
    @State private var isShowingSettings =
        ProcessInfo.processInfo.environment["INKSTONE_OPEN_SETTINGS"] != nil
    #else
    @State private var isShowingSettings = false
    #endif
    #endif

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            #if os(iOS)
            // macOS gets Settings from the `Settings` scene and ⌘, — a scene
            // type that does not exist on iOS. `SettingsView` has had an iOS
            // form since it was written and nothing could ever open it, so
            // themes, typography, editor behaviour and sync were all unreachable
            // on the phone.
            //
            // In the sidebar's own header rather than in a `.toolbar`: on iPhone
            // this view is the root of a `NavigationStack` with no title, so a
            // toolbar item would summon an otherwise empty navigation bar and
            // push the whole sidebar down to hold one button.
            HStack(spacing: 0) {
                VaultSwitcher()
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(style.uiFont)
                        .foregroundStyle(style.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Settings"))
            }
            #else
            VaultSwitcher()
            #endif
            SectionPicker(selection: $workspace.sidebarSection)

            Divider().overlay(style.divider)

            switch workspace.sidebarSection {
            case .files: FileTreeView()
            case .search: SearchPane()
            case .tags: TagListView()
            case .links: UnresolvedLinksView()
            case .outline: OutlinePane()
            }
        }
        .background(style.secondaryBackground)
        #if os(iOS)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(onDone: { isShowingSettings = false })
        }
        #endif
    }
}

private struct VaultSwitcher: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    @State private var isPickingFolder = false

    var body: some View {
        Menu {
            ForEach(workspace.registry.vaults) { vault in
                Button {
                    workspace.open(vault)
                } label: {
                    Label(vault.name, systemImage: vault.isCloudBacked ? "icloud" : "folder")
                }
            }
            Divider()
            Button("Open Folder as Vault…", systemImage: "folder.badge.plus") {
                isPickingFolder = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: workspace.vault?.isCloudBacked == true ? "icloud" : "folder")
                Text(workspace.vault?.name ?? String(localized: "No Vault"))
                    .lineLimit(1)
                Spacer()
                if workspace.isIndexing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
            .font(style.uiFont.weight(.medium))
            .foregroundStyle(style.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            // The picker hands back a security-scoped URL; open the scope before
            // reading anything so bookmark creation succeeds.
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            if let vault = try? workspace.registry.register(folder: url) {
                workspace.open(vault)
            }
        }
    }
}

private struct SectionPicker: View {
    @Binding var selection: SidebarSection
    @Environment(\.style) private var style

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    Image(systemName: icon(for: section))
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(selection == section ? style.accent : style.secondaryText)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selection == section ? style.background : .clear)
                        )
                }
                .buttonStyle(.plain)
                .help(label(for: section))
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func icon(for section: SidebarSection) -> String {
        switch section {
        case .files: return "folder"
        case .search: return "magnifyingglass"
        case .tags: return "number"
        case .links: return "link"
        case .outline: return "list.bullet.indent"
        }
    }

    private func label(for section: SidebarSection) -> String {
        switch section {
        case .files: return String(localized: "Files")
        case .search: return String(localized: "Search")
        case .tags: return String(localized: "Tags")
        case .links: return String(localized: "Unresolved Links")
        case .outline: return String(localized: "Outline")
        }
    }
}

// MARK: - Files

struct FileTreeView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    @State private var expanded: Set<URL> = []
    @State private var renaming: URL?
    @State private var renameText = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if let tree = workspace.tree, let children = tree.children {
                    ForEach(children) { node in
                        FileRow(
                            node: node,
                            depth: 0,
                            expanded: $expanded,
                            renaming: $renaming,
                            renameText: $renameText
                        )
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.automatic)
    }
}

/// One row in the file tree.
///
/// Split out as its own `View` rather than a recursive `@ViewBuilder` function
/// because a function returning `some View` cannot reference itself — the opaque
/// result type would be defined in terms of itself. A struct can.
private struct FileRow: View {
    let node: FileNode
    let depth: Int
    @Binding var expanded: Set<URL>
    @Binding var renaming: URL?
    @Binding var renameText: String

    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    var body: some View {
        let isActive = workspace.activeTab?.url == node.url
        let isExpanded = expanded.contains(node.url)

        HStack(spacing: 5) {
            Image(systemName: node.isDirectory
                  ? (isExpanded ? "chevron.down" : "chevron.right")
                  : (node.isMarkdown ? "doc.text" : Self.icon(for: node.url)))
                .font(.system(size: node.isDirectory ? 9 : 11, weight: .semibold))
                .frame(width: 10)
                .foregroundStyle(style.faintText)

            if renaming == node.url {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(style.uiFont)
                    .onSubmit {
                        workspace.rename(node.url, to: renameText)
                        renaming = nil
                    }
            } else {
                Text(node.isDirectory ? node.name : node.basename)
                    .font(style.uiFont)
                    .lineLimit(1)
                    .foregroundStyle(isActive ? style.text : style.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 12 + 10)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? style.background : .clear)
                .padding(.horizontal, 4)
        )
        .contentShape(.rect)
        .onTapGesture {
            if node.isDirectory {
                if isExpanded { expanded.remove(node.url) } else { expanded.insert(node.url) }
            } else {
                workspace.openNote(at: node.url)
            }
        }
        .contextMenu {
            if node.isDirectory {
                Button("New Note Here", systemImage: "doc.badge.plus") {
                    workspace.createNote(in: node.url)
                }
                Button("New Canvas Here", systemImage: "square.on.circle") {
                    workspace.createCanvas(in: node.url)
                }
            } else {
                Button("Open in New Tab", systemImage: "plus.rectangle.on.rectangle") {
                    workspace.openNote(at: node.url, inNewTab: true)
                }
            }
            Button("Rename…", systemImage: "pencil") {
                renameText = node.basename
                renaming = node.url
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                workspace.delete(node.url)
            }
        }

        if node.isDirectory, isExpanded, let children = node.children {
            ForEach(children) { child in
                FileRow(
                    node: child,
                    depth: depth + 1,
                    expanded: $expanded,
                    renaming: $renaming,
                    renameText: $renameText
                )
            }
        }
    }

    static func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "canvas": return "square.on.circle"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "mp3", "m4a", "wav": return "waveform"
        case "mp4", "mov": return "film"
        default: return "doc"
        }
    }
}

// MARK: - Search

struct SearchPane: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    @State private var hits: [SearchHit] = []

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            TextField(String(localized: "Search notes… (try tag:idea)"), text: $workspace.searchQuery)
                .textFieldStyle(.roundedBorder)
                .font(style.uiFont)
                .padding(8)
                .onSubmit(runSearch)
                .onChange(of: workspace.searchQuery) { _, _ in runSearch() }

            if hits.isEmpty, !workspace.searchQuery.isEmpty {
                ContentUnavailableView.search(text: workspace.searchQuery)
            } else {
                List(hits) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.title)
                            .font(style.uiFont.weight(.medium))
                            .foregroundStyle(style.text)
                        if !hit.line.isEmpty {
                            Text(hit.line.trimmingCharacters(in: .whitespaces))
                                .font(.caption)
                                .lineLimit(2)
                                .foregroundStyle(style.secondaryText)
                        }
                    }
                    .contentShape(.rect)
                    .onTapGesture { workspace.openNote(at: hit.url) }
                }
                .listStyle(.plain)
            }
        }
    }

    private func runSearch() {
        guard let store = workspace.store, workspace.searchQuery.count >= 2 else {
            hits = []
            return
        }
        hits = SearchEngine.fullText(query: workspace.searchQuery, in: workspace.index, store: store)
    }
}

// MARK: - Tags

struct TagListView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    @State private var selectedTag: String?

    var body: some View {
        List {
            Section {
                ForEach(workspace.index.tagCounts.sorted(by: { $0.key < $1.key }), id: \.key) { tag, count in
                    HStack {
                        Text("#" + tag)
                            .font(style.uiFont)
                            .foregroundStyle(selectedTag == tag ? style.accent : style.text)
                        Spacer()
                        Text(count.formatted())
                            .font(.caption)
                            .foregroundStyle(style.faintText)
                    }
                    .contentShape(.rect)
                    .onTapGesture { selectedTag = selectedTag == tag ? nil : tag }
                }
            }

            if let selectedTag {
                Section(String(localized: "Notes tagged #\(selectedTag)")) {
                    ForEach(workspace.index.notes(taggedWith: selectedTag)) { note in
                        Text(note.title)
                            .font(style.uiFont)
                            .contentShape(.rect)
                            .onTapGesture { workspace.openNote(at: note.url) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Unresolved links

struct UnresolvedLinksView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    var body: some View {
        List {
            Section(String(localized: "Unresolved links")) {
                ForEach(workspace.index.unresolved.sorted(by: { $0.value > $1.value }), id: \.key) { target, count in
                    HStack {
                        Text(target).font(style.uiFont)
                        Spacer()
                        Text(count.formatted()).font(.caption).foregroundStyle(style.faintText)
                    }
                    .contentShape(.rect)
                    .onTapGesture { workspace.createNote(named: target) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if workspace.index.unresolved.isEmpty {
                ContentUnavailableView(
                    "No unresolved links",
                    systemImage: "link",
                    description: Text("Every link in this vault points at a note that exists.")
                )
            }
        }
    }
}

// MARK: - Outline

struct OutlinePane: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    var body: some View {
        if let url = workspace.activeTab?.url,
           let note = workspace.index.metadata(for: url),
           !note.headings.isEmpty {
            List(note.headings, id: \.range.location) { heading in
                // A button, not a label: an outline that cannot be jumped from is
                // a list of headings, not a table of contents.
                Button {
                    workspace.reveal(heading.range, in: url)
                } label: {
                    Text(heading.text)
                        .font(style.uiFont)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, CGFloat(heading.level - 1) * 12)
                        .foregroundStyle(heading.level == 1 ? style.text : style.secondaryText)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        } else {
            ContentUnavailableView(
                "No outline",
                systemImage: "list.bullet.indent",
                description: Text("Headings in the open note appear here.")
            )
        }
    }
}
