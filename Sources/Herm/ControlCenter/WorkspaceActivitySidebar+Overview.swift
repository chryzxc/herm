import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceActivitySidebar {
    var searchContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("SEARCH SOURCES")
            HStack(spacing: 8) {
                DockIcon(.magnifyingGlass)
                    .dockFont(.body, weight: .medium)
                    .foregroundStyle(Color.dockAccent)
                    .frame(width: 16)
                DockTextField("Sessions, projects, Inbox, reminders", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .dockFont(.navigation)
                    .foregroundStyle(Color.dockPrimaryText)
                if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        DockIcon(.xCircle, weight: .fill)
                            .dockFont(.body)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    .buttonStyle(.dockHover)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .dockSurfaceFill(Color.dockControlSurface, stroke: Color.dockBorder, lineWidth: 0.5)
            )
            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search across the sources already connected to Hermes.")
                        .dockFont(.body, weight: .medium)
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("Sessions  ·  projects  ·  Inbox  ·  Apple Reminders")
                        .dockFont(.body)
                        .foregroundStyle(Color.dockMetadataText)
                }
                .padding(.top, 2)
            } else if control.isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("SEARCHING HERMES SOURCES…")
                        .dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                }
            } else if control.searchResults.isEmpty {
                emptyState(
                    icon: .question, title: "No matches", detail: "Try a session title, project name, or reminder.")
            } else {
                sectionLabel("RESULTS  ·  \(control.searchResults.count)")
                ForEach(control.searchResults) { result in
                    let canOpen = result.reference.source != .appleReminder && result.reference.source != .hermesCronJob
                    if canOpen {
                        Button {
                            control.openSearchResult(result)
                        } label: {
                            searchResultRow(result)
                        }
                        .buttonStyle(.dockHover)
                    } else {
                        searchResultRow(result)
                    }
                }
            }
        }
    }

    func searchResultRow(_ result: ControlSearchResult) -> some View {
        HStack(alignment: .top, spacing: 9) {
            DockIcon(result.reference.source == .appleReminder ? .listChecks : .circleDashed)
                .dockFont(.body)
                .foregroundStyle(Color.dockAccent)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(result.title)
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(result.sourceLabel)
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockSecondaryText)
                }
                Text(result.detail)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(2)
            }
            if result.reference.source != .appleReminder && result.reference.source != .hermesCronJob {
                DockIcon(.caretRight)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockListRow()
        .contentShape(Rectangle())
    }

    func sessionLifecycleColor(_ status: SessionLifecycleStatus) -> Color {
        switch status {
        case .active: Color.dockAccent
        case .completed: Color.dockSuccess
        case .failed: Color.dockDestructive
        case .stale: Color.dockWarning
        case .unavailable: Color.dockSecondaryText
        }
    }

    /// Renders a metric card in the workspace overview, with an optional tap action to switch tabs.
    func todayMetric(_ label: String, value: Int, color: Color, action: (() -> Void)? = nil) -> some View {
        let cardContent = VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .dockFont(size: 18, weight: .semibold)
                .foregroundStyle(
                    color == Color.dockWarning || color == Color.dockDestructive ? color : Color.dockPrimaryText)
            Text(label == label.uppercased() ? label.lowercased().capitalized : label)
                .dockFont(.metadata, weight: .medium)
                .foregroundStyle(Color.dockMetadataText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .dockSurfaceFill(Color.dockSurface.opacity(0.34))
        )
        .overlay {
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .stroke(Color.dockBorderLight, lineWidth: 0.5)
        }

        return Group {
            if let action {
                Button(action: action) {
                    cardContent
                }
                .buttonStyle(.dockHover)
            } else {
                cardContent
            }
        }
    }

    var repositoryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                DockIcon(workflow.repository.isGitRepository ? .gitBranch : .folder)
                    .foregroundStyle(workflow.repository.isGitRepository ? Color.dockSuccess : Color.dockSecondaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        workflow.repository.isGitRepository ? workflow.repository.branch : "No project folder selected"
                    )
                    .dockFont(.body, weight: .medium)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                    if workflow.repository.isGitRepository {
                        Text(
                            workflow.repository.changedFiles == 0
                                ? "CLEAN WORKING TREE"
                                : "\(workflow.repository.changedFiles) CHANGED FILE\(workflow.repository.changedFiles == 1 ? "" : "S")"
                        )
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(
                            workflow.repository.changedFiles == 0 ? Color.dockSuccess : DockCategoryTone.modified.color)
                    } else if let path = activeRepositoryPath {
                        Text(path).dockFont(.body).foregroundStyle(Color.dockMetadataText).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isRefreshingRepository { ProgressView().controlSize(.small) }
            }
            if workflow.repository.isGitRepository {
                DockMenu {
                    if workflow.branches.isEmpty {
                        Text("No local branches found")
                    } else {
                        ForEach(workflow.branches, id: \.self) { branch in
                            Button {
                                Task {
                                    _ = await workflow.switchBranch(
                                        branch, preferences: commandCenterPreferences, control: control)
                                }
                            } label: {
                                if branch == workflow.repository.branch {
                                    DockIconLabel(branch, icon: .check)
                                } else {
                                    Text(branch)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        DockIcon(.gitBranch)
                        Text("SWITCH BRANCH")
                        DockIcon(.caretDown)
                            .dockFont(size: 8, weight: .bold)
                    }
                }
                .buttonStyle(.dockHover)
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockAccent)
                .disabled(isRefreshingRepository || workflow.isRefreshing)
            }
            if workflow.repository.isGitRepository, !workflow.repository.latestCommit.isEmpty {
                Text(workflow.repository.latestCommit)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(2)
            }
            HStack(spacing: 14) {
                Button("CHANGE PROJECT FOLDER") {
                    showingRepositoryPicker = true
                }
                Button {
                    Task { await refreshRepository() }
                } label: {
                    DockActionLabel(
                        title: "REFRESH",
                        pendingTitle: "REFRESHING…",
                        isPending: isRefreshingRepository
                    )
                }
                .disabled(isRefreshingRepository)
            }
            .buttonStyle(.dockCompact)
            .dockFont(.body, weight: .semibold)
            .foregroundStyle(Color.dockAccent)
        }
        .padding(12)
        .dockGlassPane()
    }

    func providerSetupCard(_ capability: CapabilityState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            DockIcon(.warning)
                .dockFont(.body)
                .foregroundStyle(Color.dockWarning)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 3) {
                Text(capability.title)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                Text(capability.detail)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(2)
                if let recovery = capability.recovery {
                    Text(recovery)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(2)
                }
                if let command = capability.recoveryCommand {
                    DockCopyButton(
                        command,
                        label: "COPY \(command)",
                        accessibilityLabel: "Copy recovery command",
                        presentation: .text,
                        color: .dockAccent
                    )
                    .buttonStyle(.dockCompact)
                    .dockFont(.body, weight: .semibold)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .dockGlassPane()
        .overlay(
            RoundedRectangle(cornerRadius: DockLayout.paneRadius + 4, style: .continuous).stroke(
                Color.dockWarning.opacity(0.55), lineWidth: 0.5))
    }

    var unavailableSetupCapabilities: [CapabilityState] {
        control.capabilities.filter {
            ["reminders", "notes", "calendar", "messaging", "email"].contains($0.id) && !$0.isAvailable
        }
    }

    func attentionRow(icon: Ph, title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            DockIcon(icon).dockFont(.body).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).dockFont(.body, weight: .medium).foregroundStyle(Color.dockPrimaryText)
                Text(detail).dockFont(.body).foregroundStyle(Color.dockMetadataText).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .dockListRow()
    }

    var currentTask: WorkspaceTask? {
        if let sessionID = model.sessionID {
            return store.task(forSessionID: sessionID)
        }
        return store.activeTask
    }

    var activeRepositoryPath: String? {
        store.resolvedProjectPath(
            forSessionID: model.sessionID,
            hermesProjectPath: model.sessionID.flatMap { control.project(forSessionID: $0)?.name },
            createdSessionProjectPath: model.sessionID.flatMap { model.createdSessionProjectPaths[$0] }
        )
    }

    /// A repository path can be shared by multiple sessions. The task identity
    /// therefore includes the stable Hermes session ID so a session switch
    /// always refreshes Today’s contextual repository projection.
    var activeRepositoryIdentity: String? {
        guard let sessionID = model.sessionID, let path = activeRepositoryPath else { return nil }
        return "\(sessionID):\(path)"
    }

    func taskColor(_ status: WorkspaceTaskStatus) -> Color {
        switch status {
        case .todo: .dockSecondaryText
        case .inProgress: .dockAccent
        case .awaitingApproval: .dockWarning
        case .readyForReview: .dockSuccess
        case .done: .dockMetadataText
        }
    }

    func refreshRepository() async {
        guard let path = activeRepositoryPath else {
            selectedRepositoryDiff = nil
            await workflow.setActiveRepository(path: nil, preferences: commandCenterPreferences, control: control)
            control.setDevelopmentContextProjection(nil)
            isRefreshingRepository = false
            return
        }
        isRefreshingRepository = true
        defer {
            if path == activeRepositoryPath || activeRepositoryPath == nil {
                isRefreshingRepository = false
            }
        }
        await workflow.setActiveRepository(path: path, preferences: commandCenterPreferences, control: control)
        await workflow.refresh(preferences: commandCenterPreferences, control: control)
        guard path == activeRepositoryPath else { return }
        selectedRepositoryDiff = nil
    }

    func handleRepositoryImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let sessions = control.projectSessions
        let currentSessionIsInSelectedProject =
            model.sessionID.map { id in
                sessions.contains { $0.id == id }
            } ?? false
        if currentSessionIsInSelectedProject, !sessions.isEmpty {
            store.attachProject(at: url.path, toSessions: sessions)
        } else {
            store.attachProject(at: url.path, toSessionID: model.sessionID)
        }
    }

    var agentRoster: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                rosterTile(title: "ALL", subtitle: "Hermes", status: model.status.title, color: statusColor, id: nil)
                ForEach(model.displayedSubagents) { agent in
                    rosterTile(
                        title: agent.role ?? initials(for: agent.goal), subtitle: shortGoal(agent.goal),
                        status: agent.status, color: nativeAgentColor(agent.status), id: agent.id)
                }
            }
        }
    }

    func rosterTile(title: String, subtitle: String, status: String, color: Color, id: String?) -> some View {
        Button {
            selectedAgentID = id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    AgentAvatar(identity: id ?? "hermes", statusColor: color)
                        .frame(width: 28, height: 28)
                    Circle().fill(color).frame(width: 5, height: 5)
                }
                Text(title.uppercased())
                    .dockFont(.body, weight: .semibold)
                    .tracking(0.5)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
            }
            .frame(width: 82, alignment: .leading)
            .padding(8)
            .background(selectedAgentID == id ? color.opacity(0.12) : Color.dockSurface4)
            .overlay(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius + 1).stroke(
                    selectedAgentID == id ? color.opacity(0.5) : Color.dockBorder, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius + 1))
        }
        .buttonStyle(.dockHover)
        .help(status)
    }

    func activityRow(_ activity: AgentActivity) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(HumanDateFormatting.timeOnly(activity.timestamp))
                .dockFont(.body)
                .foregroundStyle(Color.dockMetadataText)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.kind.replacingOccurrences(of: "subagent.", with: "").uppercased())
                    .dockFont(.body, weight: .semibold)
                    .tracking(0.5)
                    .foregroundStyle(Color.dockAccent)
                Text(activity.text)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(2)
            }
        }
    }

    func initials(for value: String) -> String {
        let words = value.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "-" })
        return words.prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }

    func shortGoal(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > 22 ? String(clean.prefix(22)) + "…" : clean
    }

    func capabilityStatusRow(_ capability: CapabilityState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(capabilityReadinessColor(capability)).frame(width: 6, height: 6).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(capability.title).dockFont(.body, weight: .medium).foregroundStyle(Color.dockPrimaryText)
                    Text(capabilityReadinessLabel(capability).uppercased())
                        .dockFont(.compactStatus, weight: .semibold)
                        .foregroundStyle(capabilityReadinessColor(capability))
                    Text(capabilityAccessLabel(capability).uppercased())
                        .dockFont(.compactStatus, weight: .medium)
                        .foregroundStyle(Color.dockSecondaryText)
                }
                Text(capability.detail).dockFont(.body).foregroundStyle(Color.dockMetadataText).lineLimit(2)
                if let recovery = capability.recovery {
                    Text(recovery).dockFont(.body).foregroundStyle(Color.dockWarning).lineLimit(2)
                }
                if let command = capability.recoveryCommand {
                    DockCopyButton(
                        command,
                        label: "COPY \(command)",
                        accessibilityLabel: "Copy recovery command",
                        iconSize: 16,
                        color: .dockAccent
                    )
                    .buttonStyle(.dockCompact)
                    .dockFont(.body, weight: .semibold)
                }
            }
            Spacer(minLength: 0)
        }
    }

    func capabilityReadinessLabel(_ capability: CapabilityState) -> String {
        switch capability.probeState {
        case .verified: "Verified"
        case .unverified: "Needs review"
        case .missing: "Missing"
        case .unsupported: "Unsupported"
        }
    }

    func capabilityReadinessColor(_ capability: CapabilityState) -> Color {
        switch capability.probeState {
        case .verified: Color.dockSuccess
        case .unverified: Color.dockAccent
        case .missing, .unsupported: Color.dockWarning
        }
    }

    func capabilityAccessLabel(_ capability: CapabilityState) -> String {
        switch capability.accessClassification {
        case .safeReadOnly: "Read-only"
        case .confirmedMutation: "Confirmed mutation"
        case .externalSetup: "External setup"
        }
    }

    var capabilityInventorySnapshot: CapabilitySnapshot {
        control.capabilitySnapshot
    }

    func capabilityStates(for category: CapabilityCategory) -> [CapabilityState] {
        (capabilityInventorySnapshot.statesByCategory[category] ?? []).filter {
            !unavailableSetupCapabilities.contains($0)
        }
    }

    var capabilityInventorySummary: some View {
        HStack(spacing: 8) {
            Text("\(capabilityInventorySnapshot.totalCount) TOTAL")
            Text("\(capabilityInventorySnapshot.verifiedCount) READY").foregroundStyle(Color.dockPrimaryText)
            Text("\(capabilityInventorySnapshot.unverifiedCount) REVIEW")
            Text(
                "\(capabilityInventorySnapshot.missingCount + capabilityInventorySnapshot.unsupportedCount) MISSING/UNSUPPORTED"
            )
            .foregroundStyle(Color.dockWarning)
        }
        .dockFont(.compactStatus, weight: .semibold)
        .foregroundStyle(Color.dockSecondaryText)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
