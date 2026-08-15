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
    @State private var isInspectorPresented = true

    var body: some View {
        @Bindable var workspace = workspace

        Group {
            if workspace.vault == nil {
                WelcomeView()
            } else {
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
        }
        .tint(style.accent)
        .background(style.background)
        .sheet(isPresented: $workspace.isQuickSwitcherPresented) {
            QuickSwitcherView()
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
        case .graph: return String(localized: "Graph")
        case .calendar: return String(localized: "Calendar")
        }
    }

    private func icon(for tab: TabContent) -> String {
        switch tab {
        case .note: return "doc.text"
        case .canvas: return "square.on.circle"
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
