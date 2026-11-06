import AppKit
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
    @MainActor
    final class KanbanCardEvaluations {
        var counts: [String: Int] = [:]
    }

    private struct KanbanCardEvaluationsKey: EnvironmentKey {
        static let defaultValue: KanbanCardEvaluations? = nil
    }

    extension EnvironmentValues {
        var kanbanCardEvaluations: KanbanCardEvaluations? {
            get { self[KanbanCardEvaluationsKey.self] }
            set { self[KanbanCardEvaluationsKey.self] = newValue }
        }
    }
#endif

/// Card actions the adapter currently supports. Values, not the model, so the
/// board can skip re-rendering when unrelated control-center state publishes.
struct KanbanCardActionAvailability: Equatable {
    var details = true
    var complete = false
    var block = false
    var unblock = false
    var archive = false
    /// Triage/Todo/Ready lane drops.
    var move = false
    /// One-step assign/reassign to a bot profile.
    var assign = false

    func destinations(for status: String) -> [KanbanLane] {
        KanbanLane.allCases.filter { lane in
            switch KanbanBoardPresentation.dropOutcome(taskStatus: status, target: lane) {
            case .move: return move
            case .confirm(.complete): return complete
            case .confirm(.block): return block
            default: return false
            }
        }
    }
}

/// The Kanban lanes and cards. The board takes plain values and is compared
/// with `.equatable()`, so streaming, polling, and hover elsewhere in the
/// workspace do not re-evaluate hundreds of cards. Each lane scrolls
/// vertically on its own; the board scrolls horizontally.
struct KanbanBoardView: View, Equatable {
    static let laneWidth: CGFloat = 272
    static let railWidth: CGFloat = 48

    let tasks: [KanbanTaskSummary]
    let bots: [BotSummary]
    let visibleBots: [BotSummary]
    let avatarImages: [String: Data]
    let selectedTaskID: String?
    let actions: KanbanCardActionAvailability
    /// Pending per-task Kanban action IDs (`kanban.<action>:<task>`).
    let pendingActionIDs: Set<String>
    let loadingDetailTaskID: String?
    let onSelect: (KanbanTaskSummary) -> Void
    let onAction: (KanbanTaskSummary, KanbanTaskAction) -> Void
    let onDrop: @MainActor (KanbanTaskSummary, KanbanLane) -> Void
    /// `nil` unassigns.
    let onAssign: (KanbanTaskSummary, String?) -> Void

    @State private var expansion = KanbanLaneExpansionState()
    @State private var draggingTaskID: String?
    @State private var targetedLane: KanbanLane?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (lhs: KanbanBoardView, rhs: KanbanBoardView) -> Bool {
        lhs.selectedTaskID == rhs.selectedTaskID
            && lhs.loadingDetailTaskID == rhs.loadingDetailTaskID
            && lhs.actions == rhs.actions
            && lhs.pendingActionIDs == rhs.pendingActionIDs
            && lhs.tasks == rhs.tasks
            && lhs.bots == rhs.bots
            && lhs.visibleBots == rhs.visibleBots
            && lhs.avatarImages == rhs.avatarImages
    }

    var body: some View {
        let snapshot = KanbanBoardPresentation.makeSnapshot(tasks: tasks, bots: bots, visibleBots: visibleBots)
        // Relative activity only needs minute resolution; one shared clock
        // replaces a per-card live timer.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(KanbanLane.allCases) { lane in
                        let laneTasks = snapshot.tasks(in: lane)
                        Group {
                            if expansion.isExpanded(lane, hasTasks: !laneTasks.isEmpty) {
                                expandedLane(lane, tasks: laneTasks, snapshot: snapshot, now: context.date)
                            } else {
                                KanbanLaneRail(lane: lane, count: laneTasks.count, isDropTarget: targetedLane == lane) {
                                    expansion.expand(lane, hasTasks: !laneTasks.isEmpty)
                                }
                            }
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: KanbanLaneDropDelegate(
                                lane: lane,
                                tasks: tasks,
                                actions: actions,
                                pendingActionIDs: pendingActionIDs,
                                draggingTaskID: $draggingTaskID,
                                targetedLane: $targetedLane,
                                drop: onDrop
                            ))
                    }
                }
                .dockPadding(.bottom, 8)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .onChange(of: draggingTaskID) { _, id in
            if id == nil { targetedLane = nil }
        }
    }

    private func expandedLane(
        _ lane: KanbanLane,
        tasks laneTasks: [KanbanTaskSummary],
        snapshot: KanbanBoardPresentation.Snapshot,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                DockIcon(lane.icon, size: 13, color: Color.dockMetadataText)
                    .foregroundStyle(lane.color)
                Text(lane.rawValue.uppercased())
                    .dockFont(.metadata, weight: .semibold)
                    .tracking(0.8)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
                Text("\(laneTasks.count)")
                    .dockFont(.compactStatus, weight: .semibold, design: .monospaced)
                    .foregroundStyle(lane.color)
                    .dockPadding(.horizontal, 6)
                    .dockPadding(.vertical, 2)
                    .background(lane.color.opacity(0.12))
                    .clipShape(Capsule())
                Spacer(minLength: 4)
                Button {
                    expansion.collapse(lane, hasTasks: !laneTasks.isEmpty)
                } label: {
                    DockIcon(.caretLeft)
                        .dockFont(.compactStatus, weight: .bold)
                        .foregroundStyle(Color.dockMetadataText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .help("Collapse \(lane.rawValue) lane")
                .accessibilityLabel("Collapse \(lane.rawValue) lane")
            }
            .dockPadding(.leading, 10)
            .dockPadding(.trailing, 4)
            .frame(height: 36)
            Rectangle().fill(lane.color.opacity(0.45)).frame(height: 1)

            if laneTasks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lane.emptyTitle)
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockSecondaryText)
                    Text(lane.emptyDetail)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockMetadataText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dockPadding(12)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(laneTasks) { task in
                            KanbanTaskCard(
                                task: task,
                                lane: lane,
                                bot: snapshot.visibleBot(for: task.assignee),
                                avatarData: snapshot.visibleBot(for: task.assignee).flatMap { avatarImages[$0.id] },
                                isSelected: selectedTaskID == task.id,
                                activityLabel: (task.latestEventAt ?? task.startedAt).map {
                                    KanbanBoardPresentation.compactAge(since: $0, now: now)
                                } ?? "No activity",
                                actions: actions,
                                pendingActionIDs: pendingActionIDs.filter { $0.hasSuffix(":\(task.id)") },
                                isLoadingDetail: loadingDetailTaskID == task.id,
                                assignableBots: bots,
                                isDragging: draggingTaskID == task.id,
                                draggingTaskID: $draggingTaskID,
                                onSelect: onSelect,
                                onAction: onAction,
                                onMove: onDrop,
                                onAssign: onAssign
                            )
                            .equatable()
                        }
                    }
                    .animation(reduceMotion ? nil : .dockEase(duration: 0.2), value: laneTasks.map(\.id))
                    .dockPadding(8)
                }
            }
        }
        .frame(width: Self.laneWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(lane.color.opacity(targetedLane == lane ? 0.10 : 0))
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous))
        .contentShape(Rectangle())
        .dockWell(
            .sunken, radius: DockLayout.paneRadius, role: .pane,
            stroke: targetedLane == lane ? lane.color.opacity(0.7) : nil)
    }
}

/// Lane drop target. Only cards dragged from this board are accepted; a lane
/// the card cannot enter (its own, or a system-owned lane) shows the
/// forbidden cursor instead of highlighting.
private struct KanbanLaneDropDelegate: DropDelegate {
    let lane: KanbanLane
    let tasks: [KanbanTaskSummary]
    let actions: KanbanCardActionAvailability
    let pendingActionIDs: Set<String>
    @Binding var draggingTaskID: String?
    @Binding var targetedLane: KanbanLane?
    let drop: @MainActor (KanbanTaskSummary, KanbanLane) -> Void

    private var draggedTask: KanbanTaskSummary? {
        guard let draggingTaskID else { return nil }
        return tasks.first { $0.id == draggingTaskID }
    }

    private var accepts: Bool {
        guard let draggedTask,
            !pendingActionIDs.contains(where: { $0.hasSuffix(":\(draggedTask.id)") })
        else { return false }
        return actions.destinations(for: draggedTask.status).contains(lane)
    }

    func validateDrop(info: DropInfo) -> Bool { draggedTask != nil }

    func dropEntered(info: DropInfo) {
        if accepts { targetedLane = lane }
    }

    func dropExited(info: DropInfo) {
        if targetedLane == lane { targetedLane = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: accepts ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggingTaskID = nil
            targetedLane = nil
        }
        guard accepts, let draggedTask,
            let provider = info.itemProviders(for: [UTType.text]).first
        else { return false }
        // Validate the transferred payload against this board’s active drag.
        let lane = lane
        let drop = drop
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            let payload = (object as? NSString).map(String.init)
            Task { @MainActor in
                if payload == draggedTask.id { drop(draggedTask, lane) }
            }
        }
        return true
    }
}

/// A collapsed lane: a narrow full-height rail with the name stacked one
/// letter per line so the whole board stays in one scan line.
private struct KanbanLaneRail: View {
    let lane: KanbanLane
    let count: Int
    let isDropTarget: Bool
    let onExpand: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onExpand) {
            VStack(spacing: 8) {
                DockIcon(lane.icon, size: 13, color: Color.dockMetadataText)
                    .foregroundStyle(lane.color)
                    .frame(height: 20)
                Text("\(count)")
                    .dockFont(.compactStatus, weight: .semibold, design: .monospaced)
                    .foregroundStyle(count > 0 ? lane.color : Color.dockMetadataText)
                Text(lane.rawValue)
                    .dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(isHovered ? Color.dockPrimaryText : Color.dockSecondaryText)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: KanbanBoardView.railWidth, height: 90)
                DockIcon(.caretRight)
                    .dockFont(.metadata, weight: .bold)
                    .foregroundStyle(Color.dockMetadataText)
                Spacer(minLength: 0)
            }
            .dockPadding(.top, 8)
            .frame(width: KanbanBoardView.railWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(railBackground)
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous))
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous)
                        .stroke(lane.color.opacity(0.7), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous))
        }
        .buttonStyle(.dockHover)
        .onHover { isHovered = $0 }
        .help("Expand \(lane.rawValue) lane")
        .accessibilityLabel("Expand \(lane.rawValue) lane, \(count) tasks")
    }

    private var railBackground: Color {
        if isDropTarget { return lane.color.opacity(0.10) }
        return isHovered ? Color.dockSurface2.opacity(0.7) : Color.dockSurface.opacity(0.20)
    }
}

private struct KanbanTaskCard: View, Equatable {
    let task: KanbanTaskSummary
    let lane: KanbanLane
    let bot: BotSummary?
    let avatarData: Data?
    let isSelected: Bool
    let activityLabel: String
    let actions: KanbanCardActionAvailability
    let pendingActionIDs: Set<String>
    let isLoadingDetail: Bool
    let assignableBots: [BotSummary]
    let isDragging: Bool
    @Binding var draggingTaskID: String?
    let onSelect: (KanbanTaskSummary) -> Void
    let onAction: (KanbanTaskSummary, KanbanTaskAction) -> Void
    let onMove: @MainActor (KanbanTaskSummary, KanbanLane) -> Void
    let onAssign: (KanbanTaskSummary, String?) -> Void

    // Hover is local so it re-renders one card, not the board.
    @State private var isHovered = false
    @Environment(\.chatContextRouter) private var chatRouter
    #if DEBUG
        @Environment(\.kanbanCardEvaluations) private var evaluations
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isSelected == rhs.isSelected
            && lhs.isLoadingDetail == rhs.isLoadingDetail
            && lhs.isDragging == rhs.isDragging
            && lhs.activityLabel == rhs.activityLabel
            && lhs.actions == rhs.actions
            && lhs.pendingActionIDs == rhs.pendingActionIDs
            && lhs.task == rhs.task
            && lhs.lane == rhs.lane
            && lhs.bot == rhs.bot
            && lhs.avatarData == rhs.avatarData
            && lhs.assignableBots == rhs.assignableBots
    }

    var body: some View {
        #if DEBUG
            let _ = evaluations.map { $0.counts[task.id, default: 0] += 1 }
        #endif
        let isDraggable = !actions.destinations(for: task.status).isEmpty && !isMutationPending
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title)
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .dockPadding(.trailing, 24)

            // Format only mounted cards; task bodies can be large on old boards.
            if let summary = KanbanBoardPresentation.cardDetail(task.detail) ?? nonEmpty(task.detail) {
                Text(summary)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                if let priority = nonEmpty(task.priority) {
                    priorityTag(priority)
                }
                if let assignee = nonEmpty(task.assignee) {
                    assigneeLabel(assignee)
                } else {
                    Text("Unassigned")
                        .foregroundStyle(Color.dockMetadataText)
                }
                Spacer(minLength: 6)
                Text(activityLabel)
                    .foregroundStyle(Color.dockMetadataText)
                    .layoutPriority(1)
            }
            .dockFont(.compactStatus, weight: .medium)
            .lineLimit(1)
        }
        .dockPadding(.horizontal, 10)
        .dockPadding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if lane == .blocked || lane == .running {
                lane.color.frame(width: 2).dockPadding(.vertical, 8)
            }
        }
        .dockCard(padding: 0, isActive: isHovered)
        .overlay {
            if isSelected {
                DockThemeShape(cornerRadius: DockLayout.paneRadius, role: .pane)
                    .stroke(Color.dockAccent.opacity(0.7), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous))
        .dockHoverable()
        .overlay {
            KanbanCardDragSource(
                taskID: task.id,
                isEnabled: isDraggable,
                select: { onSelect(task) },
                dragging: { draggingTaskID = $0 ? task.id : nil }
            )
        }
        // Attached after the tap/drag gestures so they cannot swallow the
        // click, and kept in the tree so losing hover while the menu is open
        // does not tear it down.
        .overlay(alignment: .topTrailing) {
            DockMenu {
                actionMenu
            } label: {
                Group {
                    if isMutationPending {
                        ProgressView().controlSize(.mini)
                    } else {
                        Ph.dotsThree.image(size: 14, color: NSColor(Color.dockSecondaryText))
                    }
                }
                .frame(width: 28, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous).dockSurfaceFill(
                        Color.dockSurface2.opacity(0.9))
                )
                .contentShape(Rectangle())
            }
            // `.borderlessButton` drops custom labels on macOS, leaving only the indicator.
            .buttonStyle(.dockHover)
            .fixedSize()
            .dockPadding(.top, 6)
            .dockPadding(.trailing, 6)
            .disabled(isMutationPending)
            .help("More Kanban actions")
            .accessibilityLabel("More actions for \(task.title)")
        }
        .opacity(isDragging ? 0.18 : 1)
        .onHover { isHovered = $0 }
        .modifier(
            KanbanCardDragCursor(
                isEnabled: isDraggable,
                isDragging: isDragging
            )
        )
        .contextMenu { actionMenu }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(task.title), \(lane.rawValue)")
        .accessibilityAction { onSelect(task) }
    }

    private var isMutationPending: Bool { pendingActionIDs.contains { $0.hasSuffix(":\(task.id)") } }
    private var isAssignPending: Bool { pendingActionIDs.contains("kanban.reassign:\(task.id)") }

    private func priorityTag(_ priority: String) -> some View {
        let tint = (Int(priority) ?? 0) >= 80 ? Color.dockWarning : Color.dockSecondaryText
        return Text("P\(priority)")
            .dockFont(.compactStatus, weight: .semibold, design: .monospaced)
            .foregroundStyle(tint)
            .dockPadding(.horizontal, 5)
            .dockPadding(.vertical, 2)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func assigneeLabel(_ assignee: String) -> some View {
        HStack(spacing: 4) {
            if let bot {
                BotAvatarView(bot: bot, imageData: avatarData, size: 14)
            } else {
                KanbanAssigneeInitialAvatar(assignee: assignee, size: 14)
            }
            Text(assignee)
                .foregroundStyle(Color.dockSecondaryText)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var actionMenu: some View {
        if actions.details {
            Button("Details", icon: .fileText) { onSelect(task) }
                .disabled(isLoadingDetail)
        }
        if let chatRouter {
            Button("Send to chat", icon: .chatCircleText) {
                chatRouter.attach(ChatContext(kanbanTask: task), to: nil)
            }
        }
        let destinations = actions.destinations(for: task.status)
        if !destinations.isEmpty {
            DockMenu("Move to") {
                ForEach(destinations) { destination in
                    Button(destination.rawValue) { onMove(task, destination) }
                }
            }
            .disabled(isMutationPending)
        }
        if lane == .blocked, actions.unblock {
            actionButton("Unblock", icon: .arrowUUpLeft, action: .unblock)
        } else {
            if actions.complete { actionButton("Done", icon: .check, action: .complete) }
            if actions.block { actionButton("Block", icon: .pause, action: .block) }
        }
        if actions.archive { actionButton("Archive", icon: .archive, action: .archive) }
        if actions.assign, !assignableBots.isEmpty {
            Divider()
            DockMenu("Assign to", icon: .userCircle) {
                ForEach(assignableBots) { bot in
                    Button {
                        onAssign(task, bot.id)
                    } label: {
                        if isAssigned(to: bot) {
                            Label(bot.name, icon: .check)
                        } else {
                            Text(bot.name)
                        }
                    }
                    .disabled(isAssigned(to: bot))
                }
                if nonEmpty(task.assignee) != nil {
                    Divider()
                    Button("Unassign") { onAssign(task, nil) }
                }
            }
            .disabled(isAssignPending)
        }
    }

    private func isAssigned(to bot: BotSummary) -> Bool {
        task.assignee?.caseInsensitiveCompare(bot.id) == .orderedSame
    }

    private func actionButton(_ title: String, icon: Ph, action: KanbanTaskAction) -> some View {
        Button(title, icon: icon) { onAction(task, action) }
            .disabled(pendingActionIDs.contains("kanban.\(action.rawValue):\(task.id)"))
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// Uses the standard macOS grab cursors without leaving an entry on the
/// cursor stack when a card becomes disabled or leaves the view hierarchy.
private struct KanbanCardDragCursor: ViewModifier {
    let isEnabled: Bool
    let isDragging: Bool

    @State private var isHovering = false
    @State private var hasPushedCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                refreshCursor()
            }
            .onChange(of: isDragging) { _, _ in refreshCursor() }
            .onChange(of: isEnabled) { _, _ in refreshCursor() }
            .onDisappear { removeCursor() }
    }

    private func refreshCursor() {
        removeCursor()
        guard isEnabled, isHovering else { return }
        (isDragging ? NSCursor.closedHand : NSCursor.openHand).push()
        hasPushedCursor = true
    }

    private func removeCursor() {
        guard hasPushedCursor else { return }
        NSCursor.pop()
        hasPushedCursor = false
    }
}

/// Initial-letter avatar for assignees without a Bot profile.
struct KanbanAssigneeInitialAvatar: View {
    let assignee: String
    var size: CGFloat = 30

    var body: some View {
        let color = DockAccentColor.identity(for: assignee).color
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(color.opacity(0.14))
            Text(String(assignee.prefix(1)).uppercased())
                .dockFont(size: size * 0.4, weight: .bold)
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}
