import AppKit
import KeyboardShortcuts
import SwiftUI
import Foundation
import UniformTypeIdentifiers
struct SessionInspector: View {
    @ObservedObject var model: DockModel
    @ObservedObject var control: ControlCenterModel
    @ObservedObject var workflow: DeveloperWorkflowModel
    let sessionRepositoryPath: String?
    let sessionProjectIsBound: Bool
    var showsHeader = true
    @State private var selectedSection = Section.overview
    @StateObject private var preferences = CommandCenterPreferencesStore()

    private enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case activity = "Activity"
        case files = "Files"
        case changes = "Changes"
        case terminal = "Terminal"
        case verification = "Verify"

        var id: Self { self }
        var icon: String {
            switch self {
            case .overview: "bubble.left.and.bubble.right"
            case .activity: "waveform.path.ecg"
            case .files: "folder"
            case .changes: "doc.text.magnifyingglass"
            case .terminal: "terminal"
            case .verification: "checkmark.seal"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                inspectorHeader
            }
            sessionModePicker

            ScrollView {
                inspectorContent
                    .padding(16)
            }
        }
        .background(Color.scifiCanvas)
        .environment(\.colorScheme, .dark)
    }

    private var sessionModePicker: some View {
        HStack(spacing: 0) {
            ForEach([Section.overview, .activity, .files]) { section in
                sectionButton(section)
            }
            Menu {
                ForEach([Section.changes, .terminal, .verification]) { section in
                    Button {
                        withAnimation(.scifiEase(duration: 0.2)) { selectedSection = section }
                    } label: {
                        Label(section.rawValue, systemImage: section.icon)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedSection == .overview || selectedSection == .activity || selectedSection == .files ? "More" : selectedSection.rawValue)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selectedSection == .overview || selectedSection == .activity || selectedSection == .files ? Color.scifiMuted : Color.scifiFg)
                .frame(maxWidth: .infinity, minHeight: 34)
                .overlay(alignment: .bottom) {
                    if selectedSection != .overview && selectedSection != .activity && selectedSection != .files {
                        Color.scifiAccent.frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 0)
        .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
    }

    private func sectionButton(_ section: Section) -> some View {
        Button {
            withAnimation(.scifiEase(duration: 0.2)) {
                selectedSection = section
            }
        } label: {
            Text(section.rawValue)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selectedSection == section ? Color.scifiFg : Color.scifiMuted)
                .frame(maxWidth: .infinity, minHeight: 34)
                .overlay(alignment: .bottom) {
                    if selectedSection == section {
                        Color.scifiAccent.frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.scifiPress)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Show \(section.rawValue)")
    }

    private var inspectorHeader: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.scifiAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentSessionTitle ?? "Untitled session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.scifiFg)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(model.status.title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(model.status == .working ? Color.scifiAccent : Color.scifiMuted)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .overlay(alignment: .bottom) { Color.scifiBorderLight.frame(height: 0.5) }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch selectedSection {
        case .overview:
            // Build the unified session mission control snapshot. Repository
            // telemetry is only meaningful when this session owns a repository;
            // the workflow model can otherwise still contain a prior snapshot
            // while the session-scoped refresh is catching up.
            let sessionRepository = model.sessionID == nil || !sessionProjectIsBound ? nil : self.sessionRepository
            let mission = MissionControlSnapshotBuilder.make(
                sessionTitle: model.currentSessionTitle,
                repository: sessionRepository,
                model: model.runtimeConfiguration?.model,
                context: control.sessionContext,
                attention: control.attention,
                sessions: control.activeSessions,
                activeSessionID: model.sessionID,
                agents: control.activeAgents,
                processes: control.processes,
                backgroundTasks: model.backgroundTasks,
                activities: model.agentActivities,
                cronRuns: control.cronRuns,
                verification: control.verification
            )
            let openAttention = control.attention.filter { $0.state == .open }
            let activeSubagentCount = model.activeSubagents.filter { AgentActivityPresentation.isActiveStatus($0.status) }.count

            VStack(alignment: .leading, spacing: 14) {
                // Section Header
                inspectorLabel("SESSION OVERVIEW")

                // Compact repository telemetry bar. The active model is shown in
                // the composer, which is the authoritative session model control.
                if sessionRepository != nil {
                    sessionTelemetryStrip(focus: mission.focus)
                }

                // Interactive Metrics Bar
                HStack(spacing: 8) {
                    inspectorMetric("AGENTS", value: control.activeAgents.count, color: .scifiAccent)
                    inspectorMetric("RUNNING", value: activeSubagentCount, color: activeSubagentCount > 0 ? .scifiAccent : .scifiMuted)
                    inspectorMetric("ATTENTION", value: openAttention.count, color: openAttention.isEmpty ? .scifiSuccess : .scifiWarning)
                }

                // Pre-flight Readiness & Health Card
                sessionReadinessCard(readiness: mission.readiness)

                // Session Action Items requiring user attention
                if !openAttention.isEmpty {
                    inspectorLabel("NEEDS ME")
                    ForEach(openAttention.prefix(2)) { attention in
                        attentionRow(attention)
                    }
                }

                // Latest Session Activity section displaying recent agent activities or events
                inspectorLabel("LATEST ACTIVITY")
                if !model.agentActivities.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(model.agentActivities.prefix(3)) { activity in
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(Color.scifiAccent)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 4)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(activity.toolName ?? activity.kind.uppercased())
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(Color.scifiFg)
                                        Spacer()
                                        Text(HumanDateFormatting.timeOnly(activity.timestamp))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Color.scifiTertiary)
                                    }
                                    Text(activity.text)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.scifiMuted)
                                        .lineLimit(2)
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.scifiSurface4))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.scifiBorder, lineWidth: 0.5))
                        }
                    }
                } else if !model.recentEvents.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(model.recentEvents.prefix(3)) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(Color.scifiAccent)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 4)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(event.type.uppercased())
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(Color.scifiFg)
                                        Spacer()
                                        Text(HumanDateFormatting.timeOnly(event.timestamp))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Color.scifiTertiary)
                                    }
                                    Text(event.detail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.scifiMuted)
                                        .lineLimit(2)
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.scifiSurface4))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.scifiBorder, lineWidth: 0.5))
                        }
                    }
                } else {
                    inspectorCard(title: "NO RECENT ACTIVITY", value: "Activity events will be recorded here as Hermes executes tool calls or subagent tasks.")
                }

                // Verification Summary Card
                if let verification = control.verification {
                    inspectorLabel("VERIFICATION")
                    let color: Color = verification.state == .passed ? .scifiSuccess : verification.state == .failed ? .scifiDestructive : .scifiWarning
                    inspectorCard(
                        title: "STATUS  ·  \(verification.state.rawValue.uppercased())",
                        value: verification.evidence?.canonicalCommand ?? verification.evidence?.command ?? "Verification reported for active session.",
                        accent: color
                    )
                }
            }
        case .activity:
            AgentBoardView(model: model, embedded: true)
        case .files:
            VStack(alignment: .leading, spacing: 14) {
                inspectorLabel("PROJECT FILES")
                SessionFilesView(
                    projectPath: sessionRepositoryPath,
                    onRefresh: { await workflow.refresh(preferences: preferences, control: control) }
                )
            }
        case .changes:
            RepositoryChangesBrowser(
                model: model,
                workflow: workflow,
                projectPath: sessionRepositoryPath,
                onRefresh: { await workflow.refresh(preferences: preferences, control: control) }
            )
        case .terminal:
            SessionTerminalView(projectPath: sessionRepositoryPath)
        case .verification:
            VStack(alignment: .leading, spacing: 14) {
                inspectorLabel("VERIFICATION")
                if let verification = control.verification {
                    let color: Color = verification.state == .passed ? .scifiSuccess : verification.state == .failed ? .scifiDestructive : .scifiWarning
                    inspectorCard(title: "STATUS", value: verification.state.rawValue.uppercased(), accent: color)
                    if let evidence = verification.evidence,
                       let command = evidence.canonicalCommand ?? evidence.command {
                        inspectorCard(title: "EVIDENCE", value: command)
                    }
                } else {
                    inspectorCard(title: "NOT AVAILABLE", value: "Verification results will appear when Hermes reports them for this session.")
                }
            }
        }
    }

    private var sessionRepository: RepositorySnapshot? {
        guard sessionRepositoryPath != nil, workflow.repository.isGitRepository else { return nil }
        return workflow.repository
    }

    private func inspectorLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(Color.scifiMuted)
    }

    /// Renders a metric card matching the DESIGN.md glass pane specifications.
    private func inspectorMetric(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.55)
                .foregroundStyle(Color.scifiTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .scifiGlassPane()
    }

    /// Renders a glass card pane matching DESIGN.md rules.
    private func inspectorCard(title: String, value: String, accent: Color = .scifiFg) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.75)
                .foregroundStyle(Color.scifiTertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(accent)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .scifiGlassPane()
    }

    /// Renders repository telemetry without duplicating the model selector from the composer.
    private func sessionTelemetryStrip(focus: MissionControlFocus) -> some View {
        struct TelemetryItem: Identifiable {
            let id: String
            let icon: String
            let label: String
            let value: String
        }

        let items: [TelemetryItem] = [
            focus.branch.map { TelemetryItem(id: "branch", icon: "arrow.triangle.branch", label: "BRANCH", value: $0) },
            focus.contextPercent.map { TelemetryItem(id: "context", icon: "chart.bar.fill", label: "CONTEXT", value: "\(Int($0.rounded()))%") },
            focus.changedFiles.map { TelemetryItem(id: "files", icon: "doc.badge.gearshape", label: "CHANGED", value: "\($0) files") }
        ].compactMap { $0 }

        let gridColumns = [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]

        return Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: gridColumns, spacing: 8) {
                        ForEach(items) { item in
                            HStack(spacing: 6) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.scifiAccent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.label)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.scifiMuted)
                                    Text(item.value)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Color.scifiFg)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.scifiSurface2)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.scifiBorderLight, lineWidth: 0.5))
                        }
                    }
                }
                .padding(10)
                .scifiGlassPane()
            }
        }
    }

    /// Renders pre-flight readiness checks for repository cleanliness and model configuration.
    private func sessionReadinessCard(readiness: ReadinessSummary) -> some View {
        let color: Color = switch readiness.state {
        case .ready: .scifiSuccess
        case .needsReview: .scifiWarning
        case .blocked: .scifiDestructive
        case .notApplicable: .scifiMuted
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                Text("PRE-FLIGHT READINESS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.75)
                    .foregroundStyle(color)
                Spacer(minLength: 0)
                Text(readiness.state.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            }

            Text(readiness.detail)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.scifiFg)

            if let scope = readiness.verificationScope {
                Text("Scope: \(scope)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .scifiGlassPane()
    }

    /// Renders an individual attention item requiring user action or response.
    private func attentionRow(_ attention: AttentionItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.scifiWarning)
                Text(attention.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.scifiFg)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(attention.kind.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.scifiWarning)
            }
            if !attention.detail.isEmpty {
                Text(attention.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .scifiGlassPane()
    }
}
