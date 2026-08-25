import SwiftUI
import InkstoneCore
#if os(macOS)
import AppKit
#endif

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
            case .bookmarks: BookmarksPane()
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
            // A vault added by mistake was previously permanent: `forget` existed
            // on the registry and nothing called it. Its own submenu rather than
            // a row action, so opening a vault stays one tap and removing one
            // takes a deliberate second.
            if workspace.registry.vaults.count > 1 {
                Menu("Remove from Inkstone…", systemImage: "minus.circle") {
                    ForEach(workspace.registry.vaults) { vault in
                        Button(role: .destructive) {
                            workspace.forget(vault)
                        } label: {
                            Label(vault.name, systemImage: "minus.circle")
                        }
                    }
                    Divider()
                    Text("The folder and its files are left exactly where they are.")
                }
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
                        .font(style.uiIcon(1.0))
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
        case .bookmarks: return "bookmark"
        case .tags: return "number"
        case .links: return "link"
        case .outline: return "list.bullet.indent"
        }
    }

    private func label(for section: SidebarSection) -> String {
        switch section {
        case .files: return String(localized: "Files")
        case .search: return String(localized: "Search")
        case .bookmarks: return String(localized: "Bookmarks")
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
        ScrollViewReader { scroller in
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
            .onChange(of: workspace.treeReveal) { _, target in
                guard let target else { return }
                reveal(target.url, using: scroller)
            }
        }
    }

    /// Opens every folder above `url` and scrolls the row into view.
    ///
    /// The expansion has to happen before the scroll, and in a `LazyVStack` the
    /// row does not exist until its parents are open — so the scroll waits for
    /// one turn of the run loop rather than asking for an id that is not there
    /// yet.
    private func reveal(_ url: URL, using scroller: ScrollViewProxy) {
        guard let root = workspace.root else { return }
        var folder = url.deletingLastPathComponent()
        let rootPath = root.path(percentEncoded: false)
        var ancestors: [URL] = []
        // Upwards to the vault root, and no further: a path outside the vault
        // would otherwise walk to `/`.
        while folder.path(percentEncoded: false).hasPrefix(rootPath),
              folder.path(percentEncoded: false) != rootPath {
            ancestors.append(folder)
            let parent = folder.deletingLastPathComponent()
            guard parent != folder else { break }
            folder = parent
        }
        expanded.formUnion(ancestors)

        Task { @MainActor in
            // One hop, so the rows the expansion just created exist to scroll to.
            await Task.yield()
            withAnimation(.easeOut(duration: 0.2)) {
                scroller.scrollTo(url, anchor: .center)
            }
        }
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
    /// Non-nil while the history sheet is up. Carries the file rather than a
    /// Bool so the sheet cannot outlive the row that opened it and show the
    /// wrong one.
    ///
    /// Wrapped rather than conforming `URL` to `Identifiable`: that extension
    /// would apply to every URL in the project, and `id` on a file URL is a
    /// claim about identity that should not be made globally by a sidebar.
    @State private var historyTarget: HistoryTarget?

    private struct HistoryTarget: Identifiable {
        let url: URL
        var id: String { url.path(percentEncoded: false) }
    }

    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    var body: some View {
        let isActive = workspace.activeTab?.url == node.url
        let isExpanded = expanded.contains(node.url)

        HStack(spacing: 5) {
            Image(systemName: node.isDirectory
                  ? (isExpanded ? "chevron.down" : "chevron.right")
                  : (node.isMarkdown ? "doc.text" : Self.icon(for: node.url)))
                // 9 and 11 against 13pt chrome, kept as ratios so they hold
                // at any interface size.
                .font(style.uiIcon(node.isDirectory ? 9.0/13 : 11.0/13, weight: .semibold))
                .frame(width: style.uiFontSize * 10/13)
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
        .id(node.url)
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
                #if os(macOS)
                Button("Open to the Right", systemImage: "rectangle.righthalf.inset.filled") {
                    workspace.openBeside(node.url)
                }
                #endif
            }
            if !node.isDirectory {
                Button(
                    workspace.isBookmarked(node.url) ? "Remove Bookmark" : "Bookmark",
                    systemImage: workspace.isBookmarked(node.url) ? "bookmark.slash" : "bookmark"
                ) {
                    workspace.toggleBookmark(node.url)
                }
                // A submenu of the vault's folders rather than a modal picker:
                // the destinations are known and finite, and a menu is one
                // gesture where a dialog is three.
                Button("Version History…", systemImage: "clock.arrow.circlepath") {
                    historyTarget = HistoryTarget(url: node.url)
                }
                Menu("Move to…", systemImage: "folder") {
                    ForEach(workspace.folders, id: \.self) { folder in
                        Button(folderLabel(folder)) { workspace.move(node.url, to: folder) }
                            .disabled(folder == node.url.deletingLastPathComponent())
                    }
                }
            }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                workspace.duplicate(node.url)
            }
            Button("Rename…", systemImage: "pencil") {
                renameText = node.basename
                renaming = node.url
            }
            #if os(macOS)
            // macOS only. The two path items are for pasting somewhere else —
            // a terminal, a link, a message — and Finder does not exist on iOS.
            Divider()
            Button("Copy Relative Path", systemImage: "doc.on.doc") {
                copyToPasteboard(relativePath)
            }
            Button("Copy Absolute Path", systemImage: "doc.on.doc.fill") {
                copyToPasteboard(node.url.path(percentEncoded: false))
            }
            // The escape hatch for everything this app will never render, and
            // for the times another app is simply the right one — a PSD, a
            // spreadsheet, a video someone wants to scrub properly.
            Button("Open in Default App", systemImage: "arrow.up.forward.app") {
                NSWorkspace.shared.open(node.url)
            }
            Button("Reveal in Finder", systemImage: "folder") {
                // Selects the item in its parent folder rather than opening it,
                // which is what "reveal" means and what a folder needs — opening
                // a folder would show its contents, not the folder.
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            #endif
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                workspace.delete(node.url)
            }
        }

        .sheet(item: $historyTarget) { target in
            VersionHistoryView(url: target.url)
                .environment(workspace)
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

    #if os(macOS)
    /// The path as the vault knows it, for pasting into notes, messages and
    /// commands run from the vault root.
    private var relativePath: String {
        guard let root = workspace.root else { return node.url.lastPathComponent }
        return VaultPath.relative(of: node.url, in: root)
    }

    /// - Note: `clearContents()` is not optional. `NSPasteboard` keeps whatever
    ///   was there until it is told otherwise, and writing a string without
    ///   clearing first leaves the previous owner's richer representation in
    ///   place — so the paste lands as whatever was copied before this.
    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
    #endif

    /// The vault root reads as the vault's own name; everything else as its
    /// path inside it, so two folders called "Drafts" are distinguishable.
    private func folderLabel(_ folder: URL) -> String {
        guard let root = workspace.root else { return folder.lastPathComponent }
        if folder == root { return workspace.vault?.name ?? folder.lastPathComponent }
        return VaultPath.relative(of: folder, in: root)
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

/// The pinned files, in the order they were pinned.
///
/// Missing files are left out rather than removed from the store: a file can be
/// absent because a sync has not finished bringing it back, and forgetting the
/// bookmark then would turn a slow download into a lost pin.
struct BookmarksPane: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    var body: some View {
        let marks = workspace.bookmarkedURLs
        if marks.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "bookmark")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(style.faintText)
                Text("No bookmarks yet.")
                    .font(style.uiFont)
                    .foregroundStyle(style.secondaryText)
                Text("Right-click a file to pin it here.")
                    .font(style.uiFont)
                    .foregroundStyle(style.faintText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(marks, id: \.self) { url in
                        BookmarkRow(url: url)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct BookmarkRow: View {
    let url: URL

    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    var body: some View {
        let isActive = workspace.activeTab?.url == url
        HStack(spacing: 5) {
            Image(systemName: FileRow.icon(for: url))
                .font(style.uiIcon(11.0 / 13, weight: .semibold))
                .frame(width: style.uiFontSize * 10 / 13)
                .foregroundStyle(style.faintText)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(style.uiFont)
                    .lineLimit(1)
                    .foregroundStyle(isActive ? style.text : style.secondaryText)
                // The folder, because two notes can share a name and the point
                // of a pinned list is going straight to the right one.
                if let root = workspace.root {
                    let folder = VaultPath.relative(of: url.deletingLastPathComponent(), in: root)
                    if folder != url.deletingLastPathComponent().lastPathComponent || !folder.isEmpty {
                        Text(folder)
                            .font(style.uiFont)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(style.faintText)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? style.background : .clear)
                .padding(.horizontal, 4)
        )
        .contentShape(.rect)
        .onTapGesture { workspace.openNote(at: url) }
        .contextMenu {
            Button("Remove Bookmark", systemImage: "bookmark.slash") {
                workspace.toggleBookmark(url)
            }
            #if os(macOS)
            Button("Reveal in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            #endif
        }
    }
}

// MARK: - Search

struct SearchPane: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    @State private var hits: [SearchHit] = []
    @State private var isSearching = false

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            TextField(String(localized: "Search notes… (try tag:idea)"), text: $workspace.searchQuery)
                .textFieldStyle(.roundedBorder)
                .font(style.uiFont)
                .padding(8)

            if isSearching, hits.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hits.isEmpty, !workspace.searchQuery.isEmpty {
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
        .task(id: workspace.searchQuery) { await search(for: workspace.searchQuery) }
    }

    /// Runs the search off the main actor, after the typing pauses.
    ///
    /// It used to be a synchronous call straight out of `onChange`, once per
    /// keystroke. `SearchEngine.fullText` reads every note in the vault off
    /// disk, so on a vault of 8,852 notes a query that matched nothing cost
    /// **783 ms of frozen window** — and every prefix of a real query matches
    /// nothing while you are still typing it.
    ///
    /// `.task(id:)` does the cancelling: SwiftUI tears the old task down the
    /// moment the query changes, so the sleep below is a debounce and the search
    /// itself is abandoned mid-flight rather than finishing into a stale view.
    private func search(for query: String) async {
        guard let store = workspace.store, query.count >= 2 else {
            hits = []
            isSearching = false
            return
        }

        // Long enough that a typed word runs one search rather than five, short
        // enough not to feel like a pause.
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }

        isSearching = true
        let snapshot = workspace.index
        let found = await SearchEngine.fullTextConcurrently(query: query, in: snapshot, store: store)

        guard !Task.isCancelled else { return }
        hits = found
        isSearching = false
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
