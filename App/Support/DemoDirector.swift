#if DEBUG
import Foundation
#if os(macOS)
import AppKit
#endif
import CoreGraphics
import CoreSpotlight
import os
import InkstoneCore

/// Drives the app from a command file, for recording demo footage on a
/// simulator that cannot be tapped from a script.
///
///     SIMCTL_CHILD_INKSTONE_DEMO_COMMANDS=/path/commands.txt
///
/// The file is polled; each new line is one command, run once:
///
///     open Home.md              open a note (vault-relative path)
///     follow Typography Notes   follow a wikilink from the open note
///     heading The Measure       scroll the open note to a heading
///     inspector on|off          show / hide the inspector
///     switcher on|off           show / hide the quick switcher
///     switcher <query>          open the quick switcher with a query typed
///     graph                     open the graph (of the open note, or the vault)
///     templates                 open Insert Template
///     insert-template <name>    insert a template from the template folder
///     back                      go back
///     close                     close the open note (back to the list on iPhone)
///     type <text>               append text to the open note (autosaves)
///     stall-mark <label>        start a main-thread stall segment
///     stall-report              append the segment's numbers to INKSTONE_STALL_OUT
///
/// Device QA (a real iPhone, run with INKSTONE_DEMO_DEFAULTS so the vault list
/// and settings are a throwaway suite; results go to INKSTONE_DEMO_RESULT):
///     sync-bind <owner/repo> <branch>   bind the open vault and switch sync on
///     sync-now [local|remote|both]      run one sync; one result line
///     write <path>|<text>               write a file in the open vault
///     rm <path>                         delete a file in the open vault
///     refresh                           rewrite the entry files' automatic blocks
///     ls                                list the open vault's files (result)
///     real-sync-off <vault-uuid>        switch sync off for one vault in the
///                                       person's REAL settings (nothing else
///                                       is changed: not files, not GitHub)
///     forget-vault                      remove the open vault from the list
///
/// Relative paths in INKSTONE_DEMO_COMMANDS, INKSTONE_DEMO_RESULT and
/// INKSTONE_OPEN_VAULT are taken from the app's Documents folder, which is all
/// `devicectl device copy` can reach on a device.
///
/// Debug builds only. It reads one file and calls the same methods the UI does.
@MainActor
enum DemoDirector {
    /// Once per process. `onAppear` fires again whenever the scene is rebuilt —
    /// on iPhone Duo every fold and unfold moves the scene to the other
    /// screen — and a second poller replayed every command from the start.
    private static var started = false

    static func startIfRequested(workspace: Workspace) {
        guard let raw = ProcessInfo.processInfo.environment["INKSTONE_DEMO_COMMANDS"], !started else { return }
        let path = resolve(raw)
        started = true
        MainStallMonitor.shared.startIfRequested()
        Task { @MainActor in
            var done = 0
            var ticks = 0
            let log = Logger(subsystem: "com.orris.inkstone", category: "Demo")
            while true {
                try? await Task.sleep(for: .milliseconds(200))
                ticks += 1
                if ticks % 25 == 0 { log.info("demo tick \(ticks)") }
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                // Only complete lines (ending in a newline) are commands.
                let complete = text.hasSuffix("\n") ? lines.count - 1 : lines.count - 1
                while done < complete {
                    log.info("demo run \(lines[done], privacy: .public)")
                    run(lines[done].trimmingCharacters(in: .whitespaces), workspace: workspace)
                    done += 1
                }
            }
        }
    }

    /// An absolute path as is; a relative one inside Documents.
    static func resolve(_ path: String) -> String {
        guard !path.hasPrefix("/") else { return path }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appending(path: path).path(percentEncoded: false)
    }

    /// Appends one line to INKSTONE_DEMO_RESULT, for a script on the Mac to
    /// copy off the device and read.
    private static func result(_ line: String) {
        guard let raw = ProcessInfo.processInfo.environment["INKSTONE_DEMO_RESULT"] else { return }
        let url = URL(fileURLWithPath: resolve(raw))
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static func run(_ line: String, workspace: Workspace) {
        // Knowledge-base states for store screenshots.
        switch line {
        case "welcome":
            // Back to the first-run guide, with the scratch vault forgotten
            // so the screenshot shows what a new person sees.
            // Only the scratch knowledge base is forgotten, never a real vault.
            if let vault = workspace.vault, vault.url.path(percentEncoded: false).contains("ScratchKnowledgeBase") {
                workspace.forget(vault)
            } else {
                workspace.closeCurrentVault()
            }
            return
        case _ where line.hasPrefix("window "):
            // window <width> <height> — the main window's size in points.
            #if os(macOS)
            let n = line.split(separator: " ").dropFirst().compactMap { Double($0) }
            if n.count == 2, let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.frame.width > 500 }) {
                var f = w.frame
                f.origin.y += f.height - n[1]; f.size = CGSize(width: n[0], height: n[1])
                w.setFrame(f, display: true)
            }
            #endif
            return
        case "settings":
            // SwiftUI's own openSettings, through RootView (DEBUG only): the
            // old showSettingsWindow: action does nothing on macOS 26 when
            // the app isn't in front.
            NotificationCenter.default.post(name: .inkstoneDemoOpenSettings, object: nil)
            return
        case "kb-card-off":
            workspace.knowledgeBase.isShowingReadyCard = false
            return
        case "kb-confirm":
            if let plan = workspace.knowledgeBase.pendingPlan { Task { await workspace.knowledgeBase.confirm(plan) } }
            return
        // Main-thread stall measurement (MainStallMonitor, INKSTONE_STALL_OUT).
        case _ where line.hasPrefix("stall-mark "):
            MainStallMonitor.shared.mark(String(line.dropFirst("stall-mark ".count)))
            return
        case "stall-report":
            MainStallMonitor.shared.report()
            return
        case "kb-drop":
            // The copy-or-move question, as for three files dropped from the desktop.
            let desktop = URL(fileURLWithPath: NSTemporaryDirectory())
            workspace.knowledgeBase.pendingDrop = ["Q3 report.pdf", "whiteboard.jpg", "meeting.m4a"].map { desktop.appending(path: $0) }
            return
        default: break
        }
        // Commands that need no open vault.
        if line.hasPrefix("real-sync-off ") {
            // The person's own settings, not the throwaway suite this launch
            // runs on: one vault's sync switch, and nothing else.
            let id = String(line.dropFirst("real-sync-off ".count)).trimmingCharacters(in: .whitespaces)
            let real = AppSettings()
            if var binding = real.data.vaultSync[id] {
                binding.isEnabled = false
                real.data.vaultSync[id] = binding
                result("real-sync-off \(id) ok repository=\(binding.repository) enabled=\(real.data.vaultSync[id]?.isEnabled ?? true)")
            } else {
                result("real-sync-off \(id) no-such-vault")
            }
            return
        }
        guard !line.isEmpty, let root = workspace.root else { return }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "sync-bind":
            let words = arg.split(separator: " ").map(String.init)
            guard words.count == 2 else { result("sync-bind bad-args"); return }
            workspace.syncBinding = VaultSyncBinding(repository: words[0], branch: words[1], isEnabled: true)
            result("sync-bind \(words[0]) \(words[1]) ok")
        case "sync-now":
            let direction: FirstSyncDirection? = switch arg {
            case "local": .preferLocal
            case "remote": .preferRemote
            case "both": .keepBoth
            default: nil
            }
            Task { @MainActor in
                await workspace.sync(firstSyncDirection: direction)
                switch workspace.syncStatus {
                case .finished(let r):
                    result("sync ok up=\(r.uploaded.count) down=\(r.downloaded.count) delR=\(r.deletedRemotely.count) delL=\(r.deletedLocally.count) conflicted=\(r.conflicted.sorted()) failures=\(r.failures.map(\.path))")
                case .failed(let message): result("sync failed \(message)")
                default: result("sync other \(workspace.syncStatus)")
                }
            }
        case "write":
            let pieces = arg.split(separator: "|", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { result("write bad-args"); return }
            let url = root.appending(path: pieces[0])
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let ok = (try? Data(pieces[1].replacingOccurrences(of: "\\n", with: "\n").utf8).write(to: url)) != nil
            result("write \(pieces[0]) \(ok ? "ok" : "failed")")
        case "refresh":
            let changed = (try? EntryFiles.refresh(in: root)) ?? []
            result("refresh \(changed.sorted())")
        case "rm":
            let ok = (try? FileManager.default.removeItem(at: root.appending(path: arg))) != nil
            result("rm \(arg) \(ok ? "ok" : "failed")")
        case "ls":
            let base = root.standardizedFileURL.path(percentEncoded: false)
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            var names: [String] = []
            while let url = walker?.nextObject() as? URL {
                if url.lastPathComponent == ".inkstone" { walker?.skipDescendants(); continue }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                    names.append(String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count)))
                }
            }
            result("ls \(names.count)")
            names.sorted().forEach { result("  \($0)") }
        case "forget-vault":
            if let vault = workspace.vault { workspace.forget(vault); result("forget-vault ok") }
        case "open":
            workspace.openNote(at: root.appending(path: arg))
        case "follow":
            if let source = workspace.activeTab?.url {
                workspace.follow(link: WikiLink(target: arg), from: source, createIfMissing: false)
            }
        case "heading":
            if let url = workspace.activeTab?.url,
               let heading = workspace.index.notes[url]?.headings.first(where: { $0.text == arg }) {
                workspace.reveal(heading.range, in: url)
            }
        case "inspector":
            workspace.isInspectorPresented = arg == "on"
        case "switcher":
            // `switcher on|off`, or `switcher <query>` to open it with a query.
            if arg != "on", arg != "off" { workspace.quickSwitcherSeed = arg }
            workspace.isQuickSwitcherPresented = arg != "off"
        case "templates":
            workspace.isTemplatePickerPresented = true
        case "insert-template":
            if let url = workspace.templateFiles.first(where: { $0.deletingPathExtension().lastPathComponent == arg }) {
                workspace.insertTemplate(url)
            }
        case "export":
            // export pdf|html — writes the open note's export and logs where,
            // how big, and (PDF) how many pages.
            guard let note = workspace.activeTab?.url else { break }
            let format: NoteExporter.Format = arg == "html" ? .html : .pdf
            let log = Logger(subsystem: "com.orris.inkstone", category: "Demo")
            Task { @MainActor in
                do {
                    let file = try await NoteExporter.export(note, as: format, in: workspace)
                    let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
                    var pages = -1
                    if format == .pdf, let doc = CGPDFDocument(file as CFURL) { pages = doc.numberOfPages }
                    log.info("demo export \(file.path, privacy: .public) bytes \(size) pages \(pages)")
                } catch {
                    log.error("demo export failed \(error.localizedDescription, privacy: .public)")
                }
            }
        case "mode":
            // mode live|source|reading — the editor mode, as the toolbar sets it.
            switch arg {
            case "reading": workspace.settings.data.editorMode = .reading
            case "source": workspace.settings.data.editorMode = .source
            default: workspace.settings.data.editorMode = .livePreview
            }
        case "palette":
            workspace.isCommandPalettePresented = arg != "off"
        case "palette-pick":
            // As if the command were chosen in the open palette.
            workspace.pendingPaletteCommand = AppCommand.all.first { $0.id == arg }
            workspace.isCommandPalettePresented = false
        case "spotlight-query":
            // Asks the system index (not our own) for the app's items matching arg.
            spotlightQuery(arg)
        case "spotlight-open":
            if let url = workspace.root?.appending(path: arg) { workspace.openSpotlightResult(SpotlightIndexer.identifier(for: url)) }
        case "intent-daily", "intent-new":
            // Runs the real Shortcuts action, through IntentHost.
            let log = Logger(subsystem: "com.orris.inkstone", category: "Demo")
            Task { @MainActor in
                do {
                    if parts[0] == "intent-daily" {
                        let intent = AppendToDailyNoteIntent(); intent.text = arg
                        _ = try await intent.perform()
                    } else {
                        let intent = NewNoteIntent(); intent.text = arg
                        _ = try await intent.perform()
                    }
                    log.info("demo intent ok \(parts[0], privacy: .public)")
                } catch {
                    log.error("demo intent failed \(error.localizedDescription, privacy: .public)")
                }
            }
        case "graph":
            workspace.open(.graph(focus: workspace.activeTab?.url))
        case "type":
            // Appends text to the open note as typing would, autosave included.
            if let url = workspace.activeTab?.url, let document = workspace.document(for: url) {
                document.text += arg
            }
        case "caret":
            if let location = Int(arg) { workspace.setEditorCaret?(NSRange(location: location, length: 0)) }
        case "report":
            let position = workspace.activeTab?.url.flatMap { workspace.document(for: $0) }?.editorPosition
            Logger(subsystem: "com.orris.inkstone", category: "Demo")
                .info("demo report editor caret \(workspace.editorCaret?().location ?? -1) saved \(position?.selection.location ?? -1)")
        case "back":
            workspace.goBack()
        case "close":
            if let tab = workspace.activeTab { workspace.closeTab(tab) }
        default:
            break
        }
    }
}
/// CoreSpotlight calls these handlers on its own queue: kept out of the main
/// actor, or Swift's isolation check traps.
private nonisolated func spotlightQuery(_ text: String) {
    final class Found: @unchecked Sendable { var titles: [String] = []; let lock = NSLock() }
    let found = Found()
    let log = Logger(subsystem: "com.orris.inkstone", category: "Demo")
    let context = CSSearchQueryContext()
    context.fetchAttributes = ["title"]
    let query = CSSearchQuery(queryString: "textContent == \"*\(text)*\"cd || title == \"*\(text)*\"cd", queryContext: context)
    query.foundItemsHandler = { @Sendable items in
        found.lock.lock(); found.titles += items.compactMap { $0.attributeSet.title }; found.lock.unlock()
    }
    query.completionHandler = { @Sendable error in
        found.lock.lock(); let titles = found.titles.sorted(); found.lock.unlock()
        log.info("demo spotlight \(text, privacy: .public): \(titles.joined(separator: " | "), privacy: .public) \(error?.localizedDescription ?? "", privacy: .public)")
    }
    query.start()
}

/// DemoDirector's `settings` command; observed by RootView in DEBUG builds only.
/// Inside the DEBUG block: outside it, a Release build has no Foundation import
/// here and failed to compile (caught packaging 0.5.1 — CI builds Debug only).
extension Notification.Name {
    static let inkstoneDemoOpenSettings = Notification.Name("InkstoneDemoOpenSettings")
}
#endif

