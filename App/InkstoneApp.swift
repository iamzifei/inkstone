import SwiftUI
import InkstoneCore

@main
struct InkstoneApp: App {
    @State private var workspace = Workspace()

    init() {
        #if DEBUG
        Self.runHighlightBenchmarkIfRequested()
        #endif
    }

    #if DEBUG
    /// Measures the full highlight pass on a file, with no window involved.
    ///
    ///     INKSTONE_BENCH=/path/to/note.md .../Inkstone.app/Contents/MacOS/Inkstone
    ///
    /// Runs from `init` and exits, so it works when the display is asleep or a
    /// full-screen Space is in the way — GUI automation is not a reliable way to
    /// measure this, and the highlighter needs AppKit so it cannot live in the
    /// package's own test suite.
    @MainActor
    private static func runHighlightBenchmarkIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["INKSTONE_BENCH"],
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return }

        let storage = NSTextStorage(string: text)
        var highlighter = MarkdownHighlighter(style: .fallback, mode: .livePreview)
        highlighter.availableWidth = 800

        highlighter.highlight(storage, caretLineRange: nil)  // warm up

        var samples: [Double] = []
        for _ in 0..<5 {
            let started = DispatchTime.now().uptimeNanoseconds
            // A caret range is the realistic case: that is what every keystroke does.
            highlighter.highlight(storage, caretLineRange: NSRange(location: 0, length: 1))
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        samples.sort()

        let summary = String(
            format: "highlight %d chars (%.0f KB): median %.1f ms  (min %.1f, max %.1f)\n",
            storage.length, Double(text.utf8.count) / 1024, samples[2], samples[0], samples[4]
        )
        FileHandle.standardOutput.write(Data(summary.utf8))
        exit(0)
    }
    #endif

    var body: some Scene {
        WindowGroup {
            StyledRoot { RootView() }
                .environment(workspace)
                .preferredColorScheme(preferredColorScheme)
                .environment(\.locale, locale)
                .onAppear(perform: openLastVault)
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 560)
                #endif
        }
        .commands { commands }

        #if os(macOS)
        Settings {
            StyledRoot { SettingsView() }
                .environment(workspace)
                .preferredColorScheme(preferredColorScheme)
                .environment(\.locale, locale)
        }
        #endif
    }

    // MARK: - Derived environment

    private var preferredColorScheme: ColorScheme? {
        switch workspace.settings.data.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var locale: Locale {
        workspace.settings.data.language.localeIdentifier.map(Locale.init(identifier:))
            ?? Locale.autoupdatingCurrent
    }

    /// Reopens whichever vault was used last, so launching lands the user back
    /// where they were rather than on a chooser.
    private func openLastVault() {
        #if DEBUG
        // Test hook: opens a vault at launch without going through the file
        // picker, which is a separate process that can't be scripted — otherwise
        // the entire post-open UI is impossible to test automatically.
        //
        //   echo /path/to/vault > /tmp/inkstone-test-vault
        //
        // A file rather than a defaults key or an environment variable: `defaults`
        // gets redirected into the sandbox container, and the app must be launched
        // with `open` (to get a window at all), which doesn't forward the
        // environment. A file works for every launch method.
        // Under the sandbox neither /tmp nor an arbitrary folder is reachable, so
        // `INKSTONE_SCRATCH_VAULT=1` instead seeds a throwaway vault inside the
        // app's own container — always legal, and enough to exercise the whole
        // post-open UI (sidebar, editor, index) with the shipping entitlements.
        if ProcessInfo.processInfo.environment["INKSTONE_SCRATCH_VAULT"] != nil
            || FileManager.default.fileExists(atPath: Self.scratchFlagPath) {
            if let vault = try? makeScratchVault() {
                workspace.open(vault)
                debugLog("opened scratch vault at \(vault.path)")
            } else {
                debugLog("scratch vault creation failed")
            }
            return
        }

        let hookFile = "/tmp/inkstone-test-vault"
        let hookPath = (try? String(contentsOfFile: hookFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let path = (hookPath?.isEmpty == false ? hookPath : nil)
            ?? ProcessInfo.processInfo.environment["INKSTONE_OPEN_VAULT"] {
            do {
                let vault = try workspace.registry.register(folder: URL(fileURLWithPath: path, isDirectory: true))
                workspace.open(vault)
                debugLog("opened test vault: \(path)")
            } catch {
                debugLog("test vault failed: \(error)")
            }
            return
        }
        #endif

        guard workspace.vault == nil,
              let latest = workspace.registry.vaults.max(by: { $0.lastOpened < $1.lastOpened }) else { return }
        workspace.open(latest)
    }

    #if DEBUG
    /// Marker file inside the container that turns on the scratch vault, for when
    /// the launcher can't pass an environment variable (`open`).
    static var scratchFlagPath: String {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appending(path: "inkstone-scratch-vault").path(percentEncoded: false)
    }

    /// Writes a small vault into the app container and registers it. Exercises the
    /// same code path a real vault does — scan, index, watch, render.
    private func makeScratchVault() throws -> Vault {
        let root = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appending(path: "ScratchVault", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = NoteStore(root: root)
        try store.write(
            """
            ---
            tags: [示例, demo]
            ---

            # Home

            中英文混排 typography test. Link to [[Second Note]] and a #标签.

            - [ ] a task
            """,
            to: root.appending(path: "Home.md")
        )
        try store.write("# Second Note\n\nBack to [[Home]].\n", to: root.appending(path: "Second Note.md"))

        return try workspace.registry.register(folder: root, name: "Scratch")
    }

    /// Debug output that survives `open` (which discards stdout/stderr).
    private func debugLog(_ message: String) {
        let line = "[inkstone] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        let logURL = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appending(path: "inkstone-debug.log")
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }
    #endif

    // MARK: - Menu commands

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { workspace.createNote() }
                .keyboardShortcut("n")
            Button("New Canvas") { workspace.createCanvas() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Today's Daily Note") { workspace.openDailyNote() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Quick Switcher…") { workspace.isQuickSwitcherPresented = true }
                .keyboardShortcut("o")
            Button("Save") { workspace.saveAll() }
                .keyboardShortcut("s")
        }

        // Merged into the system View menu rather than declared as
        // `CommandMenu("View")`, which produced a *second* menu also called
        // "View" sitting next to the built-in one in the menu bar.
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Graph View") { workspace.open(.graph) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Calendar") { workspace.open(.calendar) }
            Divider()
            Button("Live Preview") { workspace.settings.data.editorMode = .livePreview }
                .keyboardShortcut("e", modifiers: [.command])
            Button("Source Mode") { workspace.settings.data.editorMode = .source }
            Button("Reading Mode") { workspace.settings.data.editorMode = .reading }
            Divider()
            Button("Back") { workspace.goBack() }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(!workspace.canGoBack)
            Button("Forward") { workspace.goForward() }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(!workspace.canGoForward)
        }
    }
}
