import InkstoneCore
import SwiftUI

/// Earlier states of one note, and a way back to any of them.
///
/// Local snapshots rather than git: a vault may or may not be a working copy,
/// and the shipping app is sandboxed — a spawned `git` does not inherit the
/// grant that lets the app read a folder the user picked, so that route works
/// in development and fails when installed.
///
/// Which makes the scope worth stating on screen rather than only in a commit:
/// this recovers your edits on this device. It is not a shared history, and it
/// is not a backup.
struct VersionHistoryView: View {
    let url: URL

    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    @Environment(\.dismiss) private var dismiss

    @State private var versions: [FileHistory.Version] = []
    @State private var selected: FileHistory.Version?
    @State private var preview: String = ""
    @State private var didRestore = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(style.divider)
            if versions.isEmpty {
                empty
            } else {
                HStack(spacing: 0) {
                    list
                    Divider().overlay(style.divider)
                    body(of: selected)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(style.background)
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(style.uiFont.weight(.medium))
                    .foregroundStyle(style.text)
                Text("Saved states kept on this device")
                    .font(style.uiFont)
                    .foregroundStyle(style.faintText)
            }
            Spacer()
            Button("Done") { dismiss() }
        }
        .padding(12)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(style.faintText)
            Text("No earlier versions yet.")
                .font(style.uiFont)
                .foregroundStyle(style.secondaryText)
            // Said plainly, because an empty list otherwise reads as a broken
            // feature rather than as a note that has only been saved once.
            Text("A version is kept the first time this note is saved after an edit, and at most once every few minutes after that.")
                .font(style.uiFont)
                .foregroundStyle(style.faintText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(versions) { version in
                    let isSelected = selected?.id == version.id
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.date.formatted(date: .abbreviated, time: .shortened))
                            .font(style.uiFont)
                            .foregroundStyle(isSelected ? style.text : style.secondaryText)
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(version.size), countStyle: .file))
                            .font(style.uiFont)
                            .foregroundStyle(style.faintText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSelected ? style.secondaryBackground : .clear)
                    .contentShape(.rect)
                    .onTapGesture { select(version) }
                }
            }
        }
        .frame(width: 200)
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func body(of version: FileHistory.Version?) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(preview)
                    .font(style.bodyFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            Divider().overlay(style.divider)
            HStack {
                if didRestore {
                    Label("Restored", systemImage: "checkmark.circle")
                        .font(style.uiFont)
                        .foregroundStyle(style.secondaryText)
                }
                Spacer()
                Button("Restore This Version") {
                    guard let version else { return }
                    didRestore = workspace.restore(version, of: url)
                    reload()
                }
                .disabled(version == nil)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
    }

    private func reload() {
        versions = workspace.versions(of: url)
        if selected == nil || !versions.contains(where: { $0.id == selected?.id }) {
            select(versions.first)
        }
    }

    private func select(_ version: FileHistory.Version?) {
        selected = version
        didRestore = false
        guard let version, let data = workspace.fileHistory?.contents(of: version) else {
            preview = ""
            return
        }
        preview = String(data: data, encoding: .utf8) ?? ""
    }
}
