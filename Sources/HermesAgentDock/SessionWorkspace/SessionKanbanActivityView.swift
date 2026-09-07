import SwiftUI

struct SessionKanbanActivityView: View {
    @ObservedObject var control: ControlCenterModel
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

    private var refreshState: ProjectionRefreshState? {
        control.refreshState(for: "kanban.session")
    }

    var body: some View {
        Group {
            if sessionID != nil, control.capabilityAvailable("kanban") {
                content
            }
        }
        .task(id: sessionID) {
            guard let sessionID else { return }
            if control.capabilityAvailable("kanban") {
                control.refreshSessionKanban(for: sessionID)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, control.capabilityAvailable("kanban") else { continue }
                control.refreshSessionKanban(for: sessionID)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if snapshot.activeRows.isEmpty, snapshot.completedCount == 0 {
                if refreshState?.isRefreshing == true {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(Color.dockAccent)
                        Text("LOADING SESSION KANBAN")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dockMetadataText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if refreshState?.error != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SESSION KANBAN UNAVAILABLE")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.dockWarning)
                        Text("The attribution query did not complete successfully. Retry before treating this session as empty.")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.dockSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NO SESSION-ATTRIBUTED CARDS")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.dockMetadataText)
                        Text("Global or manually created cards remain on the full board and are not shown here.")
                            .font(.system(size: 10))
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
                            LucideImage(systemName: showsCompleted ? "chevron.down" : "chevron.right")
                            Text("\(snapshot.completedCount) COMPLETED")
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .semibold))
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
                    LucideImage(systemName: "exclamationmark.triangle")
                    Text(refreshState?.isStale == true ? "STALE · \(error)" : error)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("RETRY") {
                        if let sessionID { control.refreshSessionKanban(for: sessionID) }
                    }
                    .buttonStyle(.borderless)
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.dockWarning)
            }

            if let onOpenBoard {
                Button {
                    onOpenBoard()
                } label: {
                    HStack {
                        Text("OPEN FULL KANBAN BOARD")
                        Spacer()
                        LucideImage(systemName: "arrow.up.right")
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
            }
        }
        .padding(12)
        .dockGlassPane()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            sectionLabel("SESSION KANBAN")
            Spacer(minLength: 0)
            if snapshot.activeCount > 0 {
                Text("\(snapshot.activeCount) ACTIVE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dockMetadataText)
            }
            Button {
                if let sessionID { control.refreshSessionKanban(for: sessionID) }
            } label: {
                LucideImage(systemName: "refresh-cw")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.dockAccent)
            .accessibilityLabel("Refresh session Kanban")
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 7) {
                        Text(row.status.label)
                        if let assignee = row.assignee { Text("· \(assignee)") }
                        if let boardSlug = row.boardSlug { Text("· \(boardSlug)") }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(statusColor(row.status))
                    if let detail = row.detail, row.status == .blocked {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(2)
                    }
                }
                LucideImage(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dockMetadataText)
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.dockSurface4.opacity(0.68))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.dockBorderLight, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(onOpenTask == nil && onOpenBoard == nil)
        .accessibilityLabel("\(row.status.label): \(row.title)")
    }

    private func statusColor(_ status: SessionKanbanActivityPresentation.Status) -> Color {
        switch status {
        case .running: .dockKanbanRunning
        case .blocked: .dockWarning
        case .ready: .dockAccent
        case .review: .dockKanbanReview
        case .done: .dockSuccess
        case .unknown: .dockSecondaryText
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.dockSecondaryText)
    }
}
