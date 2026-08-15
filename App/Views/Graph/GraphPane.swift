import SwiftUI
import InkstoneCore

/// Interactive force-directed graph of the whole vault.
///
/// Drawn with SwiftUI `Canvas` rather than a stack of views: at a few thousand
/// nodes, one immediate-mode draw call per frame is the difference between a
/// smooth graph and a slideshow.
struct GraphPane: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    @State private var simulation: GraphSimulation?
    @State private var alpha: Double = 1
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var hoveredNode: String?

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: alpha < 0.005)) { _ in
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
                .onChange(of: alpha) { _, _ in }
            }
            .background(style.background)
            .contentShape(.rect)
            .gesture(panGesture)
            .onTapGesture { location in
                handleTap(at: location, in: geometry.size)
            }
            .overlay(alignment: .bottomTrailing) { controls }
            .onAppear { rebuild() }
            .onChange(of: workspace.index.noteCount) { _, _ in rebuild() }
        }
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard var simulation else { return }

        // Advance the simulation and cool it down; a graph that never settles is
        // exhausting to look at.
        if alpha > 0.005 {
            simulation.step(alpha: alpha)
            Task { @MainActor in
                self.simulation = simulation
                self.alpha *= 0.985
            }
        }

        let center = CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)

        func point(_ id: String) -> CGPoint? {
            guard let position = simulation.position(of: id) else { return nil }
            return CGPoint(
                x: center.x + position.x * zoom,
                y: center.y + position.y * zoom
            )
        }

        // Links first, so nodes sit on top.
        var path = Path()
        for link in simulation.data.links {
            guard let from = point(link.source), let to = point(link.target) else { continue }
            path.move(to: from)
            path.addLine(to: to)
        }
        context.stroke(path, with: .color(style.divider), lineWidth: 1)

        for node in simulation.data.nodes {
            guard let position = point(node.id) else { continue }
            let radius = simulation.radius(for: node.id) * zoom
            let rect = CGRect(
                x: position.x - radius,
                y: position.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(color(for: node)))

            // Labels only when zoomed in or hovered — otherwise the graph turns
            // into an unreadable wall of text.
            if zoom > 0.85 || hoveredNode == node.id {
                let text = Text(node.label)
                    .font(.system(size: 10))
                    .foregroundStyle(style.secondaryText)
                context.draw(text, at: CGPoint(x: position.x, y: position.y + radius + 8), anchor: .top)
            }
        }
    }

    private func color(for node: GraphNode) -> Color {
        switch node.kind {
        case .note: return style.accent
        case .unresolved: return style.unresolvedLink
        case .tag: return style.tagColor
        case .attachment: return style.secondaryText
        }
    }

    // MARK: - Interaction

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                pan = CGSize(
                    width: dragStart.width + value.translation.width,
                    height: dragStart.height + value.translation.height
                )
            }
            .onEnded { _ in dragStart = pan }
    }

    private func handleTap(at location: CGPoint, in size: CGSize) {
        guard let simulation else { return }
        let center = CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
        for node in simulation.data.nodes {
            guard let position = simulation.position(of: node.id) else { continue }
            let point = CGPoint(x: center.x + position.x * zoom, y: center.y + position.y * zoom)
            let radius = max(10, simulation.radius(for: node.id) * zoom)
            if hypot(point.x - location.x, point.y - location.y) <= radius {
                if case .note(let url) = node.kind { workspace.openNote(at: url) }
                if case .tag(let tag) = node.kind {
                    workspace.sidebarSection = .tags
                    workspace.searchQuery = "tag:" + tag
                }
                return
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Toggle("Tags", isOn: settingBinding(\.graphShowTags))
                Toggle("Unresolved", isOn: settingBinding(\.graphShowUnresolved))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)

            HStack(spacing: 8) {
                Button { zoom = max(0.2, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                Slider(value: $zoom, in: 0.2...3).frame(width: 110)
                Button { zoom = min(3, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                Button { rebuild() } label: { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.plain)
            .foregroundStyle(style.secondaryText)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(16)
    }

    private func settingBinding(_ keyPath: WritableKeyPath<SettingsData, Bool>) -> Binding<Bool> {
        Binding(
            get: { workspace.settings.data[keyPath: keyPath] },
            set: {
                workspace.settings.data[keyPath: keyPath] = $0
                rebuild()
            }
        )
    }

    private func rebuild() {
        guard let root = workspace.root else { return }
        let data = GraphData.build(
            from: workspace.index,
            includeTags: workspace.settings.data.graphShowTags,
            includeUnresolved: workspace.settings.data.graphShowUnresolved,
            vaultRoot: root
        )
        simulation = GraphSimulation(data: data)
        alpha = 1
    }
}

/// Small non-interactive local graph shown in the inspector.
struct LocalGraphThumbnail: View {
    let url: URL

    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    @State private var simulation: GraphSimulation?
    @State private var alpha: Double = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: alpha < 0.01)) { _ in
            Canvas { context, size in
                guard var simulation else { return }
                if alpha > 0.01 {
                    simulation.step(alpha: alpha)
                    Task { @MainActor in
                        self.simulation = simulation
                        self.alpha *= 0.97
                    }
                }
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let scale: CGFloat = 0.5

                var path = Path()
                for link in simulation.data.links {
                    guard let a = simulation.position(of: link.source),
                          let b = simulation.position(of: link.target) else { continue }
                    path.move(to: CGPoint(x: center.x + a.x * scale, y: center.y + a.y * scale))
                    path.addLine(to: CGPoint(x: center.x + b.x * scale, y: center.y + b.y * scale))
                }
                context.stroke(path, with: .color(style.divider), lineWidth: 0.8)

                for node in simulation.data.nodes {
                    guard let position = simulation.position(of: node.id) else { continue }
                    let point = CGPoint(x: center.x + position.x * scale, y: center.y + position.y * scale)
                    let isCurrent = node.id == url.path(percentEncoded: false)
                    let radius: CGFloat = isCurrent ? 6 : 3.5
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: point.x - radius, y: point.y - radius,
                            width: radius * 2, height: radius * 2
                        )),
                        with: .color(isCurrent ? style.accent : style.secondaryText.opacity(0.7))
                    )
                }
            }
        }
        .onAppear(perform: rebuild)
        .onChange(of: url) { _, _ in rebuild() }
    }

    private func rebuild() {
        guard let root = workspace.root else { return }
        let full = GraphData.build(
            from: workspace.index,
            includeTags: false,
            includeUnresolved: true,
            vaultRoot: root
        )
        simulation = GraphSimulation(data: full.localGraph(around: url.path(percentEncoded: false), depth: 1))
        alpha = 1
    }
}
