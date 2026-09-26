import SwiftUI

/// One row in the notch's Tasks tab: a session that is running, waiting on
/// the user, or finished with a result the user has not opened yet.
struct EdgeNotchTask: Identifiable, Equatable {
    enum Phase: Int, Comparable {
        case attention, working, finished
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

    var isInProgress: Bool { phase != .finished }

    var tone: DockStatusTone {
        guard isStatusCurrent || phase == .finished else { return .inactive }
        switch phase {
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

/// The notch's Tasks tab: every session in progress and every finished
/// result not yet opened, drawn as office-style signage cards.
struct EdgeTaskPreview: View {
    let tasks: [EdgeNotchTask]
    let isOffline: Bool
    /// Set when a quota drop is announced alongside a task update.
    var quotaChange: EdgeQuotaChange? = nil
    let openDock: () -> Void
    @AppStorage(DoubleTapShortcut.workspaceKey) private var workspaceShortcut = DoubleTapShortcut.command
    let openTask: (EdgeNotchTask) -> Void
    @State private var hoveredID: String?

    private var inProgress: [EdgeNotchTask] { tasks.filter(\.isInProgress) }
    private var finished: [EdgeNotchTask] { tasks.filter { !$0.isInProgress } }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if tasks.isEmpty && quotaChange == nil {
                    emptyState
                } else {
                    ScrollView {
                        TimelineView(.periodic(from: .now, by: 60)) { timeline in
                            VStack(alignment: .leading, spacing: 12) {
                                section("In progress", inProgress, now: timeline.date)
                                section("Finished, not opened", finished, now: timeline.date)
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
        return Button { openTask(task) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                DockStatusDot(tone: task.tone, pulses: true)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
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
                        if let detail = task.detail {
                            Text(" · \(detail)")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.dockMetadataText)
                        }
                    }
                    .lineLimit(1)
                    if task.tone == .working {
                        DockShimmerTrack(tone: task.tone).padding(.top, 3)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                    .fill(isHovered ? Color.dockSurface4.opacity(0.6) : task.isCurrent ? Color.dockSurface4.opacity(0.35) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? task.id : (hoveredID == task.id ? nil : hoveredID) }
        .help(task.isCurrent ? "Open the current session" : "Open this session")
        .accessibilityLabel([task.title, task.isCurrent ? "current session" : nil, task.displayStatus, task.detail]
            .compactMap { $0 }.joined(separator: ". ") + ". Open session")
    }

    @ViewBuilder
    private func trailing(for task: EdgeNotchTask, now: Date) -> some View {
        if task.isCurrent {
            Text("Current")
                .font(.system(size: 10, weight: .semibold))
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
        VStack(alignment: .leading, spacing: 6) {
            Text(isOffline ? "Hermes is offline" : "No tasks in progress")
                .font(.system(size: 12, weight: .semibold))
            Text(isOffline
                 ? "Running and finished tasks appear here once Herm reconnects."
                 : "Running work and finished results you haven't opened appear here.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        EdgePreviewFooterButton(title: "Open Herm", icon: .sidebarSimple, shortcut: workspaceShortcut.keycap,
                                shortcutHelp: workspaceShortcut.title, fillsWidth: true, action: openDock)
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
