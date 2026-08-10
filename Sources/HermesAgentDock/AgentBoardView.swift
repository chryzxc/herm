import SwiftUI

/// Compact, glassmorphism-first live overview for the menubar popup's agents.
/// The board follows DESIGN.md's window anatomy and is backed by Hermes runtime state.
struct AgentBoardView: View {
    @ObservedObject var model: DockModel
    var onClose: () -> Void = {}
    var embedded = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var expandedAgentID: String?
    @State private var expandedActivityID: UUID?
    @State private var expandedPipelineItemID: String?

    private struct Agent: Identifiable {
        let id: String
        let initials: String
        let name: String
        let specialty: String
        let status: String
        let activity: String
        let diffPreview: String?
        let statusColor: Color
        let agentColor: Color
    }

    private struct PipelineItem: Identifiable {
        let id: String
        let timestamp: Date
        let status: String
        let task: String
        let agent: String
        let time: String
        let color: Color
        let detail: String?
        let diffPreview: String?
    }

    var body: some View {
        ZStack {
            // Embedded mode belongs to the Control pane and must inherit its
            // dark glass surface instead of introducing a separate black block.
            embedded ? Color.clear : Color.black
            if !embedded { ambientLight }

            VStack(spacing: 0) {
                if !embedded { titlebar }
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeading("ACTIVE AGENTS", detail: dataSource)
                        if agents.isEmpty {
                            emptyState(title: "No active Hermes subagents", detail: "Delegate work from Hermes to see named agents and live activity here.")
                        } else {
                            agentsGrid
                        }
                        sectionHeading("ACTIVE PIPELINE", detail: "\(pipeline.count) ITEMS")
                        if pipeline.isEmpty {
                            emptyState(title: "No live activity", detail: "The pipeline will populate when a Hermes subagent starts work.")
                        } else {
                            pipelineList
                        }
                    }
                    .padding(embedded ? 0 : 20)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: embedded ? 0 : 14, style: .continuous))
        .overlay {
            if !embedded {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.scifiBorderStrong, lineWidth: 0.5)
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [Color.white.opacity(0.28), Color.white.opacity(0.04), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(height: 0.5)
                    }
            }
        }
        .shadow(color: .black.opacity(embedded ? 0 : 0.5), radius: 32, y: 18)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.scifiEase(duration: 0.32)) { appeared = true }
            }
        }
    }

    private var ambientLight: some View {
        ZStack {
            Circle()
                .fill(Color.scifiAccent.opacity(embedded ? 0.045 : 0.12))
                .frame(width: 260, height: 260)
                .blur(radius: 80)
                .offset(x: -230, y: -220)
            Circle()
                .fill(Color(red: 0.02, green: 0.16, blue: 0.38).opacity(embedded ? 0.06 : 0.18))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(x: 250, y: 180)
        }
        .allowsHitTesting(false)
    }

    private var titlebar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                trafficLight(.scifiDestructive, label: "Close")
                trafficLight(.scifiWarning, label: "Minimize")
                trafficLight(.scifiSuccess, label: "Zoom")
            }
            .frame(width: 62, alignment: .leading)

            Spacer()
            Text("HERMES AGENT BOARD")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(1.15)
                .foregroundStyle(Color.scifiMuted)
            Spacer()

            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.scifiMuted)
                    .frame(width: 36, height: 36)
                    .background(Color.scifiSurface4)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.scifiPress)
            .frame(minWidth: 44, minHeight: 44)
            .help("Return to chat")
            .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Color.scifiSurface2)
        .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
    }

    private func trafficLight(_ color: Color, label: String) -> some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 0.5))
            .shadow(color: color.opacity(0.25), radius: 2)
            .help(label)
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.scifiMuted)
            Spacer()
            Text(detail)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.scifiTertiary)
        }
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 13))
                .foregroundStyle(Color.scifiTertiary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.scifiFg)
            Text(detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.scifiMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var agentsGrid: some View {
        if embedded {
            VStack(spacing: 0) {
                ForEach(agents) { agent in
                    agentTile(agent)
                }
            }
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(agents) { agent in
                    agentTile(agent)
                }
            }
        }
    }

    private func agentTile(_ agent: Agent) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .scifiEase(duration: 0.22)) {
                expandedAgentID = expandedAgentID == agent.id ? nil : agent.id
            }
        } label: {
            VStack(alignment: .leading, spacing: embedded ? 6 : 13) {
            HStack(spacing: 10) {
                agentOrb(agent)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.scifiFg)
                        .lineLimit(1)
                    Text(agent.specialty)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.scifiMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                statusBadge(agent.status, color: agent.statusColor)
            }

            Rectangle().fill(Color.scifiBorderLight).frame(height: 0.5)

            Text(agent.activity)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.scifiMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let diffPreview = agent.diffPreview {
                miniDiffPreview(diffPreview)
            }
            if expandedAgentID == agent.id {
                expandedActivity(for: agent)
            }
            }
            .padding(embedded ? 8 : 14)
            .background(embedded ? Color.clear : Color.scifiSurface)
            .overlay {
                if embedded {
                    VStack { Spacer(); Color.scifiBorderLight.frame(height: 0.5) }
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(expandedAgentID == agent.id ? agent.agentColor.opacity(0.8) : Color.scifiBorderStrong, lineWidth: expandedAgentID == agent.id ? 1 : 0.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: embedded ? 8 : 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("\(agent.name), \(agent.status). Click to \(expandedAgentID == agent.id ? "collapse" : "expand") activity.")
    }

    private func agentOrb(_ agent: Agent) -> some View {
        ZStack {
            Circle().fill(agent.agentColor.opacity(0.12))
            Circle().stroke(agent.agentColor.opacity(0.7), lineWidth: 0.6)
            Circle().trim(from: 0.08, to: 0.42)
                .stroke(agent.agentColor, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .rotationEffect(.degrees(Double(abs(agent.id.hashValue % 360))))
                .padding(4)
            Text(agent.initials)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.scifiFg)
        }
        .shadow(color: agent.agentColor.opacity(0.28), radius: 6)
    }

    private func expandedActivity(for agent: Agent) -> some View {
        let activities = model.agentActivities
            .filter { $0.agentID == agent.id }
            .sorted { $0.timestamp > $1.timestamp }
        let pending = activities.filter { activityStatus(for: $0.kind) == "Pending" }
        let running = activities.filter { activityStatus(for: $0.kind) == "Running" }
        let completed = activities.filter {
            ["Completed", "Failed", "Interrupted"].contains(activityStatus(for: $0.kind))
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ACTIVITY HISTORY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(agent.agentColor)
                Spacer()
                Text("\(activities.count) EVENTS")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
            }
            if activities.isEmpty {
                Text("No Hermes activity has been received for this agent yet.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
            } else {
                activityGroup("PENDING", items: pending, color: Color.scifiMuted, agentColor: agent.agentColor)
                activityGroup("RUNNING", items: running, color: agent.agentColor, agentColor: agent.agentColor)
                activityGroup("COMPLETED", items: completed, color: Color.scifiSuccess, agentColor: agent.agentColor)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func activityGroup(_ title: String, items: [AgentActivity], color: Color, agentColor: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title)  ·  \(items.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                ForEach(items) { activity in
                    Button {
                        withAnimation(reduceMotion ? nil : .scifiEase(duration: 0.18)) {
                            expandedActivityID = expandedActivityID == activity.id ? nil : activity.id
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 7) {
                                Circle().fill(color).frame(width: 5, height: 5).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(activity.kind.replacingOccurrences(of: "subagent.", with: "").uppercased())
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(agentColor)
                                        Text(HumanDateFormatting.timeOnly(activity.timestamp))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Color.scifiTertiary)
                                    }
                                    Text(activity.text)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Color.scifiMuted)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: expandedActivityID == activity.id ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color.scifiTertiary)
                            }
                            if expandedActivityID == activity.id {
                                activityContent(activity, accent: agentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }
        }
    }

    private func statusBadge(_ status: String, color: Color) -> some View {
        Text(status.uppercased())
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .tracking(0.55)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var pipelineList: some View {
        let timeColumnWidth: CGFloat = 68

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                pipelineHeader("STATUS", width: 76)
                pipelineHeader("TASK", width: nil)
                pipelineHeader("AGENT", width: 88)
                pipelineHeader("TIME", width: timeColumnWidth)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            ForEach(pipeline) { item in
                VStack(alignment: .leading, spacing: 7) {
                    Button {
                        withAnimation(reduceMotion ? nil : .scifiEase(duration: 0.18)) {
                            expandedPipelineItemID = expandedPipelineItemID == item.id ? nil : item.id
                        }
                    } label: {
                        HStack(spacing: 10) {
                            HStack(spacing: 6) {
                                pipelineStatusIndicator(for: item)
                                Text(item.status)
                            }
                            .frame(width: 76, alignment: .leading)
                            Text(item.task).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                            Text(item.agent).foregroundStyle(Color.scifiAccent).frame(width: 88, alignment: .leading).lineLimit(1)
                            Text(item.time)
                                .foregroundStyle(Color.scifiMuted)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(width: timeColumnWidth, alignment: .trailing)
                            Image(systemName: expandedPipelineItemID == item.id ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.scifiTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    if expandedPipelineItemID == item.id {
                        pipelineContent(item)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.scifiFg)
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Color.scifiBorderLight.frame(height: 0.5) }
            }
        }
    }

    @ViewBuilder
    private func activityContent(_ activity: AgentActivity, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let toolName = activity.toolName {
                contentField("TOOL", toolName, accent: accent)
            }
            if let handoffTarget = activity.handoffTarget {
                contentField("HANDOFF", handoffTarget, accent: accent)
            }
            contentField("DETAIL", activity.text, accent: accent)
            if let diffPreview = activity.diffPreview {
                miniDiffPreview(diffPreview)
            }
        }
        .padding(.leading, 12)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func pipelineContent(_ item: PipelineItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let detail = item.detail {
                contentField("DETAIL", detail, accent: item.color)
            }
            if let diffPreview = item.diffPreview {
                miniDiffPreview(diffPreview)
            }
        }
        .padding(.leading, 12)
        .padding(.top, 2)
    }

    private func contentField(_ label: String, _ value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(accent)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.scifiMuted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func miniDiffPreview(_ diff: String) -> some View {
        let allLines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lines = Array(allLines.prefix(4))

        return VStack(alignment: .leading, spacing: 2) {
            Text(allLines.count > lines.count ? "DIFF PREVIEW · \(lines.count)/\(allLines.count) LINES" : "DIFF PREVIEW")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(Color.scifiTertiary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(diffLineColor(line))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.scifiSurface4)
        .overlay(alignment: .leading) { Color.scifiAccent.opacity(0.55).frame(width: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Diff preview: \(lines.joined(separator: ", "))")
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .scifiTertiary }
        if line.hasPrefix("+") { return .scifiSuccess }
        if line.hasPrefix("-") { return .scifiDestructive }
        if line.hasPrefix("@@") { return .scifiAccent }
        return .scifiMuted
    }

    @ViewBuilder
    private func pipelineHeader(_ title: String, width: CGFloat?) -> some View {
        let label = Text(title)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(Color.scifiMuted)

        if let width {
            label.frame(width: width, alignment: .leading)
        } else {
            label.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func pipelineStatusIndicator(for item: PipelineItem) -> some View {
        if isInProgress(item.status) {
            ProgressView()
                .controlSize(.mini)
                .tint(item.color)
                .frame(width: 5, height: 5)
        } else {
            Circle()
                .fill(item.color)
                .frame(width: 5, height: 5)
        }
    }

    private func isInProgress(_ status: String) -> Bool {
        let normalized = status
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return ["running", "in_progress", "inprogress"].contains(normalized)
    }

    private var dataSource: String {
        model.activeSubagents.isEmpty ? "NO ACTIVE SUBAGENTS" : "LIVE HERMES STATE"
    }

    private var agents: [Agent] {
        return model.activeSubagents.map { subagent in
            let name = subagent.name ?? subagent.role ?? "Agent"
            let activity = latestActivity(for: subagent) ?? subagent.latestActivity ?? subagent.goal
            return Agent(
                id: subagent.id,
                initials: initials(name),
                name: name,
                specialty: subagent.sourceSkill ?? subagent.model ?? "Hermes delegate",
                status: subagent.status,
                activity: activity,
                diffPreview: latestDiffPreview(for: subagent),
                statusColor: color(for: subagent.status),
                agentColor: agentColor(for: subagent.id)
            )
        }
    }

    private func latestActivity(for agent: HermesSubagent) -> String? {
        model.agentActivities
            .filter { $0.agentID == agent.id && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.timestamp > $1.timestamp }
            .first?
            .text
    }

    private func latestDiffPreview(for agent: HermesSubagent) -> String? {
        model.agentActivities
            .filter { $0.agentID == agent.id && $0.diffPreview != nil }
            .sorted { $0.timestamp > $1.timestamp }
            .first?
            .diffPreview
    }

    private var pipeline: [PipelineItem] {
        var liveRows: [PipelineItem] = model.agentActivities
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(6)
            .map { activity in
                let status = activityStatus(for: activity.kind)
                return PipelineItem(
                    id: "activity:\(activity.id.uuidString)",
                    timestamp: activity.timestamp,
                    status: status,
                    task: activity.text,
                    agent: activity.agentID.flatMap { id in
                        model.activeSubagents.first(where: { $0.id == id }).map { $0.name ?? $0.role ?? "Agent" }
                    } ?? "Hermes",
                    time: HumanDateFormatting.timeOnly(activity.timestamp),
                    color: color(for: status),
                    detail: activityDetail(for: activity),
                    diffPreview: activity.diffPreview
                )
            }

        // Tool calls belong to Hermes' primary process, not only to delegated
        // agents. Keep them visible in the pipeline even when no subagent exists.
        liveRows.append(contentsOf: model.activeToolCalls.map { call in
            PipelineItem(
                id: "tool:\(call.id)",
                timestamp: call.startedAt,
                status: call.isComplete ? "Complete" : "Running",
                task: call.input.isEmpty ? call.name : "\(call.name): \(call.input)",
                agent: "Hermes",
                time: HumanDateFormatting.timeOnly(call.startedAt),
                color: call.isComplete ? .scifiSuccess : .scifiAccent,
                detail: toolDetail(for: call),
                diffPreview: call.diffPreview
            )
        })

        if !liveRows.isEmpty {
            return liveRows.sorted { $0.timestamp > $1.timestamp }
        }

        if !model.activeSubagents.isEmpty {
            return model.activeSubagents.map { agent in
                PipelineItem(
                    id: "agent:\(agent.id)",
                    timestamp: agent.startedAt ?? .distantPast,
                    status: agent.status,
                    task: agent.goal,
                    agent: agent.name ?? agent.role ?? "Agent",
                    time: agent.startedAt.map { HumanDateFormatting.timeOnly($0) } ?? "—",
                    color: color(for: agent.status),
                    detail: agent.summary ?? agent.latestActivity ?? agent.goal,
                    diffPreview: latestDiffPreview(for: agent)
                )
            }
        }

        return []
    }

    private func initials(_ value: String) -> String {
        let result = String(value.split(separator: " ").prefix(2).compactMap { $0.first })
        return result.isEmpty ? "A" : result.uppercased()
    }

    private func activityStatus(for kind: String) -> String {
        let lower = kind.lowercased()
        if lower.contains("complete") || lower.contains("finish") { return "Complete" }
        if lower.contains("error") || lower.contains("fail") { return "Failed" }
        if lower.contains("interrupt") { return "Interrupted" }
        if lower.contains("queue") || lower.contains("spawn_requested") { return "Pending" }
        if lower.hasPrefix("subagent.") { return "Running" }
        return kind
    }

    private func activityDetail(for activity: AgentActivity) -> String {
        var details = [activity.text]
        if let toolName = activity.toolName { details.append("Tool: \(toolName)") }
        if let handoffTarget = activity.handoffTarget { details.append("Handoff target: \(handoffTarget)") }
        return details.joined(separator: "\n")
    }

    private func toolDetail(for call: ActiveToolCall) -> String {
        var details = [call.input.isEmpty ? call.name : "Input: \(call.input)"]
        if let result = call.result, !result.isEmpty { details.append("Result: \(result)") }
        return details.joined(separator: "\n")
    }

    private func color(for status: String) -> Color {
        let lower = status.lowercased()
        if lower.contains("complete") || lower.contains("done") || lower.contains("finish") { return .scifiSuccess }
        if lower.contains("error") || lower.contains("fail") { return .scifiDestructive }
        if lower.contains("block") || lower.contains("approval") || lower.contains("interrupt") { return .scifiWarning }
        if lower.contains("queue") { return .scifiMuted }
        return .scifiAccent
    }

    private func agentColor(for id: String) -> Color {
        let palette: [Color] = [
            .scifiAccent,
            Color(red: 0.78, green: 0.38, blue: 1.0),
            Color(red: 1.0, green: 0.48, blue: 0.36),
            Color(red: 0.25, green: 0.86, blue: 0.72),
            Color(red: 1.0, green: 0.72, blue: 0.28),
            Color(red: 0.42, green: 0.62, blue: 1.0)
        ]
        let hash = id.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return palette[abs(hash) % palette.count]
    }
}
