import SwiftUI
import UniformTypeIdentifiers

/// Card actions the adapter currently supports. Values, not the model, so the
/// board can skip re-rendering when unrelated control-center state publishes.
struct KanbanCardActionAvailability: Equatable {
    var details = false
    var complete = false
    var block = false
    var unblock = false
    var archive = false
    /// Triage/Todo/Ready lane drops.
    var move = false
    /// One-step assign/reassign to a bot profile.
    var assign = false

    var canDrag: Bool { move || complete || block }
}

/// The Kanban lanes and cards. The board takes plain values and is compared
/// with `.equatable()`, so streaming, polling, and hover elsewhere in the
/// workspace do not re-evaluate hundreds of cards. Each lane scrolls
/// vertically on its own; the board scrolls horizontally.
struct KanbanBoardView: View, Equatable {
    static let laneWidth: CGFloat = 272
    static let railWidth: CGFloat = 40

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
                        .onDrop(of: [UTType.text], delegate: KanbanLaneDropDelegate(
                            lane: lane,
                            tasks: tasks,
                            draggingTaskID: $draggingTaskID,
                            targetedLane: $targetedLane,
                            drop: onDrop
                        ))
                    }
                }
                .padding(.bottom, 8)
                .frame(maxHeight: .infinity, alignment: .top)
            }
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
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
                Text("\(laneTasks.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(lane.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(lane.color.opacity(0.12))
                    .clipShape(Capsule())
                Spacer(minLength: 4)
                Button {
                    expansion.collapse(lane, hasTasks: !laneTasks.isEmpty)
                } label: {
                    DockIcon(.caretLeft)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.dockMetadataText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Collapse \(lane.rawValue) lane")
                .accessibilityLabel("Collapse \(lane.rawValue) lane")
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 36)
            Rectangle().fill(lane.color.opacity(0.45)).frame(height: 1)

            if laneTasks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lane.emptyTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockSecondaryText)
                    Text(lane.emptyDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockMetadataText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(laneTasks) { task in
                            KanbanTaskCard(
                                task: task,
                                lane: lane,
                                summary: snapshot.detail(for: task.id),
                                bot: snapshot.visibleBot(for: task.assignee),
                                avatarData: snapshot.visibleBot(for: task.assignee).flatMap { avatarImages[$0.id] },
                                isSelected: selectedTaskID == task.id,
                                now: now,
                                actions: actions,
                                pendingActionIDs: pendingActionIDs,
                                isLoadingDetail: loadingDetailTaskID == task.id,
                                assignableBots: bots,
                                draggingTaskID: $draggingTaskID,
                                onSelect: onSelect,
                                onAction: onAction,
                                onAssign: onAssign
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: Self.laneWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(targetedLane == lane ? lane.color.opacity(0.10) : Color.dockSurface.opacity(0.20))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if targetedLane == lane {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(lane.color.opacity(0.7), lineWidth: 1)
            }
        }
    }
}

/// Lane drop target. Only cards dragged from this board are accepted; a lane
/// the card cannot enter (its own, or a system-owned lane) shows the
/// forbidden cursor instead of highlighting.
private struct KanbanLaneDropDelegate: DropDelegate {
    let lane: KanbanLane
    let tasks: [KanbanTaskSummary]
    @Binding var draggingTaskID: String?
    @Binding var targetedLane: KanbanLane?
    let drop: @MainActor (KanbanTaskSummary, KanbanLane) -> Void

    private var draggedTask: KanbanTaskSummary? {
        guard let draggingTaskID else { return nil }
        return tasks.first { $0.id == draggingTaskID }
    }

    private var accepts: Bool {
        guard let draggedTask else { return false }
        switch KanbanBoardPresentation.dropOutcome(taskStatus: draggedTask.status, target: lane) {
        case .move, .confirm: return true
        case .none, .refused: return false
        }
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
              let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        // The remembered ID can be stale after a cancelled drag, so act only
        // when the payload itself names the same card.
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
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(count > 0 ? lane.color : Color.dockMetadataText)
                VStack(spacing: 1) {
                    ForEach(Array(lane.rawValue.uppercased().enumerated()), id: \.offset) { _, letter in
                        Text(String(letter))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isHovered ? Color.dockPrimaryText : Color.dockSecondaryText)
                            .frame(height: 13)
                    }
                }
                DockIcon(.caretRight)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.dockMetadataText)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .frame(width: KanbanBoardView.railWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(railBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(lane.color.opacity(0.7), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Expand \(lane.rawValue) lane")
        .accessibilityLabel("Expand \(lane.rawValue) lane, \(count) tasks")
    }

    private var railBackground: Color {
        if isDropTarget { return lane.color.opacity(0.10) }
        return isHovered ? Color.dockSurface2.opacity(0.7) : Color.dockSurface.opacity(0.20)
    }
}

private struct KanbanTaskCard: View {
    let task: KanbanTaskSummary
    let lane: KanbanLane
    let summary: String?
    let bot: BotSummary?
    let avatarData: Data?
    let isSelected: Bool
    let now: Date
    let actions: KanbanCardActionAvailability
    let pendingActionIDs: Set<String>
    let isLoadingDetail: Bool
    let assignableBots: [BotSummary]
    @Binding var draggingTaskID: String?
    let onSelect: (KanbanTaskSummary) -> Void
    let onAction: (KanbanTaskSummary, KanbanTaskAction) -> Void
    let onAssign: (KanbanTaskSummary, String?) -> Void

    // Hover is local so it re-renders one card, not the board.
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, showsMenu ? 24 : 0)

            if let summary = summary ?? nonEmpty(task.detail) {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
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
                Text(task.id)
                    .fontDesign(.monospaced)
                    .foregroundStyle(Color.dockMetadataText.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.dockAccent.opacity(0.7) : (isHovered ? Color.dockBorder : Color.dockBorderLight), lineWidth: isSelected ? 1 : 0.5)
        }
        .overlay(alignment: .leading) {
            if lane == .blocked || lane == .running {
                lane.color.frame(width: 2).padding(.vertical, 8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { onSelect(task) }
        .modifier(KanbanCardDragSource(
            isEnabled: actions.canDrag && !isMovePending,
            taskID: task.id,
            draggingTaskID: $draggingTaskID,
            preview: dragPreview
        ))
        // Attached after the tap/drag gestures so they cannot swallow the
        // click, and kept in the tree so losing hover while the menu is open
        // does not tear it down.
        .overlay(alignment: .topTrailing) {
            Menu { actionMenu } label: {
                Ph.dotsThree.image(size: 14)
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 28, height: 22)
                    .background(Color.dockSurface2.opacity(0.9), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            // `.borderlessButton` drops custom labels on macOS, leaving only the indicator.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.top, 6)
            .padding(.trailing, 6)
            .opacity(showsMenu ? 1 : 0)
            .allowsHitTesting(showsMenu)
            .help("More Kanban actions")
            .accessibilityLabel("More actions for \(task.title)")
        }
        .onHover { isHovered = $0 }
        .contextMenu { actionMenu }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(task.title), \(lane.rawValue)")
    }

    private var showsMenu: Bool { isHovered || isSelected }
    private var isMovePending: Bool { pendingActionIDs.contains("kanban.move:\(task.id)") }
    private var isAssignPending: Bool { pendingActionIDs.contains("kanban.reassign:\(task.id)") }

    private var dragPreview: some View {
        Text(task.title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.dockPrimaryText)
            .lineLimit(2)
            .frame(width: KanbanBoardView.laneWidth - 40, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.dockSurface2)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(lane.color.opacity(0.6), lineWidth: 1))
    }

    private var background: Color {
        if isSelected { return Color.dockAccent.opacity(0.10) }
        return isHovered ? Color.dockSurface2 : Color.dockSurface
    }

    private var activityLabel: String {
        guard let date = task.latestEventAt ?? task.startedAt else { return "No activity" }
        return KanbanBoardPresentation.compactAge(since: date, now: now)
    }

    private func priorityTag(_ priority: String) -> some View {
        let tint = (Int(priority) ?? 0) >= 80 ? Color.dockWarning : Color.dockSecondaryText
        return Text("P\(priority)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
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
        if lane == .done, actions.archive {
            actionButton("Archive", icon: .archive, action: .archive)
        } else if lane == .blocked, actions.unblock {
            actionButton("Unblock", icon: .arrowUUpLeft, action: .unblock)
        } else {
            if actions.complete { actionButton("Done", icon: .check, action: .complete) }
            if actions.block { actionButton("Block", icon: .pause, action: .block) }
        }
        if actions.assign, !assignableBots.isEmpty {
            Divider()
            Menu("Assign to", icon: .userCircle) {
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
        if !hasAnyAction {
            Text("No actions available")
        }
    }

    private var hasAnyAction: Bool {
        actions.details || actions.complete || actions.block
            || (lane == .done && actions.archive) || (lane == .blocked && actions.unblock)
            || (actions.assign && !assignableBots.isEmpty)
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

/// Starts a card drag. The dragged ID is kept locally so lanes can validate
/// the drop synchronously and refuse text dragged in from other apps.
private struct KanbanCardDragSource<Preview: View>: ViewModifier {
    let isEnabled: Bool
    let taskID: String
    @Binding var draggingTaskID: String?
    let preview: Preview

    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrag {
                draggingTaskID = taskID
                return NSItemProvider(object: taskID as NSString)
            } preview: {
                preview
            }
        } else {
            content
        }
    }
}

/// Initial-letter avatar for assignees without a Bot profile.
struct KanbanAssigneeInitialAvatar: View {
    let assignee: String
    var size: CGFloat = 30

    var body: some View {
        let hue = Double(assignee.utf8.reduce(0) { ($0 + Int($1)) % 360 }) / 360
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color(hue: hue, saturation: 0.62, brightness: 0.82))
            Text(String(assignee.prefix(1)).uppercased())
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
        }
        .frame(width: size, height: size)
    }
}
