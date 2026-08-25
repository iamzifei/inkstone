import SwiftUI
import InkstoneCore

/// Interactive force-directed graph.
///
/// One node per note, one edge per link between notes: this is a map of the
/// vault, not of any note's insides.
///
/// With a `focus` it shows only what is within `depth` hops of that note, which
/// is what opening the graph from an open note gives you — "how does this note
/// sit in the vault" is a far more common question than "show me all nine
/// thousand of them". Without one it shows everything.
///
/// Drawn with SwiftUI `Canvas` rather than a stack of views: at a few thousand
/// nodes, one immediate-mode draw call per frame is the difference between a
/// smooth graph and a slideshow.
struct GraphPane: View {
    /// The note this graph is centred on, or nil for the whole vault.
    var focus: URL?

    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style

    @State private var simulation: GraphSimulation?
    /// First group each node belongs to, parallel to `simulation.data.nodes`.
    @State private var groups: [Int?] = []
    /// Bumped to ask for a fresh layout; `.task(id:)` watches it.
    @State private var generation = 0
    @State private var isSettling = false
    @State private var search = ""
    /// Persisted rather than per-pane: switching scope opens a different tab,
    /// and a panel that closed itself every time you did that would have to be
    /// reopened to switch back. Obsidian remembers this too — it is the `close`
    /// key in its own `graph.json`.
    @AppStorage("graphSettingsPanelOpen") private var isShowingSettings = false
    /// How many hops out from `focus` to include. Obsidian's local graph calls
    /// this Depth and offers 1–5; so does this.
    @State private var depth = 1

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var hoveredNode: Int?
    /// The node being dragged and where it is being held, if any.
    @State private var held: (slot: Int, position: SIMD2<Double>)?
    @State private var viewportSize: CGSize = .zero
    /// Set once the user pans or zooms, which stops the settling layout from
    /// re-framing the view out from under them.
    @State private var hasAdjustedView = false

    /// How far the zoom control goes. A vault of a few thousand notes lays out
    /// across a few thousand units, and fitting that on screen needs about 0.1 —
    /// the old floor of 0.2 could not show such a graph whole.
    private static let zoomRange: ClosedRange<CGFloat> = 0.02...4

    var body: some View {
        // Everything the draw closure needs is read *here*, during body
        // evaluation, and handed to the canvas as values. That is load-bearing,
        // not stylistic.
        //
        // SwiftUI records a @State property as a dependency of `body` only if
        // `body` actually reads it. Reading it solely inside the `Canvas` draw
        // closure does not count — that runs at render time, not evaluation time.
        // So the graph never re-evaluated when the simulation was built: the draw
        // closure kept the copy it captured on first evaluation, where it was
        // still nil, and the pane stayed blank forever while `rebuild()` happily
        // reported 18 nodes. The same applies to `pan`, `zoom` and the display
        // settings.
        let data = workspace.settings.data
        let frame = Frame(
            simulation: simulation,
            groups: groups,
            pan: pan,
            zoom: zoom,
            hovered: hoveredNode,
            arrows: data.graphArrows,
            textFadeThreshold: data.graphTextFadeThreshold,
            nodeSize: data.graphNodeSize,
            linkThickness: data.graphLinkThickness,
            groupColours: data.graphGroups.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
        )

        return GeometryReader { geometry in
            Canvas { context, size in
                draw(frame, in: &context, size: size)
            }
            .background(style.background)
            .contentShape(.rect)
            .gesture(dragGesture(in: geometry.size))
            .onTapGesture { location in
                handleTap(at: location, in: geometry.size)
            }
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let found = node(at: location, in: geometry.size)
                    // Guarded: a mouse move that changes nothing should not
                    // repaint several thousand nodes.
                    if found != hoveredNode { hoveredNode = found }
                case .ended:
                    if hoveredNode != nil { hoveredNode = nil }
                }
            }
            #endif
            // Scroll or pinch to zoom about the pointer, the way every other
            // canvas on this platform behaves.
            .onScrollWheel { delta in zoomBy(exp(delta / 220), at: nil, in: geometry.size) }
            .gesture(MagnifyGesture().onChanged { value in
                zoomBy(value.magnification / max(0.01, lastMagnification), at: nil, in: geometry.size)
                lastMagnification = value.magnification
            }.onEnded { _ in lastMagnification = 1 })
            .overlay(alignment: .topTrailing) { settingsPanel }
            .overlay(alignment: .bottomTrailing) { controls }
            .overlay(alignment: .center) { emptyState }
            .onAppear { viewportSize = geometry.size }
            .onChange(of: geometry.size) { _, size in viewportSize = size }
        }
        // Rebuilding and settling the layout is the expensive part, and it runs
        // off the main actor — see `settle()`. Doing it inside the draw closure,
        // as this pane used to, meant one frame of an 8,844-note vault blocked
        // the main thread for four seconds and the window stopped responding.
        .task(id: generation) { await settle() }
        .onChange(of: workspace.index.noteCount) { _, _ in generation += 1 }
    }

    @State private var lastMagnification: CGFloat = 1

    /// One frame's worth of inputs, snapshotted during body evaluation.
    private struct Frame {
        let simulation: GraphSimulation?
        let groups: [Int?]
        let pan: CGSize
        let zoom: CGFloat
        let hovered: Int?
        let arrows: Bool
        let textFadeThreshold: Double
        let nodeSize: Double
        let linkThickness: Double
        let groupColours: [Color]
    }

    // MARK: - Layout

    /// Builds the graph and runs the force layout to a standstill, one frame at a
    /// time, entirely off the main actor. Each finished frame is published back
    /// as state, which is what redraws the canvas.
    private func settle() async {
        guard let root = workspace.root else { return }
        let snapshot = workspace.index
        let attachments = workspace.attachments
        let data = workspace.settings.data
        let filters = GraphData.Filters(
            search: search,
            showTags: data.graphShowTags,
            showAttachments: data.graphShowAttachments,
            showUnresolved: data.graphShowUnresolved,
            showOrphans: data.graphShowOrphans
        )
        let forces = Forces(
            centre: data.graphCentreForce,
            repel: data.graphRepelForce,
            link: data.graphLinkForce,
            linkDistance: data.graphLinkDistance
        )
        let queries = data.graphGroups.map(\.query)

        isSettling = true
        defer { isSettling = false }

        let focus = focus
        let depth = depth

        let built = await Task.detached(priority: .userInitiated) {
            let graph = focus.map { url in
                GraphData.local(
                    from: snapshot,
                    attachments: attachments,
                    around: url,
                    depth: depth,
                    filters: filters,
                    vaultRoot: root
                )
            } ?? GraphData.build(
                from: snapshot,
                attachments: attachments,
                filters: filters,
                vaultRoot: root
            )
            return (
                simulation: GraphSimulation(data: graph, forces: forces),
                groups: graph.groupMembership(queries: queries, snapshot: snapshot)
            )
        }.value

        guard !Task.isCancelled else { return }
        var working = built.simulation
        simulation = working
        groups = built.groups
        pan = .zero
        dragStart = .zero
        hasAdjustedView = false

        // Cools from 1 to nothing in ~350 frames.
        var alpha = 1.0
        var frames = 0
        while alpha > 0.005, !Task.isCancelled {
            let current = working
            let step = alpha
            working = await Task.detached(priority: .userInitiated) {
                var next = current
                next.step(alpha: step)
                return next
            }.value

            guard !Task.isCancelled else { return }
            // A node held under the pointer stays where it was put, and the rest
            // of the graph rearranges around it. The held position is kept in its
            // own state rather than read back off the simulation: `working` is a
            // value copied before the drag happened and knows nothing about it.
            if let held, held.slot < working.positions.count {
                working.pin(working.data.nodes[held.slot].id, at: held.position)
            }
            simulation = working
            alpha *= 0.985
            frames += 1

            // Re-frame as the graph grows, so it stays in view while it spreads
            // rather than fitting once at a moment picked by a timer.
            if frames.isMultiple(of: 15) { fitToContent(animated: false) }

            // Hand the main actor back a slice so the canvas can actually draw
            // the frame just produced.
            try? await Task.sleep(for: .milliseconds(8))
        }

        if !Task.isCancelled { fitToContent(animated: true) }
    }

    // MARK: - Drawing

    private func draw(_ frame: Frame, in context: inout GraphicsContext, size: CGSize) {
        guard let simulation = frame.simulation, !simulation.positions.isEmpty else { return }

        let zoom = frame.zoom
        let center = CGPoint(x: size.width / 2 + frame.pan.width, y: size.height / 2 + frame.pan.height)

        func point(_ slot: Int) -> CGPoint {
            let position = simulation.positions[slot]
            return CGPoint(x: center.x + position.x * zoom, y: center.y + position.y * zoom)
        }

        // Anything outside this never reaches the screen. On a big vault most of
        // the graph is off-canvas at any useful zoom, and skipping it early is
        // most of what keeps panning smooth.
        let visible = CGRect(origin: .zero, size: size).insetBy(dx: -60, dy: -60)

        // Links first, so nodes sit on top. One path, one stroke.
        var links = Path()
        var arrowheads = Path()
        for link in simulation.linkSlots {
            let from = point(Int(link.x))
            let to = point(Int(link.y))
            guard visible.contains(from) || visible.contains(to)
                    || visible.intersects(CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                                                 width: abs(to.x - from.x), height: abs(to.y - from.y)))
            else { continue }
            links.move(to: from)
            links.addLine(to: to)
            if frame.arrows {
                addArrowhead(to: &arrowheads, from: from, to: to,
                             clearing: max(2, simulation.radii[Int(link.y)] * frame.nodeSize * zoom))
            }
        }
        context.stroke(links, with: .color(style.divider), lineWidth: frame.linkThickness)
        if frame.arrows {
            context.fill(arrowheads, with: .color(style.divider))
        }

        // Nodes, batched by colour: a handful of fills instead of one per node.
        var paths: [ColourKey: Path] = [:]
        var labelled: [(slot: Int, point: CGPoint, radius: CGFloat)] = []
        // 0 means "never fade"; otherwise labels appear once zoomed past it.
        //
        // Text is also left off while a large graph is still settling. Shaping a
        // few hundred names is by far the most expensive thing this method does
        // — 43% of the main thread in a profile of the 9,350-node vault, nearly
        // all of it inside `CTLineCreateWithAttributedString` — and during the
        // settle the names are sliding around too fast to read anyway.
        let isBusy = isSettling && simulation.positions.count > 400
        let showLabels = !isBusy && (frame.textFadeThreshold <= 0 || zoom > frame.textFadeThreshold)

        for slot in simulation.positions.indices {
            let position = point(slot)
            // A dot below a pixel across is invisible, and on a graph zoomed out
            // to fit, every dot would be. Keep a floor so the shape still reads.
            let radius = max(1.5, simulation.radii[slot] * frame.nodeSize * zoom)
            guard visible.insetBy(dx: -radius, dy: -radius).contains(position) else { continue }

            let box = CGRect(x: position.x - radius, y: position.y - radius,
                             width: radius * 2, height: radius * 2)
            // A circle is four bezier curves; a square is four lines. Below about
            // five pixels across nobody can tell them apart, and at the zoom that
            // fits a large vault *every* node is that small — so this is the
            // common case, not the corner case.
            if radius < 2.5 {
                paths[colourKey(for: slot, frame: frame), default: Path()].addRect(box)
            } else {
                paths[colourKey(for: slot, frame: frame), default: Path()].addEllipse(in: box)
            }
            // A hovered node is always named, however far out the zoom is — and
            // whatever the layout is doing: it is the only way to identify one
            // dot in a field of them.
            if showLabels || frame.hovered == slot {
                labelled.append((slot, position, radius))
            }
        }

        for (key, path) in paths {
            context.fill(path, with: .color(colour(for: key, frame: frame)))
        }

        drawLabels(labelled, of: simulation, in: &context, hovered: frame.hovered)
    }

    /// Draws node names, dropping any that would land on one already drawn.
    ///
    /// Without this a vault of a few thousand notes is a smear: at the zoom that
    /// fits the whole graph there are far more names than there is room for, and
    /// every one of them gets painted anyway. Obsidian keeps its graph legible by
    /// fading text out as you zoom away; the effect wanted is the same — say what
    /// there is room to say — and this says it for the nodes that matter most at
    /// any zoom rather than for none of them.
    private func drawLabels(
        _ candidates: [(slot: Int, point: CGPoint, radius: CGFloat)],
        of simulation: GraphSimulation,
        in context: inout GraphicsContext,
        hovered: Int?
    ) {
        // Biggest first, so the hubs are the ones that keep their names. `slot`
        // breaks ties, because a set of equal-sized nodes must not swap labels
        // from frame to frame.
        let ordered = candidates.sorted {
            $0.radius == $1.radius ? $0.slot < $1.slot : $0.radius > $1.radius
        }

        // Occupancy in coarse screen cells. A label is about 14 points tall, so
        // the grid is that high; the width is whatever the text measures.
        var occupied: Set<SIMD2<Int>> = []
        let cell = CGSize(width: 24, height: 15)
        var drawn = 0

        for entry in ordered {
            // A hard ceiling. Not only for cost: two hundred and fifty names is
            // already more than anyone reads off one screen, and each one past
            // that is a line of CoreText shaping every frame.
            guard drawn < 250 else { break }

            let isHovered = entry.slot == hovered
            let resolved = context.resolve(
                Text(simulation.data.nodes[entry.slot].label)
                    .font(.system(size: 10))
                    .foregroundStyle(isHovered ? style.text : style.secondaryText)
            )
            let size = resolved.measure(in: CGSize(width: 200, height: 40))
            let origin = CGPoint(
                x: entry.point.x - size.width / 2,
                y: entry.point.y + entry.radius + 4
            )
            // Padded, so labels that clear each other by a hair still read as two
            // labels rather than as one run of text.
            let cells = cellsCovering(
                CGRect(origin: origin, size: size).insetBy(dx: -5, dy: -2),
                cell: cell
            )

            // The hovered node always gets its name, over the top of whatever is
            // there: it is the answer to "what is this dot".
            if !isHovered {
                guard occupied.isDisjoint(with: cells) else { continue }
            }
            occupied.formUnion(cells)
            context.draw(resolved, at: origin, anchor: .topLeading)
            drawn += 1
        }
    }

    private func cellsCovering(_ rect: CGRect, cell: CGSize) -> Set<SIMD2<Int>> {
        var cells: Set<SIMD2<Int>> = []
        let firstColumn = Int(floor(rect.minX / cell.width))
        let lastColumn = Int(floor(rect.maxX / cell.width))
        let firstRow = Int(floor(rect.minY / cell.height))
        let lastRow = Int(floor(rect.maxY / cell.height))
        // A label wider than the screen would otherwise reserve thousands of
        // cells; nothing sensible is that wide, so this is only a backstop.
        guard lastColumn - firstColumn < 200, lastRow - firstRow < 20 else { return [] }
        for column in firstColumn...lastColumn {
            for row in firstRow...lastRow {
                cells.insert(SIMD2(column, row))
            }
        }
        return cells
    }

    /// A small filled triangle just short of the target node.
    private func addArrowhead(to path: inout Path, from: CGPoint, to: CGPoint, clearing radius: CGFloat) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > radius + 6 else { return }

        let unit = CGPoint(x: dx / length, y: dy / length)
        // Sits on the edge of the target rather than under it, which is the only
        // way the direction reads at all on a dense graph.
        let tip = CGPoint(x: to.x - unit.x * radius, y: to.y - unit.y * radius)
        let base = CGPoint(x: tip.x - unit.x * 6, y: tip.y - unit.y * 6)
        let normal = CGPoint(x: -unit.y * 2.5, y: unit.x * 2.5)

        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x + normal.x, y: base.y + normal.y))
        path.addLine(to: CGPoint(x: base.x - normal.x, y: base.y - normal.y))
        path.closeSubpath()
    }

    /// What decides a node's colour: its group if it has one, else its kind.
    private enum ColourKey: Hashable {
        case focus
        case group(Int)
        case kind(GraphNode.Kind.Grouping)
    }

    private func colourKey(for slot: Int, frame: Frame) -> ColourKey {
        // The note the graph is centred on is drawn in the accent, so the eye
        // lands on it first. It is the one node the reader already knows.
        if let focus, frame.simulation?.data.nodes[slot].id == focus.path(percentEncoded: false) {
            return .focus
        }
        if slot < frame.groups.count, let group = frame.groups[slot], group < frame.groupColours.count {
            return .group(group)
        }
        return .kind(frame.simulation?.data.nodes[slot].kind.grouping ?? .note)
    }

    private func colour(for key: ColourKey, frame: Frame) -> Color {
        switch key {
        case .focus: return style.accent
        case .group(let index): return frame.groupColours[index]
        // The body text colour, as Obsidian does it, rather than the accent: a
        // field of several thousand accent-coloured dots is a wall of one loud
        // colour, and it leaves nothing for the colour groups to stand out
        // against. Notes are the quiet default; everything else is a departure
        // from it.
        case .kind(.note): return style.text
        case .kind(.unresolved): return style.faintText
        case .kind(.tag): return style.tagColor
        case .kind(.attachment): return style.secondaryText
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let simulation, simulation.positions.isEmpty, !isSettling {
            ContentUnavailableView(
                "Nothing to graph",
                systemImage: "point.3.filled.connected.trianglepath.dotted",
                description: Text(focus == nil
                                  ? "Link notes with [[wikilinks]], or loosen the filters."
                                  : "Nothing links to this note yet. Try a greater depth, or the whole vault.")
            )
        }
    }

    // MARK: - Interaction

    /// Drags a node if the gesture started on one, otherwise pans the view.
    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartedOnNode == nil {
                    dragStartedOnNode = node(at: value.startLocation, in: size) ?? -1
                }
                if let grabbed = dragStartedOnNode, grabbed >= 0 {
                    moveNode(grabbed, to: value.location, in: size)
                    return
                }
                hasAdjustedView = true
                pan = CGSize(
                    width: dragStart.width + value.translation.width,
                    height: dragStart.height + value.translation.height
                )
            }
            .onEnded { _ in
                // Released, so it rejoins the layout rather than staying nailed
                // where it was dropped.
                if let held, var simulation {
                    simulation.unpin(simulation.data.nodes[held.slot].id)
                    self.simulation = simulation
                }
                held = nil
                dragStartedOnNode = nil
                dragStart = pan
            }
    }

    /// `nil` = not yet decided, `-1` = started on empty space.
    @State private var dragStartedOnNode: Int?

    private func moveNode(_ slot: Int, to location: CGPoint, in size: CGSize) {
        guard var simulation, slot < simulation.positions.count else { return }
        let center = CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
        let position = SIMD2<Double>(
            Double((location.x - center.x) / zoom),
            Double((location.y - center.y) / zoom)
        )
        held = (slot, position)
        // Applied here as well as in the settle loop: once the layout has come to
        // rest there are no more frames, and without this the node would not move
        // until something else asked for a redraw.
        simulation.pin(simulation.data.nodes[slot].id, at: position)
        self.simulation = simulation
    }

    /// Slot of the node under a point, if any.
    private func node(at location: CGPoint, in size: CGSize) -> Int? {
        guard let simulation else { return nil }
        let nodeSize = workspace.settings.data.graphNodeSize
        let center = CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
        var best: (slot: Int, distance: CGFloat)?
        for slot in simulation.positions.indices {
            let position = simulation.positions[slot]
            let point = CGPoint(x: center.x + position.x * zoom, y: center.y + position.y * zoom)
            // A generous floor: at a zoom that fits a big vault the dots are a
            // pixel across and nothing would ever be clickable.
            let radius = max(8, simulation.radii[slot] * nodeSize * zoom)
            let distance = hypot(point.x - location.x, point.y - location.y)
            if distance <= radius, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (slot, distance)
            }
        }
        return best?.slot
    }

    private func handleTap(at location: CGPoint, in size: CGSize) {
        guard let simulation, let slot = node(at: location, in: size) else { return }
        switch simulation.data.nodes[slot].kind {
        case .note(let url), .attachment(let url):
            workspace.openNote(at: url)
        case .tag(let tag):
            workspace.sidebarSection = .tags
            workspace.searchQuery = "tag:" + tag
        case .unresolved:
            break
        }
    }

    /// Multiplies the zoom, keeping the graph point under the cursor put.
    private func zoomBy(_ factor: CGFloat, at anchor: CGPoint?, in size: CGSize) {
        let target = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom * factor))
        guard target != zoom else { return }
        hasAdjustedView = true
        if let anchor {
            // Keep whatever is under the pointer under the pointer.
            let centre = CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
            let graphPoint = CGPoint(x: (anchor.x - centre.x) / zoom, y: (anchor.y - centre.y) / zoom)
            pan = CGSize(
                width: pan.width + graphPoint.x * (zoom - target),
                height: pan.height + graphPoint.y * (zoom - target)
            )
            dragStart = pan
        }
        zoom = target
    }

    // MARK: - Chrome

    @ViewBuilder
    private var settingsPanel: some View {
        if isShowingSettings {
            GraphSettingsPanel(
                search: $search,
                focus: focus,
                depth: $depth,
                onScopeChange: { newFocus in
                    workspace.open(.graph(focus: newFocus))
                },
                onStructuralChange: { generation += 1 },
                onAnimate: { generation += 1 },
                onReset: {
                    let defaults = SettingsData()
                    var data = workspace.settings.data
                    data.graphShowTags = defaults.graphShowTags
                    data.graphShowAttachments = defaults.graphShowAttachments
                    data.graphShowUnresolved = defaults.graphShowUnresolved
                    data.graphShowOrphans = defaults.graphShowOrphans
                    data.graphArrows = defaults.graphArrows
                    data.graphTextFadeThreshold = defaults.graphTextFadeThreshold
                    data.graphNodeSize = defaults.graphNodeSize
                    data.graphLinkThickness = defaults.graphLinkThickness
                    data.graphCentreForce = defaults.graphCentreForce
                    data.graphRepelForce = defaults.graphRepelForce
                    data.graphLinkForce = defaults.graphLinkForce
                    data.graphLinkDistance = defaults.graphLinkDistance
                    // Groups are content, not a preference: resetting the dials
                    // should not silently throw away someone's saved queries.
                    workspace.settings.data = data
                    search = ""
                    depth = 1
                    generation += 1
                },
                onClose: { isShowingSettings = false }
            )
            .padding(16)
            // Kept clear of the zoom controls in the opposite corner, which the
            // panel would otherwise run underneath — leaving them visible but
            // unclickable, which is worse than hiding them.
            .padding(.bottom, 58)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if isSettling {
                ProgressView()
                    .controlSize(.mini)
                    .help("Laying out…")
            }

            Button {
                zoomBy(1 / 1.25, at: nil, in: viewportSize)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")

            Button {
                zoomBy(1.25, at: nil, in: viewportSize)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")

            Button {
                hasAdjustedView = false
                fitToContent(animated: true)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Fit the whole graph on screen")

            Button {
                isShowingSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Filters, groups, display and forces")
        }
        .buttonStyle(.plain)
        .foregroundStyle(style.secondaryText)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .padding(16)
    }

    /// Chooses a zoom and pan that bring the whole graph into view.
    private func fitToContent(animated: Bool) {
        // Once the user has moved the view, nothing re-frames it behind their
        // back. The Fit button clears the flag first, so it always works.
        guard !hasAdjustedView else { return }
        guard let simulation, !simulation.positions.isEmpty,
              viewportSize.width > 0, viewportSize.height > 0 else { return }

        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for slot in simulation.positions.indices {
            let position = simulation.positions[slot]
            let radius = simulation.radii[slot]
            minX = min(minX, position.x - radius)
            minY = min(minY, position.y - radius)
            maxX = max(maxX, position.x + radius)
            maxY = max(maxY, position.y + radius)
        }
        guard minX < maxX, minY < maxY else { return }

        let padding: CGFloat = 40
        let fitted = min(
            (viewportSize.width - padding * 2) / CGFloat(maxX - minX),
            (viewportSize.height - padding * 2) / CGFloat(maxY - minY)
        )
        // Clamped to the same range the zoom controls offer.
        let target = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, fitted))
        // Recentre on the graph's own middle, which is rarely the origin.
        let centre = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let framing = CGSize(width: -centre.x * target, height: -centre.y * target)

        if animated {
            withAnimation(.easeOut(duration: 0.35)) {
                zoom = target
                pan = framing
            }
        } else {
            // No animation while the layout is still moving: a new animation
            // every fifteenth frame fights itself and the graph judders.
            zoom = target
            pan = framing
        }
        dragStart = framing
    }
}

extension GraphNode.Kind {
    /// The kind without its payload — enough to pick a colour, and hashable so
    /// nodes can be batched into one path per colour.
    enum Grouping: Hashable {
        case note, unresolved, tag, attachment
    }

    var grouping: Grouping {
        switch self {
        case .note: .note
        case .unresolved: .unresolved
        case .tag: .tag
        case .attachment: .attachment
        }
    }
}

/// Small non-interactive local graph shown in the inspector.
struct LocalGraphThumbnail: View {
    let url: URL

    @Environment(Workspace.self) private var workspace
    @Environment(\.style) private var style
    @State private var simulation: GraphSimulation?

    var body: some View {
        // Same reason as GraphPane: read during body evaluation so SwiftUI knows
        // the canvas depends on it.
        let snapshot = simulation

        return Canvas { context, size in
            guard let simulation = snapshot, !simulation.positions.isEmpty else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let scale: CGFloat = 0.5

            var path = Path()
            for link in simulation.linkSlots {
                let a = simulation.positions[Int(link.x)]
                let b = simulation.positions[Int(link.y)]
                path.move(to: CGPoint(x: center.x + a.x * scale, y: center.y + a.y * scale))
                path.addLine(to: CGPoint(x: center.x + b.x * scale, y: center.y + b.y * scale))
            }
            context.stroke(path, with: .color(style.divider), lineWidth: 0.8)

            let current = url.path(percentEncoded: false)
            for slot in simulation.positions.indices {
                let position = simulation.positions[slot]
                let point = CGPoint(x: center.x + position.x * scale, y: center.y + position.y * scale)
                let isCurrent = simulation.data.nodes[slot].id == current
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
        .task(id: url) { await rebuild() }
    }

    /// Lays the neighbourhood out once, off the main actor, and shows the result.
    ///
    /// A thumbnail is not worth animating: it is a dozen circles in a 200-point
    /// box, and the settling wobble was only ever noise beside the note.
    private func rebuild() async {
        let snapshot = workspace.index
        let url = url
        let root = workspace.root ?? url.deletingLastPathComponent()
        simulation = await Task.detached(priority: .userInitiated) {
            // Straight from the index. Building the whole vault's graph and then
            // discarding all but this note's neighbours — which is what this did
            // — cost seconds per note opened on a large vault.
            //
            // Its own filters, not the graph tab's: a thumbnail is there to show
            // the shape of this note's links, and hiding some of them because a
            // search is still typed into a pane somewhere else would be baffling.
            var simulation = GraphSimulation(data: GraphData.local(
                from: snapshot,
                around: url,
                depth: 1,
                filters: GraphData.Filters(showTags: false, showUnresolved: true),
                vaultRoot: root
            ))
            var alpha = 1.0
            while alpha > 0.01 {
                simulation.step(alpha: alpha)
                alpha *= 0.97
            }
            return simulation
        }.value
    }
}
