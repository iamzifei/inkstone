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
    /// Dumps a rendered formula to a PNG so its actual pixels can be inspected.
    ///
    ///     INKSTONE_MATH_DUMP='\sqrt{x^2}' INKSTONE_MATH_OUT=/tmp/f.png ... Inkstone
    /// Checks that the iCloud container is actually reachable at runtime.
    ///
    ///     INKSTONE_ICLOUD_CHECK=1 .../Inkstone.app/Contents/MacOS/Inkstone
    ///
    /// The entitlement being present is not the same as the container working:
    /// that also needs the container to exist in the portal, the profile to
    /// carry it, and the user to be signed in to iCloud Drive.
    @MainActor
    private static func checkICloudIfRequested() {
        guard ProcessInfo.processInfo.environment["INKSTONE_ICLOUD_CHECK"] != nil else { return }

        let identifier = "iCloud.com.orris.inkstone"
        if let url = FileManager.default.url(forUbiquityContainerIdentifier: identifier) {
            let documents = url.appending(path: "Documents")
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            let reachable = FileManager.default.fileExists(atPath: documents.path)
            FileHandle.standardOutput.write(Data("""
            iCloud container: AVAILABLE
              url: \(url.path)
              Documents writable: \(reachable)

            """.utf8))
        } else {
            FileHandle.standardOutput.write(Data("""
            iCloud container: UNAVAILABLE for \(identifier)
              (entitlement present but container not reachable — check the portal
               container exists and that iCloud Drive is signed in)

            """.utf8))
        }
        exit(0)
    }

    @MainActor
    private static func dumpMathIfRequested() {
        guard let latex = ProcessInfo.processInfo.environment["INKSTONE_MATH_DUMP"],
              let out = ProcessInfo.processInfo.environment["INKSTONE_MATH_OUT"]
        else { return }
        guard let image = MathRenderer.shared.image(
            latex: latex, fontSize: 16, isDisplay: false, colour: .black
        ) else {
            FileHandle.standardOutput.write(Data("render failed\n".utf8))
            exit(1)
        }
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: out))
            FileHandle.standardOutput.write(Data("size \(image.size)\n".utf8))
        }
        exit(0)
    }

    @MainActor
    private static func runHighlightBenchmarkIfRequested() {
        checkICloudIfRequested()
        dumpMathIfRequested()
        guard let path = ProcessInfo.processInfo.environment["INKSTONE_BENCH"],
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return }

        let storage = NSTextStorage(string: text)
        var highlighter = MarkdownHighlighter(style: .fallback, mode: .livePreview)
        highlighter.availableWidth = 800

        highlighter.highlight(storage, caretLineRange: nil)  // warm up

        // Optional second figure: what a viewport-sized pass costs, which is what
        // the editor actually does on a large document.
        let window = ProcessInfo.processInfo.environment["INKSTONE_BENCH_WINDOW"].flatMap(Int.init)

        func measure(_ visible: NSRange?) -> [Double] {
            var samples: [Double] = []
            for _ in 0..<5 {
                let started = DispatchTime.now().uptimeNanoseconds
                // A caret range is the realistic case: that is what every keystroke does.
                highlighter.highlight(
                    storage, caretLineRange: NSRange(location: 0, length: 1), visibleRange: visible
                )
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            }
            return samples.sorted()
        }

        // Indent dump: verifies that bullets, tasks and their nested forms all
        // start their text at the same x, which is hard to confirm by eye and
        // impossible when the display is asleep.
        if ProcessInfo.processInfo.environment["INKSTONE_INDENT_DUMP"] != nil {
            let ns = storage.string as NSString
            var report = ""
            var location = 0
            while location < ns.length {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                defer { location = max(line.location + line.length, location + 1) }
                let text = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let style = storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil)
                    as? NSParagraphStyle
                // Kerning matters where a collapsed marker took a separating
                // space with it and the gap had to be put back.
                var kerns: [String] = []
                storage.enumerateAttribute(.kern, in: line) { value, r, _ in
                    if let k = value as? Double, k > 0.5 {
                        kerns.append(String(format: "%@=%.1f", ns.substring(with: r), k))
                    }
                }
                report += String(
                    format: "  first=%5.1f head=%5.1f kern=[%@]  %@\n",
                    style?.firstLineHeadIndent ?? -1, style?.headIndent ?? -1,
                    kerns.joined(separator: " ") as CVarArg,
                    text.prefix(30) as CVarArg
                )
            }
            FileHandle.standardOutput.write(Data(report.utf8))
        }

        // Caret dump: the caret is drawn at the font's natural height while the
        // line is laid out at an explicit multiple of the font size, so the two
        // diverge. Measured through a real layout manager rather than derived.
        if ProcessInfo.processInfo.environment["INKSTONE_CARET_DUMP"] != nil {
            highlighter.highlight(storage, caretLineRange: nil)
            let layoutManager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 5
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
            layoutManager.ensureLayout(for: container)

            let ns = storage.string as NSString
            var report = "\n"
            var location = 0
            while location < ns.length {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                defer { location = max(line.location + line.length, location + 1) }
                let text = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let glyph = layoutManager.glyphIndexForCharacter(at: line.location)
                guard glyph < layoutManager.numberOfGlyphs else { continue }
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                // Measured at the first *visible* character: the start of a
                // heading or task line is a concealed 0.01pt marker, whose
                // metrics say nothing about the line.
                var probe = line.location
                while probe < line.location + line.length,
                      let f = storage.attribute(.font, at: probe, effectiveRange: nil) as? PlatformFont,
                      f.pointSize < 1 { probe += 1 }
                let font = storage.attribute(.font, at: probe, effectiveRange: nil) as? PlatformFont
                let paragraph = storage.attribute(.paragraphStyle, at: probe, effectiveRange: nil)
                    as? NSParagraphStyle
                let natural = (font?.ascender ?? 0) - (font?.descender ?? 0)
                let lineHeight = paragraph?.maximumLineHeight ?? 0
                // Straight from the shared metric, so this reports what the caret
                // and the selection actually use rather than a parallel formula.
                let shared = CaretMetrics.height(in: storage, at: probe) ?? -1
                report += String(
                    format: "  fragment=%5.1f  lineHeight=%5.1f  text=%5.1f  caret&selection=%5.1f   %@\n",
                    fragment.height, lineHeight, natural, shared, text.prefix(20) as CVarArg
                )
            }
            FileHandle.standardOutput.write(Data((report + "\n").utf8))
        }

        // Checkbox dump: whether a task line is collapsed to a drawn checkbox,
        // and whether that depends on the caret. Reported for both caret states
        // because "shows [ ] instead of a checkbox" is exactly what the
        // caret-on-this-line branch is supposed to do.
        if ProcessInfo.processInfo.environment["INKSTONE_CHECKBOX_DUMP"] != nil {
            let ns = storage.string as NSString
            var report = ""
            let taskLine = ns.range(of: "- [ ]")
            for (label, caret) in [("no caret", nil as NSRange?),
                                   ("caret on line 1", NSRange(location: 0, length: 1)),
                                   ("caret ON the task line", taskLine)] {
                highlighter.highlight(storage, caretLineRange: caret)
                report += "\n  \(label):\n"
                var location = 0
                while location < ns.length {
                    let line = ns.lineRange(for: NSRange(location: location, length: 0))
                    defer { location = max(line.location + line.length, location + 1) }
                    let text = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.contains("[") || text.hasPrefix("-") else { continue }
                    var checkbox = "none"
                    var concealed = false
                    storage.enumerateAttributes(in: line) { attributes, _, _ in
                        if let checked = attributes[.inkstoneCheckbox] as? Bool {
                            checkbox = checked ? "checked" : "unchecked"
                        }
                        if let font = attributes[.font] as? PlatformFont, font.pointSize < 1 {
                            concealed = true
                        }
                    }
                    // The two font sizes the checkbox drawing depends on: the
                    // marker's (collapsed) and the text's (what it must align to).
                    var sizes = "—"
                    if let markerRange = storage.range(of: nil, in: line, key: .inkstoneCheckbox) {
                        let markerFont = storage.attribute(.font, at: markerRange.location, effectiveRange: nil) as? PlatformFont
                        let after = min(markerRange.location + markerRange.length, storage.length - 1)
                        let textFont = storage.attribute(.font, at: max(0, after), effectiveRange: nil) as? PlatformFont
                        sizes = String(format: "marker=%.2fpt(xh %.2f) text=%.2fpt(xh %.2f)",
                                       markerFont?.pointSize ?? -1, markerFont?.xHeight ?? -1,
                                       textFont?.pointSize ?? -1, textFont?.xHeight ?? -1)
                    }
                    report += "    checkbox=\(checkbox) markerHidden=\(concealed) \(sizes)  \(text.prefix(20))\n"
                }
            }
            FileHandle.standardOutput.write(Data((report + "\n").utf8))
        }

        let samples = measure(nil)
        var summary = String(
            format: "highlight %d chars (%.0f KB): median %.1f ms  (min %.1f, max %.1f)\n",
            storage.length, Double(text.utf8.count) / 1024, samples[2], samples[0], samples[4]
        )
        if let window {
            let scope = NSRange(location: 0, length: min(window, storage.length))
            let scoped = measure(scope)
            summary += String(format: "  scoped to %d chars: median %.1f ms\n", scope.length, scoped[2])

            // Sanity check that scoping styles what it claims to and nothing else:
            // a heading inside the scope must be larger than body text, and text
            // well beyond it must be untouched by this pass.
            var stylesInScope = 0
            storage.enumerateAttribute(.font, in: scope) { value, _, _ in
                if let font = value as? NSFont, font.pointSize > 20 { stylesInScope += 1 }
            }
            summary += "  headings styled inside scope: \(stylesInScope)\n"
        }
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
        let hookContents = (try? String(contentsOfFile: hookFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // "<vault path>" or "<vault path>|<note file name>".
        let hookParts = hookContents?.split(separator: "|", maxSplits: 1).map(String.init)
        let hookPath = hookParts?.first
        let hookNote = hookParts?.count == 2 ? hookParts?[1] : nil
        if let path = (hookPath?.isEmpty == false ? hookPath : nil)
            ?? ProcessInfo.processInfo.environment["INKSTONE_OPEN_VAULT"] {
            do {
                let vault = try workspace.registry.register(folder: URL(fileURLWithPath: path, isDirectory: true))
                workspace.open(vault)
                debugLog("opened test vault: \(path)")

                // Optionally open a note straight away. Clicking the sidebar is
                // unreliable to automate — the app cannot always be brought to
                // the front, and the display sleeps — so this makes a specific
                // note reachable without touching the UI at all.
                //
                //   echo "<vault>|<note.md>" > /tmp/inkstone-test-vault
                if let noteName = hookNote, !noteName.isEmpty {
                    let note = URL(fileURLWithPath: path, isDirectory: true).appending(path: noteName)
                    if FileManager.default.fileExists(atPath: note.path) {
                        workspace.openNote(at: note)
                        debugLog("opened test note: \(noteName)")
                    } else {
                        debugLog("test note not found: \(noteName)")
                    }
                }
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
            Divider()
            Button(workspace.isSyncing ? "Syncing…" : "Sync with GitHub") {
                Task { await workspace.sync() }
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])
            .disabled(!workspace.canSync)
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

private extension NSTextStorage {
    /// First range in `line` carrying `key`. Debug helper for the dumps above.
    func range(of _: Any?, in line: NSRange, key: NSAttributedString.Key) -> NSRange? {
        var found: NSRange?
        enumerateAttribute(key, in: line) { value, range, stop in
            if value != nil { found = range; stop.pointee = true }
        }
        return found
    }
}
