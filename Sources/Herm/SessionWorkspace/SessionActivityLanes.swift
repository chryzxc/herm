import SwiftUI

/// Who worked when: one lane for Herm, one per Bot profile, one per subagent.
/// Built from the same rows as the waterfall; spans and marks are recorded timing only.
struct SessionActivityLanes {
    struct Lane: Identifiable, Equatable {
        enum Kind { case main, bot, subagent }
        let id: String
        let name: String
        let kind: Kind
        var actors: [SessionCrewProjection.Actor]
        var actorIDs: Set<String> { Set(actors.map(\.id)) }
        /// Bot profile or subagent ID; seeds the face and lane hue.
        var identity: String { actors.first?.identity ?? id }
        var tone: DockAccentColor {
            switch kind {
            case .main: .violet
            case .bot: DockAccentColor.identity(for: identity)
            case .subagent: DockAccentColor.identity(for: String(id.trimmingPrefix("agent:")))
            }
        }
    }

    static let mainID = "lane:main"
    let lanes: [Lane]
    let ownerByRow: [String: String]
    private let laneIndexByActor: [String: Int]

    init(_ crew: SessionCrewProjection) {
        var lanes: [Lane] = []
        var index: [String: Int] = [:]
        for actor in crew.actors where !SessionCrewProjection.isDispatchRoot(actor.row) {
            let key: String
            let kind: Lane.Kind
            switch actor.row.kind {
            case .turn: (key, kind) = (Self.mainID, .main)
            case _ where actor.row.crewProfileID != nil: (key, kind) = ("lane:bot:" + actor.identity, .bot)
            default: (key, kind) = (actor.id, .subagent)
            }
            if let at = index[key] {
                lanes[at].actors.append(actor)
            } else {
                index[key] = lanes.count
                lanes.append(Lane(id: key, name: kind == .main ? "Herm" : actor.name, kind: kind, actors: [actor]))
            }
        }
        // Herm first, then by first recorded start; untimed lanes keep roster order at the end.
        let first = Dictionary(
            uniqueKeysWithValues: lanes.compactMap { lane in
                lane.actors.compactMap { $0.row.timing == .unavailable ? nil : $0.row.start }.min()
                    .map { (lane.id, $0) }
            })
        let sortedLanes = lanes.enumerated().sorted { a, b in
            if (a.element.kind == .main) != (b.element.kind == .main) { return a.element.kind == .main }
            switch (first[a.element.id], first[b.element.id]) {
            case (let x?, let y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        self.lanes = sortedLanes
        ownerByRow = crew.ownerByRow
        var laneIndexByActor: [String: Int] = [:]
        for (index, lane) in sortedLanes.enumerated() {
            for actor in lane.actors where laneIndexByActor[actor.id] == nil { laneIndexByActor[actor.id] = index }
        }
        self.laneIndexByActor = laneIndexByActor
    }

    func lane(owning rowID: String) -> Lane? {
        guard let owner = ownerByRow[rowID], let index = laneIndexByActor[owner] else { return nil }
        return lanes[index]
    }

    /// Rows that satisfy `keep`, plus their ancestors so the waterfall tree stays intact.
    static func scoped(_ rows: [SessionTraceRow], keep: (SessionTraceRow) -> Bool) -> [SessionTraceRow] {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var included = Set<String>()
        for row in rows where keep(row) {
            var cursor: String? = row.id
            while let id = cursor, included.insert(id).inserted { cursor = byID[id]?.parentID }
        }
        return rows.filter { included.contains($0.id) }
    }
}

/// Completed opaque tool marks use time-space paths that can be scaled without
/// visiting each historical row on every clock tick. Replay keeps exact rows.
@MainActor
struct SessionActivityToolGeometry {
    struct Batch {
        let tone: DockAccentColor
        let inset: CGFloat
        var spans = Path()
        var starts = Path()
    }

    enum Segment {
        case batch(Batch)
        case dynamic(SessionTraceRow)
    }

    let segmentsByActor: [String: [Segment]]
    static let maximumPreparedTools = 20_000

    init(lanes: SessionActivityLanes, origin: Date) {
        let count = lanes.lanes.reduce(0) { total, lane in
            total + lane.actors.reduce(0) { $0 + $1.tools.count }
        }
        guard count <= Self.maximumPreparedTools else {
            segmentsByActor = [:]
            return
        }
        var result: [String: [Segment]] = [:]
        for (index, lane) in lanes.lanes.enumerated() {
            let y = CGFloat(index) * 26
            for actor in lane.actors {
                var segments: [Segment] = []
                var batch: Batch?
                func flush() {
                    if let batch { segments.append(.batch(batch)) }
                    batch = nil
                }
                for tool in actor.tools {
                    guard !tool.active, tool.kind == .tool, tool.timing != .unavailable,
                        let start = tool.start, let elapsed = tool.elapsed(at: origin)
                    else {
                        flush()
                        segments.append(.dynamic(tool))
                        continue
                    }
                    let tone =
                        tool.failed ? DockAccentColor.coral : tool.toolName.map(SessionTraceCanvas.toolTone) ?? .violet
                    let inset: CGFloat = tool.failed ? 5 : 8
                    if batch?.tone != tone || batch?.inset != inset {
                        flush()
                        batch = Batch(tone: tone, inset: inset)
                    }
                    let x = start.timeIntervalSince(origin)
                    let top = y + inset
                    let height = 26 - inset * 2
                    batch?.spans.addRect(CGRect(x: x, y: top, width: max(0, elapsed), height: height))
                    batch?.starts.move(to: CGPoint(x: x, y: top))
                    batch?.starts.addLine(to: CGPoint(x: x, y: top + height))
                }
                flush()
                result[actor.id] = segments
            }
        }
        segmentsByActor = result
    }
}

/// Fit-to-width overview of every lane. The box marks the range the Steps plot shows;
/// clicking or dragging moves it, clicking a span selects that actor, a name filters Steps.
struct SessionActivityLaneChart: View {
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    let lanes: SessionActivityLanes
    let toolGeometry: SessionActivityToolGeometry
    let span: Double
    let origin: Date
    let now: Date
    let replayTime: Double?
    let connected: Bool
    /// Seconds per point in the Steps plot, and its width, for the view box.
    let stepsScale: CGFloat
    let stepsWidth: CGFloat
    @ObservedObject var scroll: SessionTraceScroll
    let selectedRowID: String?
    let filter: String?
    let select: (String) -> Void
    let toggleFilter: (String) -> Void
    let navigate: (Double) -> Void

    private let laneHeight: CGFloat = 26
    private let labelWidth: CGFloat = 112
    @State private var dragging = false

    var body: some View {
        let selectedLane = selectedRowID.flatMap(lanes.lane(owning:))?.id
        let content = SessionActivityLaneLabels(
            lanes: lanes.lanes, selectedLane: selectedLane, origin: origin, replayTime: replayTime,
            connected: connected, filter: filter, select: select, toggleFilter: toggleFilter
        ).equatable()
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth, height: 1)
                GeometryReader { geometry in axis(width: geometry.size.width) }
            }
            .frame(height: 16)
            ViewThatFits(in: .vertical) {
                content.overlay(alignment: .topLeading) { plot }
                ScrollView(.vertical) { content.overlay(alignment: .topLeading) { plot } }
            }
            .frame(maxHeight: laneHeight * 7)
        }
    }

    private var plot: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - labelWidth
            let scale = max(0.0001, width / max(1, span))
            Canvas { context, size in
                draw(in: &context, height: size.height, scale: scale)
            }
            .frame(width: width)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragging || abs(value.translation.width) > 3 {
                            dragging = true
                            navigate(Double(value.location.x / scale))
                        }
                    }
                    .onEnded { value in
                        defer { dragging = false }
                        guard !dragging else { return }
                        let row = Int(value.location.y / laneHeight)
                        let time = Double(value.location.x / scale)
                        let tolerance = Double(4 / scale)
                        if lanes.lanes.indices.contains(row),
                            let actor = lanes.lanes[row].actors.first(where: { actor in
                                guard let range = interval(actor.row) else { return false }
                                return time >= range.lowerBound - tolerance && time <= range.upperBound + tolerance
                            })
                        {
                            select(actor.id)
                        } else {
                            navigate(time)
                        }
                    }
            )
            .offset(x: labelWidth)
        }
        .frame(height: CGFloat(lanes.lanes.count) * laneHeight)
        .accessibilityHidden(true)
    }

    /// Seconds from origin, clipped to the replay playhead; nil when not recorded or not yet reached.
    private func interval(_ row: SessionTraceRow) -> ClosedRange<Double>? {
        guard row.timing != .unavailable, let start = row.start, let elapsed = row.elapsed(at: now) else {
            return nil
        }
        let offset = start.timeIntervalSince(origin)
        if let replayTime {
            guard let visible = SessionTraceReplay.visibleElapsed(offset: offset, elapsed: elapsed, at: replayTime)
            else { return nil }
            return offset...(offset + visible)
        }
        return offset...(offset + elapsed)
    }

    private func draw(in context: inout GraphicsContext, height: CGFloat, scale: CGFloat) {
        let step = Self.tickStep(scale)
        for tick in stride(from: step, through: span, by: step) {
            var line = Path()
            line.move(to: CGPoint(x: tick * scale, y: 0))
            line.addLine(to: CGPoint(x: tick * scale, y: height))
            context.stroke(line, with: .color(Color.dockBorderLight), lineWidth: 0.5)
        }
        for (index, lane) in lanes.lanes.enumerated() {
            let y = CGFloat(index) * laneHeight
            let tone = lane.tone
            var drewSpan = false
            for actor in lane.actors {
                guard let range = interval(actor.row) else { continue }
                drewSpan = true
                let rect = CGRect(
                    x: range.lowerBound * scale, y: y + 5,
                    width: max(3, (range.upperBound - range.lowerBound) * scale), height: laneHeight - 10)
                let shape = Path(roundedRect: rect, cornerRadius: 3)
                let failed = actor.row.failed && replayTime.map { $0 >= range.upperBound } ?? true
                let fill =
                    failed ? DockAccentColor.coral.fill : lane.kind == .main ? Color.dockSecondaryText : tone.fill
                context.fill(shape, with: .color(fill.opacity(lane.kind == .main ? 0.12 : 0.22)))
                context.stroke(shape, with: .color(fill.opacity(0.6)), lineWidth: 1)
                if actor.row.active, connected, replayTime == nil {
                    context.fill(
                        Path(CGRect(x: rect.maxX - 2, y: rect.minY, width: 2, height: rect.height)),
                        with: .color(tone.color))
                }
                if replayTime == nil, let segments = toolGeometry.segmentsByActor[actor.id] {
                    for segment in segments {
                        switch segment {
                        case .batch(let batch):
                            let color = batch.tone.fill
                            var scaled = context
                            scaled.scaleBy(x: scale, y: 1)
                            scaled.fill(batch.spans, with: .color(color))
                            var caps = context
                            caps.translateBy(x: 0.75, y: 0)
                            caps.scaleBy(x: scale, y: 1)
                            caps.stroke(batch.starts, with: .color(color), lineWidth: 1.5 / scale)
                        case .dynamic(let tool):
                            drawTool(tool, in: &context, y: y, scale: scale)
                        }
                    }
                } else {
                    for tool in actor.tools { drawTool(tool, in: &context, y: y, scale: scale) }
                }
            }
            if !drewSpan, replayTime == nil {
                context.draw(
                    Text("Timing unavailable").font(DockTypography.font(.metadata, scale: workspaceScale))
                        .foregroundColor(Color.dockSecondaryText),
                    at: CGPoint(x: 6, y: y + laneHeight / 2), anchor: .leading)
            }
        }
        // Range the Steps plot currently shows; hidden when it already shows everything.
        let start = Double(scroll.x / max(0.0001, stepsScale))
        let length = Double(stepsWidth / max(0.0001, stepsScale))
        if length < span * 0.98 {
            let box = CGRect(
                x: start * scale, y: 0.5, width: max(6, length * scale), height: height - 1)
            context.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(Color.dockPrimaryText.opacity(0.06)))
            context.stroke(
                Path(roundedRect: box, cornerRadius: 3), with: .color(Color.dockPrimaryText.opacity(0.45)),
                lineWidth: 1)
        }
        let live = lanes.lanes.contains { $0.actors.contains { $0.row.active } }
        if let playhead = replayTime ?? (live ? span : nil) {
            var line = Path()
            line.move(to: CGPoint(x: playhead * scale, y: 0))
            line.addLine(to: CGPoint(x: playhead * scale, y: height))
            context.stroke(line, with: .color(Color.dockPrimaryText.opacity(0.65)), lineWidth: 1)
        }
    }

    private func drawTool(_ tool: SessionTraceRow, in context: inout GraphicsContext, y: CGFloat, scale: CGFloat) {
        guard let mark = interval(tool) else { return }
        let failedTool = tool.failed && replayTime.map { $0 >= mark.upperBound } ?? true
        let color: Color =
            failedTool
            ? DockAccentColor.coral.fill
            : tool.kind == .tool
                ? tool.toolName.map(SessionTraceCanvas.toolTone)?.fill ?? DockAccentColor.violet.fill
                : DockAccentColor.violet.fill.opacity(0.75)
        let inset: CGFloat = failedTool ? 5 : 8
        context.fill(
            Path(
                CGRect(
                    x: mark.lowerBound * scale, y: y + inset,
                    width: max(1.5, (mark.upperBound - mark.lowerBound) * scale),
                    height: laneHeight - inset * 2)),
            with: .color(color))
    }

    /// Denser than the Steps ruler: the overview is narrow and never scrolls.
    private static func tickStep(_ scale: CGFloat) -> Double { SessionTraceCanvas.tickStep(scale * 1.6) }

    private func axis(width: CGFloat) -> some View {
        let scale = max(0.0001, width / max(1, span))
        return Canvas { context, size in
            let step = Self.tickStep(scale)
            for tick in stride(from: 0, through: span, by: step) where tick * scale < size.width - 28 {
                context.draw(
                    Text(SessionTraceCanvas.tickLabel(tick)).font(DockTypography.font(.metadata, scale: workspaceScale))
                        .foregroundColor(Color.dockSecondaryText),
                    at: CGPoint(x: tick * scale + 3, y: size.height / 2), anchor: .leading)
            }
        }
    }

}

/// The chart clock changes only its plot; lane labels update when their inputs change.
private struct SessionActivityLaneLabels: View, Equatable {
    let lanes: [SessionActivityLanes.Lane]
    let selectedLane: String?
    let origin: Date
    let replayTime: Double?
    let connected: Bool
    let filter: String?
    let select: (String) -> Void
    let toggleFilter: (String) -> Void
    let laneHeight: CGFloat = 26
    let labelWidth: CGFloat = 112
    let themeRevision = DockThemeRuntime.revision

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lanes == rhs.lanes && lhs.selectedLane == rhs.selectedLane && lhs.origin == rhs.origin
            && lhs.replayTime == rhs.replayTime && lhs.connected == rhs.connected && lhs.filter == rhs.filter
            && lhs.themeRevision == rhs.themeRevision
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(lanes) { lane in
                HStack(spacing: 0) {
                    label(lane)
                    Color.clear
                }
                .frame(height: laneHeight)
                .background(selectedLane == lane.id ? Color.dockSurface2 : Color.clear)
            }
        }
    }

    private func label(_ lane: SessionActivityLanes.Lane) -> some View {
        let latest = lane.actors.last { $0.row.active } ?? lane.actors.last!
        let state = SessionCrewProjection.state(
            latest, at: replayTime.map { origin.addingTimeInterval($0) }, connected: connected)
        let filtered = filter == lane.id
        return Button {
            toggleFilter(lane.id)
        } label: {
            HStack(spacing: 6) {
                face(lane, mood: state.mood)
                Text(lane.name).dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .underline(filtered)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .dockPadding(.horizontal, 4)
            .frame(width: labelWidth, height: laneHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .help(
            "\(kind(lane)) · \(state.label)\n"
                + (filtered ? "Show all steps" : "Show only \(lane.name)'s steps")
        )
        .accessibilityLabel("\(lane.name), \(kind(lane)), \(state.label)")
        .accessibilityValue(filtered ? "Filtering steps" : "")
        .accessibilityHint(filtered ? "Shows all steps" : "Shows only this lane's steps")
        .accessibilityAction(named: "Inspect") { select(latest.id) }
    }

    private func kind(_ lane: SessionActivityLanes.Lane) -> String {
        switch lane.kind {
        case .main: "Main session"
        case .bot: lane.actors.count == 1 ? "Bot" : "Bot · \(lane.actors.count) requests"
        case .subagent: "Subagent"
        }
    }

    @ViewBuilder private func face(_ lane: SessionActivityLanes.Lane, mood: BotMood) -> some View {
        if lane.kind == .bot {
            Canvas { context, _ in
                context.translateBy(x: 1, y: 1)
                BotFaceMark.draw(
                    in: &context, id: lane.identity, size: 16, mood: mood, pose: .rest,
                    theme: DockThemeRuntime.current)
            }
            .frame(width: 18, height: 18)
        } else {
            DockIcon(
                lane.kind == .main ? .chatText : .usersThree, size: 11,
                color: lane.kind == .main ? Color.dockSecondaryText : lane.tone.color
            )
            .frame(width: 18, height: 18)
            .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: 5))
        }
    }
}
