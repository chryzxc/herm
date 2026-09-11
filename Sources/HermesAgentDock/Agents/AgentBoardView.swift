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
    @State private var agentScope: AgentScope
    @State private var showsAgentNodes = false

    private enum AgentScope: String, CaseIterable, Identifiable {
        case live = "Live"
        case all = "All"
        var id: Self { self }
    }

    init(model: DockModel, onClose: @escaping () -> Void = {}, embedded: Bool = false) {
        self.model = model
        self.onClose = onClose
        self.embedded = embedded
        _agentScope = State(initialValue: embedded ? .live : .all)
    }

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
        let totalPipelineItemCount = pipeline.count
        let pipelineItems = Array(pipeline.prefix(embedded ? 20 : 40))
        ZStack {
            // Embedded mode belongs to the Control pane and must inherit its
            // dark glass surface instead of introducing a separate black block.
            embedded ? Color.clear : Color.dockCanvas

            VStack(spacing: 0) {
                if !embedded { titlebar }
                if embedded {
                    boardContent(totalPipelineItemCount: totalPipelineItemCount, pipelineItems: pipelineItems)
                } else {
                    ScrollView(showsIndicators: false) {
                        boardContent(totalPipelineItemCount: totalPipelineItemCount, pipelineItems: pipelineItems)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: embedded ? 0 : 14, style: .continuous))
        .overlay {
            if !embedded {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.dockBorderStrong, lineWidth: 0.5)
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
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.dockEase(duration: 0.32)) { appeared = true }
            }
        }
    }

    @ViewBuilder
    private func boardContent(totalPipelineItemCount: Int, pipelineItems: [PipelineItem]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            activeAgentsHeading
            agentSectionContent
            sectionHeading("ACTIVE PIPELINE", detail: totalPipelineItemCount > pipelineItems.count ? "LATEST \(pipelineItems.count) / \(totalPipelineItemCount)" : "\(totalPipelineItemCount) ITEMS")
            if pipelineItems.isEmpty {
                emptyState(title: "No live activity", detail: "The pipeline will populate when a Hermes subagent starts work.")
            } else {
                pipelineList(pipelineItems)
            }
        }
        .padding(embedded ? 0 : 20)
    }

    private var ambientLight: some View {
        ZStack {
            Circle()
                .fill(Color.dockAccent.opacity(embedded ? 0.045 : 0.12))
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
        if mapAgents.isEmpty {
            emptyState(title: "No active Hermes subagents", detail: "Delegate work from Hermes to see named agents and live activity here.")
        } else {
            if showsAgentNodes {
                AgentHandoffMapView(
                    model: model,
                    selectedAgentID: $expandedAgentID,
                    allowsContinuousAnimation: !embedded,
                    agents: mapAgents
                )
                    .frame(maxWidth: .infinity, minHeight: 460, alignment: .leading)
            } else {
                agentList
            }
            if showsAgentNodes, let selectedAgent = agents.first(where: { $0.id == expandedAgentID }) {
                expandedActivity(for: selectedAgent)
                    .padding(12)
                    .background(Color.dockSurface4)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var activeAgentsHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Active Agents")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.dockSecondaryText)
                Spacer(minLength: 0)
                Text(agentSummary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                Toggle(isOn: $showsAgentNodes) {
                        Text(showsAgentNodes ? "Nodes" : "List")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockSecondaryText)
                }
                .toggleStyle(.switch)
                .accessibilityLabel("Show agents as \(showsAgentNodes ? "nodes" : "list")")
            }
            HStack(spacing: 2) {
                ForEach(AgentScope.allCases) { scope in
                    Button {
                        withAnimation(reduceMotion ? nil : .dockEase(duration: 0.16)) {
                            agentScope = scope
                        }
                    } label: {
                        Text(scope.rawValue.uppercased())
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(agentScope == scope ? Color.dockPrimaryText : Color.dockSecondaryText)
                            .frame(width: 50, height: 30)
                            .background(agentScope == scope ? Color.dockAccentMuted : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(agentScope == scope ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Color.dockSurface4)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Active agents scope")
        }
    }

    private var agentList: some View {
        LazyVStack(spacing: 6) {
            ForEach(mapAgents) { subagent in
                let agent = agents.first(where: { $0.id == subagent.id })
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) {
                            expandedAgentID = expandedAgentID == subagent.id ? nil : subagent.id
                        }
                    } label: {
                        agentListRow(subagent, agent: agent)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())

                    if let agent, expandedAgentID == subagent.id {
                        expandedActivity(for: agent)
                            .padding(.horizontal, 12)
                            .padding(.top, 2)
                            .padding(.bottom, 12)
                    }
                }
                .background(Color.dockSurface4.opacity(expandedAgentID == subagent.id ? 1 : 0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(expandedAgentID == subagent.id ? Color.dockAccent.opacity(0.55) : Color.dockBorderLight, lineWidth: 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func agentListRow(_ subagent: HermesSubagent, agent: Agent?) -> some View {
        let name = subagent.name ?? subagent.role ?? "Agent"
        let detail = agentListDetail(for: subagent, displayName: name)
        let eventCount = pipeline.filter { $0.agentID == subagent.id }.count
        let isSelected = expandedAgentID == subagent.id

        return HStack(spacing: 10) {
            Circle()
                .fill((agent?.agentColor ?? agentColor(for: subagent.id)).opacity(0.2))
                .overlay {
                    Circle().stroke(agent?.agentColor ?? agentColor(for: subagent.id), lineWidth: 1.2)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.dockPrimaryText)
                }
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text("\(eventCount) \(eventCount == 1 ? "EVENT" : "EVENTS")")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color(for: subagent.status))
            Text(subagent.status.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color(for: subagent.status))
                .frame(minWidth: 62, alignment: .trailing)
            LucideImage(systemName: isSelected ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.dockMetadataText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func agentListDetail(for agent: HermesSubagent, displayName: String) -> String {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = [agent.model, agent.sourceSkill, agent.role]
        return candidates.compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.lowercased() != normalizedName else { return nil }
            return trimmed
        }.first ?? "Hermes delegate"
    }

    private var titlebar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                trafficLight(.dockDestructive, label: "Close")
                trafficLight(.dockWarning, label: "Minimize")
                trafficLight(.dockSuccess, label: "Zoom")
            }
            .frame(width: 62, alignment: .leading)

            Spacer()
            Text("HERMES AGENT BOARD")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.15)
                .foregroundStyle(Color.dockSecondaryText)
            Spacer()

            Button(action: onClose) {
                LucideImage(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 36, height: 36)
                    .background(Color.dockSurface4)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .help("Return to chat")
            .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Color.dockSurface2)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func trafficLight(_ color: Color, label: String) -> some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(Color.dockBorderLight, lineWidth: 0.5))
            .help(label)
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.lowercased().capitalized)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.dockSecondaryText)
            Spacer()
            Text(detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dockMetadataText)
        }
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LucideImage(systemName: "person.2.slash")
                .font(.system(size: 13))
                .foregroundStyle(Color.dockMetadataText)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dockPrimaryText)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
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
                Text("Activity History")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(agent.agentColor)
                Spacer()
                Text("\(activities.count) EVENTS")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dockMetadataText)
            }
            if activities.isEmpty {
                Text("No Hermes activity has been received for this agent yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
            } else {
                activityGroup("PENDING", items: pending, color: Color.dockSecondaryText, agentColor: agent.agentColor)
                activityGroup("RUNNING", items: running, color: agent.agentColor, agentColor: agent.agentColor)
                activityGroup("COMPLETED", items: completed, color: Color.dockSuccess, agentColor: agent.agentColor)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func activityGroup(_ title: String, items: [PipelineItem], color: Color, agentColor: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title)  ·  \(items.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                ForEach(items) { activity in
                    Button {
                        withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) {
                            expandedActivityID = expandedActivityID == activity.id ? nil : activity.id
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 7) {
                                Circle().fill(color).frame(width: 5, height: 5).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(activity.status.uppercased())
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(agentColor)
                                        if !activity.agent.isEmpty {
                                            Text("·")
                                                .foregroundStyle(Color.dockMetadataText)
                                            Text(activity.agent)
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(agentColor)
                                                .lineLimit(1)
                                        }
                                        Text(HumanDateFormatting.timeOnly(activity.timestamp))
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.dockMetadataText)
                                    }
                                    Text(activity.task)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.dockSecondaryText)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                LucideImage(systemName: expandedActivityID == activity.id ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color.dockMetadataText)
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
                        withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) {
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
                            Text(item.agent).foregroundStyle(Color.dockAccent).frame(width: 88, alignment: .leading).lineLimit(1)
                            Text(item.time)
                                .foregroundStyle(Color.dockSecondaryText)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(width: timeColumnWidth, alignment: .trailing)
                            pipelineDuration(item)
                                .frame(width: durationColumnWidth, alignment: .trailing)
                            LucideImage(systemName: expandedPipelineItemID == item.id ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.dockMetadataText)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    if expandedPipelineItemID == item.id {
                        pipelineContent(item)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.dockPrimaryText)
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Color.dockBorderLight.frame(height: 0.5) }
            }
        }
    }

    @ViewBuilder
    private func activityContent(_ activity: AgentActivity, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header metadata grid for subagent activities: Agent, Tool, and Time
            HStack(alignment: .top, spacing: 14) {
                if let agentID = activity.agentID, !agentID.isEmpty {
                    contentField("AGENT", agentID, accent: accent)
                }
                if let toolName = activity.toolName, !toolName.isEmpty {
                    contentField("TOOL", toolName, accent: accent)
                }
                contentField("TIME", HumanDateFormatting.timeOnly(activity.timestamp), accent: Color.dockMetadataText)
            }

            if let handoffTarget = activity.handoffTarget, !handoffTarget.isEmpty {
                contentField("HANDOFF TARGET", handoffTarget, accent: accent)
            }
            contentField("DETAIL", activity.text, accent: accent)
            if let diffPreview = activity.diffPreview, !diffPreview.isEmpty {
                miniDiffPreview(diffPreview)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.dockSurface4))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.dockBorder, lineWidth: 0.5))
    }

    @ViewBuilder
    private func pipelineContent(_ item: PipelineItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Enhanced expanded view displaying Agent, Task Name, Duration, and Status
            HStack(alignment: .top, spacing: 14) {
                if !item.task.isEmpty {
                    contentField("TASK NAME", item.task, accent: item.color)
                }
                if !item.agent.isEmpty {
                    contentField("AGENT", item.agent, accent: Color.dockAccent)
                }
                let durationStr = elapsedDuration(for: item, at: Date()).map(Self.formatDuration) ?? (item.isActive ? "RUNNING" : "—")
                contentField("DURATION", durationStr, accent: Color.dockPrimaryText)
                contentField("STATUS", item.status.uppercased(), accent: item.color)
            }

            if let startedAt = item.startedAt {
                let startStr = HumanDateFormatting.timeOnly(startedAt)
                let endStr = item.completedAt.map(HumanDateFormatting.timeOnly) ?? (item.isActive ? "Now" : "—")
                contentField("TIMESTAMPS", "Started: \(startStr)  ·  Ended: \(endStr)", accent: Color.dockMetadataText)
            }

            if let detail = item.detail, !detail.isEmpty {
                contentField("DETAIL", detail, accent: item.color)
            }
            if let diffPreview = item.diffPreview, !diffPreview.isEmpty {
                miniDiffPreview(diffPreview)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.dockSurface4))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.dockBorder, lineWidth: 0.5))
    }

    private func contentField(_ label: String, _ value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(accent)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(Color.dockSecondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func miniDiffPreview(_ diff: String) -> some View {
        let allLines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lines = Array(allLines.prefix(4))

        return VStack(alignment: .leading, spacing: 2) {
            Text(allLines.count > lines.count ? "DIFF PREVIEW · \(lines.count)/\(allLines.count) LINES" : "DIFF PREVIEW")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Color.dockMetadataText)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 10))
                    .foregroundStyle(diffLineColor(line))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.dockSurface4)
        .overlay(alignment: .leading) { Color.dockAccent.opacity(0.55).frame(width: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Diff preview: \(lines.joined(separator: ", "))")
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .dockMetadataText }
        if line.hasPrefix("+") { return .dockSuccess }
        if line.hasPrefix("-") { return .dockDestructive }
        if line.hasPrefix("@@") { return .dockAccent }
        return .dockSecondaryText
    }

    @ViewBuilder
    private func pipelineHeader(
        _ title: String,
        width: CGFloat?,
        alignment: Alignment = .leading
    ) -> some View {
        let label = Text(title)
            .font(.system(size: 12, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Color.dockSecondaryText)

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
            .foregroundStyle(duration == nil ? Color.dockMetadataText : Color.dockSecondaryText)
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
        model.activeSubagents.isEmpty ? "COMPLETED SESSION HISTORY" : "LIVE HERMES STATE"
    }

    /// The embedded Activity panel is a live monitor, not an unbounded
    /// historical graph. Keep every active worker and only the newest finished
    /// workers needed for nearby context; full history stays in the pipeline.
    private var mapAgents: [HermesSubagent] {
        let all = model.agentPresentationSnapshot.displayedSubagents
        guard agentScope == .live else { return all }
        let liveIDs = Set(model.activeSubagents.map(\.id))
        let live = all.filter { liveIDs.contains($0.id) }
        let recentHistory = all.filter { !liveIDs.contains($0.id) }
        return live + recentHistory.prefix(max(0, 12 - live.count))
    }

    private var agentSummary: String {
        let total = model.agentPresentationSnapshot.displayedSubagents.count
        if agentScope == .all { return "ALL \(total)" }
        return "LIVE \(mapAgents.count) / \(total)"
    }

    private var agents: [Agent] {
        return model.agentPresentationSnapshot.displayedSubagents.map { subagent in
            return Agent(
                id: subagent.id,
                agentColor: agentColor(for: subagent.id)
            )
        }
    }

    private var pipeline: [PipelineItem] {
        model.agentPresentationSnapshot.pipeline.map { item in
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
        if lower.contains("complete") || lower.contains("done") || lower.contains("finish") { return .dockSuccess }
        if lower.contains("error") || lower.contains("fail") { return .dockDestructive }
        if lower.contains("block") || lower.contains("approval") || lower.contains("interrupt") { return .dockWarning }
        if lower.contains("queue") { return .dockSecondaryText }
        return .dockAccent
    }

    private func agentColor(for id: String) -> Color {
        let palette: [Color] = [
            .dockAccent,
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
