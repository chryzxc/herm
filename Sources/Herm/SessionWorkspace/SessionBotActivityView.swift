import SwiftUI

struct SessionBotActivityView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var botMode: BotModeModel
    let sessionID: String?
    /// Exact session-attributed cards supplied by the canonical Kanban
    /// projection. Direct Bot relays remain below as separate history.
    var kanbanTasks: [KanbanTaskSummary] = []
    var onOpenBotChat: ((BotSummary) -> Void)?
    var embedded = false
    @State private var expandedRecordIDs: Set<String> = []

    private var snapshot: SessionBotActivityPresentation.Snapshot {
        _ = model.botActivityRevision
        var records = model.botActivityBySessionID.values.flatMap { $0 }
        let sessionIDs = Set(model.botActivitySessionIDs.compactMap { $0 }.filter { !$0.isEmpty })
        let knownResults = Set(records.filter { sessionIDs.contains($0.originSessionID) }.compactMap { $0.result })
        let originSessionID = model.kanbanSessionID ?? sessionID
        for (index, message) in model.messages.enumerated() {
            guard let botID = message.botProfileID,
                  message.role == .hermes,
                  !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !knownResults.contains(message.text),
                  let originSessionID else { continue }
            let request = index > 0 && model.messages[index - 1].role == .user
                ? model.messages[index - 1].text
                : "Bot response"
            records.append(BotActivityRecord(
                originSessionID: originSessionID,
                botID: botID,
                botName: message.botDisplayName ?? botID,
                summary: request,
                state: .completed,
                createdAt: message.timestamp,
                updatedAt: message.timestamp,
                result: message.text
            ))
        }
        // Kanban cards are the durable activity source for dispatched Bot
        // work. Only cards already admitted by the strict session projection
        // arrive here, including a null-session card recovered by an exact
        // trusted tool reference. Never infer a Bot from conversation prose.
        let knownIDs = Set(records.map(\.id))
        for task in kanbanTasks {
            let recordID = "kanban:\(task.id)"
            guard !knownIDs.contains(recordID) else { continue }
            let bot = task.assignee.flatMap { id in botMode.visibleBots.first(where: { $0.id == id }) }
            records.append(BotActivityRecord(
                id: recordID,
                originSessionID: originSessionID ?? sessionID ?? "",
                botID: bot?.id ?? "delegated-agent",
                botName: bot?.name ?? (task.assignee?.isEmpty == false ? task.assignee! : "Delegated agent"),
                summary: task.title,
                state: SessionBotActivityPresentation.state(forKanbanStatus: task.status),
                createdAt: task.startedAt ?? task.latestEventAt ?? Date(),
                updatedAt: task.latestEventAt ?? task.completedAt ?? task.startedAt ?? Date(),
                result: task.latestEventNote,
                linkedCardID: task.id
            ))
        }
        return SessionBotActivityPresentation.snapshot(records: records, sessionIDs: model.botActivitySessionIDs)
    }

    var body: some View {
        let snapshot = snapshot
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("BOT ACTIVITY")
                    .dockFont(.navigation, weight: .medium)
                    .foregroundStyle(Color.dockSecondaryText)
                Spacer()
            }
            if snapshot.list.isEmpty {
                Text(snapshot.emptyMessage)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .padding(.vertical, 8)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.list) { record in
                        let bot = botMode.visibleBots.first(where: { $0.id == record.botID })
                        BotActivityRow(record: record, bot: bot, avatar: bot.flatMap { botMode.avatarImages[$0.id] },
                                       expanded: expandedRecordIDs.contains(record.id),
                                       onToggle: { toggle(record.id) }, onOpenBotChat: onOpenBotChat)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                }
            }
        }
        // New records slide in and state changes recolor smoothly.
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: snapshot.list.map { "\($0.id)|\($0.state.rawValue)" })
        .padding(embedded ? 0 : 12)
        .modifier(BotActivityGlassModifier(isEmbedded: embedded))
        .task(id: sessionID) {
            await botMode.refreshNow(force: true)
            await botMode.loadAvatars()
        }
    }

    private func toggle(_ id: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if expandedRecordIDs.contains(id) { expandedRecordIDs.remove(id) } else { expandedRecordIDs.insert(id) }
        }
    }
}

/// One Bot's piece of work. The whole card toggles the result; a working Bot
/// gets the star orbit and an accent outline.
private struct BotActivityRow: View {
    let record: BotActivityRecord
    let bot: BotSummary?
    let avatar: Data?
    let expanded: Bool
    let onToggle: () -> Void
    let onOpenBotChat: ((BotSummary) -> Void)?
    @State private var hovering = false

    private var working: Bool { record.state == .working }
    private var stateColor: Color {
        switch record.state {
        case .working: .dockAccent
        case .waiting: .dockWarning
        case .completed: .dockSuccess
        case .failed: .dockDestructive
        case .queued, .canceled: .dockMetadataText
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    if let bot {
                        BotAvatarView(bot: bot, imageData: avatar, size: 34, mood: BotMood(activity: record.state))
                    } else {
                        BotFaceMark(id: record.botID, size: 34, animated: true, mood: BotMood(activity: record.state))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.botName)
                            .dockFont(.navigation, weight: .semibold)
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(1)
                        Text(record.summary)
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    statePill
                    Text(HumanDateFormatting.timeOnly(record.updatedAt))
                        .dockFont(.compactStatus, weight: .regular, design: .monospaced)
                        .foregroundStyle(Color.dockMetadataText)
                    DockIcon(.caretDown, size: 10, color: hovering ? .dockSecondaryText : .dockMetadataText)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(record.botName), \(record.summary), \(record.state.label)")
            .accessibilityHint(expanded ? "Collapse activity" : "Expand activity")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let result = record.result, !result.isEmpty {
                        Text(result)
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockPrimaryText)
                            .textSelection(.enabled)
                    }
                    if let bot {
                        Button("OPEN IN BOT CHAT") { onOpenBotChat?(bot) }
                            .buttonStyle(.dockCompact)
                            .dockFont(.compactStatus, weight: .semibold, design: .monospaced)
                            .foregroundStyle(Color.dockAccent)
                    }
                }
                .padding(.leading, 56)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(hovering ? Color.dockSurface6.opacity(0.8) : Color.dockSurface4.opacity(0.72))
        .overlay {
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .stroke(working ? Color.dockAccent.opacity(0.45) : Color.dockBorderLight, lineWidth: working ? 1 : 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var statePill: some View {
        HStack(spacing: 4) {
            if [.working, .waiting, .queued].contains(record.state) {
                BotActivityPulse(color: stateColor)
            }
            Text(record.state.label.uppercased())
                .dockFont(size: 9, weight: .semibold)
                .contentTransition(.interpolate)
        }
        .foregroundStyle(stateColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(stateColor.opacity(0.14)))
    }
}

/// A breathing dot for work still in flight. Still under Reduce Motion.
private struct BotActivityPulse: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(color)
            .frame(width: 5, height: 5)
            .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.35]) { dot, phase in
                dot.opacity(phase).scaleEffect(0.8 + 0.2 * phase)
            } animation: { _ in .easeInOut(duration: 0.8) }
    }
}

private struct BotActivityGlassModifier: ViewModifier {
    let isEmbedded: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEmbedded {
            content
        } else {
            content.dockGlassPane()
        }
    }
}
