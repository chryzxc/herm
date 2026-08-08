import SwiftUI

/// Compact, glassmorphism-first live overview for the menubar popup's agents.
/// The board follows DESIGN.md's window anatomy and is backed by Hermes runtime state.
struct AgentBoardView: View {
    @ObservedObject var model: DockModel
    var onClose: () -> Void = {}
    var embedded = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private struct Agent: Identifiable {
        let id: String
        let initials: String
        let name: String
        let specialty: String
        let status: String
        let activity: String
        let statusColor: Color
    }

    private struct PipelineItem: Identifiable {
        let id = UUID()
        let status: String
        let task: String
        let agent: String
        let time: String
        let color: Color
    }

    var body: some View {
        ZStack {
            // Embedded mode belongs to the Control pane and must inherit its
            // dark glass surface instead of introducing a separate black block.
            embedded ? Color.scifiSurface : Color.black
            ambientLight

            VStack(spacing: 0) {
                if !embedded { titlebar }
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
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
                    .padding(20)
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
        .shadow(color: .black.opacity(0.5), radius: 32, y: 18)
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
                    .frame(width: 26, height: 26)
                    .background(Color.scifiSurface4)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
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

    private var agentsGrid: some View {
            // The Activity pane is intentionally a two-column roster so the
        // operator can scan all agents in one view.
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(agents) { agent in
                agentTile(agent)
            }
        }
    }

    private func agentTile(_ agent: Agent) -> some View {
        VStack(alignment: .leading, spacing: 13) {
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
        }
        .padding(14)
        .background(Color.scifiSurface)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.scifiBorder, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func agentOrb(_ agent: Agent) -> some View {
        ZStack {
            Circle().fill(Color.scifiAccent.opacity(0.12))
            Circle().stroke(Color.scifiAccent.opacity(0.55), lineWidth: 0.6)
            Circle().trim(from: 0.08, to: 0.42)
                .stroke(Color.scifiAccent, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .rotationEffect(.degrees(Double(abs(agent.id.hashValue % 360))))
                .padding(4)
            Text(agent.initials)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.scifiFg)
        }
        .shadow(color: Color.scifiAccent.opacity(0.18), radius: 6)
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
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                pipelineHeader("STATUS", width: 76)
                pipelineHeader("TASK", width: nil)
                pipelineHeader("AGENT", width: 88)
                pipelineHeader("TIME", width: 38)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            ForEach(pipeline) { item in
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Circle().fill(item.color).frame(width: 5, height: 5)
                        Text(item.status)
                    }
                    .frame(width: 76, alignment: .leading)
                    Text(item.task).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Text(item.agent).foregroundStyle(Color.scifiAccent).frame(width: 88, alignment: .leading).lineLimit(1)
                    Text(item.time).foregroundStyle(Color.scifiMuted).frame(width: 38, alignment: .trailing)
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
                specialty: subagent.model ?? "Hermes delegate",
                status: subagent.status,
                activity: activity,
                statusColor: color(for: subagent.status)
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

    private var pipeline: [PipelineItem] {
        var liveRows: [PipelineItem] = model.agentActivities.suffix(6).reversed().map {
                PipelineItem(
                    status: $0.kind,
                    task: $0.text,
                    agent: $0.agentID.flatMap { id in
                        model.activeSubagents.first(where: { $0.id == id }).map { $0.name ?? $0.role ?? "Agent" }
                    } ?? "Hermes",
                    time: Self.timeFormatter.string(from: $0.timestamp),
                    color: .scifiAccent
                )
        }

        // Tool calls belong to Hermes' primary process, not only to delegated
        // agents. Keep them visible in the pipeline even when no subagent exists.
        liveRows.append(contentsOf: model.activeToolCalls.map { call in
            PipelineItem(
                status: call.isComplete ? "Complete" : "Running",
                task: call.input.isEmpty ? call.name : "\(call.name): \(call.input)",
                agent: "Hermes",
                time: Self.timeFormatter.string(from: Date()),
                color: call.isComplete ? .scifiSuccess : .scifiAccent
            )
        })

        if !liveRows.isEmpty {
            return liveRows
        }

        if !model.activeSubagents.isEmpty {
            return model.activeSubagents.map { agent in
                PipelineItem(
                    status: agent.status,
                    task: agent.goal,
                    agent: agent.name ?? agent.role ?? "Agent",
                    time: agent.startedAt.map { Self.timeFormatter.string(from: $0) } ?? "—",
                    color: color(for: agent.status)
                )
            }
        }

        return []
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func initials(_ value: String) -> String {
        String(value.split(separator: " ").prefix(2).compactMap { $0.first })
    }

    private func color(for status: String) -> Color {
        status.lowercased().contains("block") || status.lowercased().contains("approval") ? .scifiWarning : .scifiAccent
    }
}
