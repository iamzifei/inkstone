import SwiftUI
import ImageIO
import InkstoneCore

@main
struct InkstoneApp: App {
    /// Normally the real one. `INKSTONE_DEMO_DEFAULTS` swaps in a throwaway
    /// suite instead, so a screenshot run cannot show — or disturb — the
    /// repository, vault list and token state of whoever is actually using this
    /// Mac. Isolation by construction rather than by remembering to blank
    /// fields afterwards.
    @State private var workspace: Workspace = {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["INKSTONE_DEMO_DEFAULTS"],
           let defaults = UserDefaults(suiteName: suite) {
            return Workspace(registry: VaultRegistry(defaults: defaults),
                             settings: AppSettings(defaults: defaults))
        }
        #endif
        return Workspace()
    }()

    /// Shared, so the settings pane and the assistant see the same library.
    @State private var skillLibrary = SkillLibrary()
    /// Semantic recall, shared by the assistant and the settings pane.
    @State private var semantic = SemanticSearchService()

    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow

    /// Held here rather than created in the commands block, because Sparkle's
    /// scheduled-check timer lives as long as this object does. Rebuilding it on
    /// a view update would restart the cycle on every redraw.
    @StateObject private var updater = Updater()
    #endif

    init() {
        LaunchTiming.mark("app init")
        #if os(iOS) && DEBUG
        // On-device check of the background wiring. Prints what the scheduler
        // actually accepted, which a successful build says nothing about.
        if ProcessInfo.processInfo.environment["INKSTONE_BG_CHECK"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await BackgroundSync.diagnose()
            }
        }
        #endif

        #if os(iOS)
        // Must happen before the app finishes launching, and exactly once per
        // identifier — a second registration of the same identifier terminates
        // the app. A view is too late and too often.
        BackgroundSync.register(workspace: workspace)
        LaunchTiming.mark("background tasks registered")
        #endif

        // Debug hooks are macOS-only: they measure through AppKit text metrics
        // and write images with AppKit imaging.
        #if DEBUG && os(macOS)
        Self.runHighlightBenchmarkIfRequested()
        SmokeTest.runIfRequested()
        GuideShots.runIfRequested()
        OnboardingView.dumpIfRequested()
        SyncHealthSection.dumpIfRequested()
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
    /// **This hook needs a build signed with the shipping entitlements.** It is
    /// compiled into debug builds only, and debug builds are routinely signed
    /// with `Inkstone-Dev.entitlements`, which has no iCloud keys — so the hook
    /// and the entitlement were never present in the same binary, and the hook's
    /// verdict was an artefact of that. To run it honestly:
    ///
    ///     xcodebuild ... -configuration Debug -derivedDataPath .build-icloud
    ///     cp /Applications/Inkstone.app/Contents/embedded.provisionprofile \
    ///        .build-icloud/Build/Products/Debug/Inkstone.app/Contents/
    ///     codesign --force --options runtime --sign "Developer ID Application" \
    ///       --entitlements App/Resources/Inkstone.entitlements \
    ///       .build-icloud/Build/Products/Debug/Inkstone.app
    ///
    /// It now reports which of the three causes applies, so a build that cannot
    /// ask the question can no longer be read as an answer about the container.
    @MainActor
    private static func checkICloudIfRequested() {
        guard ProcessInfo.processInfo.environment["INKSTONE_ICLOUD_CHECK"] != nil else { return }

        // A semaphore rather than an async main: this runs from `init`, before
        // there is a run loop to drive a Task to completion.
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: ICloudAvailability = .unreachable
        Task.detached {
            result = await ICloudContainer.resolve(ICloudContainer.identifier)
            semaphore.signal()
        }
        semaphore.wait()

        var report: String
        switch result {
        case .available(let url):
            report = """
            iCloud container: AVAILABLE
              url: \(url.path)
            """
            // INKSTONE_ICLOUD_CHECK=create also makes the vault, through the
            // same call the button uses — so this verifies the shipping path
            // rather than a re-implementation of it that could drift.
            if ProcessInfo.processInfo.environment["INKSTONE_ICLOUD_CHECK"] == "create" {
                do {
                    let vault = try ICloudContainer.createVaultFolder(in: url)
                    report += "\n  vault: \(vault.path)"
                } catch {
                    report += "\n  vault: FAILED — \(error.localizedDescription)"
                }
            }
        case .notEntitled:
            report = """
            iCloud container: NOT ENTITLED
              This binary is not signed with a ubiquity-container entitlement, so
              it cannot reach any container and says nothing about whether one
              exists. Re-sign it as shown above and run the check again.
            """
        case .notSignedIn:
            report = """
            iCloud container: NOT SIGNED IN
              No iCloud identity for ubiquitous files. Sign in to iCloud and turn
              on iCloud Drive.
            """
        case .unreachable:
            report = """
            iCloud container: UNREACHABLE for \(ICloudContainer.identifier)
              Entitled and signed in, and the container still did not resolve —
              this one really is about the container.
            """
        }
        FileHandle.standardOutput.write(Data((report + "\n").utf8))
        exit(0)
    }

    #if os(macOS)
    // Debug hooks below use AppKit-only imaging and text metrics.
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

    /// Runs the editor's highlighter over every Markdown file under a folder
    /// and reports crashes, slow files and any change to the text.
    ///
    ///     INKSTONE_CORPUS=/path/to/copy INKSTONE_CORPUS_OUT=/path/report.tsv Inkstone
    ///
    /// Point it at a *copy* of a vault: it only reads, but a test corpus should
    /// never be someone's real notes. The name of each file is written to
    /// `<out>.current` before it is styled, so if the process dies the file
    /// that killed it is on disk. The text check matters most: the editor's
    /// storage *is* the file, so a highlighter that altered a character would
    /// save that change into the note.
    @MainActor
    private static func runCorpusIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["INKSTONE_CORPUS"], let out = env["INKSTONE_CORPUS_OUT"] else { return }
        let root = URL(fileURLWithPath: folder)
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "md" } ?? [])
            .sorted { $0.path < $1.path }
        let skip = Int(env["INKSTONE_CORPUS_SKIP"] ?? "") ?? 0
        var report = "ms\tchars\tchanged\tpath\n"
        var changed = 0, slowest: [(Double, String)] = []
        let width = Double(env["INKSTONE_CORPUS_WIDTH"] ?? "") ?? 700
        for (i, url) in files.enumerated() where i >= skip {
            try? "\(i)\t\(url.path)\n".write(toFile: out + ".current", atomically: true, encoding: .utf8)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let storage = NSTextStorage(string: text)
            var highlighter = MarkdownHighlighter(style: .fallback, mode: .livePreview)
            highlighter.availableWidth = CGFloat(width)
            let folderURL = url.deletingLastPathComponent()
            highlighter.resolveAttachment = { target in
                let candidate = folderURL.appending(path: target)
                return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
            }
            let started = DispatchTime.now().uptimeNanoseconds
            highlighter.highlight(storage, caretLineRange: nil)
            // A second pass with the caret on a middle line: un-concealing a
            // line is its own code path.
            let ns = storage.string as NSString
            let caret = ns.lineRange(for: NSRange(location: ns.length / 2, length: 0))
            highlighter.highlight(storage, caretLineRange: caret)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            let isChanged = storage.string != text
            if isChanged { changed += 1 }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            report += String(format: "%.1f\t%d\t%d\t%@\n", ms, ns.length, isChanged ? 1 : 0, relative)
            slowest.append((ms, relative))
        }
        try? report.write(toFile: out, atomically: true, encoding: .utf8)
        slowest.sort { $0.0 > $1.0 }
        var summary = "files \(files.count - skip)  text changed: \(changed)\nslowest:\n"
        for (ms, path) in slowest.prefix(15) { summary += String(format: "  %7.1f ms  %@\n", ms, path) }
        FileHandle.standardOutput.write(Data(summary.utf8))
        try? FileManager.default.removeItem(atPath: out + ".current")
        exit(0)
    }

    @MainActor
    private static func runHighlightBenchmarkIfRequested() {
        checkICloudIfRequested()
        dumpMathIfRequested()
        runCorpusIfRequested()
        guard let path = ProcessInfo.processInfo.environment["INKSTONE_BENCH"],
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return }

        let storage = NSTextStorage(string: text)
        var highlighter = MarkdownHighlighter(style: .fallback, mode: .livePreview)
        highlighter.availableWidth = 800
        // Resolve embeds against the benchmarked file's own folder. Without this
        // every `![[picture.png]]` rendered as an unresolved link, which made the
        // hook useless for looking at anything involving an image — including
        // whether a `|300` size hint was being honoured.
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        highlighter.resolveAttachment = { target in
            let candidate = folder.appending(path: target)
            return FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false))
                ? candidate : nil
        }
        // And `![[Note]]`, resolved the same way, so a document containing an
        // embed can be looked at without opening a vault.
        highlighter.resolveNoteEmbed = { link in
            guard !link.target.isEmpty else { return nil }
            let candidate = folder.appending(path: link.target + ".md")
            guard let embedded = try? String(
                contentsOf: candidate, encoding: .utf8
            ) else { return nil }
            let range = NoteSlice.range(in: embedded, fragment: link.fragment)
            guard range.length > 0 else { return nil }
            let slice = (embedded as NSString).substring(with: range)
            return slice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : slice
        }

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

        // Button dump: renders the copy button in each of its states into PNGs.
        //
        // Offscreen on purpose. Verifying a hover state by driving the real
        // pointer means moving the user's cursor and clicking wherever their
        // focus happens to be, which is both unreliable — the events land in
        // whatever window is frontmost — and rude. This draws the same code path
        // into an image instead.
        if let outputDirectory = ProcessInfo.processInfo.environment["INKSTONE_BUTTON_DUMP"] {
            highlighter.highlight(storage, caretLineRange: nil)
            let width = ProcessInfo.processInfo.environment["INKSTONE_BUTTON_DUMP_WIDTH"]
                .flatMap(Double.init) ?? 520
            let containerHeight = ProcessInfo.processInfo.environment["INKSTONE_BUTTON_DUMP_HEIGHT"]
                .flatMap(Double.init) ?? 900
            highlighter.availableWidth = CGFloat(width)
            highlighter.highlight(storage, caretLineRange: nil)
            let container = NSTextContainer(size: CGSize(width: width, height: containerHeight))
            container.lineFragmentPadding = 5
            let layoutManager = NSLayoutManager()
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
            layoutManager.ensureLayout(for: container)

            // The first block that carries a copy button.
            var target: NSRange?
            storage.enumerateAttribute(
                .inkstoneBlockFill, in: NSRange(location: 0, length: storage.length)
            ) { value, range, stop in
                guard value != nil else { return }
                target = range
                stop.pointee = true
            }

            for (name, hovered, copied) in [
                ("normal", nil as NSRange?, nil as NSRange?),
                ("hover", target, nil as NSRange?),
                ("copied", nil as NSRange?, target),
            ] {
                let size = CGSize(
                    width: width + 20,
                    height: ProcessInfo.processInfo.environment["INKSTONE_BUTTON_DUMP_HEIGHT"]
                        .flatMap(Double.init) ?? 140
                )
                let image = NSImage(size: size)
                // Flipped, because `NSTextView` is: an unflipped dump draws the
                // tick upside down and would have sent me chasing a bug in the
                // app that only existed in this harness.
                image.lockFocusFlipped(true)
                Style.fallback.palette.background.platformColor.setFill()
                CGRect(origin: .zero, size: size).fill()
                EditorRenderer(
                    storage: storage, layoutManager: layoutManager, container: container,
                    origin: CGPoint(x: 10, y: 10), style: .fallback,
                    hoveredCopyBlock: hovered, copiedCopyBlock: copied
                ).draw(in: CGRect(origin: .zero, size: size))
                let glyphs = layoutManager.glyphRange(for: container)
                // Backgrounds first, and separately: `drawGlyphs` paints glyphs
                // only, so `.backgroundColor` — which is what `==highlight==`
                // uses — was missing from every dump. That read as a rendering
                // regression in the app, which it was not.
                layoutManager.drawBackground(forGlyphRange: glyphs, at: CGPoint(x: 10, y: 10))
                layoutManager.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: 10, y: 10))
                image.unlockFocus()

                let url = URL(fileURLWithPath: outputDirectory)
                    .appending(path: "button-\(name).png")
                if let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: url)
                    FileHandle.standardOutput.write(Data("wrote \(url.path)\n".utf8))
                }
            }
        }

        // Table dump: the line fragment against the glyphs inside it. The row
        // bands and separators are drawn from the fragments, and the text is
        // positioned by TextKit inside them — if those two disagree the bands
        // look offset from their own text.
        if ProcessInfo.processInfo.environment["INKSTONE_TABLE_DUMP"] != nil {
            highlighter.highlight(storage, caretLineRange: nil)
            let layoutManager = NSLayoutManager()
            let container = NSTextContainer(
                size: CGSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
            )
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
                guard storage.attribute(.inkstoneTableBlock, at: line.location, effectiveRange: nil) != nil
                else { continue }
                let glyph = layoutManager.glyphIndexForCharacter(at: line.location)
                guard glyph < layoutManager.numberOfGlyphs else { continue }
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                let text = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
                report += String(
                    format: "  fragment=%7.2f..%7.2f (h%6.2f)  used=%7.2f..%7.2f (h%6.2f)  %@\n",
                    fragment.minY, fragment.maxY, fragment.height,
                    used.minY, used.maxY, used.height,
                    text.prefix(24) as CVarArg
                )
            }
            FileHandle.standardOutput.write(Data((report + "\n").utf8))
        }

        // Conceal dump: which marker-only lines are actually collapsed.
        if ProcessInfo.processInfo.environment["INKSTONE_CONCEAL_DUMP"] != nil {
            highlighter.highlight(storage, caretLineRange: nil)
            let ns = storage.string as NSString
            var report = "\n"
            var location = 0
            while location < ns.length {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                defer { location = max(line.location + line.length, location + 1) }
                let text = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.hasPrefix("```") || text == "---" || text.hasPrefix("|") else { continue }
                var hidden = true
                var height = -1.0
                // Only the visible characters: a trailing newline keeps its own
                // font and would make every collapsed line look uncollapsed.
                let visible = NSRange(location: line.location,
                                      length: max(0, line.length - (line.length > 0 ? 1 : 0)))
                storage.enumerateAttributes(in: visible) { attributes, _, _ in
                    if let f = attributes[.font] as? PlatformFont, f.pointSize >= 1 { hidden = false }
                    if let p = attributes[.paragraphStyle] as? NSParagraphStyle {
                        height = p.maximumLineHeight
                    }
                }
                report += String(format: "  collapsed=%-5@ lineHeight=%5.1f  %@\n",
                                 String(hidden) as NSString, height, text.prefix(24) as CVarArg)
            }
            FileHandle.standardOutput.write(Data((report + "\n").utf8))
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
                // Where the glyphs actually sit inside the fragment. Centring the
                // highlight on the fragment assumes the text is centred in it;
                // that assumption is what this measures.
                let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                let baseline = fragment.minY + layoutManager.location(forGlyphAt: glyph).y
                let ascender = font?.ascender ?? 0
                let textTop = baseline - ascender
                // Where a heading rule would land, against where its glyphs end.
                if storage.attribute(.inkstoneHeadingRule, at: probe, effectiveRange: nil) != nil {
                    let gr = layoutManager.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
                    let box = layoutManager.boundingRect(forGlyphRange: gr, in: container)
                    FileHandle.standardOutput.write(Data(String(
                        format: "  [heading] box=%.1f..%.1f  glyphBottom=%.1f  ruleAt=%.1f  gap=%.1f\n",
                        box.minY, box.maxY, baseline - (font?.descender ?? 0),
                        box.maxY - 1, box.maxY - 1 - (baseline - (font?.descender ?? 0))
                    ).utf8))
                }
                let m = CaretMetrics.metrics(in: storage, at: probe)
                let top = baseline - (m?.aboveBaseline ?? 0)
                report += String(
                    format: "  textTop=%6.1f..%6.1f (h%5.1f)   caret&sel=%6.1f..%6.1f (h%5.1f)   %@\n",
                    textTop, baseline - (font?.descender ?? 0), (font?.ascender ?? 0) - (font?.descender ?? 0),
                    top, top + (m?.height ?? 0), m?.height ?? -1,
                    text.prefix(18) as CVarArg
                )
                _ = used
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
    #endif

    var body: some Scene {
        let _ = LaunchTiming.mark("scene body")
        WindowGroup {
            StyledRoot { RootView() }
                .environment(workspace)
                .environment(skillLibrary)
                .environment(semantic)
                .preferredColorScheme(preferredColorScheme)
                .environment(\.locale, locale)
                #if os(iOS)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        // Two different things, both needed. Queue the next
                        // unattended run, and keep this process alive long
                        // enough to finish a sync that is already going.
                        BackgroundSync.schedule(workspace: workspace)
                        Task { await BackgroundSync.finishInFlightWork(workspace: workspace) }
                    case .active:
                        // Coming back to the foreground: the in-app timer takes
                        // over, so pending background requests are just wake-ups
                        // that would find nothing to do.
                        BackgroundSync.cancelAll()
                        workspace.restartAutoSync()
                        workspace.deliverSharedItems()
                    default:
                        break
                    }
                }
                #endif
                .onAppear {
                    LaunchTiming.mark("root onAppear")
                    #if os(macOS)
                    // Once per guide version; see OnboardingLauncher.
                    if OnboardingLauncher.consumeFirstShow() {
                        openWindow(id: OnboardingView.windowID)
                    }
                    #endif
                    openLastVault()
                    #if DEBUG
                    DemoDirector.startIfRequested(workspace: workspace)
                    #endif
                    seedDemoSyncBinding()
                    // A token saved before it could travel; move it onto iCloud
                    // Keychain so the other device does not ask for it again.
                    SyncCredentials.migrateToICloudKeychain()
                    workspace.startSharingSyncConfiguration()
                }
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 560)
                #endif
        }
        .commands {
            commands
            #if os(macOS)
            CheckForUpdatesCommand(updater: updater)
            WelcomeGuideCommand(title: localized("Show Welcome Guide"))
            #endif
        }

        #if os(macOS)
        // Opened by `openWindow`, never automatically at launch by SwiftUI.
        Window(localized("Welcome to Inkstone"), id: OnboardingView.windowID) {
            StyledRoot { OnboardingView() }
                .environment(workspace)
                .preferredColorScheme(preferredColorScheme)
                .environment(\.locale, locale)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            StyledRoot { SettingsView() }
                .environment(workspace)
                .environment(skillLibrary)
                .environment(semantic)
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
    /// Fills the Sync pane with a plausible, invented setup for screenshots.
    ///
    ///     INKSTONE_DEMO_SYNC=you/notes@main
    ///
    /// Paired with `INKSTONE_DEMO_DEFAULTS`, which is where it is written — this
    /// never touches the real settings.
    private func seedDemoSyncBinding() {
        #if DEBUG
        guard let spec = ProcessInfo.processInfo.environment["INKSTONE_DEMO_SYNC"] else { return }
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        workspace.syncBinding = VaultSyncBinding(
            repository: parts.first ?? "",
            branch: parts.count == 2 ? parts[1] : "main",
            isEnabled: true
        )
        print("[demo] seeded sync binding: \(spec) on \(workspace.vault?.name ?? "no vault")")
        #endif
    }

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
        // A knowledge base made the way the first-run guide makes one (fresh
        // each launch, inside the container), for testing creation and
        // organizing end to end without the folder panel — which runs out of
        // process and cannot be driven from a script.
        // Screenshots: the app's own appearance setting, whatever the
        // system's (INKSTONE_APPEARANCE=light|dark).
        if let mode = ProcessInfo.processInfo.environment["INKSTONE_APPEARANCE"].flatMap(AppearanceMode.init(rawValue:)) {
            workspace.settings.data.appearance = mode
        }
        if ProcessInfo.processInfo.environment["INKSTONE_SCRATCH_KB"] != nil {
            let parent = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appending(path: "ScratchKnowledgeBase", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: parent)
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let folder = try KnowledgeBaseCreator.create(
                    named: KnowledgeBaseCreator.defaultName(workspace.knowledgeBaseLanguage),
                    in: parent, language: workspace.knowledgeBaseLanguage)
                if ProcessInfo.processInfo.environment["INKSTONE_SCRATCH_KB"] == "seed" {
                    try Self.seedScratchInbox(folder, layout: KnowledgeBaseLayout(language: workspace.knowledgeBaseLanguage))
                }
                let vault = try workspace.registry.register(folder: folder, name: folder.lastPathComponent)
                workspace.open(vault)
                workspace.knowledgeBase.showReadyCard()
                debugLog("opened scratch knowledge base at \(folder.path)")
            } catch {
                debugLog("scratch knowledge base failed: \(error)")
            }
            return
        }
        if ProcessInfo.processInfo.environment["INKSTONE_SCRATCH_VAULT"] != nil
            || FileManager.default.fileExists(atPath: Self.scratchFlagPath) {
            if let vault = try? makeScratchVault() {
                workspace.open(vault)
                debugLog("opened scratch vault at \(vault.path)")
                // On iOS the note list is a navigation stack, so nothing but the
                // sidebar is on screen until something is tapped — and the
                // simulator cannot be tapped from a script. Opening a note by
                // name is the only way to see the editor at all.
                if let name = ProcessInfo.processInfo.environment["INKSTONE_OPEN_NOTE"] {
                    let url = vault.url.appending(path: name)
                    if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                        workspace.openNote(at: url)
                        debugLog("opened note \(name)")
                    } else {
                        debugLog("note not found: \(name)")
                    }
                }
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
            ?? ProcessInfo.processInfo.environment["INKSTONE_OPEN_VAULT"].map(DemoDirector.resolve) {
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

        workspace.openMostRecentVaultIfNeeded()
    }

    #if DEBUG
    /// Marker file inside the container that turns on the scratch vault, for when
    /// the launcher can't pass an environment variable (`open`).
    static var scratchFlagPath: String {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appending(path: "inkstone-scratch-vault").path(percentEncoded: false)
    }

    /// A few things dropped in the scratch knowledge base's inbox: a note
    /// about a project that exists, a picture and its copy, a private file,
    /// a loose thought — one of each path the organizer takes.
    private static func seedScratchInbox(_ root: URL, layout: KnowledgeBaseLayout) throws {
        let fm = FileManager.default
        func put(_ path: String, _ text: String) throws {
            let url = root.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let L = layout
        // Already filed: what a knowledge base looks like after a few weeks.
        let filed: [(String, String)]
        // Just dropped in: one of each path the organizer takes.
        let dropped: [(String, String)]
        let project: String
        switch L.language {
        case .simplifiedChinese:
            project = "装修"
            filed = [("\(L.projects)/装修/20261102-水电改造方案.md", "# 水电改造方案\n\n厨房新增两路插座。\n"),
                     ("\(L.projects)/新书稿/20261020-第三章提纲.md", "# 第三章提纲\n"),
                     ("\(L.areas)/健康/20261015-体检复查.md", "# 体检复查\n"),
                     ("\(L.areas)/财务/20261101-十月账单.md", "# 十月账单\n"),
                     ("\(L.resources)/园艺/20261008-玫瑰冬季修剪.md", "# 玫瑰冬季修剪\n"),
                     ("\(L.resources)/读书笔记/20260930-思考快与慢.md", "# 思考，快与慢\n"),
                     ("\(L.outputs)/20261110-年度复盘草稿.md", "# 年度复盘草稿\n")]
            dropped = [("装修报价单.md", "# 装修报价\n\n客厅吊顶 12,000，厨房橱柜 18,000。\n"),
                       ("护照扫描.txt", "护照号码与签发日期（示例）。\n"),
                       ("随手记.md", "今天想到：周末去看看花市。\n")]
        case .traditionalChinese:
            project = "裝修"
            filed = [("\(L.projects)/裝修/20261102-水電改造方案.md", "# 水電改造方案\n"),
                     ("\(L.projects)/新書稿/20261020-第三章大綱.md", "# 第三章大綱\n"),
                     ("\(L.areas)/健康/20261015-健檢複查.md", "# 健檢複查\n"),
                     ("\(L.areas)/財務/20261101-十月帳單.md", "# 十月帳單\n"),
                     ("\(L.resources)/園藝/20261008-玫瑰冬季修剪.md", "# 玫瑰冬季修剪\n"),
                     ("\(L.resources)/讀書筆記/20260930-快思慢想.md", "# 快思慢想\n"),
                     ("\(L.outputs)/20261110-年度回顧草稿.md", "# 年度回顧草稿\n")]
            dropped = [("裝修報價單.md", "# 裝修報價\n\n客廳天花板 12,000，廚房櫥櫃 18,000。\n"),
                       ("護照掃描.txt", "護照號碼與簽發日期（範例）。\n"),
                       ("隨手記.md", "今天想到：週末去看看花市。\n")]
        case .english:
            project = "Renovation"
            filed = [("\(L.projects)/Renovation/20261102-Wiring plan.md", "# Wiring plan\n"),
                     ("\(L.projects)/Book draft/20261020-Chapter 3 outline.md", "# Chapter 3 outline\n"),
                     ("\(L.areas)/Health/20261015-Check-up results.md", "# Check-up results\n"),
                     ("\(L.areas)/Money/20261101-October bills.md", "# October bills\n"),
                     ("\(L.resources)/Gardening/20261008-Winter rose pruning.md", "# Winter rose pruning\n"),
                     ("\(L.resources)/Reading/20260930-Thinking, Fast and Slow.md", "# Thinking, Fast and Slow\n"),
                     ("\(L.outputs)/20261110-Year in review draft.md", "# Year in review draft\n")]
            dropped = [("Renovation quote.md", "# Renovation quote\n\nLiving-room ceiling 12,000; kitchen cabinets 18,000.\n"),
                       ("passport scan.txt", "Passport number and issue date (sample).\n"),
                       ("random thought.md", "Thought today: visit the flower market this weekend.\n")]
        }
        _ = project
        for (path, text) in filed { try put(path, text) }
        for (name, text) in dropped { try put("\(L.inbox)/\(name)", text) }
        let ctx = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.85, green: 0.3, blue: 0.25, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        ctx.setFillColor(red: 1, green: 0.9, blue: 0.6, alpha: 1); ctx.fillEllipse(in: CGRect(x: 30, y: 15, width: 50, height: 50))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        let copy = L.language == .english ? "IMG_0001 copy.png" : "IMG_0001 副本.png"
        try (data as Data).write(to: root.appending(path: "\(L.inbox)/IMG_0001.png"))
        try (data as Data).write(to: root.appending(path: "\(L.inbox)/\(copy)"))
        _ = try? EntryFiles.refresh(in: root)
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

            # Home 中文标题

            中英文混排 typography test. Link to [[Second Note]] and a #标签.

            - [ ] a task
            - [x] a finished task
            - a plain bullet
              - a nested bullet

            > A quote, with a second line
            > that wraps.

            | Column | Value |
            |--------|-------|
            | one    | 1     |
            | 中文   | 2     |

            Inline maths $E = mc^2$ and a fence:

            ```
            有人问我，现在创业，是应该先做自媒体还是先做产品。

            这个问题，光是这个月，我就被问了十几次。

            但他们有一个共同点。
            ```

            ```mermaid
            graph LR
              A[Note] --> B[Link]
              B --> C[Graph]
            ```

            ---

            [^1]: A footnote definition.
            """,
            to: root.appending(path: "Home.md")
        )
        try store.write("""
            # Diagram

            ```mermaid
            graph LR
              A[Note] --> B[Link]
              B --> C[Graph]
            ```

            Back to [[Home]].
            """, to: root.appending(path: "Second Note.md"))

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
            Button(localized("New Note")) { workspace.createNote() }
                .keyboardShortcut("n")
            Button(localized("New Canvas")) { workspace.createCanvas() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button(localized("Today's Daily Note")) { workspace.openDailyNote() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button(localized("Quick Switcher…")) { workspace.isQuickSwitcherPresented = true }
                .keyboardShortcut("o")
            Button(localized("Command Palette…")) { workspace.isCommandPalettePresented = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            // The on-device model's home. Disabled without a selection, since
            // there is nothing for it to work on — and it works on selections
            // only, because 4,000 tokens does not stretch further.
            Button(localized("Rewrite Selection…")) { workspace.isQuickRewritePresented = true }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(workspace.editorSelection?.isEmpty != false)
            Button(localized("Save")) { workspace.saveAll() }
                .keyboardShortcut("s")
            Divider()
            Button(localized("Export as PDF…")) { workspace.exportActiveNote(as: .pdf) }
                .keyboardShortcut("e", modifiers: [.command, .option, .shift])
                .disabled(workspace.presentEditorFind == nil)
            Button(localized("Export as HTML…")) { workspace.exportActiveNote(as: .html) }
                .disabled(workspace.presentEditorFind == nil)
            Button(localized("Export as Image…")) { workspace.exportActiveNote(as: .png) }
                .disabled(workspace.presentEditorFind == nil)
            Divider()
            Button(workspace.isSyncing ? localized("Syncing…") : localized("Sync with GitHub")) {
                Task { await workspace.sync() }
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])
            .disabled(!workspace.canSync)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button(localized("Find…")) { workspace.presentEditorFind?(false) }
                .keyboardShortcut("f")
                .disabled(workspace.presentEditorFind == nil)
            Button(localized("Find and Replace…")) { workspace.presentEditorFind?(true) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(workspace.presentEditorFind == nil)
            Button(localized("Insert Template…")) { workspace.isTemplatePickerPresented = true }
                .disabled(workspace.presentEditorFind == nil)
            #if os(macOS)
            // ⌘G only: ⇧⌘G (the usual Find Previous) is already the graph,
            // and the find bar has its own previous / next buttons.
            Button(localized("Find Next")) {
                let sender = NSMenuItem()
                sender.tag = NSTextFinder.Action.nextMatch.rawValue
                NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
            }
            .keyboardShortcut("g")
            .disabled(workspace.presentEditorFind == nil)
            #endif
        }

        // Merged into the system View menu rather than declared as
        // `CommandMenu("View")`, which produced a *second* menu also called
        // "View" sitting next to the built-in one in the menu bar.
        CommandGroup(after: .toolbar) {
            Divider()
            Button(localized("Graph View")) { workspace.open(.graph(focus: workspace.activeTab?.url)) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button(localized("Whole Vault Graph")) { workspace.open(.graph(focus: nil)) }
                .keyboardShortcut("g", modifiers: [.command, .option])
            Button(localized("Reveal in Sidebar")) {
                if let url = workspace.activeTab?.url { workspace.revealInTree(url) }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(workspace.activeTab?.url == nil)
            Button(localized("Rebuild Index")) { workspace.rebuildIndex() }
                .disabled(workspace.root == nil || workspace.isIndexing)
            Button(localized("Calendar")) { workspace.open(.calendar) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button(localized("Search Vault")) {
                // The sidebar's search pane: full text and `tag:` queries,
                // unlike the quick switcher (⌘O), which matches names.
                workspace.sidebarSection = .search
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Button(workspace.isInspectorPresented ? localized("Hide Inspector") : localized("Show Inspector")) {
                workspace.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button(localized("Live Preview")) { workspace.settings.data.editorMode = .livePreview }
                .keyboardShortcut("e", modifiers: [.command])
            Button(localized("Source Mode")) { workspace.settings.data.editorMode = .source }
                .keyboardShortcut("e", modifiers: [.command, .option])
            Button(localized("Reading Mode")) { workspace.settings.data.editorMode = .reading }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button(localized("Back")) { workspace.goBack() }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(!workspace.canGoBack)
            Button(localized("Forward")) { workspace.goForward() }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(!workspace.canGoForward)
        }
    }
}

#if os(macOS)
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
#endif
