import SwiftUI
import CoreSpotlight
import InkstoneCore

/// Top-level layout: sidebar, editor, inspector.
///
/// One view for both platforms. `NavigationSplitView` already adapts — three
/// columns on a Mac or iPad, a stack on iPhone — so the only platform-specific
/// code here is toolbar placement.
struct RootView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    @State private var columnVisibility: NavigationSplitViewVisibility = .all


    @State private var isDropTargeted = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        DevicePostureReader { posture in rootContent(posture) }
    }

    @ViewBuilder
    private func rootContent(_ posture: DevicePosture) -> some View {
        @Bindable var workspace = workspace

        Group {
            if workspace.vault == nil {
                WelcomeView()
            } else {
                #if os(iOS)
                // A compact width — every iPhone, and an iPad in Slide Over —
                // collapses `NavigationSplitView` to a single column, and the
                // detail column is then only reachable by navigating to it.
                // Selecting a note here changes workspace state rather than
                // following a `NavigationLink`, so nothing pushed and the editor
                // was unreachable: the note highlighted and the view stayed put.
                if case .bent(let crease, let isHorizontal) = posture {
                    creaseSplit(crease: crease, isHorizontal: isHorizontal)
                } else if sizeClass == .compact {
                    NavigationStack {
                        SidebarView()
                            .environment(\.isPhoneRootList, true)
                            .navigationDestination(isPresented: showingDetail) {
                                DetailView()
                                    .toolbar { toolbarContent }
                                    // Compact width presents the inspector as a
                                    // sheet. It was never attached here, so on
                                    // iPhone the toolbar button did nothing and
                                    // backlinks, outline and properties were
                                    // unreachable.
                                    .inspector(isPresented: $workspace.isInspectorPresented) {
                                        InspectorView()
                                            .presentationDetents([.medium, .large])
                                            .presentationDragIndicator(.visible)
                                    }
                            }
                    }
                } else {
                    splitView
                }
                #else
                splitView
                #endif
            }
        }
        .tint(style.accent)
        .background(style.background)
        // Files dragged onto the window go to the knowledge base's inbox
        // (views that take drops themselves — the editor — come first).
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard workspace.knowledgeBase.isKnowledgeBase, !files.isEmpty else { return false }
            workspace.knowledgeBase.receive(files)
            return true
        } isTargeted: { isDropTargeted = $0 && workspace.knowledgeBase.isKnowledgeBase }
        .overlay {
            if isDropTargeted, let layout = workspace.knowledgeBase.layout {
                DropTargetOverlay(inbox: layout.inbox)
            }
        }
        .background {
            Color.clear.fileImporter(
                isPresented: Binding(get: { workspace.knowledgeBase.isPickingFiles },
                                     set: { workspace.knowledgeBase.isPickingFiles = $0 }),
                allowedContentTypes: [.item, .folder], allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { workspace.knowledgeBase.receive(urls) }
            }
        }
        .overlay(alignment: .bottom) {
            if let result = workspace.knowledgeBase.lastResult {
                OrganizeBanner(result: result)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: workspace.knowledgeBase.lastResult?.batch)
        // The knowledge base's sheets, one at a time (two `.sheet`s changing
        // in one transaction can drop the second on iOS): the "ready" card
        // first, then a round waiting for a yes.
        .sheet(item: Binding(
            get: { KnowledgeBaseSheet.current(workspace.knowledgeBase) },
            set: { if $0 == nil { KnowledgeBaseSheet.closeCurrent(workspace.knowledgeBase) } }
        )) { sheet in
            switch sheet {
            case .ready: KnowledgeBaseReadyCard()
            case .plan(let plan): ChangePlanSheet(plan: plan)
            case .drop(let urls): DropChoiceSheet(urls: urls)
            }
        }
        .alert("Knowledge base", isPresented: Binding(
            get: { workspace.knowledgeBase.failure != nil },
            set: { if !$0 { workspace.knowledgeBase.clearFailure() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspace.knowledgeBase.failure ?? "")
        }

        .onAppear { LaunchTiming.mark("first window") }
        .sheet(isPresented: $workspace.isQuickSwitcherPresented) {
            QuickSwitcherView()
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                workspace.openSpotlightResult(id)
            }
        }
        .sheet(isPresented: $workspace.isTemplatePickerPresented) {
            TemplatePickerView()
        }
        #if os(iOS)
        // The exported file is left for the share target to finish reading;
        // the next export sweeps folders over an hour old.
        .sheet(item: $workspace.exportedFile) { file in
            ShareSheet(items: [file.url]).ignoresSafeArea()
        }
        #endif
        .alert("Export failed", isPresented: Binding(
            get: { workspace.exportFailure != nil }, set: { if !$0 { workspace.exportFailure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspace.exportFailure ?? "")
        }
        .sheet(isPresented: $workspace.isCommandPalettePresented, onDismiss: {
            // Run the chosen command once the palette is fully gone: several
            // open a sheet of their own, which cannot present over one that is
            // still closing.
            if let command = workspace.pendingPaletteCommand {
                workspace.pendingPaletteCommand = nil
                command.run(workspace)
            }
        }) {
            CommandPaletteView()
        }
        #if os(macOS)
        .sheet(isPresented: $workspace.isQuickRewritePresented) {
            // Guarded on both: the menu item is disabled without a selection,
            // but a shortcut can still fire between the selection changing and
            // the menu updating.
            if let selection = workspace.editorSelection, !selection.isEmpty,
               let replace = workspace.replaceEditorSelection {
                QuickRewriteView(original: selection, onReplace: replace)
            } else {
                ContentUnavailableView("Select some text first", systemImage: "text.cursor")
                    .frame(width: 380, height: 200)
            }
        }
        #endif
    }

    @ViewBuilder
    private var splitView: some View {
        @Bindable var workspace = workspace
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            DetailView()
                .inspector(isPresented: $workspace.isInspectorPresented) {
                    InspectorView()
                        .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
                }
        }
        .toolbar { toolbarContent }
    }

    #if os(iOS)
    /// iPhone Duo partly folded: one pane either side of the crease, nothing
    /// drawn across it. The note gets the first pane (top, or left page); the
    /// second holds what you look at *while* reading it — backlinks, outline,
    /// properties. With no note open, the note list and a prompt to pick one.
    ///
    /// Laid out from the system's division region rather than from the hinge
    /// angle, as Apple advises; `crease` is in this view's coordinates.
    @ViewBuilder
    private func creaseSplit(crease: CGRect, isHorizontal: Bool) -> some View {
        let hasNote = workspace.activeTab != nil
        let first = NavigationStack {
            Group {
                if hasNote { DetailView().toolbar { toolbarContent } } else { SidebarView() }
            }
        }
        let second = NavigationStack {
            Group {
                if hasNote { InspectorView() } else { EmptyStatePane() }
            }
        }
        if isHorizontal {
            VStack(spacing: 0) {
                first.frame(height: max(0, crease.minY))
                style.secondaryBackground.frame(height: crease.height)
                second.frame(maxHeight: .infinity)
            }
        } else {
            HStack(spacing: 0) {
                first.frame(width: max(0, crease.minX))
                style.secondaryBackground.frame(width: crease.width)
                second.frame(maxWidth: .infinity)
            }
        }
    }

    /// Drives the push, and closes the tab again when the user swipes back — so
    /// returning to the list actually deselects, rather than leaving a note
    /// open that nothing on screen refers to.
    private var showingDetail: Binding<Bool> {
        Binding(
            get: { workspace.activeTab != nil },
            set: { presented in
                if !presented, let tab = workspace.activeTab {
                    workspace.closeTab(tab)
                }
            }
        )
    }
    #endif

    private var syncSymbol: String {
        switch workspace.syncStatus {
        case .running: "arrow.trianglehead.2.clockwise"
        case .failed: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
        default: "arrow.trianglehead.2.clockwise"
        }
    }

    private var syncHelp: String {
        switch workspace.syncStatus {
        case .idle: localized("Sync with GitHub")
        case .running(let message): message
        case .failed(let message): message
        case .finished(let report):
            report.changeCount == 0
                ? localized("Up to date")
                : localized("\(report.changeCount) change(s) synced")
        // Says what actually happened. "Failed" would be wrong — the run was cut
        // short by the system, what it moved is kept, and the next one resumes.
        case .interrupted: localized("Sync ran out of time — carrying on")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Every button here shows an icon and nothing else, so every one of them
        // carries a `.help`. Without it the only way to learn what the toolbar
        // does is to press things and find out. The text names the keyboard
        // shortcut too where there is one, since that is the other thing a
        // hovering user is usually after.
        ToolbarItemGroup(placement: .navigation) {
            Button {
                workspace.goBack()
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .disabled(!workspace.canGoBack)
            .help("Back to the previous note (⌘[)")

            Button {
                workspace.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.forward")
            }
            .disabled(!workspace.canGoForward)
            .help("Forward (⌘])")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                workspace.isQuickSwitcherPresented = true
            } label: {
                Label("Quick Switcher", systemImage: "magnifyingglass")
            }
            .help("Find a note by name (⌘O)")

            Button {
                // Focused on whatever is open, which is nearly always what is
                // wanted: "show me how this note sits in the vault". The pane
                // has a switch to the whole vault.
                workspace.open(.graph(focus: workspace.activeTab?.url))
            } label: {
                Label("Graph View", systemImage: "point.3.filled.connected.trianglepath.dotted")
            }
            .help("Graph view — every note in the vault and the links between them (⇧⌘G)")

            Button {
                workspace.open(.calendar)
            } label: {
                Label("Calendar", systemImage: "calendar")
            }
            .help("Calendar of daily notes (⇧⌘L)")

            Menu {
                Button("New Note", systemImage: "doc.badge.plus") { workspace.createNote() }
                Button("New Canvas", systemImage: "square.on.circle") { workspace.createCanvas() }
                Button("Today's Daily Note", systemImage: "sun.max") { workspace.openDailyNote() }
            } label: {
                Label("New", systemImage: "plus")
            }
            .help("New note (⌘N), canvas (⇧⌘N), or today's daily note (⇧⌘D)")

            // Only present once GitHub sync is switched on: a sync button that
            // can never do anything is worse than no button.
            if workspace.syncBinding.isEnabled {
                Button {
                    Task { await workspace.sync() }
                } label: {
                    Label("Sync with GitHub", systemImage: syncSymbol)
                        .symbolEffect(.rotate, isActive: workspace.isSyncing)
                }
                .disabled(!workspace.canSync)
                .help(syncHelp)
            }

            #if os(iOS)
            // Touch has no ⌘F or menu bar; these are the ways in there.
            if workspace.presentEditorFind != nil {
                Button {
                    workspace.presentEditorFind?(false)
                } label: {
                    Label("Find in Note", systemImage: "doc.text.magnifyingglass")
                }
            }
            // Always there, so the command palette is reachable from the graph
            // or calendar too; the note's own actions only with a note open.
            Menu {
                if workspace.presentEditorFind != nil {
                    Button("Insert Template…", systemImage: "doc.on.doc") {
                        workspace.isTemplatePickerPresented = true
                    }
                    Button("Export as PDF…", systemImage: "doc.richtext") {
                        workspace.exportActiveNote(as: .pdf)
                    }
                    Button("Export as HTML…", systemImage: "chevron.left.forwardslash.chevron.right") {
                        workspace.exportActiveNote(as: .html)
                    }
                    Divider()
                }
                Button("Command Palette…", systemImage: "command") {
                    workspace.isCommandPalettePresented = true
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            #endif

            Button {
                workspace.isInspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(workspace.isInspectorPresented
                  ? localized("Hide the inspector (⌥⌘I)")
                  : localized("Show the inspector — properties, backlinks, local graph (⌥⌘I)"))
        }
    }
}

/// The main content area: one pane, or two side by side.
private struct DetailView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    var body: some View {
        #if os(macOS)
        // A draggable divider rather than a fixed half: the two panes are rarely
        // wanted at the same width — a note beside its reference, an image
        // beside the note that embeds it.
        if workspace.isSplit {
            HSplitView {
                PaneView(pane: .primary)
                PaneView(pane: .secondary)
            }
            .background(style.background)
        } else {
            PaneView(pane: .primary)
        }
        #else
        // No split on a phone: two half-columns of text is worse than one.
        PaneView(pane: .primary)
        #endif
    }
}

/// One half of the content area — its own tabs, its own active tab.
private struct PaneView: View {
    let pane: Workspace.Pane

    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    private var tabs: [TabContent] {
        pane == .primary ? workspace.tabs : workspace.secondaryTabs
    }

    private var active: TabContent? {
        pane == .primary ? workspace.activeTab : workspace.secondaryActiveTab
    }

    var body: some View {
        VStack(spacing: 0) {
            // The right-hand pane always shows its strip, even with one tab:
            // without it there is nothing to close, and no way back to a single
            // pane short of closing the file some other way.
            if tabs.count > 1 || (pane == .secondary && !tabs.isEmpty) {
                TabStrip(pane: pane)
                Divider().overlay(style.divider)
            }

            switch active {
            case .note(let url):
                NoteEditorPane(url: url)
                    .id(url)
            case .canvas(let url):
                CanvasPane(url: url)
                    .id(url)
            case .attachment(let url, let kind):
                AttachmentView(url: url, kind: kind)
                    .id(url)
            case .graph(let focus):
                GraphPane(focus: focus)
                    .id(focus)
            case .calendar:
                CalendarPane()
            case nil:
                EmptyStatePane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.background)
        // Any click in a pane makes it the one new work lands in, so following a
        // link on the right opens beside it rather than jumping back to the left.
        .contentShape(.rect)
        .onTapGesture { workspace.focusedPane = pane }
    }
}

private struct TabStrip: View {
    var pane: Workspace.Pane = .primary

    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    private var tabs: [TabContent] {
        pane == .primary ? workspace.tabs : workspace.secondaryTabs
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(tabs) { tab in
                    let isActive = (pane == .primary ? workspace.activeTab
                                                     : workspace.secondaryActiveTab) == tab
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: tab))
                            .font(.caption2)
                        Text(title(for: tab))
                            .lineLimit(1)
                        Button {
                            workspace.closeTab(tab)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                #if os(iOS)
                                // An 8 pt target is unhittable with a finger.
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                                #endif
                        }
                        .accessibilityLabel(Text("Close Tab"))
                        .buttonStyle(.plain)
                        .opacity(isActive ? 1 : 0.4)
                    }
                    .font(style.uiFont)
                    .foregroundStyle(isActive ? style.text : style.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isActive ? style.secondaryBackground : .clear)
                    )
                    .contentShape(.rect)
                    .onTapGesture {
                        if pane == .primary { workspace.activeTab = tab }
                        else { workspace.secondaryActiveTab = tab }
                        workspace.focusedPane = pane
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.hidden)
    }

    private func title(for tab: TabContent) -> String {
        switch tab {
        case .note(let url), .canvas(let url):
            return url.deletingPathExtension().lastPathComponent
        // The extension stays: two files can differ only by it, and for
        // something being looked at rather than edited it is half the identity.
        case .attachment(let url, _): return url.lastPathComponent
        // Named after the note, because a strip of tabs all saying "Graph" is
        // no help in telling them apart.
        case .graph(let focus):
            return focus.map { $0.deletingPathExtension().lastPathComponent }
                ?? localized("Graph")
        case .calendar: return localized("Calendar")
        }
    }

    private func icon(for tab: TabContent) -> String {
        switch tab {
        case .note: return "doc.text"
        case .canvas: return "square.on.circle"
        case .attachment(_, let kind):
            switch kind {
            case .image: return "photo"
            case .video: return "film"
            case .audio: return "waveform"
            case .pdf: return "doc.richtext"
            case .other: return "doc"
            }
        case .graph: return "point.3.filled.connected.trianglepath.dotted"
        case .calendar: return "calendar"
        }
    }
}

private struct EmptyStatePane: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    var body: some View {
        ContentUnavailableView {
            Label("No note open", systemImage: "doc.text")
        } description: {
            Text("Pick a note from the sidebar, or start a new one.")
        } actions: {
            Button("New Note") { workspace.createNote() }
                .buttonStyle(.borderedProminent)
            Button("Open Quick Switcher") { workspace.isQuickSwitcherPresented = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.background)
    }
}
