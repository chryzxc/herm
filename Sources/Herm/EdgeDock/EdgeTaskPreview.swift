import SwiftUI

/// One row in the notch’s Tasks tab: session work or canonical Kanban activity.
struct EdgeNotchTask: Identifiable, Equatable {
    enum Phase: Int, Comparable {
        case attention, working, pending, finished
        static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    var presentationID: String {
        "\(session?.profileID ?? attentionRequest?.profileID ?? "")/\(isCurrent ? "current" : "background")/\(id)"
    }
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
    /// One-tap answers shown under an attention row (approval, clarify, queued card question).
    var choices: [String] = []
    var deliveryQuestion: EdgeDeliveryQuestion? = nil
    var attentionRequest: AttentionRequest? = nil
    var answerState: AttentionAnswerState? = nil
    var isFailure = false
    var routine: RoutineReference? = nil
    /// The working Bot's profile for rows without a `session`: the open
    /// session's row and Bot DMs whose own session is not known yet.
    var profileID: String? = nil

    static func choiceLabel(_ choice: String) -> String {
        switch choice {
        case ApprovalChoice.once: "Allow once"
        case ApprovalChoice.session: "Allow this session"
        case ApprovalChoice.always: "Always allow"
        case ApprovalChoice.deny: "Deny"
        default: choice
        }
    }

    var isInProgress: Bool { phase != .finished }

    /// The notch groups sessions and Kanban cards together. Only running work
    /// is in progress; Kanban cards waiting in review get their own section.
    enum Section: Int, CaseIterable {
        case inProgress, finished, review, attention
        var title: String {
            switch self {
            case .inProgress: "In progress"
            case .finished: "Finished"
            case .review: "Review"
            case .attention: "Needs your attention"
            }
        }
    }

    var section: Section {
        switch phase {
        case .working: .inProgress
        case .finished: .finished
        case .pending: .review
        case .attention: .attention
        }
    }

    /// One list for sessions and Kanban: by section, the open session first,
    /// then newest first. Sorted once per data change, not per render.
    static func merged(_ tasks: [EdgeNotchTask]) -> [EdgeNotchTask] {
        tasks.sorted { lhs, rhs in
            if lhs.section != rhs.section { return lhs.section.rawValue < rhs.section.rawValue }
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            if lhs.updatedAt != rhs.updatedAt {
                return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
            }
            return lhs.id < rhs.id
        }
    }

    var tone: DockStatusTone {
        guard isStatusCurrent || phase == .finished else { return .inactive }
        if isFailure { return .attention }
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
    static func build(
        current: EdgeNotchTask?, sessions: [HermesSession], activity: [String: String] = [:],
        currentSessionIDs: Set<String>, isOnline: Bool,
        attention: [String: DockModel.SessionAttention] = [:]
    ) -> [EdgeNotchTask] {
        // Without a live row of its own, the open session's index row stands in.
        // The open session can be known by a runtime alias its index row does
        // not carry, so an in-progress row with its title is the same chat.
        let others =
            sessions
            .filter { session in
                guard let current else { return true }
                return !currentSessionIDs.contains(session.id)
                    && !(current.isInProgress && session.isWorking && session.displayTitle == current.title)
            }
            .filter { $0.isWorking || $0.hasUnreadUpdate || attention[$0.id] != nil }
            .map { session in
                EdgeNotchTask(
                    id: session.id,
                    title: session.displayTitle,
                    phase: attention[session.id] != nil ? .attention : session.isWorking ? .working : .finished,
                    statusLabel: attention[session.id]?.status.title ?? (session.isWorking ? "Working" : "Finished"),
                    detail: attention[session.id]?.summary
                        ?? (session.isWorking ? activity[session.id] : session.displayPreview),
                    updatedAt: session.lastUpdatedAt,
                    isCurrent: false,
                    isStatusCurrent: isOnline,
                    session: session,
                    choices: attention[session.id]?.choices ?? [],
                    attentionRequest: attention[session.id]?.responseTarget
                )
            }
        return ([current].compactMap { $0 } + others).sorted { lhs, rhs in
            if lhs.phase != rhs.phase { return lhs.phase < rhs.phase }
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
    }
}

extension EdgeNotchTask {
    /// Bots the open session messaged or @mentioned, as their own rows.
    /// Kanban assignments are left to the board's rows. A finished DM stays
    /// for 15 minutes so its result can be seen without opening the Dock.
    /// `listedSessionIDs` are sessions that already have a row of their own.
    static func botRows(
        records: [BotActivityRecord], steps: [String: String], isOnline: Bool,
        listedSessionIDs: Set<String> = [], now: Date = Date()
    ) -> [EdgeNotchTask] {
        records.compactMap { record in
            guard record.linkedCardID == nil,
                !listedSessionIDs.contains(record.botChatSessionID ?? "")
            else { return nil }
            // ponytail: a live DM whose completion Herm missed would stay forever;
            // past 3h it is stale, matching `workingBotDispatches`.
            if record.isLive
                ? record.createdAt < now.addingTimeInterval(-3 * 3600)
                : record.updatedAt < now.addingTimeInterval(-15 * 60)
            {
                return nil
            }
            let (phase, label): (Phase, String) =
                switch record.state {
                case .working: (.working, "Working")
                case .queued: (.working, "Queued")
                case .waiting: (.attention, "Waiting on you")
                case .completed: (.finished, "Finished")
                case .failed: (.finished, "Failed")
                case .canceled: (.finished, "Canceled")
                }
            let detail =
                record.isLive
                ? steps[record.id] : record.result?.split(whereSeparator: \.isNewline).first.map(String.init)
            let session = record.botChatSessionID.map {
                HermesSession(
                    id: $0, profileID: record.botID, title: record.summary, preview: "",
                    startedAt: record.createdAt, messageCount: 0, source: HermesFeatureIDs.sessionSource)
            }
            return EdgeNotchTask(
                id: "bot:\(record.id)", title: record.summary, phase: phase, statusLabel: label,
                detail: [record.botName, detail].compactMap { $0 }.joined(separator: " · "),
                updatedAt: record.updatedAt, isCurrent: false, isStatusCurrent: isOnline,
                session: session, isFailure: record.state == .failed, profileID: record.botID)
        }
    }
}

/// The notch’s Tasks tab: one list of session and Kanban rows, pre-sorted by `merged`.
struct EdgeTaskPreview: View {
    let tasks: [EdgeNotchTask]
    let isOffline: Bool
    /// Set when a quota drop is announced alongside a task update.
    var quotaChange: EdgeQuotaChange? = nil
    var kanbanUnavailable = false
    var bots: [BotSummary] = []
    var avatarImages: [String: Data] = [:]
    var quickMessage: (() -> Void)? = nil
    var reply: ((EdgeNotchTask) -> Void)? = nil
    var quickState: EdgeNotchState? = nil
    var quickModel: DockModel? = nil
    var quotaControl: ControlCenterModel? = nil
    var closeReply: () -> Void = {}
    var answer: ((EdgeNotchTask, String) -> Void)? = nil
    var peek: ((EdgeNotchTask) -> Void)? = nil
    var recall: (() -> Void)? = nil
    var steer: ((EdgeNotchTask) -> Void)? = nil
    var beginEditing: () -> Void = {}
    /// The top island's icon-only action strip in place of the labelled footer.
    var compactFooter = false
    /// An announcement: only the updated rows (and quota change), measured to size the shell.
    var glimpse = false
    let openDock: () -> Void
    @AppStorage(DoubleTapShortcut.workspaceKey) private var workspaceShortcut = DoubleTapShortcut.command
    let openTask: (EdgeNotchTask) -> Void
    @FocusState private var focusedTask: EdgePreviewItemID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    private var keyboardItems: [EdgePreviewItemID] {
        tasks.map { $0.previewIdentity(currentProfileID: quickModel?.sessionProfileID) }
    }

    private func reconcileKeyboard(previous: [EdgePreviewItemID]) {
        guard let quickState, quickState.previewInteraction.mode == .keyboard else { return }
        quickState.previewInteraction.reconcile(previous: previous, current: keyboardItems)
        focusedTask = quickState.previewInteraction.selected
    }

    private func moveKeyboard(_ offset: Int) -> KeyPress.Result {
        guard let quickState, quickState.previewInteraction.mode == .keyboard else { return .ignored }
        quickState.previewInteraction.move(offset, items: keyboardItems)
        focusedTask = quickState.previewInteraction.selected
        return .handled
    }

    var body: some View {
        // One pass per render; grouping keeps the pre-sorted order.
        let groups = Dictionary(grouping: tasks, by: \.section)
        let botLookup = KanbanBoardPresentation.makeSnapshot(tasks: [], bots: bots)
        if glimpse { return AnyView(glimpseBody(bots: botLookup)) }
        return AnyView(
            VStack(spacing: 0) {
                Group {
                    if tasks.isEmpty && quotaChange == nil {
                        emptyState
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                                    // Eager stacks: lazy rows re-estimate heights while scrolling and the list jumps.
                                    VStack(alignment: .leading, spacing: 12) {
                                        ForEach(EdgeNotchTask.Section.allCases, id: \.self) { section in
                                            self.section(
                                                section.title, groups[section] ?? [], bots: botLookup,
                                                now: timeline.date)
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
                            .onChange(of: focusedTask) { _, id in
                                if let id {
                                    quickState?.previewInteraction.selected = id
                                    proxy.scrollTo(id, anchor: .center)
                                }
                            }
                            .onChange(
                                of: quickState?.composing == true ? quickState?.quickReplyTask?.presentationID : nil,
                                initial: true
                            ) { _, id in
                                if let id { proxy.scrollTo("reply-\(id)", anchor: .bottom) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if compactFooter {
                    islandFooter
                } else {
                    Divider().overlay(Color.dockBorderLight)
                    footer
                }
            }
            .foregroundStyle(Color.dockPrimaryText)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { reconcileKeyboard(previous: keyboardItems) }
            .onChange(of: keyboardItems) { old, _ in reconcileKeyboard(previous: old) }
            .onChange(of: quickState?.previewInteraction.mode) { _, mode in
                if mode == .keyboard { reconcileKeyboard(previous: keyboardItems) }
            })
    }

    private func glimpseBody(bots: KanbanBoardPresentation.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tasks, id: \.presentationID) { card($0, bots: bots, now: .now) }
            if let quotaChange {
                EdgeQuotaChangeCard(change: quotaChange, compact: true).padding(.horizontal, 10)
            }
        }
        .foregroundStyle(Color.dockPrimaryText)
        .padding(.horizontal, 6)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: { height in
            if abs((quickState?.glimpseHeight ?? 0) - height) > 0.5 { quickState?.glimpseHeight = height }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [EdgeNotchTask], bots: KanbanBoardPresentation.Snapshot, now: Date)
        -> some View
    {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                DockSectionLabel(title: title, count: items.count)
                ForEach(items, id: \.presentationID) { card($0, bots: bots, now: now) }
            }
        }
    }

    private func card(_ task: EdgeNotchTask, bots: KanbanBoardPresentation.Snapshot, now: Date) -> some View {
        let isReplying =
            quickState?.composing == true && quickState?.quickReplyTask?.presentationID == task.presentationID
        return EdgeTaskHoverContent { isHovered in
            let showsReply =
                isHovered || isReplying || voiceOverEnabled || quickState?.previewInteraction.mode == .keyboard
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    taskButton(task, bots: bots, now: now)
                    if task.routine == nil, task.kanbanTask == nil, task.phase != .attention, let reply,
                        task.session != nil || task.isCurrent
                    {
                        replyToggle(task, isReplying: isReplying, visible: showsReply, reply: reply)
                            .padding(.top, 5)
                            .padding(.trailing, 4)
                            .offset(x: showsReply ? 0 : 12)
                            .frame(width: showsReply ? 34 : 0, alignment: .trailing)
                            .clipped()
                    }
                }
                .animation(
                    reduceMotion || !DockThemeStyle.current.animates ? nil : .dockEase(duration: 0.18),
                    value: showsReply)
                if task.phase == .attention, !task.choices.isEmpty, let answer {
                    choiceButtons(task, answer: answer)
                }
                if isReplying, let quickState, let quickModel, let quotaControl {
                    EdgeQuickMessageView(
                        model: quickModel, control: quotaControl, state: quickState, inline: true,
                        close: closeReply, openDock: openDock
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .id("reply-\(task.presentationID)")
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .contextMenu {
                if task.phase == .working, let steer {
                    Button("Steer a live subagent…") { steer(task) }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                    .dockSelectionFill(
                        isHovered || isReplying,
                        fallback: isHovered || isReplying ? Color.dockSurface4.opacity(0.6) : .clear)
            )
            .animation(.dockEase(duration: 0.16), value: isReplying)
        }
    }

    /// Detail text with the file icon before any word that names a file ("Reading App.vue").
    private static func detailText(_ detail: String) -> Text {
        detail.split(separator: " ", omittingEmptySubsequences: false).enumerated().reduce(Text("")) { text, item in
            let word = String(item.element)
            let sep = item.offset == 0 ? Text("") : Text(" ")
            guard let image = ArtifactFileIcon.inlineImage(forPath: word, size: 11) else {
                return text + sep + Text(word)
            }
            return text + sep + Text(Image(nsImage: image)).baselineOffset(-2) + Text("\u{2009}") + Text(word)
        }
    }

    /// The full question and its answers, so a background decision never needs the chat open.
    private func choiceButtons(_ task: EdgeNotchTask, answer: @escaping (EdgeNotchTask, String) -> Void) -> some View {
        let isApproval = task.choices.contains(ApprovalChoice.once) || task.choices.contains(ApprovalChoice.deny)
        let isDisabled =
            !task.isStatusCurrent || task.answerState?.blocksSubmission == true
            || (task.deliveryQuestion == nil && task.attentionRequest == nil)
        return VStack(alignment: .leading, spacing: 8) {
            if let detail = task.detail, !detail.isEmpty {
                // Approvals carry a command or path: show it as code in its own well, like the chat card.
                Text(detail)
                    .font(isApproval ? .system(size: 11, design: .monospaced) : .system(size: 11))
                    .foregroundStyle(isApproval ? Color.dockPrimaryText : Color.dockSecondaryText)
                    .lineLimit(isApproval ? 5 : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, isApproval ? 8 : 0)
                    .padding(.vertical, isApproval ? 6 : 0)
                    .background {
                        if isApproval {
                            DockThemeShape(cornerRadius: DockLayout.controlRadius)
                                .fill(Color.dockSurface2)
                                .stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline)
                        }
                    }
            }
            let buttons = ForEach(task.choices, id: \.self) { choice in
                Button(role: choice == ApprovalChoice.deny ? .destructive : nil) {
                    answer(task, choice)
                } label: {
                    Text(EdgeNotchTask.choiceLabel(choice))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: isApproval ? nil : .infinity, alignment: isApproval ? .center : .leading)
                }
                .buttonStyle(DockSecondaryButtonStyle())
                .disabled(isDisabled)
                .accessibilityLabel("Answer \(EdgeNotchTask.choiceLabel(choice))")
            }
            if isApproval {
                // Allow once leads in the accent style; the rest wrap below when narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { approvalButtons(task, answer: answer, disabled: isDisabled) }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 6) {
                        approvalButtons(task, answer: answer, disabled: isDisabled)
                    }
                }
                .controlSize(.small)
            } else {
                VStack(spacing: 5) { buttons }.controlSize(.small)
            }
            if let submission = task.answerState {
                HStack(alignment: .top, spacing: 6) {
                    if case .sending = submission { ProgressView().controlSize(.mini) }
                    Text(submission.message)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(3)
                    if case .failed = submission {
                        Button("Retry") { answer(task, submission.choice) }
                            .buttonStyle(.dockCompact)
                            .dockFont(.metadata, weight: .medium)
                            .disabled(!task.isStatusCurrent)
                            .accessibilityLabel("Retry answer to \(task.title)")
                    }
                    if case .uncertain = submission,
                        let request = task.attentionRequest, let quickModel
                    {
                        Button("Check request") { quickModel.recheckAttention(request) }
                            .buttonStyle(.dockCompact)
                            .dockFont(.metadata, weight: .medium)
                            .disabled(!task.isStatusCurrent)
                            .accessibilityLabel("Check whether request for \(task.title) is still pending")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func approvalButtons(
        _ task: EdgeNotchTask, answer: @escaping (EdgeNotchTask, String) -> Void, disabled: Bool
    ) -> some View {
        ForEach(task.choices, id: \.self) { choice in
            let label = Button(role: choice == ApprovalChoice.deny ? .destructive : nil) {
                answer(task, choice)
            } label: {
                Text(EdgeNotchTask.choiceLabel(choice)).lineLimit(1)
            }
            .disabled(disabled)
            .accessibilityLabel("Answer \(EdgeNotchTask.choiceLabel(choice))")
            if choice == ApprovalChoice.once {
                label.buttonStyle(DockPrimaryButtonStyle())
            } else {
                label.buttonStyle(DockSecondaryButtonStyle())
            }
        }
    }

    /// Reply lives inside the card and turns into a close button while composing.
    private func replyToggle(
        _ task: EdgeNotchTask, isReplying: Bool, visible: Bool,
        reply: @escaping (EdgeNotchTask) -> Void
    ) -> some View {
        Button {
            isReplying ? closeReply() : reply(task)
        } label: {
            DockIcon(isReplying ? .x : .arrowBendUpLeft, size: 13, color: .dockSecondaryText)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous).dockSurfaceFill(
                        Color.dockSurface4.opacity(isReplying ? 0.9 : 0.5), interactive: true)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.dockPress)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
        .disabled(quickState?.quickSending == true)
        .dockHoverTip(isReplying ? "Close reply" : "Reply in the notch", edge: .trailing, gap: 30)
        .accessibilityLabel(isReplying ? "Close reply" : "Reply to \(task.title)")
    }

    @ViewBuilder
    private func statusMark(_ task: EdgeNotchTask, size: CGFloat = 12) -> some View {
        if let state = task.activityState {
            DockActivityIndicator(state: state, size: size)
        } else {
            DockStatusDot(tone: task.tone, pulses: true, muted: true)
        }
    }

    private func taskButton(_ task: EdgeNotchTask, bots: KanbanBoardPresentation.Snapshot, now: Date) -> some View {
        let identity = task.previewIdentity(currentProfileID: quickModel?.sessionProfileID)
        return Button {
            if task.phase == .finished, task.kanbanTask == nil, let peek { peek(task) } else { openTask(task) }
        } label: {
            taskButtonLabel(task, bots: bots, now: now)
        }
        .buttonStyle(.dockHover)
        .modifier(
            EdgeTaskKeyboardControl(
                identity: identity, selection: $focusedTask,
                move: moveKeyboard,
                activate: {
                    if task.phase == .finished, task.kanbanTask == nil, let peek { peek(task) } else { openTask(task) }
                },
                isComposing: quickState?.composing == true
                    && quickState?.quickReplyTask?.presentationID == task.presentationID)
        )
        .help(
            task.kanbanTask != nil
                ? "Open this Kanban card"
                : task.phase == .finished && peek != nil ? "Preview saved reply" : "Open this session"
        )
        .accessibilityLabel(
            [task.title, task.isCurrent ? "current session" : nil, task.displayStatus, task.detail]
                .compactMap { $0 }.joined(separator: ". ")
                + (task.kanbanTask != nil
                    ? ". Open Kanban card"
                    : task.phase == .finished && peek != nil ? ". Preview saved reply" : ". Open session"))
    }

    private func taskButtonLabel(_ task: EdgeNotchTask, bots: KanbanBoardPresentation.Snapshot, now: Date) -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let assignee = task.kanbanTask?.assignee, !assignee.isEmpty {
                let bot = bots.bot(for: assignee)
                Group {
                    if let bot {
                        BotAvatarView(bot: bot, imageData: avatarImages[bot.id], size: 26)
                    } else {
                        KanbanAssigneeInitialAvatar(assignee: assignee, size: 26)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    statusMark(task, size: 11)
                        .background(Circle().fill(Color.dockOpaqueCanvas).padding(-1))
                        .offset(x: 3, y: 3)
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityLabel("Assigned to \(bot?.name ?? assignee)")
            } else if let bot = sessionBot(task) {
                // The session's Bot (or the default one) stands in for the
                // spinner: a working Herm face already orbits.
                let working = task.tone == .working
                BotAvatarView(
                    bot: bot, imageData: avatarImages[bot.id], size: 26, mood: BotMood(ask: task.activityState),
                    orbits: working
                )
                .overlay(alignment: .bottomTrailing) {
                    if !working || !BotAvatarView.showsHermFace(avatarImages[bot.id], id: bot.id) {
                        statusMark(task, size: 11)
                            .background(Circle().fill(Color.dockOpaqueCanvas).padding(-1))
                            .offset(x: 3, y: 3)
                    }
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityLabel("\(bot.name), \(task.displayStatus)")
            } else {
                statusMark(task)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .dockFont(.body, weight: .semibold)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    trailing(for: task, now: now)
                }
                HStack(spacing: 0) {
                    // Hue only for trouble; everything else stays neutral.
                    // The spinner and shimmer already say "Working"; show only the activity.
                    let showStatus = !(task.tone == .working && task.detail?.isEmpty == false)
                    if showStatus {
                        Text(task.displayStatus)
                            .dockFont(.metadata, weight: .medium)
                            .foregroundStyle(task.tone == .attention ? task.tone.color : Color.dockSecondaryText)
                    }
                    if let detail = task.detail, !detail.isEmpty, task.choices.isEmpty {
                        let summaryPrefix = OnDeviceAssist.attribution + " · "
                        let visibleDetail =
                            detail.hasPrefix(summaryPrefix)
                            ? String(detail.dropFirst(summaryPrefix.count)) : detail
                        (Text(showStatus ? " · " : "") + Self.detailText(visibleDetail))
                            .help(detail)
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                }
                .lineLimit(1)
                if task.detail?.hasPrefix(OnDeviceAssist.attribution + " · ") == true {
                    OnDeviceAssistNotice()
                }
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

    /// The Bot running a session row: its profile's Bot, else the default
    /// Bot. Empty when the Bots plugin is off, which keeps the spinner.
    private func sessionBot(_ task: EdgeNotchTask) -> BotSummary? {
        guard task.session != nil || task.profileID != nil || task.isCurrent else { return nil }
        let profileID = task.session?.profileID ?? task.profileID
        return bots.first { $0.id == profileID } ?? bots.first(where: \.isDefault)
    }

    @ViewBuilder
    private func trailing(for task: EdgeNotchTask, now: Date) -> some View {
        if task.isCurrent {
            Text("Current")
                .dockFont(.metadata, weight: .medium)
                .foregroundStyle(Color.dockSecondaryText)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(Capsule().fill(Color.dockSurface4.opacity(0.8)))
                .fixedSize()
        } else if let updatedAt = task.updatedAt {
            Text("\(EdgeQuotaPreview.shortDuration(now.timeIntervalSince(updatedAt))) ago")
                .dockFont(.metadata).monospacedDigit()
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DockSpacing.tight) {
            Text(emptyTitle)
                .dockFont(.body, weight: .semibold)
            Text(emptyDetail)
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, DockSpacing.group)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyTitle: String {
        if isOffline { return "Hermes is offline" }
        return kanbanUnavailable ? "Kanban is unavailable" : "Nothing in progress"
    }

    private var emptyDetail: String {
        if isOffline { return "Updates will resume when Herm reconnects." }
        return kanbanUnavailable
            ? "The board could not be refreshed. Herm will retry automatically."
            : "Running sessions, Kanban cards and unopened results appear here."
    }

    /// Round icon buttons in a centered capsule, the island's answer to the side panel's footer row.
    private var islandFooter: some View {
        HStack(spacing: 2) {
            if let quickMessage { islandAction("Quick message", icon: .chats, action: quickMessage) }
            secondaryActions
        }
        .padding(3)
        .background(Capsule().fill(Color.dockSurface4.opacity(0.6)))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    /// The side panel leads with a composer-style entry, then the shared icon actions.
    private var footer: some View {
        HStack(spacing: 4) {
            if let quickMessage {
                Button(action: quickMessage) {
                    HStack(spacing: 8) {
                        DockIcon(.chats, size: 13, color: .dockSecondaryText)
                        Text("Quick message…").dockFont(.body).foregroundStyle(Color.dockMetadataText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(Capsule().fill(Color.dockSurface4.opacity(0.6)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.dockHover)
                .accessibilityLabel("Quick message")
            } else {
                Spacer(minLength: 0)
            }
            secondaryActions
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var secondaryActions: some View {
        if let recall { islandAction("Search", icon: .magnifyingGlass, action: recall) }
        islandAction("Open Herm (\(workspaceShortcut.title))", icon: .arrowsOutSimple, action: openDock)
    }

    private func islandAction(_ title: String, icon: Ph, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DockIcon(icon, size: 14, color: .dockSecondaryText)
                .frame(width: 34, height: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(.dockHover)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Keep pointer movement local to a row instead of invalidating the whole list.
private struct EdgeTaskHoverContent<Content: View>: View {
    @State private var isHovered = false
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(isHovered)
            .onHover { isHovered = $0 }
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
                    .dockFont(.body, weight: .medium)
                    .foregroundStyle(isHovering ? Color.dockPrimaryText : Color.dockSecondaryText)
                if fillsWidth { Spacer(minLength: 8) }
                if let shortcut {
                    Text(shortcut)
                        .dockFont(.compactStatus, weight: .medium, design: .rounded)
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
                    .dockSelectionFill(isHovering, fallback: isHovering ? Color.dockSurface4.opacity(0.6) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockPress)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(shortcutHelp ?? "")
    }
}

/// A clarify question a headless coordinator turn queued for the user (software-delivery plugin,
/// `$HERMES_HOME/delivery/questions/<card>.json`). Answered by messaging the asking session.
struct EdgeDeliveryQuestion: Hashable, Sendable {
    let taskID: String
    let sessionID: String
    var profileID: String? = nil
    let question: String
    let choices: [String]
    let file: URL

    func answerText(_ choice: String) -> String { "ANSWER \(taskID): \(choice)" }

    func answerDraft(_ choice: String) throws -> QuickDraftRecord {
        guard !sessionID.isEmpty, choices.contains(choice) else {
            throw QuickDraftError.message("This question no longer has a valid answer destination.")
        }
        var record = QuickDraftRecord(
            destination: QuickDestination(
                profileID: profileID,
                sessionID: sessionID, title: "Bot Chat"), text: answerText(choice))
        record.requestsVisualReply = false
        return record
    }

    static var directory: URL {
        let home =
            ProcessInfo.processInfo.environment["HERMES_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
        return home.appendingPathComponent("delivery/questions")
    }

    static func load(from directory: URL = directory) -> [EdgeDeliveryQuestion] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let taskID = json["task_id"] as? String,
                let first = (json["questions"] as? [[String: Any]])?.first,
                let question = first["question"] as? String
            else { return nil }
            return EdgeDeliveryQuestion(
                taskID: taskID, sessionID: json["session_id"] as? String ?? "",
                profileID: json["profile"] as? String, question: question, choices: first["choices"] as? [String] ?? [],
                file: file)
        }
    }

    static func loadOffMain(from directory: URL = directory) async -> [EdgeDeliveryQuestion] {
        await Task.detached(priority: .utility) { load(from: directory) }.value
    }

    func removeIfCurrent() async throws -> Bool {
        try await Task.detached(priority: .utility) {
            guard Self.load(from: file.deletingLastPathComponent()).contains(self) else { return false }
            try FileManager.default.removeItem(at: file)
            return true
        }.value
    }

    var row: EdgeNotchTask {
        EdgeNotchTask(
            id: "question-\(taskID)", title: "Kanban \(taskID)", phase: .attention,
            statusLabel: "Needs your answer", detail: question, updatedAt: nil, isCurrent: false,
            isStatusCurrent: true,
            session: sessionID.isEmpty
                ? nil
                : HermesSession(
                    id: sessionID, profileID: profileID, title: "Bot Chat", preview: "",
                    startedAt: nil, messageCount: 0, source: "desktop"),
            choices: choices, deliveryQuestion: self)
    }
}
