import SwiftUI
import InkstoneCore

/// Infinite canvas editor for `.canvas` files (JSON Canvas 1.0).
///
/// Nodes are real SwiftUI views inside a scaled/offset container so text stays
/// selectable and editable — a `Canvas` draw call would be faster but would make
/// the cards dead pixels.
struct CanvasPane: View {
    let url: URL

    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    @State private var document = CanvasDocument()
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var selection: Set<String> = []
    @State private var editingNode: String?
    /// Node the user started dragging a new edge from.
    @State private var connectingFrom: String?
    /// Viewport size, needed to centre the content; see fitToContent().
    @State private var viewportSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            content
                .onAppear {
                    viewportSize = geometry.size
                    load()
                }
                .onChange(of: geometry.size) { _, size in
                    let wasUnsized = viewportSize == .zero
                    viewportSize = size
                    // The first real size arrives after onAppear, so the initial
                    // fit has to be redone once the viewport is actually known.
                    if wasUnsized { fitToContent() }
                }
                .onDisappear(perform: save)
        }
    }

    private var content: some View {
        ZStack {
            style.background.ignoresSafeArea()

            // Edges are drawn beneath the node views.
            Canvas { context, _ in
                for edge in document.edges {
                    guard let from = document.node(id: edge.fromNode),
                          let to = document.node(id: edge.toNode) else { continue }
                    var path = Path()
                    let start = anchor(of: from, side: edge.fromSide, towards: to)
                    let end = anchor(of: to, side: edge.toSide, towards: from)
                    path.move(to: transform(start))
                    // A gentle curve reads better than a straight line when nodes
                    // are offset diagonally.
                    let control = CGPoint(x: (start.x + end.x) / 2, y: start.y)
                    path.addQuadCurve(to: transform(end), control: transform(control))
                    context.stroke(
                        path,
                        with: .color(edge.color.map { Color(hex: $0.hexValue) } ?? style.secondaryText),
                        lineWidth: 1.6
                    )
                }
            }
            .allowsHitTesting(false)

            ForEach(document.nodes) { node in
                nodeView(node)
                    .frame(width: node.width * zoom, height: node.height * zoom)
                    .position(transform(CGPoint(x: node.x + node.width / 2, y: node.y + node.height / 2)))
            }
        }
        .contentShape(.rect)
        .gesture(panGesture)
        .overlay(alignment: .bottom) { toolbar }
    }

    // MARK: - Nodes

    @ViewBuilder
    private func nodeView(_ node: CanvasNode) -> some View {
        let isSelected = selection.contains(node.id)
        let accent = node.color.map { Color(hex: $0.hexValue) } ?? style.divider

        Group {
            switch node.type {
            case .text:
                if editingNode == node.id {
                    TextEditor(text: textBinding(for: node))
                        .font(style.bodyFont)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                } else {
                    ScrollView {
                        Text(node.text ?? "")
                            .font(style.bodyFont)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
            case .file:
                VStack(alignment: .leading, spacing: 4) {
                    Label(node.file.map { ($0 as NSString).lastPathComponent } ?? "", systemImage: "doc.text")
                        .font(style.uiFont.weight(.medium))
                    if let file = node.file, let root = workspace.root,
                       let text = try? workspace.store?.read(root.appending(path: file)) {
                        Text(text.prefix(400))
                            .font(.caption)
                            .foregroundStyle(style.secondaryText)
                            .lineLimit(12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
            case .link:
                Link(destination: URL(string: node.url ?? "") ?? URL(string: "https://example.com")!) {
                    Label(node.url ?? "", systemImage: "globe")
                        .font(style.uiFont)
                        .padding(10)
                }
            case .group:
                VStack(alignment: .leading) {
                    Text(node.label ?? "")
                        .font(style.uiFont.weight(.semibold))
                        .foregroundStyle(style.secondaryText)
                        .padding(6)
                    Spacer()
                }
            }
        }
        .background(node.type == .group ? Color.clear : style.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? style.accent : accent, lineWidth: isSelected ? 2 : 1)
        )
        .onTapGesture(count: 2) { editingNode = node.id }
        .onTapGesture {
            editingNode = nil
            if selection.contains(node.id) { selection.remove(node.id) } else { selection = [node.id] }
            if node.type == .file, let file = node.file, let root = workspace.root {
                workspace.openNote(at: root.appending(path: file), inNewTab: true)
            }
        }
        .gesture(
            DragGesture()
                .onChanged { value in move(node, by: value.translation) }
                .onEnded { _ in save() }
        )
    }

    private func textBinding(for node: CanvasNode) -> Binding<String> {
        Binding(
            get: { document.node(id: node.id)?.text ?? "" },
            set: { newValue in
                guard let index = document.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                document.nodes[index].text = newValue
            }
        )
    }

    private func move(_ node: CanvasNode, by translation: CGSize) {
        guard let index = document.nodes.firstIndex(where: { $0.id == node.id }) else { return }
        // Translation is in screen points; divide by zoom to stay in canvas space.
        document.nodes[index].x = node.x + translation.width / zoom
        document.nodes[index].y = node.y + translation.height / zoom
    }

    // MARK: - Geometry

    private func transform(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + pan.width, y: point.y * zoom + pan.height)
    }

    /// Where an edge attaches to a node: the declared side, or the side facing
    /// the other node when the file doesn't specify one.
    private func anchor(of node: CanvasNode, side: CanvasEdge.Side?, towards other: CanvasNode) -> CGPoint {
        let center = CGPoint(x: node.x + node.width / 2, y: node.y + node.height / 2)
        let otherCenter = CGPoint(x: other.x + other.width / 2, y: other.y + other.height / 2)
        let resolved: CanvasEdge.Side = side ?? {
            let dx = otherCenter.x - center.x
            let dy = otherCenter.y - center.y
            if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
            return dy > 0 ? .bottom : .top
        }()

        switch resolved {
        case .top: return CGPoint(x: center.x, y: node.y)
        case .bottom: return CGPoint(x: center.x, y: node.y + node.height)
        case .left: return CGPoint(x: node.x, y: center.y)
        case .right: return CGPoint(x: node.x + node.width, y: center.y)
        }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                pan = CGSize(
                    width: panStart.width + value.translation.width,
                    height: panStart.height + value.translation.height
                )
            }
            .onEnded { _ in panStart = pan }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        // `.labelStyle(.iconOnly)` below, so each of these is a bare glyph with
        // nothing naming it. Every one carries a `.help`; on the two that are
        // conditionally disabled it says what would enable them, which is the
        // question a dimmed button actually raises.
        HStack(spacing: 14) {
            Button { addNode(.text) } label: { Label("Card", systemImage: "plus.rectangle") }
                .help("Add a card")
            Button { addNode(.group) } label: { Label("Group", systemImage: "rectangle.dashed") }
                .help("Add a group")
            Button {
                connectSelection()
            } label: {
                Label("Connect", systemImage: "arrow.right")
            }
            .disabled(selection.count != 2)
            .help(selection.count == 2
                  ? String(localized: "Draw an arrow between the two selected cards")
                  : String(localized: "Select two cards to connect them"))

            Divider().frame(height: 16)

            Button { zoom = max(0.2, zoom / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Button { fitToContent() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Fit the whole canvas on screen")
            Button { zoom = min(3, zoom * 1.2) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")

            Button(role: .destructive) {
                document.nodes.removeAll { selection.contains($0.id) }
                document.edges.removeAll { selection.contains($0.fromNode) || selection.contains($0.toNode) }
                selection.removeAll()
                save()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(selection.isEmpty)
            .help(selection.isEmpty
                  ? String(localized: "Select a card to delete it")
                  : String(localized: "Delete the selected cards"))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(style.secondaryText)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 20)
    }

    private func addNode(_ type: CanvasNode.NodeType) {
        // Drop new nodes at the centre of the current viewport.
        let node = CanvasNode(
            type: type,
            x: -pan.width / zoom,
            y: -pan.height / zoom,
            width: type == .group ? 400 : 260,
            height: type == .group ? 300 : 140,
            text: type == .text ? "" : nil,
            label: type == .group ? String(localized: "Group") : nil
        )
        document.nodes.append(node)
        selection = [node.id]
        if type == .text { editingNode = node.id }
        save()
    }

    private func connectSelection() {
        let ids = Array(selection)
        guard ids.count == 2 else { return }
        document.edges.append(CanvasEdge(fromNode: ids[0], toNode: ids[1]))
        save()
    }

    /// Frames the whole canvas in the viewport.
    ///
    /// The previous version set `pan` to the negated content centre, which put
    /// that centre at the *origin* — the top-left corner of the view, not the
    /// middle of it. Opening a canvas therefore showed one corner of one card
    /// and acres of empty space. Centring needs the viewport size, so the pane
    /// now tracks it.
    private func fitToContent() {
        guard let bounds = document.bounds,
              viewportSize.width > 0, viewportSize.height > 0
        else { return }

        let padding: CGFloat = 64
        let usableWidth = max(viewportSize.width - padding * 2, 1)
        let usableHeight = max(viewportSize.height - padding * 2, 1)
        let contentWidth = max(bounds.maxX - bounds.minX, 1)
        let contentHeight = max(bounds.maxY - bounds.minY, 1)
        // Never zoom *in* past 1: a two-card canvas blown up to fill a 27-inch
        // display looks broken rather than helpful.
        let fitted = min(usableWidth / contentWidth, usableHeight / contentHeight)
        zoom = min(1, max(0.15, fitted))

        let midX = (bounds.minX + bounds.maxX) / 2
        let midY = (bounds.minY + bounds.maxY) / 2
        pan = CGSize(
            width: viewportSize.width / 2 - midX * zoom,
            height: viewportSize.height / 2 - midY * zoom
        )
        panStart = pan
    }

    // MARK: - Persistence

    private func load() {
        document = (try? CanvasDocument.load(from: url)) ?? CanvasDocument()
        fitToContent()
    }

    private func save() {
        try? document.save(to: url)
    }
}

extension Color {
    /// Convenience for the hex strings JSON Canvas stores.
    init(hex: String) {
        let components = ThemeColor(hex).components
        self = Color(.sRGB, red: components.red, green: components.green, blue: components.blue, opacity: components.alpha)
    }
}
