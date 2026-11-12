import SwiftUI

/// Reads current projections when available; captured content survives transcript paging.
struct SessionDataPreviewView: View {
    let content: SessionPreviewContent
    @ObservedObject var model: DockModel
    @ObservedObject var botMode: BotModeModel
    let onOpenPullRequestChat: (PullRequestRecord) -> Void

    var body: some View {
        Group {
            if case .message(let message) = content {
                SessionMessageTabView(message: message, model: model)
            } else if case .file(let url) = content {
                FilePreviewPane(url: url, model: model)
            } else if case .botSettings(let captured) = content {
                BotProfileEditorSheet(
                    model: botMode, bot: botMode.botsByID[captured.id] ?? captured,
                    onDone: {
                        Task {
                            await botMode.refreshNow(force: true)
                            await botMode.loadAvatars()
                            await botMode.loadRuntimeConfigs(force: true)
                        }
                    }, isEmbedded: true)
            } else if case .pullRequest(let reference) = content {
                SessionPullRequestPreview(reference: reference, onOpenChat: onOpenPullRequestChat)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        previewContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dockPadding(DockSpacing.inspectorInset)
                }
            }
        }
        .foregroundStyle(Color.dockPrimaryText)
        .environment(\.sessionPreviewWorkspace, WorkspaceIdentity.session(model))
    }

    @ViewBuilder private var previewContent: some View {
        switch content {
        case .message, .file, .pullRequest, .botSettings: EmptyView()
        case .bot(let captured):
            let bot = botMode.botsByID[captured.id] ?? captured
            header(bot.name, subtitle: bot.title ?? "Bot profile", icon: .robot, bot: bot)
            if botMode.botsByID[bot.id] == nil { capturedNotice }
            DockChipFlow {
                if let provider = bot.provider { DockMetadataPill(text: provider) }
                if let model = bot.model { DockMetadataPill(text: model) }
            }
            prose("About", icon: .identificationCard, text: bot.description)
            group("Profile", icon: .robot) {
                fact("Profile", bot.id)
                if let lastActive = bot.lastActive {
                    fact("Last activity", lastActive.formatted(date: .abbreviated, time: .shortened))
                }
                if let chat = bot.chat { fact("Chat", chat.title ?? chat.sessionID) }
                if let worker = bot.worker { fact("Worker", worker.title ?? worker.sessionID) }
            }
            prose("Latest chat preview", icon: .chatText, text: bot.preview)
        case .dispatch(let captured):
            let record = currentDispatch(captured) ?? captured
            let bot = botMode.botsByID[record.botID]
            header(bot?.name ?? record.botName, subtitle: "Dispatched task", icon: .paperPlaneTilt, bot: bot)
            if currentDispatch(captured) == nil { capturedNotice }
            DockChipFlow {
                DockMetadataPill(text: record.state.label)
                if let id = record.linkedCardID { DockMetadataPill(text: "Kanban " + id) }
            }
            group("Dispatch", icon: .clock) {
                fact("Started", record.createdAt.formatted(date: .abbreviated, time: .shortened))
                fact("Updated", record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                fact("Profile", record.botID)
                if let session = record.botChatSessionID { fact("Session", session) }
            }
            prose("Task", icon: .listChecks, text: record.summary)
            if let result = record.result, !result.isEmpty {
                prose("Reply", icon: .chatText, text: DockModel.botReply(from: result).reply)
            } else {
                unavailable("No reply has been reported for this dispatch.")
            }
        case .tool(let captured):
            toolDetail(currentTool(captured.id) ?? captured, captured: currentTool(captured.id) == nil)
        case .output(let record):
            SessionOutputPreview(record: record, model: model)
        case .activity(let message, let captured):
            let current = model.messages.first { $0.id == message.id }
            let calls =
                message.id == model.streamingMessageIDForPresentation
                ? model.streamingTurnActivity : current?.activity ?? captured
            header("Activity", subtitle: message.timeLabel, icon: .chartBarHorizontal)
            if current == nil { capturedNotice }
            DockChipFlow {
                DockMetadataPill(text: "\(calls.count) \(calls.count == 1 ? "step" : "steps")")
                DockMetadataPill(text: "\(calls.count(where: \.isComplete)) finished")
                if let duration = (current ?? message).responseDuration {
                    DockMetadataPill(text: TurnActivityView.stepDuration(duration))
                }
            }
            ForEach(Array(calls.enumerated()), id: \.element.id) { index, call in
                group("Step \(index + 1)", icon: TurnActivityView.icon(for: call.name)) {
                    Button {
                        SessionMessageTabs.shared.open(.tool(call), in: WorkspaceIdentity.session(model))
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text(AgentActivityPresentation.toolActivityTitle(name: call.name, context: call.context))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                        }
                    }
                    .buttonStyle(.dockLink)
                    .dockFont(.body, weight: .semibold)
                    fact("State", call.traceOutcome ?? (call.isComplete ? "Finished" : "Running"))
                    if let result = toolMarkdown(call.result, section: .result, call: call) {
                        MarkdownMessageView(markdown: result, bodySize: DockTypography.size(.body)).equatable()
                    }
                }
            }
        }
    }

    private func currentTool(_ id: String) -> ActiveToolCall? {
        model.streamingTurnActivity.first { $0.id == id }
            ?? model.messages.lazy.flatMap(\.activity).first { $0.id == id }
    }

    private func currentDispatch(_ captured: BotActivityRecord) -> BotActivityRecord? {
        model.botActivitySessionIDs.compactMap { $0 }.lazy
            .flatMap { model.botActivityBySessionID[$0] ?? [] }
            .first { $0.id == captured.id && $0.originSessionID == captured.originSessionID }
    }

    private func toolDetail(_ call: ActiveToolCall, captured: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(
                AgentActivityPresentation.toolActivityTitle(name: call.name, context: call.context),
                subtitle: call.name == ActiveToolCall.thinkingName ? "Reasoning" : "Activity details",
                icon: TurnActivityView.icon(for: call.name))
            if captured { capturedNotice }
            group("Execution", icon: .clock) {
                fact("State", call.traceOutcome ?? (call.isComplete ? "Finished" : "Running"))
                fact("Started", call.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let duration = call.traceDuration ?? call.completedAt.map({ $0.timeIntervalSince(call.startedAt) }) {
                    fact("Duration", TurnActivityView.stepDuration(duration))
                }
                if let timing = call.traceTiming { fact("Timing", timing.rawValue.capitalized) }
                if !call.context.isEmpty { fact("Context", call.context) }
                if let agent = call.agentID { fact("Agent", agent) }
                if let session = call.childSessionID { fact("Session", session) }
            }
            if let markdown = toolMarkdown(call.input, section: .input, call: call) {
                markdownGroup("Input", icon: .arrowLineDown, markdown: markdown, copy: call.input)
            }
            if let args = call.args, !args.isEmpty {
                group("Arguments", icon: .code) {
                    ForEach(args.keys.sorted(), id: \.self) { key in fact(key, args[key] ?? "") }
                }
            }
            if let markdown = toolMarkdown(call.result, section: .result, call: call) {
                markdownGroup("Result", icon: .arrowLineUp, markdown: markdown, copy: call.result ?? "")
            } else {
                unavailable("No result has been reported for this activity.")
            }
            if let markdown = toolMarkdown(call.diffPreview, section: .diff, call: call) {
                markdownGroup("Changes", icon: .gitDiff, markdown: markdown, copy: call.diffPreview ?? "")
            }
        }
    }

    private func toolMarkdown(_ value: String?, section: SessionTraceProjection.DetailSection, call: ActiveToolCall)
        -> String?
    {
        SessionTraceProjection.detailMarkdown(
            value, section: section, kind: call.name == ActiveToolCall.thinkingName ? .thinking : .tool)
    }

    private func header(_ title: String, subtitle: String, icon: Ph, bot: BotSummary? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let bot {
                BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: 40, orbits: false)
            } else {
                DockIcon(icon, size: 20, color: .dockSecondaryText)
                    .frame(width: 40, height: 40)
                    .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: DockLayout.controlRadius))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).dockFont(.pageTitle, weight: .semibold).textSelection(.enabled)
                Text(subtitle).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            }
            Spacer(minLength: 0)
        }
        .dockPadding(.vertical, 4)
    }

    private func group<Content: View>(_ title: String, icon: Ph, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DockIconLabel(title, icon: icon).dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockSecondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard()
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
            Text(value).dockFont(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func prose(_ title: String, icon: Ph, text: String?) -> some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            markdownGroup(title, icon: icon, markdown: text, copy: text)
        }
    }

    private func markdownGroup(_ title: String, icon: Ph, markdown: String, copy: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DockIconLabel(title, icon: icon).dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockSecondaryText)
                Spacer(minLength: 0)
                DockCopyButton(copy, accessibilityLabel: "Copy " + title.lowercased(), presentation: .icon)
                    .buttonStyle(DockPressButtonStyle()).frame(width: 28, height: 28)
            }
            MarkdownMessageView(markdown: markdown, bodySize: DockTypography.size(.body)).equatable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard()
    }

    private var capturedNotice: some View {
        unavailable("Captured preview · current data is no longer loaded.")
    }

    private func unavailable(_ text: String) -> some View {
        Text(text).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
