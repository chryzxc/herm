import Combine
import SwiftUI

struct ComposerSessionControlView: View {
    let model: DockModel
    @State private var presentationRevision = 0
    @Environment(\.dockHostVisible) private var hostVisible

    var body: some View {
        let _ = presentationRevision
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
                                .compactMap { $0 }.filter { !$0.isEmpty } + goal.subgoals,
                            actions: HermesSessionControl.Action.available(goalStatus: goal.status),
                            isEnabled: model.sessionActionsReady, run: model.runSessionControlAction)
                    }
                    if let loop = snapshot.loop {
                        let timing = loop.maxTicks > 0 ? " · \(loop.ticksFired)/\(loop.maxTicks) runs" : ""
                        ComposerAutomationRow(
                            title: "Loop \(loop.status.capitalized)\(timing)",
                            details: [
                                loop.prompt, "Interval: \(loop.intervalSeconds.formatted()) seconds",
                                loop.deferredByGoal ? "Waiting for goal" : nil, loop.pausedReason,
                            ].compactMap { $0 },
                            actions: HermesSessionControl.Action.available(loopStatus: loop.status),
                            isEnabled: model.sessionActionsReady, run: model.runSessionControlAction)
                    }
                    if let heartbeat = snapshot.heartbeat {
                        ComposerAutomationRow(
                            title: "Heartbeat \(heartbeat.status.capitalized)",
                            details: [
                                heartbeat.prompt, "Interval: \(heartbeat.intervalSeconds) seconds",
                                "Runs: \(heartbeat.fireCount)",
                            ],
                            actions: HermesSessionControl.Action.available(heartbeatStatus: heartbeat.status),
                            isEnabled: model.sessionActionsReady, run: model.runSessionControlAction)
                    }
                }
            }
        }
        .onReceive(
            Publishers.MergeMany(
                DockModel.change(model.$sessionID), DockModel.change(model.$sessionProfileID),
                DockModel.change(model.$profileScopeID), DockModel.change(model.$sessionControlOwner),
                DockModel.change(model.$sessionControl), DockModel.change(model.$sessionControlStale),
                DockModel.change(model.$sessionTranscriptLoadState))
        ) { _ in presentationRevision &+= 1 }
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
    let actions: [HermesSessionControl.Action]
    let isEnabled: Bool
    let run: (HermesSessionControl.Action) async -> Void
    @State private var expanded = false
    /// The action in flight: its icon shows progress and the row ignores repeats until it finishes.
    @State private var pending: HermesSessionControl.Action?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
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
                ForEach(actions, id: \.self) { action in
                    DockIconButton(
                        icon: action.icon, label: action.label, help: action.help,
                        isBusy: pending == action, hasBackground: false, size: 22,
                        style: DockThemePalette(theme: DockThemeRuntime.current)
                    ) {
                        guard pending == nil else { return }
                        pending = action
                        Task {
                            await run(action)
                            pending = nil
                        }
                    }
                    .disabled(pending != nil || !isEnabled)
                }
            }
            .dockPadding(.trailing, actions.isEmpty ? 0 : 6)
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

extension HermesSessionControl.Action {
    fileprivate var icon: Ph {
        switch self {
        case .goalPause, .loopPause, .heartbeatPause: .pause
        case .goalResume, .loopResume, .heartbeatResume: .play
        case .goalClear, .heartbeatClear: .x
        case .loopStop: .stop
        }
    }

    fileprivate var help: String {
        switch self {
        case .goalPause: "Pause goal"
        case .goalResume: "Resume goal"
        case .goalClear: "Clear goal"
        case .loopPause: "Pause loop"
        case .loopResume: "Resume loop"
        case .loopStop: "Stop loop"
        case .heartbeatPause: "Pause heartbeat"
        case .heartbeatResume: "Resume heartbeat"
        case .heartbeatClear: "Clear heartbeat"
        }
    }
}
