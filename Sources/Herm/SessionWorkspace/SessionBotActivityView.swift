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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("BOT ACTIVITY")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.dockSecondaryText)
                Spacer()
            }
            if snapshot.list.isEmpty {
                Text(snapshot.emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSecondaryText)
                    .padding(.vertical, 8)
            } else {
                listView
            }
        }
        .padding(embedded ? 0 : 12)
        .modifier(BotActivityGlassModifier(isEmbedded: embedded))
        .task(id: sessionID) {
            await botMode.refreshNow(force: true)
            await botMode.loadAvatars()
        }
    }

    private var listView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(snapshot.list) { record in
                activityRow(record)
            }
        }
    }

    private func activityRow(_ record: BotActivityRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
            if let bot = botMode.visibleBots.first(where: { $0.id == record.botID }) {
                BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: 34)
            } else {
                BotFaceMark(id: record.botID, size: 34, animated: true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(record.botName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Text(record.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(record.state.label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(record.state == .completed ? Color.dockSuccess : record.state == .failed ? Color.dockDestructive : Color.dockAccent)
                .frame(minWidth: 62, alignment: .trailing)
            Text(HumanDateFormatting.timeOnly(record.updatedAt))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.dockMetadataText)
            Button {
                if expandedRecordIDs.contains(record.id) {
                    expandedRecordIDs.remove(record.id)
                } else {
                    expandedRecordIDs.insert(record.id)
                }
            } label: {
                DockIcon(expandedRecordIDs.contains(record.id) ? .caretUp : .caretDown)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dockMetadataText)
            }
            .buttonStyle(.dockHover)
            .accessibilityLabel(expandedRecordIDs.contains(record.id) ? "Collapse \(record.botName) activity" : "Expand \(record.botName) activity")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.dockSurface4.opacity(0.72))
        .overlay {
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .stroke(Color.dockBorderLight, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(record.botName), \(record.summary), \(record.state.label)")
            if expandedRecordIDs.contains(record.id) {
                VStack(alignment: .leading, spacing: 5) {
                    if let result = record.result, !result.isEmpty {
                        Text(result)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockPrimaryText)
                            .textSelection(.enabled)
                    }
                    if let bot = botMode.visibleBots.first(where: { $0.id == record.botID }) {
                        Button("OPEN IN BOT CHAT") { onOpenBotChat?(bot) }
                            .buttonStyle(.dockHover)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.dockAccent)
                    }
                }
                .padding(.horizontal, 56)
                .padding(.bottom, 10)
            }
        }
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
