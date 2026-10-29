import Combine
import SwiftUI

struct SessionDashboardCard: View {
    let row: SessionDashboardRow
    let isCurrent: Bool
    let isLoadingSession: Bool
    let request: AttentionItem?
    let activity: LatestActivityItem?
    let profileID: String?
    let client: HermesRPCClientProtocol?
    /// Runtime IDs Hermes may key this saved session's live requests by.
    var runtimeIDs: [String] = []
    /// Only a gateway-owned turn can be interrupted from Herm.
    var isGatewayLive = false
    /// Not observed: tiles take only attention, answer and activity changes.
    var model: DockModel?
    let onRespond: () -> Void
    @StateObject private var content = SessionDashboardCardContent()
    @State private var attention: DockModel.SessionAttention?
    @State private var answer: AttentionAnswerState?
    @State private var liveActivity: String?
    @State private var draft = ""
    @State private var sending = false
    @State private var stopping = false
    @State private var actionError: String?
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var replyFocused: Bool

    private var ids: [String] { [row.id] + runtimeIDs }
    private var isWorking: Bool { isCurrent && row.status == .working }
    private var replyUnavailableReason: String? {
        if !isCurrent { return "Activity is not current. Refresh to retry." }
        if isWorking { return "Reply when this turn finishes." }
        return model?.quickMessageUnavailableReason(for: row.session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // A fixed four-line slot keeps tiles even without nested scroll bars;
            // a pending request grows it so its answers are never clipped.
            update.frame(
                maxWidth: .infinity, minHeight: 64, maxHeight: attention == nil ? 64 : nil, alignment: .topLeading
            )
            .clipped()
            footer
        }
        .foregroundStyle(Color.dockPrimaryText)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            DockThemeShape(cornerRadius: DockLayout.paneRadius, role: .pane)
                .fill(hovered ? Color.dockSurface2 : Color.dockSurface)
                .contentShape(Rectangle())
                .onTapGesture { if !isLoadingSession { onRespond() } }
        )
        .overlay {
            DockThemeShape(cornerRadius: DockLayout.paneRadius, role: .pane).stroke(
                hovered || replyFocused ? Color.dockBorderStrong : Color.dockBorderLight,
                lineWidth: DockLayout.hairline)
        }
        .onHover { hovered = $0 }
        .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.16), value: hovered)
        .animation(nil, value: row.status)
        .task(id: "\(row.session.lastUpdatedAt?.timeIntervalSince1970 ?? 0)-\(isCurrent)") {
            guard let client, isCurrent else { return }
            await content.load(session: row.session, profileID: profileID, client: client)
        }
        .onReceive(attentionChanges) { all in
            attention = ids.lazy.compactMap { all[$0] }.first
            answer = attention?.responseTarget.flatMap { model?.attentionAnswers[$0] }
        }
        .onReceive(answerChanges) { all in
            answer = attention?.responseTarget.flatMap { all[$0] }
        }
        .onReceive(activityChanges) { labels in
            liveActivity = ids.lazy.compactMap { labels[$0] }.first
        }
    }

    private var attentionChanges: AnyPublisher<[String: DockModel.SessionAttention], Never> {
        model?.$sessionAttention.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
    }
    private var answerChanges: AnyPublisher<[AttentionRequest: AttentionAnswerState], Never> {
        model?.$attentionAnswers.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
    }
    private var activityChanges: AnyPublisher<[String: String], Never> {
        model?.sessionActivityLabelChanges ?? Empty().eraseToAnyPublisher()
    }

    @ViewBuilder
    private var update: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attention, let target = attention.responseTarget, isCurrent {
                attentionBody(attention, target: target)
            } else if let request {
                Text(request.title).dockFont(.body, weight: .semibold).lineLimit(1)
                Text(request.detail).dockFont(.body).lineLimit(3)
            } else if let preview = content.text ?? SessionDashboardCardContent.preview(row.session.preview) {
                Text(Self.inlineMarkdown(preview)).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(4).help(preview)
            } else {
                Text(content.error == nil ? "No saved update yet." : "Latest reply unavailable.")
                    .dockFont(.body).foregroundStyle(Color.dockMetadataText)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if isCurrent, let state = row.status.activityState {
                    DockActivityIndicator(state: state, size: 12, unreadDot: true)
                }
                if !isCurrent || row.status != .none {
                    Text(statusText).dockFont(.metadata, weight: .medium).lineLimit(1)
                }
                if isWorking, let label = liveActivity ?? activity?.activityName {
                    Text("·")
                    Text(label).dockFont(.metadata).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let date = row.session.lastUpdatedAt {
                    Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .dockFont(.metadata).foregroundStyle(Color.dockMetadataText).lineLimit(1)
                }
            }
            .foregroundStyle(Color.dockSecondaryText)
            Button(action: onRespond) {
                Text(row.session.displayTitle)
                    .dockFont(.body, weight: .semibold)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.dockLink)
            .disabled(isLoadingSession)
            .help("Open \(row.session.displayTitle)")
            if let project = row.project {
                DockIconLabel(project, icon: .folder)
                    .dockFont(.metadata).foregroundStyle(Color.dockMetadataText).lineLimit(1)
            }
        }
    }

    private var statusText: String {
        guard isCurrent else { return "Status not current" }
        switch row.status {
        case .none: return ""
        case .unreadComplete: return "Ready to review"
        default: return row.status.label
        }
    }

    @ViewBuilder
    private func attentionBody(_ attention: DockModel.SessionAttention, target: AttentionRequest) -> some View {
        Text(attention.summary).dockFont(.body, weight: .semibold).lineLimit(3).help(attention.summary)
        if attention.choices.isEmpty {
            Text("Open the chat to answer this request.").dockFont(.metadata)
                .foregroundStyle(Color.dockSecondaryText)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { choiceButtons(attention, target: target) }
                VStack(alignment: .leading, spacing: 6) { choiceButtons(attention, target: target) }
            }
            .dockButtonSize(.compact)
        }
        if let answer {
            HStack(spacing: 6) {
                if case .sending = answer { ProgressView().controlSize(.mini) }
                Text(answer.message).lineLimit(3)
                if case .uncertain = answer {
                    Button("Check request") { model?.recheckAttention(target) }.buttonStyle(.dockSecondary)
                }
            }
            .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
        }
    }

    @ViewBuilder
    private func choiceButtons(_ attention: DockModel.SessionAttention, target: AttentionRequest) -> some View {
        ForEach(attention.choices, id: \.self) { choice in
            let button = Button(role: choice == ApprovalChoice.deny ? .destructive : nil) {
                model?.answerAttention(target, choice: choice)
            } label: {
                Text(EdgeNotchTask.choiceLabel(choice)).lineLimit(1)
            }
            .disabled(answer?.blocksSubmission == true)
            .accessibilityLabel("Answer \(EdgeNotchTask.choiceLabel(choice)) for \(row.session.displayTitle)")
            if choice == attention.choices.first {
                button.buttonStyle(.dockPrimary)
            } else {
                button.buttonStyle(.dockSecondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(replyUnavailableReason ?? "Reply…", text: $draft)
                    .textFieldStyle(.plain)
                    .dockFont(.body)
                    .focused($replyFocused)
                    .onSubmit(send)
                    .disabled(replyUnavailableReason != nil || sending)
                    .accessibilityLabel("Reply to \(row.session.displayTitle)")
                if isWorking, isGatewayLive {
                    DockIconButton(
                        icon: .stop, label: "Stop \(row.session.displayTitle)", isBusy: stopping, size: 24,
                        style: style, action: stop
                    )
                    .disabled(stopping)
                } else {
                    DockIconButton(
                        icon: .arrowUp, label: "Send reply to \(row.session.displayTitle)", isProminent: true,
                        isBusy: sending, size: 24, style: style, action: send
                    )
                    .disabled(
                        replyUnavailableReason != nil || sending
                            || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 36)
            .background(DockThemeShape(cornerRadius: DockLayout.controlRadius).fill(Color.dockControlSurface))
            .overlay {
                DockThemeShape(cornerRadius: DockLayout.controlRadius)
                    .stroke(
                        replyFocused ? Color.dockBorderStrong : Color.dockBorderLight,
                        lineWidth: DockLayout.hairline)
            }
            if let actionError {
                Text(actionError).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).lineLimit(2)
            }
        }
    }

    private var style: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }

    /// Keeps links and emphasis from the reply while flattening block structure into tile text.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func send() {
        guard let model, replyUnavailableReason == nil, !sending else { return }
        sending = true
        actionError = nil
        model.sendQuickMessage(draft, to: row.session, profileID: profileID) { error in
            sending = false
            if let error {
                actionError = HermesDiagnosticsService.safeSummary(error)
            } else {
                draft = ""
            }
        }
    }

    private func stop() {
        guard let model, !stopping else { return }
        stopping = true
        actionError = nil
        let session = row.session
        let service = HermesWorkflowRPC(
            client: model.quickWorkflowClient, profileID: session.profileID ?? profileID)
        Task {
            do {
                try await service.stopSession(session)
                model.loadSessions()
            } catch {
                actionError = HermesDiagnosticsService.safeSummary(error.localizedDescription)
            }
            stopping = false
        }
    }
}
