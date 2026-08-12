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
    @State private var expandedActivityID: String?
    @State private var expandedPipelineItemID: String?

    private struct Agent: Identifiable {
        let id: String
        let agentColor: Color
    }

    private struct PipelineItem: Identifiable {
        let id: String
        let agentID: String?
        let timestamp: Date
        let status: String
        let task: String
        let agent: String
        let time: String
        let startedAt: Date?
        let completedAt: Date?
        let durationSeconds: TimeInterval?
        let isActive: Bool
        let color: Color
        let detail: String?
        let diffPreview: String?
    }

    var body: some View {
        let pipelineItems = pipeline
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
                        agentSectionContent
                        sectionHeading("ACTIVE PIPELINE", detail: "\(pipelineItems.count) ITEMS")
                        if pipelineItems.isEmpty {
                            emptyState(title: "No live activity", detail: "The pipeline will populate when a Hermes subagent starts work.")
                        } else {
                            pipelineList(pipelineItems)
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

    @ViewBuilder
    private var agentSectionContent: some View {
        if agents.isEmpty {
            emptyState(title: "No active Hermes subagents", detail: "Delegate work from Hermes to see named agents and live activity here.")
        } else {
            AgentHandoffMapView(model: model, selectedAgentID: $expandedAgentID)
                .frame(height: 460)
            if let selectedAgent = agents.first(where: { $0.id == expandedAgentID }) {
                expandedActivity(for: selectedAgent)
                    .padding(12)
                    .background(Color.scifiSurface4)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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

    private func expandedActivity(for agent: Agent) -> some View {
        // The node inspector and the pipeline intentionally share the same
        // projection. A tool call already attributed to Architect/Security in
        // the pipeline must also appear in that worker's node history.
        let activities = pipeline
            .filter { $0.agentID == agent.id }
            .sorted { $0.timestamp > $1.timestamp }
        let pending = activities.filter { $0.status.localizedCaseInsensitiveContains("pending") }
        let running = activities.filter { isInProgress($0.status) }
        let completed = activities.filter { !$0.status.localizedCaseInsensitiveContains("pending") && !isInProgress($0.status) }

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
    private func activityGroup(_ title: String, items: [PipelineItem], color: Color, agentColor: Color) -> some View {
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
                                        Text(activity.status.uppercased())
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(agentColor)
                                        if !activity.agent.isEmpty {
                                            Text("·")
                                                .foregroundStyle(Color.scifiTertiary)
                                            Text(activity.agent)
                                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(agentColor)
                                                .lineLimit(1)
                                        }
                                        Text(HumanDateFormatting.timeOnly(activity.timestamp))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Color.scifiTertiary)
                                    }
                                    Text(activity.task)
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
                                pipelineContent(activity)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }
        }
    }

    private func pipelineList(_ items: [PipelineItem]) -> some View {
        let timeColumnWidth: CGFloat = 68
        let durationColumnWidth: CGFloat = 72

        return LazyVStack(spacing: 0) {
            HStack(spacing: 10) {
                pipelineHeader("STATUS", width: 76)
                pipelineHeader("TASK", width: nil)
                pipelineHeader("AGENT", width: 88)
                pipelineHeader("TIME", width: timeColumnWidth)
                pipelineHeader("DURATION", width: durationColumnWidth, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            ForEach(items) { item in
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
                            pipelineDuration(item)
                                .frame(width: durationColumnWidth, alignment: .trailing)
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
    private func pipelineHeader(
        _ title: String,
        width: CGFloat?,
        alignment: Alignment = .leading
    ) -> some View {
        let label = Text(title)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(Color.scifiMuted)

        if let width {
            label.frame(width: width, alignment: alignment)
        } else {
            label.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func pipelineDuration(_ item: PipelineItem) -> some View {
        if item.isActive, item.startedAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                durationText(item, at: context.date)
            }
        } else {
            durationText(item, at: Date())
        }
    }

    private func durationText(_ item: PipelineItem, at date: Date) -> some View {
        let duration = elapsedDuration(for: item, at: date)
        let text = duration.map(Self.formatDuration) ?? "—"
        return Text(text)
            .foregroundStyle(duration == nil ? Color.scifiTertiary : Color.scifiMuted)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .monospacedDigit()
            .accessibilityLabel(duration.map { "Duration \(Self.accessibleDuration($0))" } ?? "Duration unavailable")
    }

    private func elapsedDuration(for item: PipelineItem, at date: Date) -> TimeInterval? {
        if let durationSeconds = item.durationSeconds {
            return max(0, durationSeconds)
        }
        guard let startedAt = item.startedAt else { return nil }
        if let completedAt = item.completedAt {
            return max(0, completedAt.timeIntervalSince(startedAt))
        }
        guard item.isActive else { return nil }
        return max(0, date.timeIntervalSince(startedAt))
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded(.down)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }

    private static func accessibleDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return [
            hours > 0 ? "\(hours) hours" : nil,
            minutes > 0 ? "\(minutes) minutes" : nil,
            remainder > 0 || seconds == 0 ? "\(remainder) seconds" : nil
        ]
        .compactMap { $0 }
        .joined(separator: " ")
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
            return Agent(
                id: subagent.id,
                agentColor: agentColor(for: subagent.id)
            )
        }
    }

    private var pipeline: [PipelineItem] {
        AgentActivityPresentation.pipeline(
            activities: model.agentActivities,
            toolCalls: model.activeToolCalls,
            subagents: model.activeSubagents
        ).map { item in
            PipelineItem(
                id: item.id,
                agentID: item.agentID,
                timestamp: item.timestamp,
                status: item.status,
                task: item.task,
                agent: item.agent,
                time: HumanDateFormatting.timeOnly(item.timestamp),
                startedAt: item.startedAt,
                completedAt: item.completedAt,
                durationSeconds: item.durationSeconds,
                isActive: item.isActive,
                color: color(for: item.status),
                detail: item.detail,
                diffPreview: item.diffPreview
            )
        }
    }

    private func activityPhase(for activity: AgentActivity) -> AgentActivityPhase {
        AgentActivityPresentation.phase(for: activity.kind)
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
        return palette[stableHash(for: id) % palette.count]
    }

    private func stableHash(for id: String) -> Int {
        let hash = id.utf8.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) }
        return Int(hash % UInt64(Int.max))
    }
}
