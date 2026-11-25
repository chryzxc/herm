import SwiftUI

enum OfficeDeskTab: String, CaseIterable {
    case work = "Work"
    case activity = "Activity"
    case crew = "Crew"
    case kanban = "Kanban"
}

struct OfficeDeskView: View {
    @Binding var tab: OfficeDeskTab
    @Binding var crewQuery: String
    @Binding var eventFilter: OfficeDeskEvent.Kind?
    let agents: [OfficePreviewAgentPresentation]
    let bots: [BotSummary]
    let avatarImages: [String: Data]
    let events: [OfficeDeskEvent]
    let lanes: [OfficePreviewBoardLane]
    let isKanbanCurrent: Bool
    let isOnline: Bool
    let onFocus: (String) -> Void

    @Namespace private var tabs

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                ForEach(OfficeDeskTab.allCases, id: \.self) { item in
                    DockTabButton(
                        title: item.rawValue, isSelected: item == tab, selectionNamespace: tabs, fillsWidth: true
                    ) { tab = item }
                }
            }
            .dockTabTrack()
            .dockPadding(.horizontal, 14)
            .dockPadding(.vertical, 10)
            Divider()
            switch tab {
            case .work: work
            case .activity: activity
            case .crew: crew
            case .kanban: OfficeBoardInspector(lanes: lanes, isCurrent: isKanbanCurrent)
            }
        }
    }

    private var work: some View {
        let groups = OfficeDeskWorkGroups(agents: agents, kanbanCurrent: isKanbanCurrent)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !isOnline {
                    empty("Hermes is offline", detail: "Reconnect to see who is working now.", icon: .wifiSlash)
                } else {
                    if !groups.attention.isEmpty {
                        workSection("Needs attention", agents: groups.attention)
                    }
                    if !groups.working.isEmpty {
                        workSection("Working now", agents: groups.working)
                    }
                    if !groups.board.isEmpty {
                        workSection("Review and queue", agents: groups.board)
                    }
                    if groups.isEmpty {
                        empty(
                            "No active work reported",
                            detail: isKanbanCurrent
                                ? "New sessions and task updates will appear here."
                                : "Live sessions can appear here even when Kanban is unavailable.",
                            icon: .tray)
                    }
                }
            }
            .dockPadding(14)
        }
    }

    private func workSection(_ title: String, agents: [OfficePreviewAgentPresentation]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).dockFont(.body, weight: .semibold)
                Spacer()
                Text(agents.count.formatted()).dockFont(.metadata, weight: .medium)
                    .foregroundStyle(Color.dockMetadataText).monospacedDigit()
                    .accessibilityLabel("\(agents.count) bots")
            }
            .dockPadding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
            ForEach(agents) { agent in botRow(agent, showsWork: true) }
        }
    }

    private var crew: some View {
        let query = crewQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = agents.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        return VStack(alignment: .leading, spacing: 0) {
            DockSearchField(placeholder: "Find a bot", text: $crewQuery, accessibilityID: "office.crew.search")
                .dockPadding(14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if matching.isEmpty {
                        empty(
                            query.isEmpty ? "No bots reported" : "No matching bots",
                            detail: query.isEmpty ? "Bots appear when Hermes reports the roster." : "Try another name.",
                            icon: .users)
                    }
                    ForEach(matching) { agent in botRow(agent, showsWork: false) }
                }
                .dockPadding(.horizontal, 14)
                .dockPadding(.bottom, 14)
            }
        }
    }

    private func botRow(_ agent: OfficePreviewAgentPresentation, showsWork: Bool) -> some View {
        let status = OfficeAgentStatus(agent: agent, isDataCurrent: isKanbanCurrent)
        let bot = bots.first { $0.id == agent.faceID }
        let summary = agent.liveWork == nil ? agent.taskData?.title ?? agent.mainSession?.title : agent.liveWork?.title
        return Button {
            onFocus(agent.id)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                if let bot {
                    BotAvatarView(bot: bot, imageData: avatarImages[bot.id], size: 30)
                        .accessibilityHidden(true)
                } else {
                    DockIcon(.cpu, size: 16, color: .dockSecondaryText).frame(width: 30, height: 30)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(agent.name).dockFont(.body, weight: .semibold).lineLimit(1)
                        Spacer(minLength: 4)
                        HStack(spacing: 4) {
                            DockStatusDot(tone: status.tone, size: 6)
                            Text(status.label).dockFont(.metadata, weight: .medium)
                        }
                        .foregroundStyle(Color.dockSecondaryText)
                    }
                    if showsWork {
                        if agent.reportedWork.count > 1 {
                            let sessions = agent.reportedWork.filter { $0.sessionID != nil }.count
                            let count = agent.reportedWork.count
                            Text(sessions == count ? "\(count) active sessions" : "\(count) active items")
                                .dockFont(.metadata, weight: .medium)
                                .foregroundStyle(Color.dockSecondaryText)
                            ForEach(agent.reportedWork.prefix(2)) { item in
                                sessionPreview(item)
                            }
                        } else {
                            if let summary {
                                Text(summary).dockFont(.body).foregroundStyle(Color.dockPrimaryText)
                                    .lineLimit(2)
                            }
                            if let detail = agent.monitorDetail, detail != summary {
                                Text(detail).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                DockIcon(.caretRight, size: 10, color: .dockMetadataText)
            }
            .frame(minHeight: 44)
            .dockPadding(.horizontal, 8)
            .dockPadding(.vertical, showsWork ? 7 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityHint("Shows this bot's work and centers the office camera")
    }

    private func sessionPreview(_ item: BotLiveWork) -> some View {
        let status: OfficeAgentStatus = item.status == .blocked ? .blocked : .working
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.title ?? "Session details unavailable").lineLimit(1)
            Spacer(minLength: 4)
            Text(status.label).foregroundStyle(status.color).fixedSize()
        }
        .dockFont(.metadata)
        .foregroundStyle(Color.dockSecondaryText)
    }

    private var activity: some View {
        let visible = events.filter { eventFilter == nil || $0.kind == eventFilter }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(isOnline ? "Recent activity" : "Last reported · offline")
                    .dockFont(.body, weight: .semibold)
                Spacer()
                DockMenu {
                    Button("All events") { eventFilter = nil }
                    ForEach(OfficeDeskEvent.Kind.allCases, id: \.self) { kind in
                        Button(kind.filterTitle) { eventFilter = kind }
                    }
                } label: {
                    Label(eventFilter?.filterTitle ?? "All events", icon: .funnel)
                }
            }
            .dockPadding(14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if visible.isEmpty {
                        empty(
                            "No events to show",
                            detail: "Reported session steps, handoffs, and Kanban changes appear here.",
                            icon: .clockCounterClockwise)
                    }
                    ForEach(visible) { event in
                        eventRow(event)
                        Divider().dockPadding(.leading, 34)
                    }
                }
                .dockPadding(.horizontal, 14)
                .dockPadding(.bottom, 14)
            }
        }
    }

    private func eventRow(_ event: OfficeDeskEvent) -> some View {
        HStack(alignment: .top, spacing: 9) {
            DockIcon(event.kind.icon, size: 14, color: .dockSecondaryText)
                .frame(width: 25, height: 23)
                .dockWell()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).dockFont(.body, weight: .medium)
                    .foregroundStyle(Color.dockPrimaryText).lineLimit(3)
                Text(event.context).dockFont(.metadata)
                    .foregroundStyle(Color.dockSecondaryText).lineLimit(2)
            }
            Spacer(minLength: 4)
            Text(event.timestamp, format: .relative(presentation: .numeric)).dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText).monospacedDigit().fixedSize()
                .help(event.timestamp.formatted(date: .abbreviated, time: .shortened))
        }
        .dockPadding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func empty(_ title: String, detail: String, icon: Ph) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DockIcon(icon, size: 17, color: .dockSecondaryText)
            Text(title).dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
            Text(detail).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockPadding(12)
    }
}

extension OfficeDeskEvent.Kind {
    fileprivate var icon: Ph {
        switch self {
        case .step: .pulse
        case .handoff: .arrowBendUpRight
        case .kanban: .kanban
        }
    }
}
