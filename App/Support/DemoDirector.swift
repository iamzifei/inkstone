#if DEBUG
import Foundation
import CoreGraphics
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
///
/// Debug builds only. It reads one file and calls the same methods the UI does.
@MainActor
enum DemoDirector {
    /// Once per process. `onAppear` fires again whenever the scene is rebuilt —
    /// on iPhone Duo every fold and unfold moves the scene to the other
    /// screen — and a second poller replayed every command from the start.
    private static var started = false

    static func startIfRequested(workspace: Workspace) {
        guard let path = ProcessInfo.processInfo.environment["INKSTONE_DEMO_COMMANDS"], !started else { return }
        started = true
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

    private static func run(_ line: String, workspace: Workspace) {
        guard !line.isEmpty, let root = workspace.root else { return }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
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
        case "graph":
            workspace.open(.graph(focus: workspace.activeTab?.url))
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
#endif
