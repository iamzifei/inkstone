import SwiftUI
import InkstoneCore

/// The graph's settings panel: Filters, Groups, Display, Forces.
///
/// Laid out to match Obsidian's, section for section and control for control,
/// because that is what was asked for and because anyone arriving from Obsidian
/// already knows what each dial does. The force sliders in particular keep
/// Obsidian's ranges and default readings, so a number noted there transfers.
struct GraphSettingsPanel: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    /// Search text lives in the pane rather than in settings: it is a question
    /// being asked now, not a preference. Obsidian persists it; a filter you
    /// cannot see the reason for, days later, is worse than retyping it.
    @Binding var search: String
    /// The note the graph is centred on, if any.
    var focus: URL?
    /// Hops out from `focus`. Ignored when showing the whole vault.
    @Binding var depth: Int
    /// Switches between this note's neighbourhood and the whole vault.
    var onScopeChange: (URL?) -> Void
    /// Called whenever a change means the graph has to be rebuilt or re-run.
    /// Display-only changes redraw on their own and do not use this.
    var onStructuralChange: () -> Void
    var onAnimate: () -> Void
    var onReset: () -> Void
    var onClose: () -> Void

    @State private var showScope = true
    @State private var showFilters = true
    @State private var showGroups = true
    @State private var showDisplay = true
    @State private var showForces = true

    var body: some View {
        @Bindable var settings = workspace.settings

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                if let focus {
                    section("Scope", isExpanded: $showScope) {
                        Picker("", selection: Binding(
                            get: { true },
                            set: { isLocal in if !isLocal { onScopeChange(nil) } }
                        )) {
                            Text("This note").tag(true)
                            Text("Whole vault").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Text(focus.deletingPathExtension().lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(style.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        // Obsidian's local graph calls this Depth and offers the
                        // same 1–5. One hop is what links to this note and what
                        // it links to; each step past that is a ring further out.
                        Stepper(value: Binding(
                            get: { depth },
                            set: {
                                depth = $0
                                onStructuralChange()
                            }
                        ), in: 1...5) {
                            Text("Depth: \(depth)")
                        }
                        .help("How many links out from this note to follow")
                    }
                } else {
                    section("Scope", isExpanded: $showScope) {
                        Picker("", selection: Binding(
                            get: { false },
                            set: { isLocal in if isLocal { onScopeChange(currentNote) } }
                        )) {
                            Text("This note").tag(true)
                            Text("Whole vault").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(currentNote == nil)
                        .help(currentNote == nil
                              ? String(localized: "Open a note to centre the graph on it")
                              : String(localized: "Centre the graph on the note you have open"))
                    }
                }

                section("Filters", isExpanded: $showFilters) {
                    TextField("Search files…", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(onStructuralChange)
                        .padding(.bottom, 4)

                    toggle("Tags", $settings.data.graphShowTags,
                           help: "Draw a node for every tag, joined to the notes carrying it")
                    toggle("Attachments", $settings.data.graphShowAttachments,
                           help: "Draw a node for every embedded image, PDF or clip")
                    toggle("Existing files only", existingFilesOnly,
                           help: "Hide links pointing at notes that don't exist yet")
                    toggle("Orphans", $settings.data.graphShowOrphans,
                           help: "Keep notes that nothing links to and that link to nothing")
                }

                section("Groups", isExpanded: $showGroups) {
                    ForEach($settings.data.graphGroups) { $group in
                        GroupRow(group: $group, onChange: onStructuralChange) {
                            settings.data.graphGroups.removeAll { $0.id == group.id }
                            onStructuralChange()
                        }
                    }
                    Button("New group") {
                        settings.data.graphGroups.append(.next(after: settings.data.graphGroups))
                    }
                    .frame(maxWidth: .infinity)
                    .help("Colour every node matching a search")
                }

                section("Display", isExpanded: $showDisplay) {
                    toggle("Arrows", $settings.data.graphArrows,
                           help: "Show which way each link points")
                    slider("Text fade threshold", $settings.data.graphTextFadeThreshold,
                           in: 0...3, format: "%.2f",
                           help: "Zoom below which labels fade out. 0 keeps them on always")
                    slider("Node size", $settings.data.graphNodeSize,
                           in: 0.1...5, format: "%.2f", help: "How big the dots are")
                    slider("Link thickness", $settings.data.graphLinkThickness,
                           in: 0.1...5, format: "%.2f", help: "How heavy the lines are")

                    Button("Animate", action: onAnimate)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help("Run the layout again from the start")
                }

                section("Forces", isExpanded: $showForces) {
                    slider("Centre force", $settings.data.graphCentreForce,
                           in: Forces.centreRange, format: "%.2f",
                           help: "Pull toward the middle. Higher packs the graph tighter",
                           onChange: onStructuralChange)
                    slider("Repel force", $settings.data.graphRepelForce,
                           in: Forces.repelRange, format: "%.2f",
                           help: "How hard nodes push each other apart",
                           onChange: onStructuralChange)
                    slider("Link force", $settings.data.graphLinkForce,
                           in: Forces.linkRange, format: "%.2f",
                           help: "How strongly a link pulls its two notes together",
                           onChange: onStructuralChange)
                    slider("Link distance", $settings.data.graphLinkDistance,
                           in: Forces.linkDistanceRange, format: "%.0f",
                           help: "How far apart a link tries to hold its two notes",
                           onChange: onStructuralChange)
                }
            }
            .padding(14)
        }
        .frame(width: 290)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style.divider))
    }

    private var header: some View {
        HStack {
            Spacer()
            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .help("Put every graph setting back to its default")

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close the settings panel")
        }
        .foregroundStyle(style.secondaryText)
        .padding(.bottom, 6)
    }

    /// The note that "This note" would centre on: whatever the workspace has
    /// open, if it is a file at all.
    private var currentNote: URL? { workspace.activeTab?.url }

    /// "Existing files only" is the same switch as "show unresolved", read the
    /// other way round. Obsidian words it this way and the wording is clearer,
    /// so the setting keeps its old name and the UI flips it here.
    private var existingFilesOnly: Binding<Bool> {
        Binding(
            get: { !workspace.settings.data.graphShowUnresolved },
            set: { workspace.settings.data.graphShowUnresolved = !$0 }
        )
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section<Content: View>(
        _ title: LocalizedStringKey,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
                    Text(title).font(.headline)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(style.text)

            if isExpanded.wrappedValue {
                content()
            }
        }
        .padding(.vertical, 10)
        Divider().overlay(style.divider)
    }

    private func toggle(
        _ title: LocalizedStringKey,
        _ value: Binding<Bool>,
        help: LocalizedStringKey
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { value.wrappedValue },
            set: {
                value.wrappedValue = $0
                onStructuralChange()
            }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(help)
    }

    private func slider(
        _ title: LocalizedStringKey,
        _ value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String,
        help: LocalizedStringKey,
        onChange: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            HStack(spacing: 8) {
                // A monospaced, fixed-width readout: without it the slider jumps
                // sideways as the number gets wider while you drag it.
                Text(String(format: format, value.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(style.secondaryText)
                    .frame(width: 42, alignment: .leading)
                Slider(value: value, in: range) { editing in
                    if !editing { onChange?() }
                }
            }
        }
        .help(help)
    }
}

/// One colour group: a swatch, the query, and a way to be rid of it.
private struct GroupRow: View {
    @Binding var group: SettingsData.GraphGroup
    var onChange: () -> Void
    var onDelete: () -> Void

    @Environment(\.style) private var style

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: Binding(
                get: { Color(red: group.red, green: group.green, blue: group.blue) },
                set: { colour in
                    let components = colour.resolvedComponents
                    group.red = components.red
                    group.green = components.green
                    group.blue = components.blue
                }
            ))
            .labelsHidden()
            .frame(width: 28)

            TextField("Search files…", text: $group.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onChange)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(style.secondaryText)
            .help("Remove this group")
        }
    }
}

private extension Color {
    /// sRGB components, for storing a picked colour in settings.
    var resolvedComponents: (red: Double, green: Double, blue: Double) {
        let resolved = resolve(in: EnvironmentValues())
        return (Double(resolved.red), Double(resolved.green), Double(resolved.blue))
    }
}
