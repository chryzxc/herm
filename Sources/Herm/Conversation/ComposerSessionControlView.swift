import SwiftUI

struct ComposerSessionControlView: View {
    @ObservedObject var model: DockModel
    @Environment(\.dockHostVisible) private var hostVisible

    var body: some View {
        let sessionID = model.sessionID
        let profileID = model.sessionProfileID ?? model.profileScopeID
        let owner = "\(profileID ?? "")|\(sessionID ?? "")|\(hostVisible)"
        VStack(alignment: .leading, spacing: 4) {
            if let sessionID,
                model.sessionControlOwner == model.sessionControlKey(sessionID: sessionID, profileID: profileID)
            {
                if model.sessionControlStale {
                    Text("Session automation unavailable or out of date")
                        .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                        .dockPadding(.horizontal, 8)
                }
                if let snapshot = model.sessionControl {
                    if let goal = snapshot.goal {
                        let status =
                            goal.lastVerdict == "blocked"
                            ? "Blocked"
                            : goal.waitBarrier != nil ? "Waiting" : goal.status.capitalized
                        let turns = goal.maxTurns > 0 ? " · Turn \(goal.turnsUsed)/\(goal.maxTurns)" : ""
                        ComposerAutomationRow(
                            title: "Goal \(status)\(turns)",
                            details: [goal.title, goal.pausedReason, goal.waitBarrier?.reason, goal.lastReason]
                                .compactMap { $0 }.filter { !$0.isEmpty } + goal.subgoals)
                    }
                    if let loop = snapshot.loop {
                        let timing = loop.maxTicks > 0 ? " · \(loop.ticksFired)/\(loop.maxTicks) runs" : ""
                        ComposerAutomationRow(
                            title: "Loop \(loop.status.capitalized)\(timing)",
                            details: [
                                loop.prompt, "Interval: \(loop.intervalSeconds.formatted()) seconds",
                                loop.deferredByGoal ? "Waiting for goal" : nil, loop.pausedReason,
                            ].compactMap { $0 })
                    }
                    if let heartbeat = snapshot.heartbeat {
                        ComposerAutomationRow(
                            title: "Heartbeat \(heartbeat.status.capitalized)",
                            details: [
                                heartbeat.prompt, "Interval: \(heartbeat.intervalSeconds) seconds",
                                "Runs: \(heartbeat.fireCount)",
                            ])
                    }
                }
            }
        }
        .task(id: owner) {
            guard hostVisible, let sessionID, !sessionID.isEmpty else { return }
            if model.sessionControlOwner != model.sessionControlKey(sessionID: sessionID, profileID: profileID) {
                model.sessionControl = nil
                model.sessionControlOwner = nil
                model.sessionControlStale = false
            }
            while !Task.isCancelled {
                await model.refreshSessionControl(sessionID: sessionID, profileID: profileID)
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
}

private struct ComposerAutomationRow: View {
    let title: String
    let details: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    DockIcon(expanded ? .caretDown : .caretRight, size: 10, color: .dockMetadataText)
                    Text(title).dockFont(.body).foregroundStyle(Color.dockSecondaryText).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .dockPadding(.horizontal, 8)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                            Text(detail).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .dockPadding(.horizontal, 26).dockPadding(.bottom, 8)
                }
                .frame(maxHeight: 140).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
