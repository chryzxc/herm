import SwiftUI

/// Native scene over Timeline's clock and selection. The graph never launches work.
struct SessionCrewView: View {
    let projection: SessionCrewProjection
    let selectedRowID: String?
    let replayDate: Date?
    let now: Date
    let connected: Bool
    let animated: Bool
    let expanded: Bool
    let select: (String?) -> Void
    @State private var zoom: Double = 1
    @State private var focusedID: String?
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var focus = HermFocus.shared

    private var owner: String? { selectedRowID.flatMap { projection.ownerByRow[$0] } }
    private var rootID: String? { projection.root(selectedRowID: selectedRowID, replayDate: replayDate) }
    private var crew: [SessionCrewProjection.Actor] {
        let selected = projection.actors.first { $0.id == owner }
        return projection.bots.map { actor in
            selected?.identity == actor.identity ? selected! : actor
        }
    }
    private var motion: Bool { animated && !reduceMotion && focus.engaged && DockThemeStyle.current.animates }

    var body: some View {
        let actors = crew
        let branch = SessionCrewLayout.focused(actors, on: focusedID)
        let pages = max(1, Int(ceil(Double(branch.count) / 12)))
        let currentPage = min(page, pages - 1)
        let shown = Array(branch.dropFirst(currentPage * 12).prefix(12))
        VStack(spacing: 4) {
            if actors.count > 3 { controls(actors, pages: pages, currentPage: currentPage) }
            if shown.isEmpty {
                Text("No bots recorded in this selection").dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(maxWidth: .infinity, minHeight: 36)
            } else {
                GeometryReader { geometry in
                    let layout = SessionCrewLayout(actors: shown, width: geometry.size.width, zoom: zoom)
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            connections(shown, layout: layout)
                            ForEach(shown) { actor in
                                if let point = layout.positions[actor.id] {
                                    actorButton(actor)
                                        .frame(width: layout.nodeWidth, height: 98)
                                        .position(point)
                                }
                            }
                        }
                        .frame(width: layout.size.width, height: layout.size.height)
                    }
                }
                .frame(height: 112)
            }
            if owner != nil { context(actors) }
        }
        .onChange(of: rootID) { _, _ in
            focusedID = nil
            page = 0
        }
        .onChange(of: owner) { _, id in
            guard let id, let index = actors.firstIndex(where: { $0.id == id }) else { return }
            focusedID = nil
            page = index / 12
        }
    }

    private func controls(_ actors: [SessionCrewProjection.Actor], pages: Int, currentPage: Int) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(actors) { actor in
                    Button("\(actor.name) · \(actor.kind)") { select(actor.id) }
                }
            } label: {
                Label(actors.count == 1 ? "1 bot" : "\(actors.count) bots", systemImage: "person.2")
                    .dockFont(.metadata)
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer(minLength: 0)
            if focusedID != nil {
                Button("All bots") {
                    focusedID = nil
                    page = 0
                }.buttonStyle(.dockCompact)
            } else if owner != nil, actors.count > 1 {
                Button("Focus") {
                    focusedID = owner
                    page = 0
                }.buttonStyle(.dockCompact)
            }
            if expanded {
                Menu {
                    ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { value in
                        Button("\(Int(value * 100))%") { zoom = value }
                    }
                } label: {
                    Text("\(Int(zoom * 100))%").dockFont(.metadata)
                }
                .menuStyle(.borderlessButton).fixedSize().help("Crew zoom")
            }
            if pages > 1 {
                Button {
                    page = max(0, currentPage - 1)
                } label: {
                    Image(systemName: "chevron.left").frame(width: 20, height: 20)
                }.buttonStyle(.dockHover).disabled(currentPage == 0).accessibilityLabel("Previous crew group")
                Text("\(currentPage + 1)/\(pages)").dockFont(.metadata).monospacedDigit()
                Button {
                    page = min(pages - 1, currentPage + 1)
                } label: {
                    Image(systemName: "chevron.right").frame(width: 20, height: 20)
                }.buttonStyle(.dockHover).disabled(currentPage == pages - 1).accessibilityLabel("Next crew group")
            }
        }
        .padding(.horizontal, 4)
    }

    private func actorButton(_ actor: SessionCrewProjection.Actor) -> some View {
        let state = SessionCrewProjection.state(actor, at: replayDate, connected: connected)
        let selected = owner == actor.id
        let clock = replayDate ?? now.addingTimeInterval(-actor.row.shift)
        let moving = motion && state.moving && (replayDate != nil || connected)
        let pose = moving ? BotFacePose.at(clock.timeIntervalSinceReferenceDate, busy: true) : .rest
        return Button {
            select(actor.id)
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .bottom) {
                    Ellipse().fill(selected ? Color.dockAccent.opacity(0.16) : Color.dockSurface2)
                        .frame(width: 52, height: 12).offset(y: 3)
                    Canvas { context, _ in
                        context.translateBy(x: 8, y: 4)
                        BotFaceMark.draw(
                            in: &context, id: actor.identity, size: 36, mood: state.mood,
                            pose: pose, theme: DockThemeRuntime.current)
                    }
                    .frame(width: 52, height: 48)
                    if selected, let tool = state.toolName {
                        DockIcon(TurnActivityView.icon(for: tool), size: 12)
                            .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                            .padding(4).background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: 5))
                            .offset(x: 22, y: -28)
                    }
                }
                Text(actor.name).dockFont(.metadata, weight: .semibold).lineLimit(1)
                Text(zoom < 1 ? actor.kind : state.label)
                    .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).lineLimit(2)
                    .frame(height: 28, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(state.visible ? 1 : 0.35)
        }
        .buttonStyle(.dockHover)
        .accessibilityLabel("\(actor.name), \(actor.kind), \(state.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(actor.kind): \(actor.row.input ?? actor.row.title)\n\(state.label)")
    }

    private func connections(_ actors: [SessionCrewProjection.Actor], layout: SessionCrewLayout) -> some View {
        Canvas { context, _ in
            for actor in actors {
                guard let parent = actor.parentID, let from = layout.positions[parent],
                    let to = layout.positions[actor.id],
                    SessionCrewProjection.state(actor, at: replayDate, connected: connected).visible
                else { continue }
                let start = CGPoint(x: from.x + layout.nodeWidth / 2 - 8, y: from.y - 28)
                let end = CGPoint(x: to.x - layout.nodeWidth / 2 + 8, y: to.y - 28)
                let mid = (start.x + end.x) / 2
                var path = Path()
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: mid, y: start.y), control2: CGPoint(x: mid, y: end.y))
                let selected = owner == actor.id || owner == parent
                let ink: Color = selected ? .dockAccent : .dockBorder
                context.stroke(path, with: .color(ink), lineWidth: selected ? 1.5 : 1)
                var arrow = Path()
                arrow.move(to: CGPoint(x: end.x - 5, y: end.y - 3))
                arrow.addLine(to: end)
                arrow.addLine(to: CGPoint(x: end.x - 5, y: end.y + 3))
                context.stroke(arrow, with: .color(ink), lineWidth: 1)
                // One brief marker at the recorded start; never perpetual message traffic.
                if motion, connected || replayDate != nil, let began = actor.row.start {
                    let time = (replayDate ?? now.addingTimeInterval(-actor.row.shift)).timeIntervalSince(began)
                    if (0..<1.2).contains(time) {
                        let point = path.trimmedPath(from: 0, to: time / 1.2).currentPoint ?? start
                        context.fill(
                            Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                            with: .color(Color.dockAccent))
                    }
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func context(_ actors: [SessionCrewProjection.Actor]) -> some View {
        let actor = actors.first { $0.id == owner } ?? actors.first
        return HStack(spacing: 8) {
            if let actor {
                let state = SessionCrewProjection.state(actor, at: replayDate, connected: connected)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(actor.name) · \(actor.kind)").dockFont(.metadata, weight: .semibold)
                    Text(actor.row.input ?? actor.row.title).dockFont(.metadata)
                        .foregroundStyle(Color.dockSecondaryText).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let toolID = state.toolID {
                    Button("Show step") { select(toolID) }.buttonStyle(.dockCompact)
                }
            }
        }
        .frame(height: 38).padding(.horizontal, 8)
        .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Stable columns by ancestry; labels never shrink when the graph grows.
struct SessionCrewLayout {
    let positions: [String: CGPoint]
    let size: CGSize
    let nodeWidth: CGFloat

    init(actors: [SessionCrewProjection.Actor], width: CGFloat, zoom: Double) {
        nodeWidth = 112 * max(0.75, zoom)
        let byID = Dictionary(actors.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var positions: [String: CGPoint] = [:]
        var counts: [Int: Int] = [:]
        let botsOnly = actors.allSatisfy { $0.row.crewProfileID != nil && $0.parentID == nil }
        let columns = max(1, Int((width - 16) / (nodeWidth + 44)))
        for (index, actor) in actors.enumerated() {
            var depth = 0
            var cursor = actor.parentID
            var seen: Set<String> = [actor.id]
            while let id = cursor, let parent = byID[id], seen.insert(id).inserted {
                depth += 1
                cursor = parent.parentID
            }
            if botsOnly { depth = index % columns }
            let slot = counts[depth, default: 0]
            counts[depth] = slot + 1
            positions[actor.id] = CGPoint(
                x: 16 + nodeWidth / 2 + CGFloat(depth) * (nodeWidth + 44),
                y: 56 + CGFloat(slot) * 142)
        }
        self.positions = positions
        size = CGSize(
            width: max(width, CGFloat((counts.keys.max() ?? 0) + 1) * (nodeWidth + 44)),
            height: max(180, CGFloat(counts.values.max() ?? 1) * 142 + 12))
    }

    static func focused(_ actors: [SessionCrewProjection.Actor], on id: String?) -> [SessionCrewProjection.Actor] {
        guard let id, actors.contains(where: { $0.id == id }) else { return actors }
        let byID = Dictionary(actors.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return actors.filter { actor in
            var cursor: String? = actor.id
            var seen = Set<String>()
            while let next = cursor, seen.insert(next).inserted {
                if next == id { return true }
                cursor = byID[next]?.parentID
            }
            return false
        }
    }
}
