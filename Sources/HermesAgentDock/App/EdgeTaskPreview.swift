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

    /// Needs-you first, then running work, then unopened results; the open
    /// session leads its group and the rest are newest first.
    static func build(current: EdgeNotchTask?, sessions: [HermesSession],
                      currentSessionID: String?, isOnline: Bool) -> [EdgeNotchTask] {
        let others = sessions
            .filter { $0.id != currentSessionID && ($0.isWorking || $0.hasUnreadUpdate) }
            .map { session in
                EdgeNotchTask(
                    id: session.id,
                    title: session.displayTitle,
                    phase: session.isWorking ? .working : .finished,
                    statusLabel: session.isWorking ? "Working" : "Finished",
                    detail: session.displayPreview,
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
    let currentSessionTitle: String?
    let openDock: () -> Void
    let openTask: (EdgeNotchTask) -> Void
    @State private var hoveredID: String?

    private var inProgress: [EdgeNotchTask] { tasks.filter(\.isInProgress) }
    private var finished: [EdgeNotchTask] { tasks.filter { !$0.isInProgress } }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if tasks.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        TimelineView(.periodic(from: .now, by: 60)) { timeline in
                            VStack(alignment: .leading, spacing: 12) {
                                section("In progress", inProgress, now: timeline.date)
                                section("Finished, not opened", finished, now: timeline.date)
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
        Button { openTask(task) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    DockStatusDot(tone: task.tone, pulses: true)
                    Text(task.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(trailing(for: task, now: now))
                        .font(DockTypography.machineMetadata)
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                        .fixedSize()
                }
                HStack(spacing: 0) {
                    Text(task.displayStatus)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(task.tone.color)
                    if let detail = task.detail {
                        Text(" · \(detail)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                }
                .lineLimit(1)
                .padding(.leading, 15)
                if task.tone == .working {
                    DockShimmerTrack(tone: task.tone)
                        .padding(.leading, 15)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dockSignageCard(tone: task.tone, emphasized: task.isCurrent, highlighted: hoveredID == task.id)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredID = $0 ? task.id : (hoveredID == task.id ? nil : hoveredID) }
        .help(task.isCurrent ? "Open the current session" : "Open this session")
        .accessibilityLabel([task.title, task.isCurrent ? "current session" : nil, task.displayStatus, task.detail]
            .compactMap { $0 }.joined(separator: ". ") + ". Open session")
    }

    private func trailing(for task: EdgeNotchTask, now: Date) -> String {
        if task.isCurrent { return "Current" }
        guard let updatedAt = task.updatedAt else { return "" }
        return "\(EdgeQuotaPreview.shortDuration(now.timeIntervalSince(updatedAt))) ago"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isOffline ? "Hermes is offline" : "No tasks in progress")
                .font(.system(size: 12, weight: .semibold))
            Text(isOffline
                 ? "Running and finished tasks appear here once the Dock reconnects."
                 : "Running work and finished results you haven't opened appear here.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let currentSessionTitle {
                Text(currentSessionTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Open Dock", action: openDock)
                .buttonStyle(.plain)
                .foregroundStyle(Color.dockAccent)
                .font(.system(size: 12, weight: .semibold))
                .frame(height: 36)
                .contentShape(Rectangle())
                .fixedSize()
        }
        .lineLimit(1)
    }
}
