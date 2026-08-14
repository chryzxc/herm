import SwiftUI

struct AgentMapTreeLayout {
    struct Result {
        let positions: [String: CGPoint]
        let rootPosition: CGPoint
        let contentSize: CGSize
    }

    static let horizontalStride: CGFloat = 184
    static let verticalStride: CGFloat = 166
    static let nodeWidth: CGFloat = 132
    static let nodeHeight: CGFloat = 116
    static let maximumColumns = 3
    static let horizontalInset: CGFloat = 48
    static let rootID = "__hermes_root__"

    static func make(agents: [HermesSubagent], minimumSize: CGSize) -> Result {
        var canonicalIDByReference = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.id) })
        for agent in agents {
            if let childSessionID = agent.childSessionID, !childSessionID.isEmpty {
                canonicalIDByReference[childSessionID] = agent.id
            }
        }
        var depthByID: [String: Int] = [:]
        var visiting = Set<String>()
        let parentByID = Dictionary(uniqueKeysWithValues: agents.compactMap { agent -> (String, String)? in
            guard let parentReference = agent.parentID,
                  let parentID = canonicalIDByReference[parentReference],
                  parentID != agent.id else { return nil }
            return (agent.id, parentID)
        })

        var depth: ((String) -> Int)!
        depth = { id in
            if let existing = depthByID[id] { return existing }
            if visiting.contains(id) {
                return 0
            }
            visiting.insert(id)
            let value = parentByID[id].map { depth($0) + 1 } ?? 0
            visiting.remove(id)
            depthByID[id] = value
            return value
        }

        for agent in agents { _ = depth(agent.id) }
        let levels = Dictionary(grouping: agents, by: { depthByID[$0.id] ?? 0 })
        let orderedLevels = levels.keys.sorted()
        let widestRowCount = levels.values.map { min(maximumColumns, $0.count) }.max() ?? 1
        let graphWidth = max(
            minimumSize.width,
            CGFloat(max(0, widestRowCount - 1)) * horizontalStride + nodeWidth + 96
        )
        var rowOffset = 0
        var positions: [String: CGPoint] = [:]
        for level in orderedLevels {
            let agentsAtLevel = (levels[level] ?? []).sorted { $0.id < $1.id }
            let rowsInLevel = Int(ceil(Double(agentsAtLevel.count) / Double(maximumColumns)))
            for (index, agent) in agentsAtLevel.enumerated() {
                let row = index / maximumColumns
                let column = index % maximumColumns
                let x = horizontalInset + nodeWidth / 2 + CGFloat(column) * horizontalStride
                positions[agent.id] = CGPoint(
                    x: x,
                    y: 204 + CGFloat(rowOffset + row) * verticalStride
                )
            }
            rowOffset += rowsInLevel
        }
        let rootY: CGFloat = 76
        let height = max(minimumSize.height, 204 + CGFloat(max(0, rowOffset - 1)) * verticalStride + nodeHeight / 2 + 56)

        return Result(
            positions: positions,
            rootPosition: CGPoint(x: horizontalInset + nodeWidth / 2, y: rootY),
            contentSize: CGSize(width: graphWidth, height: height)
        )
    }
}

/// Inline, read-only visualization of the current Hermes delegation tree.
/// All nodes and connections are projections of DockModel's in-memory live state.
struct AgentHandoffMapView: View {
    @ObservedObject var model: DockModel
    @Binding var selectedAgentID: String?
    var allowsContinuousAnimation = true
    var agents: [HermesSubagent]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flowPhase: CGFloat = 0

    private struct MapNode: Identifiable {
        let id: String
        let parentID: String?
        let childSessionID: String?
        let name: String
        let initials: String
        let role: String
        let status: String
        let activityCount: Int
        let shouldPulse: Bool
        let identityColor: Color
        let statusColor: Color
    }

    private struct MapEdge: Identifiable {
        let id: String
        let sourceID: String
        let targetID: String
        let color: Color
        let isHandoff: Bool
        let isFlowing: Bool
    }

    var body: some View {
        mapSurface
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .onAppear {
            startHandoffFlowIfNeeded()
            model.refreshDelegationStatus()
        }
        .onChange(of: hasActiveFlows) { _, _ in
            startHandoffFlowIfNeeded()
        }
        .onDisappear { flowPhase = 0 }
    }

    private var hasActiveHandoffs: Bool {
        model.agentActivities.contains { $0.agentID != nil && $0.handoffTarget?.isEmpty == false }
    }

    private var activelyWorkingAgentIDs: Set<String> {
        model.agentPresentationSnapshot.activeAgentIDs
            .union(model.activeToolCalls.filter { !$0.isComplete }.compactMap(\.agentID))
    }

    private var hasActiveFlows: Bool {
        hasActiveHandoffs || !activelyWorkingAgentIDs.isEmpty
    }

    private func startHandoffFlowIfNeeded() {
        guard allowsContinuousAnimation, !reduceMotion, hasActiveFlows, agents.count <= 12, flowPhase == 0 else { return }
        // The phase must not finish on a multiple of the dash pattern: that
        // renders identically to its starting position and looks static.
        withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
            flowPhase = -160
        }
    }

    private var mapSurface: some View {
        let layout = AgentMapTreeLayout.make(
            agents: agents,
            minimumSize: CGSize(width: 480, height: 460)
        )
        let mapNodes = nodes
        let mapEdges = edges(for: mapNodes)
        let animateEdges = mapNodes.count <= 12
        let showWideGlow = mapNodes.count <= 6

        // The board owns vertical scrolling. This map has an explicit content
        // height so it cannot paint into the pipeline below it.
        return ScrollView(.horizontal, showsIndicators: true) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.scifiCanvas.opacity(0.86))
                    .overlay(alignment: .topLeading) { grid }
                ambientLight

                Canvas { context, _ in
                    for edge in mapEdges {
                        let source = edge.sourceID == AgentMapTreeLayout.rootID
                            ? layout.rootPosition
                            : layout.positions[edge.sourceID]
                        guard let source, let target = layout.positions[edge.targetID] else { continue }
                        let connection = connectionPath(
                            from: source,
                            to: target,
                            sourceIsRoot: edge.sourceID == AgentMapTreeLayout.rootID
                        )
                        // A quiet base path preserves the topology while the
                        // brighter dash layer reads as live work moving from
                        // the orchestrator toward the active agent.
                        context.stroke(
                            connection.path,
                            with: .color(edge.color.opacity(edge.isHandoff ? 0.5 : 0.22)),
                            style: StrokeStyle(
                                lineWidth: edge.isHandoff ? 2 : 1.2,
                                lineCap: .round
                            )
                        )
                        if edge.isFlowing && allowsContinuousAnimation && animateEdges && showWideGlow && !reduceMotion {
                            context.stroke(
                                connection.path,
                                with: .color(edge.color.opacity(0.32)),
                                style: StrokeStyle(
                                    lineWidth: edge.isHandoff ? 6 : 4.5,
                                    lineCap: .round,
                                    dash: [7, 30],
                                    dashPhase: flowPhase
                                )
                            )
                        }
                        context.stroke(
                            connection.path,
                            with: .color(edge.color.opacity(edge.isHandoff ? 1 : 0.95)),
                            style: StrokeStyle(
                                lineWidth: edge.isHandoff ? 2 : 1.2,
                                lineCap: .round,
                                dash: edge.isFlowing && allowsContinuousAnimation && animateEdges ? [10, 18] : [],
                                dashPhase: edge.isFlowing && allowsContinuousAnimation && animateEdges && !reduceMotion ? flowPhase : 0
                            )
                        )
                        context.fill(arrowhead(at: connection.end, direction: connection.direction), with: .color(edge.color.opacity(0.9)))
                    }
                }
                .allowsHitTesting(false)

                rootNode
                    .position(layout.rootPosition)

                ForEach(mapNodes) { node in
                    agentNode(node)
                        .position(layout.positions[node.id] ?? .zero)
                }
            }
            .frame(width: layout.contentSize.width, height: layout.contentSize.height)
        }
        .frame(minWidth: min(layout.contentSize.width, 480))
        .frame(height: layout.contentSize.height)
        .background(Color.scifiCanvas.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.scifiBorderStrong, lineWidth: 0.5))
    }

    private var grid: some View {
        Canvas { context, size in
            let spacing: CGFloat = 36
            var path = Path()
            stride(from: CGFloat.zero, through: size.width, by: spacing).forEach { x in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(from: CGFloat.zero, through: size.height, by: spacing).forEach { y in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(Color.white.opacity(0.018)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private var rootNode: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.scifiAccent.opacity(0.18), lineWidth: 7)
                    .frame(width: 68, height: 68)
                Circle().fill(Color.scifiAccent.opacity(0.12))
                Circle().stroke(Color.scifiAccent, lineWidth: 1.5)
                Text("H")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.scifiFg)
            }
            .frame(width: 62, height: 62)
            .shadow(color: Color.scifiAccentGlow, radius: 14)
            Text("HERMES")
                .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.scifiFg)
            Text("ORCHESTRATOR")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.scifiTertiary)
        }
        .frame(width: 132, height: 116)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hermes orchestrator")
    }

    private func agentNode(_ node: MapNode) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .scifiEase(duration: 0.2)) {
                selectedAgentID = selectedAgentID == node.id ? nil : node.id
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if node.shouldPulse && allowsContinuousAnimation && !reduceMotion {
                        RunningAgentPulse(color: node.statusColor)
                    }
                    // The opaque base intentionally masks connectors beneath
                    // the circular identity mark so its glyph stays legible.
                    Circle().fill(Color.scifiCanvas)
                    Circle().fill(node.identityColor.opacity(0.18))
                    Circle().stroke(node.identityColor, lineWidth: selectedAgentID == node.id ? 2.5 : 1.5)
                    Text(node.initials)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.scifiFg)
                }
                .frame(width: 58, height: 58)
                .overlay(alignment: .bottomTrailing) {
                    if node.activityCount > 0 {
                        Text("\(node.activityCount)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.scifiBg)
                            .frame(minWidth: 17, minHeight: 17)
                            .background(Circle().fill(node.statusColor))
                            .overlay(Circle().stroke(Color.scifiCanvas, lineWidth: 2))
                            .offset(x: 4, y: 4)
                    }
                }
                .shadow(color: node.identityColor.opacity(selectedAgentID == node.id ? 0.42 : 0.16), radius: selectedAgentID == node.id ? 12 : 6)
                Text(node.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.scifiFg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: AgentMapTreeLayout.nodeWidth)
                Text(node.role)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.scifiMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: AgentMapTreeLayout.nodeWidth)
                Text("\(node.activityCount) \(node.activityCount == 1 ? "EVENT" : "EVENTS") · \(node.status.uppercased())")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(node.statusColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: AgentMapTreeLayout.nodeWidth)
            }
            .frame(width: AgentMapTreeLayout.nodeWidth, height: AgentMapTreeLayout.nodeHeight, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(node.name), \(node.status), \(node.activityCount) events. Click to \(selectedAgentID == node.id ? "close" : "inspect") activity.")
    }

    private var ambientLight: some View {
        ZStack {
            Circle().fill(Color.scifiAccent.opacity(0.09)).frame(width: 300, height: 300).blur(radius: 100).offset(x: -120, y: -120)
            Circle().fill(Color.scifiSuccess.opacity(0.04)).frame(width: 260, height: 260).blur(radius: 110).offset(x: 150, y: 140)
        }
        .allowsHitTesting(false)
    }

    private func connectionPath(from source: CGPoint, to target: CGPoint, sourceIsRoot: Bool) -> (path: Path, end: CGPoint, direction: CGFloat) {
        // Node positions refer to the centre of their 132 × 116 container;
        // the icon circles occupy its top 58pt. Anchor to the actual circle
        // edges, not the container centre, so paths never cross node labels.
        let sourceCircleBottom = source.y + (sourceIsRoot ? 4 : 0)
        let targetCircleTop = target.y - AgentMapTreeLayout.nodeHeight / 2
        let start = CGPoint(x: source.x, y: sourceCircleBottom)
        let end = CGPoint(x: target.x, y: targetCircleTop)
        let distance = max(44, abs(end.y - start.y) * 0.46)
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x, y: start.y + distance),
            control2: CGPoint(x: end.x, y: end.y - distance)
        )
        return (path, end, target.y >= source.y ? 1 : -1)
    }

    private func arrowhead(at point: CGPoint, direction: CGFloat) -> Path {
        var path = Path()
        path.move(to: point)
        path.addLine(to: CGPoint(x: point.x - 4.5, y: point.y - direction * 8))
        path.addLine(to: CGPoint(x: point.x + 4.5, y: point.y - direction * 8))
        path.closeSubpath()
        return path
    }

    private var nodes: [MapNode] {
        return agents.map { agent in
            let name = agent.name ?? agent.role ?? "Agent"
            return MapNode(
                id: agent.id,
                parentID: agent.parentID,
                childSessionID: agent.childSessionID,
                name: name,
                initials: initials(name),
                role: nodeDetail(for: agent, displayName: name),
                status: agent.status,
                activityCount: activityCount(for: agent),
                shouldPulse: activelyWorkingAgentIDs.contains(agent.id),
                identityColor: identityColor(for: agent.id),
                statusColor: statusColor(for: agent.status)
            )
        }
    }

    private func edges(for nodes: [MapNode]) -> [MapEdge] {
        var canonicalIDByReference = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.id) })
        for node in nodes {
            if let childSessionID = node.childSessionID, !childSessionID.isEmpty {
                canonicalIDByReference[childSessionID] = node.id
            }
        }
        let flowingAgentIDs = activelyWorkingAgentIDs
        var values = nodes.map { node in
            MapEdge(
                id: "tree:\(node.id)",
                sourceID: node.parentID.flatMap { canonicalIDByReference[$0] } ?? AgentMapTreeLayout.rootID,
                targetID: node.id,
                color: isActive(node.status) ? .scifiAccent : Color.scifiBorderLight,
                isHandoff: false,
                isFlowing: flowingAgentIDs.contains(node.id)
            )
        }

        let handoffs = model.agentActivities.compactMap { activity -> MapEdge? in
            guard let sourceID = activity.agentID,
                  let source = nodes.first(where: { $0.id == sourceID }),
                  let targetValue = activity.handoffTarget?.lowercased(),
                  let target = nodes.first(where: { $0.id.lowercased() == targetValue || $0.name.lowercased() == targetValue }),
                  source.id != target.id else { return nil }
            return MapEdge(
                id: "handoff:\(activity.id.uuidString)",
                sourceID: source.id,
                targetID: target.id,
                color: .scifiAccent,
                isHandoff: true,
                isFlowing: true
            )
        }
        values.append(contentsOf: handoffs)
        return values
    }

    private func initials(_ value: String) -> String {
        let value = String(value.split(separator: " ").prefix(2).compactMap(\.first))
        return value.isEmpty ? "A" : value.uppercased()
    }

    private func activityCount(for agent: HermesSubagent) -> Int {
        activityCountsByAgentID[agent.id, default: 0]
    }

    /// Materialize the shared pipeline only once for the node collection,
    /// instead of rebuilding it once per agent badge during live updates.
    private var activityCountsByAgentID: [String: Int] {
        model.agentPresentationSnapshot.activityCountsByAgentID
    }

    private func nodeDetail(for agent: HermesSubagent, displayName: String) -> String {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = [agent.role, agent.sourceSkill, agent.model]
        return candidates.compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.lowercased() != normalizedName else { return nil }
            return trimmed
        }.first ?? "Hermes delegate"
    }

    private func identityColor(for id: String) -> Color {
        let palette: [Color] = [
            .scifiAccent,
            Color(red: 0.78, green: 0.38, blue: 1),
            Color(red: 1, green: 0.48, blue: 0.36),
            Color(red: 0.25, green: 0.86, blue: 0.72),
            Color(red: 1, green: 0.72, blue: 0.28),
            Color(red: 0.42, green: 0.62, blue: 1)
        ]
        return palette[stableHash(id) % palette.count]
    }

    private func statusColor(for status: String) -> Color {
        let value = status.lowercased()
        if value.contains("complete") || value.contains("done") || value.contains("finish") { return .scifiSuccess }
        if value.contains("fail") || value.contains("error") { return .scifiDestructive }
        if value.contains("block") || value.contains("interrupt") || value.contains("approval") { return .scifiWarning }
        if value.contains("queue") || value.contains("pending") { return .scifiMuted }
        return .scifiAccent
    }

    private func isActive(_ status: String) -> Bool {
        let value = status.lowercased()
        return value.contains("running") || value.contains("working") || value.contains("finalizing")
    }

    private func stableHash(_ id: String) -> Int {
        let hash = id.utf8.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) }
        return Int(hash % UInt64(Int.max))
    }

}
