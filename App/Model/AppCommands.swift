import Foundation
import InkstoneCore
#if os(macOS)
import AppKit
#endif

/// One command the command palette can run: the same actions as the menus,
/// with the menu's title and shortcut, so a command found in the palette is
/// recognisable in the menu bar and the other way round.
struct AppCommand: Identifiable {
    let id: String
    /// Localization key — identical to the menu item's title.
    let title: String.LocalizationValue
    let shortcut: String?
    let systemImage: String
    var isAvailable: @MainActor (Workspace) -> Bool = { _ in true }
    let run: @MainActor (Workspace) -> Void

    var localizedTitle: String { localized(title) }
}

extension AppCommand {
    /// Every menu command, in menu order. When a menu command is added, add it
    /// here too; the Mac smoke test checks each title here is in the menu bar.
    @MainActor static let all: [AppCommand] = {
        let noteOpen: @MainActor (Workspace) -> Bool = { $0.presentEditorFind != nil }
        var list: [AppCommand] = [
            // File
            AppCommand(id: "new-note", title: "New Note", shortcut: "⌘N", systemImage: "square.and.pencil") { $0.createNote() },
            AppCommand(id: "new-canvas", title: "New Canvas", shortcut: "⇧⌘N", systemImage: "rectangle.on.rectangle") { $0.createCanvas() },
            AppCommand(id: "daily-note", title: "Today's Daily Note", shortcut: "⇧⌘D", systemImage: "calendar.badge.clock") { $0.openDailyNote() },
            AppCommand(id: "quick-switcher", title: "Quick Switcher…", shortcut: "⌘O", systemImage: "doc.text.magnifyingglass") { $0.isQuickSwitcherPresented = true },
            AppCommand(id: "save", title: "Save", shortcut: "⌘S", systemImage: "square.and.arrow.down") { $0.saveAll() },
            AppCommand(id: "export-pdf", title: "Export as PDF…", shortcut: "⌥⇧⌘E", systemImage: "doc.richtext",
                       isAvailable: noteOpen) { $0.exportActiveNote(as: .pdf) },
            AppCommand(id: "export-html", title: "Export as HTML…", shortcut: nil, systemImage: "chevron.left.forwardslash.chevron.right",
                       isAvailable: noteOpen) { $0.exportActiveNote(as: .html) },
            AppCommand(id: "sync", title: "Sync with GitHub", shortcut: "⇧⌘Y", systemImage: "arrow.triangle.2.circlepath",
                       isAvailable: { $0.canSync }) { w in Task { await w.sync() } },
            // Edit
            AppCommand(id: "find", title: "Find…", shortcut: "⌘F", systemImage: "magnifyingglass",
                       isAvailable: noteOpen) { $0.presentEditorFind?(false) },
            AppCommand(id: "find-replace", title: "Find and Replace…", shortcut: "⌥⌘F", systemImage: "arrow.left.arrow.right",
                       isAvailable: noteOpen) { $0.presentEditorFind?(true) },
            AppCommand(id: "insert-template", title: "Insert Template…", shortcut: nil, systemImage: "doc.on.doc",
                       isAvailable: noteOpen) { $0.isTemplatePickerPresented = true },
            // View
            AppCommand(id: "graph", title: "Graph View", shortcut: "⇧⌘G", systemImage: "point.3.connected.trianglepath.dotted") { $0.open(.graph(focus: $0.activeTab?.url)) },
            AppCommand(id: "vault-graph", title: "Whole Vault Graph", shortcut: "⌥⌘G", systemImage: "circle.hexagongrid") { $0.open(.graph(focus: nil)) },
            AppCommand(id: "reveal", title: "Reveal in Sidebar", shortcut: "⌥⌘R", systemImage: "sidebar.left",
                       isAvailable: { $0.activeTab?.url != nil }) { w in if let url = w.activeTab?.url { w.revealInTree(url) } },
            AppCommand(id: "rebuild-index", title: "Rebuild Index", shortcut: nil, systemImage: "arrow.clockwise",
                       isAvailable: { $0.root != nil && !$0.isIndexing }) { $0.rebuildIndex() },
            AppCommand(id: "calendar", title: "Calendar", shortcut: "⇧⌘L", systemImage: "calendar") { $0.open(.calendar) },
            AppCommand(id: "search", title: "Search Vault", shortcut: "⇧⌘F", systemImage: "text.magnifyingglass") { $0.sidebarSection = .search },
            AppCommand(id: "inspector", title: "Show/Hide Inspector", shortcut: "⌥⌘I", systemImage: "sidebar.right") { $0.isInspectorPresented.toggle() },
            AppCommand(id: "live-preview", title: "Live Preview", shortcut: "⌘E", systemImage: "eye") { $0.settings.data.editorMode = .livePreview },
            AppCommand(id: "source-mode", title: "Source Mode", shortcut: "⌥⌘E", systemImage: "chevron.left.forwardslash.chevron.right") { $0.settings.data.editorMode = .source },
            AppCommand(id: "reading-mode", title: "Reading Mode", shortcut: "⇧⌘E", systemImage: "book") { $0.settings.data.editorMode = .reading },
            AppCommand(id: "back", title: "Back", shortcut: "⌘[", systemImage: "chevron.left",
                       isAvailable: { $0.canGoBack }) { $0.goBack() },
            AppCommand(id: "forward", title: "Forward", shortcut: "⌘]", systemImage: "chevron.right",
                       isAvailable: { $0.canGoForward }) { $0.goForward() },
        ]
        #if os(macOS)
        list.insert(AppCommand(id: "find-next", title: "Find Next", shortcut: "⌘G", systemImage: "arrow.down",
                               isAvailable: noteOpen) { _ in
            let sender = NSMenuItem()
            sender.tag = NSTextFinder.Action.nextMatch.rawValue
            NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
        }, at: list.firstIndex { $0.id == "insert-template" }! + 1)
        // The rewrite sheet is Mac-only (the on-device model's home there).
        list.insert(AppCommand(id: "rewrite", title: "Rewrite Selection…", shortcut: "⌥⌘K", systemImage: "wand.and.stars",
                               isAvailable: { $0.editorSelection?.isEmpty == false }) { $0.isQuickRewritePresented = true },
                    at: list.firstIndex { $0.id == "save" }!)
        #endif
        return list
    }()
}
