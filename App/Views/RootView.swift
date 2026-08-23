import SwiftUI
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

    // The inspector starts open on a Mac and closed everywhere else. On an iPad
    // the sidebar and the inspector are both overlays at these widths, so
    // opening both by default left the editor as a strip between two floating
    // panels — three columns' worth of chrome on a screen that fits two.
    #if os(macOS)
    @State private var isInspectorPresented = true
    #else
    @State private var isInspectorPresented = false
    #endif

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
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
                if sizeClass == .compact {
                    NavigationStack {
                        SidebarView()
                            .navigationDestination(isPresented: showingDetail) {
                                DetailView()
                                    .toolbar { toolbarContent }
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
        .sheet(isPresented: $workspace.isQuickSwitcherPresented) {
            QuickSwitcherView()
        }
    }

    @ViewBuilder
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            DetailView()
                .inspector(isPresented: $isInspectorPresented) {
                    InspectorView()
                        .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
                }
        }
        .toolbar { toolbarContent }
    }

    #if os(iOS)
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
        case .idle: String(localized: "Sync with GitHub")
        case .running(let message): message
        case .failed(let message): message
        case .finished(let report):
            report.changeCount == 0
                ? String(localized: "Up to date")
                : String(localized: "\(report.changeCount) change(s) synced")
        // Says what actually happened. "Failed" would be wrong — the run was cut
        // short by the system, what it moved is kept, and the next one resumes.
        case .interrupted: String(localized: "Sync paused — it will continue")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                workspace.goBack()
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .disabled(!workspace.canGoBack)

            Button {
                workspace.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.forward")
            }
            .disabled(!workspace.canGoForward)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                workspace.isQuickSwitcherPresented = true
            } label: {
                Label("Quick Switcher", systemImage: "magnifyingglass")
            }

            Button {
                workspace.open(.graph)
            } label: {
                Label("Graph View", systemImage: "point.3.filled.connected.trianglepath.dotted")
            }

            Button {
                workspace.open(.calendar)
            } label: {
                Label("Calendar", systemImage: "calendar")
            }

            Menu {
                Button("New Note", systemImage: "doc.badge.plus") { workspace.createNote() }
                Button("New Canvas", systemImage: "square.on.circle") { workspace.createCanvas() }
                Button("Today's Daily Note", systemImage: "sun.max") { workspace.openDailyNote() }
            } label: {
                Label("New", systemImage: "plus")
            }

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

            Button {
                isInspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
        }
    }
}

/// The main content area: tab strip plus whatever the active tab shows.
private struct DetailView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    var body: some View {
        VStack(spacing: 0) {
            if workspace.tabs.count > 1 {
                TabStrip()
                Divider().overlay(style.divider)
            }

            switch workspace.activeTab {
            case .note(let url):
                NoteEditorPane(url: url)
                    .id(url)
            case .canvas(let url):
                CanvasPane(url: url)
                    .id(url)
            case .attachment(let url, let kind):
                AttachmentView(url: url, kind: kind)
                    .id(url)
            case .graph:
                GraphPane()
            case .calendar:
                CalendarPane()
            case nil:
                EmptyStatePane()
            }
        }
        .background(style.background)
    }
}

private struct TabStrip: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(workspace.tabs) { tab in
                    let isActive = workspace.activeTab == tab
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
                        }
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
                    .onTapGesture { workspace.activeTab = tab }
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
        case .graph: return String(localized: "Graph")
        case .calendar: return String(localized: "Calendar")
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
