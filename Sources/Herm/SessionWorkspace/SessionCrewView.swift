import SwiftUI

enum SessionCrewDisplay: Hashable { case list, tree }

/// Delegates as a flat list, or as the delegation tree that led to them. Rows follow
/// Timeline's clock and selection; the view never launches work.
struct SessionCrewView: View {
    let projection: SessionCrewProjection
    let members: [SessionCrewProjection.Actor]
    let display: SessionCrewDisplay
    let selectedRowID: String?
    let replayDate: Date?
    let now: Date
    let connected: Bool
    let animated: Bool
    var empty = "No bots recorded in this selection"
    let select: (String?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var focus = HermFocus.shared

    private var owner: String? { selectedRowID.flatMap { projection.ownerByRow[$0] } }
    private var motion: Bool { animated && !reduceMotion && focus.engaged && DockThemeStyle.current.animates }

    private var lines: [SessionCrewOutline.Line] {
        if display == .tree { return SessionCrewOutline.lines(projection.actors, members: Set(members.map(\.id))) }
        // A Bot with several dispatches shows the instance that owns the selection.
        let selected = projection.actors.first { $0.id == owner }
        return members.map { actor in
            SessionCrewOutline.Line(
                actor: selected?.identity == actor.identity ? selected! : actor, depth: 0, member: true)
        }
    }

    var body: some View {
        let lines = lines
        if lines.isEmpty {
            Text(empty).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                .frame(maxWidth: .infinity, minHeight: 36)
        } else {
            let rows = VStack(spacing: 0) {
                ForEach(lines) { row($0) }
            }
            ViewThatFits(in: .vertical) {
                rows
                ScrollView(.vertical) { rows }
            }
            .frame(maxHeight: 220)
        }
    }

    private func row(_ line: SessionCrewOutline.Line) -> some View {
        let actor = line.actor
        let state = SessionCrewProjection.state(actor, at: replayDate, connected: connected)
        let selected = owner == actor.id
        let detail = actor.row.input.map(SessionTraceProjection.taskTitle) ?? actor.row.title
        return Button {
            select(actor.id)
        } label: {
            HStack(spacing: 8) {
                guides(line.depth)
                avatar(actor, state: state)
                VStack(alignment: .leading, spacing: 1) {
                    Text(actor.name).dockFont(.metadata, weight: .semibold)
                        .foregroundStyle(line.member ? Color.dockPrimaryText : Color.dockSecondaryText)
                    if detail != actor.name {
                        Text(detail).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                if line.member { status(state) }
                if state.visible, let start = actor.row.start {
                    Text(start.formatted(date: .omitted, time: .shortened))
                        .dockFont(.metadata).monospacedDigit().foregroundStyle(Color.dockSecondaryText)
                        .help(start.formatted(date: .abbreviated, time: .standard))
                }
                if line.member {
                    // Replay must not leak the final duration before the row ends.
                    if replayDate == nil {
                        Text(actor.row.elapsed(at: now).map(Self.duration) ?? "—")
                            .dockFont(.metadata).monospacedDigit().foregroundStyle(Color.dockSecondaryText)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 8).frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.dockSurface2 : Color.clear)
            .contentShape(Rectangle())
            .opacity(state.visible ? 1 : 0.35)
        }
        .buttonStyle(.dockHover)
        .accessibilityLabel("\(actor.name), \(actor.kind), \(state.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(actor.kind): \(actor.row.input ?? actor.row.title)\n\(state.label)")
    }

    /// One rail per ancestor; the last carries a branch tick into the row.
    private func guides(_ depth: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { level in
                ZStack {
                    Color.dockBorderLight.frame(width: 1)
                    if level == depth - 1 {
                        Color.dockBorderLight.frame(width: 7, height: 1).offset(x: 4)
                    }
                }
                .frame(width: 16)
            }
        }
    }

    @ViewBuilder private func avatar(_ actor: SessionCrewProjection.Actor, state: SessionCrewProjection.State)
        -> some View
    {
        if actor.row.crewProfileID != nil {
            let clock = replayDate ?? now.addingTimeInterval(-actor.row.shift)
            let moving = motion && state.moving && (replayDate != nil || connected)
            let pose = moving ? BotFacePose.at(clock.timeIntervalSinceReferenceDate, busy: true) : .rest
            Canvas { context, _ in
                context.translateBy(x: 1, y: 1)
                BotFaceMark.draw(
                    in: &context, id: actor.identity, size: 22, mood: state.mood, pose: pose,
                    theme: DockThemeRuntime.current)
            }
            .frame(width: 24, height: 24)
        } else {
            DockIcon(actor.row.kind == .turn ? .chatText : .usersThree, size: 13, color: Color.dockSecondaryText)
                .frame(width: 24, height: 24)
                .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Settled outcomes read as a glyph; anything else keeps its words.
    @ViewBuilder private func status(_ state: SessionCrewProjection.State) -> some View {
        switch state.mood {
        case .done:
            DockIcon(.checkCircle, size: 13, color: Color.dockSuccess).accessibilityLabel(state.label)
        case .failed:
            HStack(spacing: 4) {
                DockIcon(.xCircle, size: 13, color: Color.dockDestructive)
                Text(state.label)
            }
            .dockFont(.metadata).foregroundStyle(Color.dockDestructive)
        default:
            HStack(spacing: 4) {
                if state.moving { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                Text(state.label).lineLimit(1)
            }
            .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
        }
    }

    static func duration(_ seconds: Double) -> String {
        if seconds >= 60 { return String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60) }
        return seconds < 10 ? String(format: "%.1fs", seconds) : String(format: "%.0fs", seconds)
    }
}

/// Members plus the actors that delegated to them, depth-first in recorded order.
enum SessionCrewOutline {
    struct Line: Identifiable {
        let actor: SessionCrewProjection.Actor
        let depth: Int
        let member: Bool
        var id: String { actor.id }
    }

    static func lines(_ actors: [SessionCrewProjection.Actor], members: Set<String>) -> [Line] {
        let byID = Dictionary(actors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var included = Set<String>()
        for id in members {
            var cursor: String? = id
            while let next = cursor, byID[next] != nil, included.insert(next).inserted {
                cursor = byID[next]?.parentID
            }
        }
        let kept = actors.filter { included.contains($0.id) }
        let children = Dictionary(grouping: kept) { $0.parentID ?? "" }
        var lines: [Line] = []
        var seen = Set<String>()
        func visit(_ actor: SessionCrewProjection.Actor, depth: Int) {
            guard seen.insert(actor.id).inserted else { return }
            lines.append(Line(actor: actor, depth: depth, member: members.contains(actor.id)))
            for child in children[actor.id] ?? [] { visit(child, depth: depth + 1) }
        }
        for actor in kept where actor.parentID.map({ !included.contains($0) }) ?? true { visit(actor, depth: 0) }
        return lines
    }
}
