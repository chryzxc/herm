import SwiftUI

enum EdgeTaskSource: String, CaseIterable {
    case activity, kanban

    var title: String { self == .activity ? "Activity" : "Kanban" }

    func includes(_ task: EdgeNotchTask) -> Bool {
        self == .kanban ? task.kanbanTask != nil : task.kanbanTask == nil
    }
}

/// One row in the notch’s Tasks tab: session work or canonical Kanban activity.
struct EdgeNotchTask: Identifiable, Equatable {
    enum Phase: Int, Comparable {
        case attention, working, pending, finished
        static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let title: String
    let phase: Phase
    let statusLabel: String
    let detail: String?
    let updatedAt: Date?
    /// The session currently open in the Dock. It opens without resuming.
    let isCurrent: Bool
    /// False while Hermes is offline: the last projection stays visible but
    /// live states are no longer claimed.
    let isStatusCurrent: Bool
    let session: HermesSession?
    var kanbanTask: KanbanTaskSummary? = nil

    var isInProgress: Bool { phase != .finished }

    var tone: DockStatusTone {
        guard isStatusCurrent || phase == .finished else { return .inactive }
        if let kanbanTask {
            switch SessionKanbanActivityPresentation.Status(rawValue: kanbanTask.status) {
            case .blocked: return .attention
            case .running: return .working
            case .review: return .review
            case .ready: return .queued
            case .done: return .complete
            case .unknown: return .inactive
            }
        }
        switch phase {
        case .pending: return .queued
        case .attention: return .attention
        case .working: return .working
        case .finished: return .complete
        }
    }

    var displayStatus: String {
        tone == .inactive ? "Status not current" : statusLabel
    }

    /// A background session that was working is now finished; the open
    /// session's own completion is announced from its live status instead.
    static func newlyFinished(from previous: [EdgeNotchTask], to current: [EdgeNotchTask]) -> Bool {
        let wasWorking = Set(previous.filter { !$0.isCurrent && $0.phase == .working }.map(\.id))
        return current.contains { !$0.isCurrent && $0.phase == .finished && wasWorking.contains($0.id) }
    }

    /// Needs-you first, then running work, then unopened results; the open
    /// session leads its group and the rest are newest first.
    /// A working row shows its latest activity, never the session's opening
    /// prompt, which says nothing about what is happening now.
    static func build(current: EdgeNotchTask?, sessions: [HermesSession], activity: [String: String] = [:],
                      currentSessionIDs: Set<String>, isOnline: Bool) -> [EdgeNotchTask] {
        // Without a live row of its own, the open session's index row stands in.
        // The open session can be known by a runtime alias its index row does
        // not carry, so an in-progress row with its title is the same chat.
        let others = sessions
            .filter { session in
                guard let current else { return true }
                return !currentSessionIDs.contains(session.id)
                    && !(current.isInProgress && session.isWorking && session.displayTitle == current.title)
            }
            .filter { $0.isWorking || $0.hasUnreadUpdate }
            .map { session in
                EdgeNotchTask(
                    id: session.id,
                    title: session.displayTitle,
                    phase: session.isWorking ? .working : .finished,
                    statusLabel: session.isWorking ? "Working" : "Finished",
                    detail: session.isWorking ? activity[session.id] : session.displayPreview,
                    updatedAt: session.lastUpdatedAt,
                    isCurrent: false,
                    isStatusCurrent: isOnline,
                    session: session
                )
            }
        return ([current].compactMap { $0 } + others).sorted { lhs, rhs in
            if lhs.phase != rhs.phase { return lhs.phase < rhs.phase }
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
    }
}

/// The notch’s Tasks tab shares compact activity rows between sessions and Kanban.
struct EdgeTaskPreview: View {
    let tasks: [EdgeNotchTask]
    let isOffline: Bool
    var source: EdgeTaskSource = .activity
    /// Set when a quota drop is announced alongside a task update.
    var quotaChange: EdgeQuotaChange? = nil
    var kanbanUnavailable = false
    var bots: [BotSummary] = []
    var avatarImages: [String: Data] = [:]
    var quickMessage: (() -> Void)? = nil
    var reply: ((EdgeNotchTask) -> Void)? = nil
    var quickState: EdgeNotchState? = nil
    var quickModel: DockModel? = nil
    var closeReply: () -> Void = {}
    let openDock: () -> Void
    @AppStorage(DoubleTapShortcut.workspaceKey) private var workspaceShortcut = DoubleTapShortcut.command
    let openTask: (EdgeNotchTask) -> Void
    @State private var hoveredID: String?

    private var visibleTasks: [EdgeNotchTask] { tasks.filter(source.includes) }
    private var inProgress: [EdgeNotchTask] { tasks.filter { $0.kanbanTask == nil && $0.isInProgress } }
    private var finished: [EdgeNotchTask] { tasks.filter { $0.kanbanTask == nil && !$0.isInProgress } }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if visibleTasks.isEmpty && quotaChange == nil {
                    emptyState
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                                VStack(alignment: .leading, spacing: 12) {
                                    if source == .kanban {
                                        section("Kanban activity", visibleTasks, now: timeline.date)
                                    } else {
                                        section("In progress", inProgress, now: timeline.date)
                                        section("Finished, not opened", finished, now: timeline.date)
                                    }
                                    if let quotaChange {
                                        VStack(alignment: .leading, spacing: 6) {
                                            DockSectionLabel(title: "Quota")
                                            EdgeQuotaChangeCard(change: quotaChange, compact: true)
                                                .id(quotaChange.current.updatedAt)
                                                .padding(.horizontal, 10)
                                        }
                                    }
                                }
                                .padding(.vertical, 12)
                            }
                        }
                        .scrollIndicators(.never)
                        .onChange(of: quickState?.composing == true ? quickState?.quickReplyTask?.id : nil, initial: true) { _, id in
                            if let id { proxy.scrollTo("reply-\(id)", anchor: .bottom) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Color.dockBorderLight)
            footer
        }
        .foregroundStyle(Color.dockPrimaryText)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [EdgeNotchTask], now: Date) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                DockSectionLabel(title: title, count: items.count)
                ForEach(items) { card($0, now: now) }
            }
        }
    }

    private func card(_ task: EdgeNotchTask, now: Date) -> some View {
        let isHovered = hoveredID == task.id
        let isReplying = quickState?.composing == true && quickState?.quickReplyTask?.id == task.id
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                taskButton(task, now: now)
                if task.kanbanTask == nil, let reply, task.session != nil || task.isCurrent {
                    replyToggle(task, isReplying: isReplying, visible: isHovered || isReplying || task.isCurrent, reply: reply)
                        .padding(.top, 5)
                        .padding(.trailing, 4)
                }
            }
            if isReplying, let quickState, let quickModel {
                EdgeQuickMessageView(model: quickModel, state: quickState, inline: true,
                                     close: closeReply, openDock: openDock)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .id("reply-\(task.id)")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                .fill(isHovered || isReplying ? Color.dockSurface4.opacity(0.6) : task.isCurrent ? Color.dockSurface4.opacity(0.35) : .clear)
        )
        .onHover { hoveredID = $0 ? task.id : (hoveredID == task.id ? nil : hoveredID) }
        .animation(.dockEase(duration: 0.16), value: isReplying)
    }

    /// Reply lives inside the card and turns into a close button while composing.
    private func replyToggle(_ task: EdgeNotchTask, isReplying: Bool, visible: Bool,
                             reply: @escaping (EdgeNotchTask) -> Void) -> some View {
        Button { isReplying ? closeReply() : reply(task) } label: {
            DockIcon(isReplying ? .x : .arrowBendUpLeft, size: 13, color: .dockSecondaryText)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous).fill(Color.dockSurface4.opacity(isReplying ? 0.9 : 0.5)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.dockPress)
        .opacity(visible ? 1 : 0)
        .disabled(quickState?.quickSending == true)
        .modifier(EdgeHoverTip(text: isReplying ? "Close reply" : "Reply in the notch"))
        .accessibilityLabel(isReplying ? "Close reply" : "Reply to \(task.title)")
    }

    private func taskButton(_ task: EdgeNotchTask, now: Date) -> some View {
        Button { openTask(task) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let assignee = task.kanbanTask?.assignee, !assignee.isEmpty {
                    let bot = KanbanBoardPresentation.makeSnapshot(tasks: [], bots: bots).bot(for: assignee)
                    Group {
                        if let bot {
                            BotAvatarView(bot: bot, imageData: avatarImages[bot.id], size: 26)
                        } else {
                            KanbanAssigneeInitialAvatar(assignee: assignee, size: 26)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        DockStatusDot(tone: task.tone, pulses: true, muted: true)
                            .background(Circle().fill(Color.dockCanvas).padding(-2))
                            .offset(x: 2, y: 2)
                    }
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    .accessibilityLabel("Assigned to \(bot?.name ?? assignee)")
                } else {
                    DockStatusDot(tone: task.tone, pulses: true, muted: true)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(task.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        trailing(for: task, now: now)
                    }
                    HStack(spacing: 0) {
                        // Hue only for trouble; everything else stays neutral.
                        Text(task.displayStatus)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(task.tone == .attention ? task.tone.color : Color.dockSecondaryText)
                        if let detail = task.detail, !detail.isEmpty {
                            Text(" · \(detail)")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.dockMetadataText)
                        }
                    }
                    .lineLimit(1)
                    if task.tone == .working {
                        DockShimmerTrack(tone: task.tone, muted: true).padding(.top, 3)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(task.kanbanTask != nil ? "Open this Kanban card" : task.isCurrent ? "Open the current session" : "Open this session")
        .accessibilityLabel([task.title, task.isCurrent ? "current session" : nil, task.displayStatus, task.detail]
            .compactMap { $0 }.joined(separator: ". ") + (task.kanbanTask != nil ? ". Open Kanban card" : ". Open session"))
    }

    @ViewBuilder
    private func trailing(for task: EdgeNotchTask, now: Date) -> some View {
        if task.isCurrent {
            Text("Current")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.dockSecondaryText)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(Capsule().fill(Color.dockSurface4.opacity(0.8)))
                .fixedSize()
        } else if let updatedAt = task.updatedAt {
            Text("\(EdgeQuotaPreview.shortDuration(now.timeIntervalSince(updatedAt))) ago")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DockSpacing.tight) {
            Text(emptyTitle)
                .font(.system(size: 12, weight: .semibold))
            Text(emptyDetail)
                .font(DockTypography.body)
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, DockSpacing.group)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyTitle: String {
        if isOffline { return "Hermes is offline" }
        if source == .kanban { return kanbanUnavailable ? "Kanban is unavailable" : "No Kanban activity" }
        return "No activity in progress"
    }

    private var emptyDetail: String {
        if isOffline { return "Updates will resume when Herm reconnects." }
        if source == .kanban {
            return kanbanUnavailable ? "The board could not be refreshed. Herm will retry automatically."
                : "Running cards and recent board changes appear here."
        }
        return "Running sessions and unopened results appear here."
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if let quickMessage {
                EdgePreviewFooterButton(title: "Quick message", icon: .chats, action: quickMessage)
            }
            Spacer(minLength: 0)
            EdgePreviewFooterButton(title: "Open Herm", icon: .sidebarSimple,
                                    shortcutHelp: workspaceShortcut.title, action: openDock)
        }
        .padding(.vertical, 6)
    }
}

/// The preview's one footer action: a quiet row that lifts on hover, with an
/// optional keyboard hint. Replaces accent text links so the footer reads as
/// part of the panel rather than a web link.
struct EdgePreviewFooterButton: View {
    let title: String
    let icon: Ph
    var shortcut: String?
    var shortcutHelp: String?
    var fillsWidth = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                DockIcon(icon, size: 13, color: isHovering ? .dockPrimaryText : .dockSecondaryText)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHovering ? Color.dockPrimaryText : Color.dockSecondaryText)
                if fillsWidth { Spacer(minLength: 8) }
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.dockMetadataText)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.dockBorder, lineWidth: 0.5))
                        .help(shortcutHelp ?? "")
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 30, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                    .fill(isHovering ? Color.dockSurface4.opacity(0.6) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockPress)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(shortcutHelp ?? "")
    }
}

/// `.help` tooltips never appear in the non-activating notch panel, so hover
/// draws its own label beside the control.
private struct EdgeHoverTip: ViewModifier {
    let text: String
    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                pending?.cancel()
                guard hovering else { shown = false; return }
                pending = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    if !Task.isCancelled { shown = true }
                }
            }
            .overlay(alignment: .trailing) {
                if shown {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.dockSurface4))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.dockBorderStrong, lineWidth: 1))
                        .alignmentGuide(.trailing) { $0[.leading] - 30 }
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.dockEase(duration: 0.12), value: shown)
    }
}
