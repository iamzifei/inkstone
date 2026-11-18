import SwiftUI
import InkstoneCore

/// What sync has done and is about to do, in one place.
///
/// The status line under the GitHub settings shows only this session's last
/// run: gone after a relaunch, one failure message, the first three
/// conflicts. This section answers the questions that remain — when did it
/// last work, what is waiting to be resolved, and what will the next run do —
/// without anyone having to run it to find out.
struct SyncHealthSection: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    var body: some View {
        Section {
            LabeledContent("Last successful sync") {
                if let date = workspace.lastSuccessfulSync {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text("Never")
                }
            }

            if case .finished(let report) = workspace.syncStatus, !report.failures.isEmpty {
                DisclosureGroup("\(report.failures.count) file(s) failed in the last run") {
                    ForEach(report.failures, id: \.path) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.path).font(.callout)
                            Text(failure.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            let copies = workspace.conflictCopies
            if !copies.isEmpty {
                DisclosureGroup("\(copies.count) conflict copy(ies) to resolve") {
                    ForEach(copies, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            workspace.openFile(at: url)
                        }
                        #if os(macOS)
                        .buttonStyle(.link)
                        #endif
                    }
                    Text("Each is the GitHub version of a note that was also edited here. Keep the one you want and delete the other.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(workspace.isPreviewingSync ? "Checking…" : "Preview Next Sync") {
                    Task { await workspace.previewSync() }
                }
                .disabled(workspace.isPreviewingSync || workspace.isSyncing)
                Spacer()
            }
            if let error = workspace.syncPreviewError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(style.palette.unresolvedLink.color)
            } else if let preview = workspace.syncPreview {
                PreviewSummary(preview: preview)
            }
        } header: {
            Text("Sync health")
        } footer: {
            Text("Preview only looks: nothing is uploaded, downloaded or deleted until you sync.")
        }
    }
}

private struct PreviewSummary: View {
    let preview: SyncPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if preview.needsFirstSyncDirection {
                Label("First sync: \(preview.conflicts.count) file(s) differ on the two sides. Sync will ask which side to keep.",
                      systemImage: "questionmark.circle")
            }
            if preview.wouldStopForLargeDeletion {
                Label("Sync would stop and ask before deleting this many files.",
                      systemImage: "exclamationmark.triangle")
            }
            if preview.isEmpty {
                Label("Nothing to sync — already up to date.", systemImage: "checkmark.circle")
            }
            row("Upload", preview.uploads, "arrow.up")
            row("Download", preview.downloads, "arrow.down")
            row("Delete on GitHub", preview.deletesRemote, "trash")
            row("Delete here", preview.deletesLocal, "trash")
            if !preview.needsFirstSyncDirection {
                row("Conflict (both kept)", preview.conflicts, "arrow.triangle.branch")
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func row(_ title: LocalizedStringKey, _ paths: [String], _ symbol: String) -> some View {
        if !paths.isEmpty {
            DisclosureGroup {
                ForEach(paths.prefix(50), id: \.self) { Text($0).font(.caption) }
                if paths.count > 50 { Text("…and \(paths.count - 50) more").font(.caption).foregroundStyle(.secondary) }
            } label: {
                Label { Text(title) + Text(" · \(paths.count)") } icon: { Image(systemName: symbol) }
            }
        }
    }
}

#if DEBUG && os(macOS)
import AppKit

extension SyncHealthSection {
    /// Renders this section into a PNG, for checking its layout without a
    /// GitHub account: a throwaway vault with a conflict copy, and a preview
    /// filled in by hand (the preview logic itself is tested in
    /// SyncPreviewTests against an in-memory GitHub).
    ///
    ///     INKSTONE_SYNC_HEALTH_DUMP=/path/out.png .../Inkstone
    @MainActor
    static func dumpIfRequested() {
        guard let out = ProcessInfo.processInfo.environment["INKSTONE_SYNC_HEALTH_DUMP"] else { return }
        Task { @MainActor in
            let root = FileManager.default.temporaryDirectory.appending(path: "inkstone-health-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? "# Home\n".write(to: root.appending(path: "Home.md"), atomically: true, encoding: .utf8)
            try? "# Home (GitHub)\n".write(to: root.appending(path: "Home (conflict 2026-11-18 192101).md"), atomically: true, encoding: .utf8)
            let suite = "com.orris.inkstone.healthdump"
            let defaults = UserDefaults(suiteName: suite)!
            let workspace = Workspace(registry: VaultRegistry(defaults: defaults), settings: AppSettings(defaults: defaults))
            if let vault = try? workspace.registry.register(folder: root, name: "Demo") { workspace.open(vault) }
            workspace.refreshTree()
            var preview = SyncPreview()
            preview.uploads = ["Reading notes.md", "Journal/2026-11-18.md"]
            preview.downloads = ["Ideas.md"]
            preview.deletesRemote = ["Old draft.md"]
            workspace.syncPreview = preview
            let view = StyledRoot { Form { SyncHealthSection() }.formStyle(.grouped) }
                .environment(workspace)
                .frame(width: 560, height: 520)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -40000, y: -40000))
            window.orderFrontRegardless()
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
            try? await Task.sleep(for: .seconds(1.5))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                do {
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    FileHandle.standardError.write(Data("[health] wrote \(out)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("[health] write failed \(error)\n".utf8))
                }
            } else {
                FileHandle.standardError.write(Data("[health] no bitmap rep\n".utf8))
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            exit(0)
        }
    }
}
#endif
