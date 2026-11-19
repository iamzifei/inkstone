import SwiftUI
import InkstoneCore

/// Settings › Knowledge Base: how organizing behaves, which AI decides where
/// a file goes, what dropping a file does — and the organizing rules
/// themselves, editable as plain text (they are the prompt Inkstone and any
/// AI agent follow).
struct KnowledgeBaseSettingsPane: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var settings = workspace.settings
        let kb = workspace.knowledgeBase

        Form {
            Section {
                Toggle("Organize the inbox automatically", isOn: $settings.data.knowledgeBase.autoOrganize)
                Button("Organize Inbox Now") { Task { await kb.organize() } }
                    .disabled(!kb.isKnowledgeBase)
            } header: {
                Text("Organizing")
            } footer: {
                Text("Small rounds are done at once and can be undone. More than 20 files, or duplicates, wait for your yes. Nothing is ever deleted.")
            }

            Section {
                Toggle("Use the on-device model", isOn: $settings.data.knowledgeBase.useOnDeviceModel)
                if let message = AppleOnDeviceProvider.availabilityMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Use my assistant's model", isOn: $settings.data.knowledgeBase.useAssistantModel)
                Toggle("Read text in pictures", isOn: $settings.data.knowledgeBase.recognizeTextInImages)
            } header: {
                Text("AI")
            } footer: {
                Text("The on-device model runs on this device; nothing leaves it. Your assistant's model (your own key) is sent the name and the start of a file it can't place by the rules — never a file that looks private, and never the names of your private folder.")
            }

            Section("Adding files") {
                Picker("When files are dropped in", selection: $settings.data.knowledgeBase.dropAction) {
                    Text("Ask each time").tag(KnowledgeBaseSettings.DropAction.ask)
                    Text("Copy Files").tag(KnowledgeBaseSettings.DropAction.copy)
                    Text("Move Files").tag(KnowledgeBaseSettings.DropAction.move)
                }
            }

            Section {
                Toggle("Keep AGENTS.md, README.md and SOURCE_OF_TRUTH.md up to date", isOn: $settings.data.knowledgeBase.maintainEntryFiles)
            } footer: {
                Text("Only the part between Inkstone's markers is rewritten; what you write around it stays.")
            }

            Section {
                if let root = kb.root, let layout = kb.layout {
                    RulesEditor(root: root, layout: layout)
                } else {
                    Text("Open a knowledge base to edit its rules.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Organizing rules")
            } footer: {
                Text("Write your own rules under the first heading, one per line, like \"Invoices → 20-Areas/Finance\". Below it is the default policy; change it in plain words — the on-device model and any AI agent read it.")
            }
        }
        .formStyle(.grouped)
    }
}

/// The rules file as text: saved to the knowledge base on Save; "Restore
/// default policy" puts the policy back and keeps your own rules.
private struct RulesEditor: View {
    let root: URL
    let layout: KnowledgeBaseLayout
    @State private var text = ""
    @State private var saved = ""
    @State private var readable = true
    @State private var problem: String?
    /// What is on disk now, when it changed since the editor read it.
    @State private var onDisk: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !readable {
                HStack {
                    Text("The rules file can't be read right now (it may still be downloading). Try again in a moment.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Try Again") { reload() }
                }
            }
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 220)
                .disabled(!readable)
            if let onDisk {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The rules changed on disk (another device or app) since you opened them.")
                        .font(.callout.weight(.medium))
                    HStack {
                        Button("Use the Version on Disk (Discard My Changes)") { text = onDisk; saved = onDisk; self.onDisk = nil }
                        Button("Keep Mine and Save") {
                            do {
                                try RulesFile.save(text, expected: onDisk, root: root, layout: layout)
                                saved = text; self.onDisk = nil
                            } catch RulesFile.SaveError.changedOnDisk(let current) {
                                self.onDisk = current            // changed again: show the newest
                            } catch { problem = error.localizedDescription }
                        }
                    }
                }
            }
            HStack {
                Button("Restore Default Policy") {
                    text = RulesFile.restoringDefaultPolicy(text, language: layout.language)
                }
                .disabled(!readable)
                Spacer()
                if text != saved {
                    Button("Revert") { text = saved }
                    Button("Save") {
                        do {
                            try RulesFile.save(text, expected: saved, root: root, layout: layout)
                            saved = text
                        } catch RulesFile.SaveError.changedOnDisk(let current) {
                            onDisk = current
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .task(id: root) { reload() }
        // Picks up an edit made elsewhere, unless there are unsaved changes.
        .onAppear { if text == saved { reload() } }
    }

    private func reload() {
        onDisk = nil; problem = nil
        if let current = RulesFile.read(root: root, layout: layout) {
            text = current; saved = current; readable = true
        } else {
            readable = false
        }
    }
}
