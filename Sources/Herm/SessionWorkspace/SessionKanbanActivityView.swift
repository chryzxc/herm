import SwiftUI

struct SessionKanbanActivityView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var control: ControlCenterModel
    @ObservedObject var botMode: BotModeModel
    let sessionID: String?
    var onOpenBoard: (() -> Void)?
    var onOpenTask: ((String) -> Void)?

    @State private var showsCompleted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var snapshot: SessionKanbanActivityPresentation.Snapshot {
        guard sessionID != nil, control.sessionKanbanSessionID == sessionID else {
            return .init(activeRows: [], completedRows: [])
        }
        return SessionKanbanActivityPresentation.makeSnapshot(tasks: control.sessionKanbanTasks)
    }

    private var botWorkRows: [SessionKanbanActivityPresentation.BotWorkRow] {
        SessionKanbanActivityPresentation.botWork(
            tasks: control.sessionKanbanTasks, bots: botMode.visibleBots, sessionID: sessionID)
    }

    private var sessionActivityBots: [BotSummary] {
        let activityBotIDs = Set(botWorkRows.map(\.botID))
        return botMode.visibleBots.filter { activityBotIDs.contains($0.id) }
    }

    private func activityText(for bot: BotSummary) -> String {
        botWorkRows
            .filter { $0.botID == bot.id }
            .map { "\($0.status.label) · \($0.title)" }
            .joined(separator: "\n")
    }

    private var refreshState: ProjectionRefreshState? {
        control.refreshState(for: "kanban.session")
    }

    var body: some View {
        Group {
            if sessionID != nil {
                content
            } else {
                unavailableContent
            }
        }
        .task(id: sessionID) {
            guard let sessionID else { return }
            control.refreshSessionKanban(for: sessionID)
            while !Task.isCancelled {
                // Feed rows and handoffs reach the chat through this poll, so
                // stay quick while work is live and relax when idle.
                let live =
                    model.status == .working
                    || control.sessionKanbanTasks.contains {
                        !["done", "archived", "completed"].contains($0.status.lowercased())
                    }
                try? await Task.sleep(for: .seconds(live ? 5 : 15))
                guard !Task.isCancelled else { continue }
                control.refreshSessionKanban(for: sessionID, quiet: true)
            }
        }
        .onChange(of: model.observedKanbanTaskRevision) { _, _ in
            // A terminal tool row can disappear before the 15-second polling
            // pass. Its exact task reference is retained by DockModel, so
            // refresh immediately rather than presenting a false empty state.
            if let sessionID { control.refreshSessionKanban(for: sessionID) }
        }
    }

    @ViewBuilder
    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("SESSION ACTIVITY")
            Text(sessionID == nil ? "SESSION ATTRIBUTION UNAVAILABLE" : "KANBAN CAPABILITY UNAVAILABLE")
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockWarning)
            Text(
                sessionID == nil
                    ? "This session has no durable attribution ID, so Bot work cannot be matched safely."
                    : "Hermes did not advertise the Kanban capability for this session."
            )
            .dockFont(.body)
            .foregroundStyle(Color.dockSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .dockGlassPane()
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !botWorkRows.isEmpty {
                botWorkSection
            }

            if snapshot.activeRows.isEmpty, snapshot.completedCount == 0 {
                if refreshState?.isRefreshing == true {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(Color.dockAccent)
                        Text("LOADING SESSION KANBAN")
                    }
                    .dockFont(.compactStatus, weight: .semibold)
                    .foregroundStyle(Color.dockMetadataText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if refreshState?.error != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SESSION KANBAN UNAVAILABLE")
                            .dockFont(.metadata, weight: .semibold)
                            .foregroundStyle(Color.dockWarning)
                        Text(
                            "The attribution query did not complete successfully. Retry before treating this session as empty."
                        )
                        .dockFont(.compactStatus, weight: .regular)
                        .foregroundStyle(Color.dockSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NO SESSION-ATTRIBUTED CARDS")
                            .dockFont(.metadata, weight: .semibold)
                            .foregroundStyle(Color.dockMetadataText)
                        Text("Global or manually created cards remain on the full board and are not shown here.")
                            .dockFont(.compactStatus, weight: .regular)
                            .foregroundStyle(Color.dockSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                ForEach(snapshot.activeRows) { row in
                    taskRow(row)
                }
                if snapshot.completedCount > 0 {
                    Button {
                        withAnimation(reduceMotion ? nil : .dockEase(duration: 0.16)) {
                            showsCompleted.toggle()
                        }
                    } label: {
                        HStack {
                            DockIcon(showsCompleted ? .caretDown : .caretRight)
                            Text("\(snapshot.completedCount) COMPLETED")
                            Spacer()
                        }
                    }
                    .buttonStyle(.dockHover)
                    .dockFont(.compactStatus, weight: .semibold)
                    .foregroundStyle(Color.dockMetadataText)
                    if showsCompleted {
                        ForEach(snapshot.completedRows) { row in
                            taskRow(row)
                        }
                    }
                }
            }

            if let error = refreshState?.error {
                HStack(alignment: .top, spacing: 7) {
                    DockIcon(.warning)
                    Text(refreshState?.isStale == true ? "STALE · \(error)" : error)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("RETRY") {
                        if let sessionID { control.refreshSessionKanban(for: sessionID) }
                    }
                    .buttonStyle(.dockCompact)
                }
                .dockFont(.compactStatus, weight: .regular)
                .foregroundStyle(Color.dockWarning)
            }

            if let onOpenBoard {
                Button {
                    onOpenBoard()
                } label: {
                    HStack {
                        Text("OPEN FULL KANBAN BOARD")
                        Spacer()
                        DockIcon(.arrowUpRight)
                    }
                }
                .buttonStyle(.dockHover)
                .dockFont(.compactStatus, weight: .semibold)
                .foregroundStyle(Color.dockAccent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DockLayout.tight)
        .dockGlassPane()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            sectionLabel("BOT ACTIVITY")
            Spacer(minLength: 0)
            if snapshot.activeCount > 0 {
                Text("\(snapshot.activeCount) ACTIVE")
                    .dockFont(.compactStatus, weight: .semibold)
                    .foregroundStyle(Color.dockMetadataText)
            }
            Button {
                if let sessionID { control.refreshSessionKanban(for: sessionID) }
            } label: {
                DockIcon(.arrowsClockwise)
            }
            .buttonStyle(.dockHover)
            .foregroundStyle(Color.dockAccent)
            .accessibilityLabel("Refresh session Kanban")
        }
    }

    private var botActivitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if sessionActivityBots.isEmpty {
                Text("No activity yet.")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
            } else {
                ForEach(sessionActivityBots) { bot in
                    HStack(alignment: .top, spacing: 9) {
                        BotAvatarView(
                            bot: bot, imageData: botMode.avatarImages[bot.id], size: 30,
                            orbits: botWorkRows.contains { $0.botID == bot.id && $0.status == .running })
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(bot.name)
                                    .dockFont(.body, weight: .semibold)
                                    .foregroundStyle(Color.dockPrimaryText)
                                Spacer(minLength: 4)
                                if bot.isRecentlyActive {
                                    Text("ACTIVE NOW")
                                        .dockFont(.compactStatus, weight: .semibold, design: .monospaced)
                                        .foregroundStyle(Color.dockSuccess)
                                }
                            }
                            Text(BotRosterPresentation.role(for: bot))
                                .dockFont(.metadata, weight: .medium)
                                .foregroundStyle(Color.dockMetadataText)
                                .lineLimit(1)
                            Text(activityText(for: bot))
                                .dockFont(.body)
                                .foregroundStyle(Color.dockSecondaryText)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(
                            Color.dockSurface4.opacity(0.68))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).stroke(
                            Color.dockBorderLight, lineWidth: 0.5))
                }
            }
        }
    }

    private var botWorkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("BOT WORK")
            ForEach(botWorkRows) { row in
                Button {
                    onOpenTask?(row.taskID)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(statusColor(row.status)).frame(width: 7, height: 7).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.botName).dockFont(.metadata, weight: .semibold).foregroundStyle(Color.dockAccent)
                            Text(row.title).dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
                                .lineLimit(2)
                            Text("\(row.status.label) · KANBAN TASK \(row.taskID)")
                                .dockFont(.compactStatus, weight: .medium, design: .monospaced)
                                .foregroundStyle(statusColor(row.status))
                        }
                        Spacer(minLength: 0)
                        DockIcon(.caretRight).dockFont(.compactStatus, weight: .semibold).foregroundStyle(
                            Color.dockMetadataText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(
                            Color.dockSurface4.opacity(0.68))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
                }
                .buttonStyle(.dockHover)
                .disabled(onOpenTask == nil)
                .accessibilityLabel("\(row.botName), \(row.status.label): \(row.title)")
            }
        }
    }

    private func taskRow(_ row: SessionKanbanActivityPresentation.Row) -> some View {
        Button {
            if let onOpenTask {
                onOpenTask(row.id)
            } else {
                onOpenBoard?()
            }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(statusColor(row.status))
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 7) {
                        Text(row.status.label)
                        if let assignee = row.assignee { Text("· \(assignee)") }
                        if let boardSlug = row.boardSlug { Text("· \(boardSlug)") }
                    }
                    .dockFont(.compactStatus, weight: .medium)
                    .foregroundStyle(statusColor(row.status))
                    if let detail = row.detail, row.status == .blocked {
                        Text(detail)
                            .dockFont(.compactStatus, weight: .regular)
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(2)
                    }
                }
                DockIcon(.caretRight)
                    .dockFont(.compactStatus, weight: .semibold)
                    .foregroundStyle(Color.dockMetadataText)
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(
                    Color.dockSurface4.opacity(0.68))
            )
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).stroke(
                    Color.dockBorderLight, lineWidth: 0.5))
        }
        .buttonStyle(.dockHover)
        .disabled(onOpenTask == nil && onOpenBoard == nil)
        .accessibilityLabel("\(row.status.label): \(row.title)")
    }

    private func statusColor(_ status: SessionKanbanActivityPresentation.Status) -> Color {
        switch status {
        case .running: .dockKanbanRunning
        case .blocked: .dockWarning
        case .ready: DockStatusTone.queued.color
        case .review: .dockKanbanReview
        case .done: .dockSuccess
        case .unknown: .dockSecondaryText
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .dockFont(.metadata, weight: .semibold)
            .tracking(0.8)
            .foregroundStyle(Color.dockSecondaryText)
    }
}
