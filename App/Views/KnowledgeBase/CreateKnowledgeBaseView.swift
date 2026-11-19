import SwiftUI
import UniformTypeIdentifiers
import InkstoneCore

/// The first thing someone new sees: what a knowledge base is, in plain
/// words, then a name and a place, then it is made — skeleton, rules, entry
/// files — and opened, with a short "drop things in" card.
struct CreateKnowledgeBaseView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    enum Place: Hashable { case iCloud, folder, existing }

    @State private var step = 0
    @State private var name = ""
    @State private var place: Place = .iCloud
    @State private var isPicking = false
    @State private var isWorking = false
    @State private var problem: String?

    private var language: KnowledgeBaseLanguage { workspace.knowledgeBaseLanguage }

    var body: some View {
        VStack(spacing: 22) {
            if step == 0 { intro } else { setup }
        }
        .frame(maxWidth: 440)
        .animation(.snappy, value: step)
        .onAppear { if name.isEmpty { name = KnowledgeBaseCreator.defaultName(language) } }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            make(at: url)
        }
        .alert("Couldn't create the knowledge base", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: Step 1 — what it is

    private var intro: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(style.accent)
                Text("Your AI knowledge base")
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 14) {
                point("folder", "It's just a folder", "Everything stays as ordinary files on your device or in iCloud — no account, nothing locked in.")
                point("tray.and.arrow.down", "Drop anything in", "Notes, PDFs, photos, recordings. Inkstone files each one by your rules, names it and keeps a log you can undo.")
                point("sparkles", "Ready for AI", "It writes AGENTS.md, README.md and SOURCE_OF_TRUTH.md, so any AI assistant knows what is where.")
            }
            Button { step = 1 } label: {
                Text("Create my knowledge base").frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func point(_ icon: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(style.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(style.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Step 2 — name and place

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Name it, and choose where it lives").font(.title3.weight(.semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .disabled(place == .existing)
            VStack(alignment: .leading, spacing: 8) {
                option(.iCloud, "icloud", "iCloud Drive", "Recommended: on all your devices.")
                option(.folder, "folder", "A folder you choose", "On this device, or a synced folder (Dropbox, OneDrive …).")
                option(.existing, "folder.badge.plus", "A folder you already have", "Your files stay where they are; Inkstone only adds its rules and entry files.")
            }
            HStack {
                Button("Back") { step = 0 }
                Spacer()
                Button {
                    switch place {
                    case .iCloud: makeInICloud()
                    case .folder, .existing: isPicking = true
                    }
                } label: {
                    if isWorking { ProgressView().controlSize(.small) } else { Text(place == .iCloud ? "Create" : "Choose Folder…") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            }
        }
    }

    private func option(_ value: Place, _ icon: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        Button { place = value } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: place == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(place == value ? style.accent : style.faintText)
                Image(systemName: icon).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(text).font(.caption).foregroundStyle(style.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(place == value ? style.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: Making it

    private func makeInICloud() {
        isWorking = true
        Task {
            defer { isWorking = false }
            guard case .available(let container) = await ICloudContainer.resolve() else {
                problem = localized("iCloud Drive isn't available. Sign in to iCloud, or choose a folder instead.")
                return
            }
            let documents = container.appending(path: "Documents", directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
                let folder = try KnowledgeBaseCreator.create(named: name, in: documents, language: language)
                try open(folder, name: folder.lastPathComponent)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// The picked folder: the parent of a new knowledge base, or (for
    /// `.existing`) the folder itself.
    private func make(at picked: URL) {
        let access = picked.startAccessingSecurityScopedResource()
        defer { if access { picked.stopAccessingSecurityScopedResource() } }
        do {
            if place == .existing {
                try KnowledgeBaseCreator.adopt(picked, language: language)
                try open(picked, name: picked.lastPathComponent)
            } else {
                let folder = try KnowledgeBaseCreator.create(named: name, in: picked, language: language)
                try open(folder, name: folder.lastPathComponent)
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func open(_ folder: URL, name: String) throws {
        let vault = try workspace.registry.register(folder: folder, name: name)
        workspace.open(vault)
        // `open` reports nothing; whether it worked shows in the workspace.
        guard workspace.vault?.id == vault.id else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: folder.path])
        }
        workspace.knowledgeBase.showReadyCard()
    }
}

/// Shown once, right after a knowledge base is made: where things go.
struct KnowledgeBaseReadyCard: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    var body: some View {
        let layout = workspace.knowledgeBase.layout ?? KnowledgeBaseLayout(language: workspace.knowledgeBaseLanguage)
        VStack(alignment: .leading, spacing: 16) {
            Label("Your knowledge base is ready", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(style.accent)
            Text("Drop files anywhere in this window — or into \(layout.inbox) — and they are filed for you. Anything Inkstone isn't sure about waits in \(layout.review) for you to decide.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Your rules are in \(layout.rulesFile): change them in plain words, in Settings › Knowledge Base.")
                .font(.callout).foregroundStyle(style.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Got it") {
                    // State drives the sheet; dismiss() here could close the
                    // next one (a round waiting behind this card).
                    workspace.knowledgeBase.isShowingReadyCard = false
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: 460)
    }
}
