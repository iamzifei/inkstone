import SwiftUI
import InkstoneCore

/// Preferences. Tabbed on macOS, a plain form on iOS.
struct SettingsView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        #if os(macOS)
        TabView {
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            TypographySettings().tabItem { Label("Typography", systemImage: "textformat") }
            EditorSettings().tabItem { Label("Editor", systemImage: "square.and.pencil") }
            FilesSettings().tabItem { Label("Files & Links", systemImage: "folder") }
            SyncSettings().tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 560, height: 460)
        #else
        NavigationStack {
            Form {
                NavigationLink { AppearanceSettings() } label: { Label("Appearance", systemImage: "paintpalette") }
                NavigationLink { TypographySettings() } label: { Label("Typography", systemImage: "textformat") }
                NavigationLink { EditorSettings() } label: { Label("Editor", systemImage: "square.and.pencil") }
                NavigationLink { FilesSettings() } label: { Label("Files & Links", systemImage: "folder") }
                NavigationLink { SyncSettings() } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            }
            .navigationTitle("Settings")
        }
        #endif
    }
}

private struct AppearanceSettings: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var settings = workspace.settings

        Form {
            Picker("Language", selection: $settings.data.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.endonym).tag(language)
                }
            }
            // Changing the app language needs a relaunch on Apple platforms
            // unless we swap bundles at runtime; say so rather than silently
            // doing nothing.
            Text("Takes effect after restarting Inkstone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Appearance", selection: $settings.data.appearance) {
                Text("System").tag(AppearanceMode.system)
                Text("Light").tag(AppearanceMode.light)
                Text("Dark").tag(AppearanceMode.dark)
            }
            .pickerStyle(.segmented)

            Picker("Theme", selection: $settings.data.themeID) {
                ForEach(settings.availableThemes) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct TypographySettings: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var settings = workspace.settings

        Form {
            Section("Body text") {
                FontPicker(
                    title: String(localized: "Font"),
                    selection: $settings.data.typography.editorFont,
                    suggestions: Typography.recommendedCJKFonts
                )
                LabeledStepper(
                    title: String(localized: "Size"),
                    value: $settings.data.typography.editorFontSize,
                    range: 11...32,
                    step: 0.5,
                    format: "%.1f pt"
                )
                LabeledStepper(
                    title: String(localized: "Line height"),
                    value: $settings.data.typography.lineHeightMultiple,
                    range: 1.0...2.6,
                    step: 0.05,
                    format: "%.2f×"
                )
                LabeledStepper(
                    title: String(localized: "Letter spacing"),
                    value: $settings.data.typography.letterSpacing,
                    range: -1...4,
                    step: 0.1,
                    format: "%.1f pt"
                )
            }

            Section("Code") {
                FontPicker(
                    title: String(localized: "Font"),
                    selection: $settings.data.typography.codeFont,
                    suggestions: Typography.recommendedCodeFonts
                )
                LabeledStepper(
                    title: String(localized: "Size"),
                    value: $settings.data.typography.codeFontSize,
                    range: 9...24,
                    step: 0.5,
                    format: "%.1f pt"
                )
                LabeledStepper(
                    title: String(localized: "Line height"),
                    value: $settings.data.typography.codeLineHeightMultiple,
                    range: 1.0...2.2,
                    step: 0.05,
                    format: "%.2f×"
                )
            }

            Section("Layout") {
                Toggle("Limit line width", isOn: $settings.data.typography.isReadableLineWidthEnabled)
                LabeledStepper(
                    title: String(localized: "Max line width"),
                    value: $settings.data.typography.readableLineWidth,
                    range: 400...1200,
                    step: 20,
                    format: "%.0f pt"
                )
                .disabled(!settings.data.typography.isReadableLineWidthEnabled)
                LabeledStepper(
                    title: String(localized: "Heading scale"),
                    value: $settings.data.typography.headingScale,
                    range: 1.05...1.5,
                    step: 0.01,
                    format: "%.2f"
                )
            }

            Section("Chinese typography") {
                Toggle("Space between Chinese and Latin", isOn: $settings.data.typography.cjkLatinSpacing)
                Text("Adds a hair space between 中文 and English while rendering. Your files are never modified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Compress full-width punctuation", isOn: $settings.data.typography.cjkPunctuationCompression)
            }
        }
        .formStyle(.grouped)
    }
}

private struct EditorSettings: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var settings = workspace.settings

        Form {
            Picker("Default mode", selection: $settings.data.editorMode) {
                Text("Live Preview").tag(EditorMode.livePreview)
                Text("Source").tag(EditorMode.source)
                Text("Reading").tag(EditorMode.reading)
            }
            Toggle("Continue lists on Return", isOn: $settings.data.smartLists)
            Toggle("Auto-close brackets and quotes", isOn: $settings.data.autoPairBrackets)
            Toggle("Check spelling", isOn: $settings.data.spellCheck)
            Toggle("Show frontmatter as properties", isOn: $settings.data.showFrontmatterAsProperties)
            Toggle("Indent with tabs", isOn: $settings.data.indentWithTabs)
            Stepper("Tab size: \(settings.data.tabSize)", value: $settings.data.tabSize, in: 2...8)
        }
        .formStyle(.grouped)
    }
}

private struct FilesSettings: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var settings = workspace.settings

        Form {
            Section("New notes") {
                TextField("Default folder", text: $settings.data.defaultNewNoteFolder)
                TextField("Attachment folder", text: $settings.data.attachmentFolder)
            }
            Section("Links") {
                Picker("New link format", selection: $settings.data.newLinkFormat) {
                    Text("[[Wikilink]]").tag(SettingsData.LinkFormat.wikilink)
                    Text("[Markdown](link.md)").tag(SettingsData.LinkFormat.markdown)
                }
                Toggle("Use shortest path when possible", isOn: $settings.data.useShortestPathLinks)
                Toggle("Update links when a note is renamed", isOn: $settings.data.updateLinksOnRename)
            }
            Section("Daily notes") {
                TextField("Folder", text: $settings.data.dailyNoteFolder)
                TextField("Date format", text: $settings.data.dailyNoteFormat)
                Toggle("Week starts on Monday", isOn: $settings.data.weekStartsOnMonday)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SyncSettings: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Form {
            Section("iCloud Drive") {
                if workspace.vault?.isCloudBacked == true {
                    Label("This vault lives in iCloud Drive and syncs automatically.", systemImage: "checkmark.icloud")
                } else {
                    Text("This vault is stored locally. Move it into iCloud Drive to sync across devices.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("GitHub") {
                Text("Git sync is not wired up yet in this build.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Images", isOn: syncBinding(for: .image))
                Toggle("Audio", isOn: syncBinding(for: .audio))
                Toggle("PDFs", isOn: syncBinding(for: .pdf))
                Toggle("Video", isOn: syncBinding(for: .video))
                Toggle("Other files", isOn: syncBinding(for: .other))

                LabeledContent("Skip files larger than") {
                    HStack(spacing: 6) {
                        TextField(
                            "",
                            value: sizeLimitBinding,
                            format: .number
                        )
                        .labelsHidden()
                        .frame(width: 70)
                        Text("MB")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("File types to sync")
            } footer: {
                Text("Notes and canvases always sync. Set the size limit to 0 for no limit.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func syncBinding(for kind: AttachmentKind) -> Binding<Bool> {
        Binding(
            get: { workspace.settings.data.syncPolicy.syncs(kind) },
            set: { workspace.settings.data.syncPolicy.setSyncs(kind, $0) }
        )
    }

    private var sizeLimitBinding: Binding<Int> {
        Binding(
            get: { workspace.settings.data.syncPolicy.maximumFileSizeMB },
            set: { workspace.settings.data.syncPolicy.maximumFileSizeMB = max(0, $0) }
        )
    }
}

// MARK: - Reusable controls

private struct FontPicker: View {
    let title: String
    @Binding var selection: FontChoice
    let suggestions: [String]

    var body: some View {
        Picker(title, selection: Binding(
            get: { key(for: selection) },
            set: { selection = choice(for: $0) }
        )) {
            Text("System").tag("system")
            Text("Serif").tag("serif")
            Text("Rounded").tag("rounded")
            Text("Monospaced").tag("monospaced")
            Divider()
            ForEach(availableSuggestions, id: \.self) { family in
                Text(family).tag("named:" + family)
            }
        }
    }

    /// Only offer families actually installed — a picker full of fonts that
    /// silently fall back to the system font is worse than a short list.
    private var availableSuggestions: [String] {
        #if os(macOS)
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        #else
        let installed = Set(UIFont.familyNames)
        #endif
        let matching = suggestions.filter { installed.contains($0) }
        if case .named(let current) = selection, !matching.contains(current) {
            return matching + [current]
        }
        return matching
    }

    private func key(for choice: FontChoice) -> String {
        switch choice {
        case .system: return "system"
        case .serif: return "serif"
        case .rounded: return "rounded"
        case .monospaced: return "monospaced"
        case .named(let family): return "named:" + family
        }
    }

    private func choice(for key: String) -> FontChoice {
        switch key {
        case "system": return .system
        case "serif": return .serif
        case "rounded": return .rounded
        case "monospaced": return .monospaced
        default: return .named(String(key.dropFirst("named:".count)))
        }
    }
}

private struct LabeledStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(String(format: format, value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}
