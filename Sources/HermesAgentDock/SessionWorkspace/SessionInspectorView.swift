import AppKit
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
    @State private var isSwitchingBranch = false
    @StateObject private var preferences = CommandCenterPreferencesStore()

    private let sessionTabFont = Font.system(size: 12, weight: .medium)

    private enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case activity = "Activity"
        case files = "Files"
        case changes = "Source Control"
        case terminal = "Terminal"
        case verification = "Verify"

        var id: Self { self }
        var navigationTitle: String {
            switch self {
            case .files: "Explorer"
            case .terminal: "Terminal"
            case .activity: "Activity"
            case .changes: "Source Control"
            case .overview: "Overview"
            case .verification: "Verify"
            }
        }
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

            if let workflowError = workflow.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.dockWarning)
                    Text(workflowError)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.dockWarning.opacity(0.08))
                .overlay(alignment: .bottom) {
                    Color.dockWarning.opacity(0.25).frame(height: 0.5)
                }
            }

            GeometryReader { proxy in
                ScrollView {
                    inspectorContent
                        .padding(16)
                        .frame(minHeight: max(0, proxy.size.height - 32), alignment: .top)
                }
            }
        }
        .background(Color.dockCanvas)
    }

    private var sessionModePicker: some View {
        HStack(spacing: 0) {
            ForEach([Section.overview, .files, .terminal, .activity, .changes]) { section in
                sectionButton(section)
            }
            Menu {
                ForEach([Section.verification]) { section in
                    Button {
                        withAnimation(.dockEase(duration: 0.2)) { selectedSection = section }
                    } label: {
                        Label(section.rawValue, systemImage: section.icon)
                    }
                }
            } label: {
                Text("More")
                    .font(sessionTabFont)
                    .foregroundStyle(selectedSection == .verification ? Color.dockPrimaryText : Color.dockSecondaryText)
                    .frame(maxWidth: .infinity, minHeight: 34)
                .overlay(alignment: .bottom) {
                    if selectedSection == .verification {
                        Color.dockAccent.frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 0)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func sectionButton(_ section: Section) -> some View {
        Button {
            withAnimation(.dockEase(duration: 0.2)) {
                selectedSection = section
            }
        } label: {
            Text(section.navigationTitle)
                .font(sessionTabFont)
                .foregroundStyle(selectedSection == section ? Color.dockPrimaryText : Color.dockSecondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 34)
                .overlay(alignment: .bottom) {
                    if selectedSection == section {
                        Color.dockAccent.frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Show \(section.rawValue)")
    }

    private var inspectorHeader: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentSessionTitle ?? "Untitled session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                if let sessionProjectName {
                    Label(sessionProjectName, systemImage: "folder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(model.status.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(model.status == .working ? Color.dockAccent : Color.dockSecondaryText)
        }
        .padding(.horizontal, 16)
        .frame(height: sessionProjectName == nil ? 50 : 58)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private var sessionProjectName: String? {
        guard sessionProjectIsBound,
              let sessionRepositoryPath,
              !sessionRepositoryPath.isEmpty else { return nil }
        let name = URL(fileURLWithPath: sessionRepositoryPath).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private var latestSessionActivities: [AgentActivityPresentation.PipelineActivity] {
        // Reuse DockModel's cached projection: calling pipeline() directly here
        // rebuilt the full history on every inspector render and stalled the
        // UI while streaming events kept invalidating the body.
        Array(model.agentPresentationSnapshot.pipeline.prefix(3))
    }

    private var latestSessionEvents: [AgentEvent] {
        Array(model.recentEvents.sorted { $0.timestamp > $1.timestamp }.prefix(3))
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
                attention: control.attention(for: model.sessionID),
                sessions: control.activeSessions,
                activeSessionID: model.sessionID,
                agents: control.activeAgents.filter { $0.sessionID == model.sessionID },
                processes: control.processes,
                backgroundTasks: model.currentSessionBackgroundTasks,
                activities: model.agentActivities,
                cronRuns: control.cronRuns,
                verification: control.verification
            )
            let openAttention = control.openAttention(for: model.sessionID)
            let sessionActiveAgents = control.activeAgents.filter { $0.sessionID == model.sessionID }
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
                    inspectorMetric("AGENTS", value: sessionActiveAgents.count, color: .dockAccent)
                    inspectorMetric("RUNNING", value: activeSubagentCount, color: activeSubagentCount > 0 ? .dockAccent : .dockSecondaryText)
                    inspectorMetric("ATTENTION", value: openAttention.count, color: openAttention.isEmpty ? .dockSuccess : .dockWarning)
                }

                // Pre-flight Readiness & Health Card
                sessionReadinessCard(readiness: mission.readiness)
                AgentOperationsRadarView(agents: model.sessionAgents)

                // Session Action Items requiring user attention
                if !openAttention.isEmpty {
                    inspectorLabel("NEEDS ME")
                    ForEach(openAttention.prefix(2)) { attention in
                        attentionRow(attention)
                    }
                }

                // Latest Session Activity section displaying recent agent activities or events
                inspectorLabel("LATEST ACTIVITY")
                if !latestSessionActivities.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(latestSessionActivities, id: \.id) { (activity: AgentActivityPresentation.PipelineActivity) in
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(Color.dockAccent)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 4)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(activity.task)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.dockPrimaryText)
                                        Spacer()
                                        Text(HumanDateFormatting.timeOnly(activity.timestamp))
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.dockMetadataText)
                                    }
                                    Text(activity.detail ?? "")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.dockSecondaryText)
                                        .lineLimit(2)
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.dockSurface4))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.dockBorder, lineWidth: 0.5))
                        }
                    }
                } else if !latestSessionEvents.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(latestSessionEvents, id: \.id) { (event: AgentEvent) in
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(Color.dockAccent)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 4)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(event.type.uppercased())
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.dockPrimaryText)
                                        Spacer()
                                        Text(HumanDateFormatting.timeOnly(event.timestamp))
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.dockMetadataText)
                                    }
                                    Text(event.detail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.dockSecondaryText)
                                        .lineLimit(2)
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.dockSurface4))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.dockBorder, lineWidth: 0.5))
                        }
                    }
                } else {
                    inspectorCard(title: "NO RECENT ACTIVITY", value: "Activity events will be recorded here as Hermes executes tool calls or subagent tasks.")
                }

                // Verification Summary Card
                if let verification = control.verification {
                    inspectorLabel("VERIFICATION")
                    let color: Color = verification.state == .passed ? .dockSuccess : verification.state == .failed ? .dockDestructive : .dockWarning
                    inspectorCard(
                        title: "STATUS  ·  \(verification.state.rawValue.uppercased())",
                        value: verification.evidence?.canonicalCommand ?? verification.evidence?.command ?? "Verification reported for active session.",
                        accent: color
                    )
                }
            }
        case .activity:
            VStack(alignment: .leading, spacing: 12) {
                SessionKanbanActivityView(control: control, sessionID: model.kanbanSessionID)
                AgentBoardView(model: model, embedded: true)
            }
        case .files:
            VStack(alignment: .leading, spacing: 14) {
                inspectorLabel("PROJECT FILES")
                SessionFilesView(
                    projectPath: sessionRepositoryPath,
                    onRefresh: { await workflow.refresh(preferences: preferences, control: control) }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    let color: Color = verification.state == .passed ? .dockSuccess : verification.state == .failed ? .dockDestructive : .dockWarning
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
        guard sessionRepositoryPath != nil else { return nil }
        return workflow.repository.isGitRepository ? workflow.repository : nil
    }

    private func inspectorLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.dockSecondaryText)
    }

    /// Renders a metric card matching the DESIGN.md glass pane specifications.
    private func inspectorMetric(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.55)
                .foregroundStyle(Color.dockMetadataText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .dockGlassPane()
    }

    /// Renders a glass card pane matching DESIGN.md rules.
    private func inspectorCard(title: String, value: String, accent: Color = .dockPrimaryText) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.75)
                .foregroundStyle(Color.dockMetadataText)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accent)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .dockGlassPane()
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
                            if item.id == "branch", workflow.repository.isGitRepository {
                                Menu {
                                    ForEach(workflow.branches, id: \.self) { branch in
                                        Button {
                                            isSwitchingBranch = true
                                            Task {
                                                _ = await workflow.switchBranch(branch, preferences: preferences, control: control)
                                                isSwitchingBranch = false
                                            }
                                        } label: {
                                            if branch == workflow.repository.branch {
                                                Label(branch, systemImage: "checkmark")
                                            } else {
                                                Text(branch)
                                            }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        HStack(spacing: 5) {
                                            Image(systemName: isSwitchingBranch ? "arrow.triangle.2.circlepath" : item.icon)
                                                .font(.system(size: 11))
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 8, weight: .bold))
                                        }
                                        .foregroundStyle(Color.dockAccent)
                                        VStack(alignment: .leading, spacing: 2) {
                                            if item.id == "branch" {
                                                Text(item.value)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundStyle(Color.dockPrimaryText)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            } else {
                                                Text(item.label)
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(Color.dockSecondaryText)
                                                Text(item.value)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundStyle(Color.dockPrimaryText)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.dockSurface2)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
                                }
                                .menuStyle(.borderlessButton)
                                .buttonStyle(.borderless)
                                .disabled(isSwitchingBranch || workflow.branches.isEmpty)
                            } else {
                                HStack(spacing: 6) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.dockAccent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.label)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Color.dockSecondaryText)
                                        Text(item.value)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Color.dockPrimaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.dockSurface2)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
                            }
                        }
                    }
                }
                .padding(10)
                .dockGlassPane()
            }
        }
    }

    /// Renders pre-flight readiness checks for repository cleanliness and model configuration.
    private func sessionReadinessCard(readiness: ReadinessSummary) -> some View {
        let color: Color = switch readiness.state {
        case .ready: .dockSuccess
        case .needsReview: .dockWarning
        case .blocked: .dockDestructive
        case .notApplicable: .dockSecondaryText
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                Text("PRE-FLIGHT READINESS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.75)
                    .foregroundStyle(color)
                Spacer(minLength: 0)
                Text(readiness.state.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
            }

            Text(readiness.detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dockPrimaryText)

            if let scope = readiness.verificationScope {
                Text("Scope: \(scope)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .dockGlassPane()
    }

    /// Renders an individual attention item requiring user action or response.
    private func attentionRow(_ attention: AttentionItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockWarning)
                Text(attention.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(attention.kind.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dockWarning)
            }
            if !attention.detail.isEmpty {
                Text(attention.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .dockGlassPane()
    }
}
