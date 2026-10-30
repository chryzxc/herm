import AppKit
import SwiftUI

enum ConversationMessageActionKind: String, CaseIterable, Identifiable {
    case copy
    case readAloud
    case branch
    case refresh
    case reply
    case pin

    var id: String { rawValue }

    var icon: Ph {
        switch self {
        case .copy: .copy
        case .readAloud: .speakerHigh
        case .branch: .shuffleAngular
        case .refresh: .arrowClockwise
        case .reply: .arrowBendUpLeft
        case .pin: .pushPin
        }
    }

    var label: String {
        switch self {
        case .copy: "Copy message"
        case .readAloud: "Read message aloud"
        case .branch: "Branch from this message"
        case .refresh: "Refresh this response"
        case .reply: "Reply to this message"
        case .pin: "Pin message"
        }
    }
}
/// One transcript bubble, isolating per-message SwiftUI work behind an O(1)
/// equality boundary. DockPopover rebuilds row values on every publication;
/// when nothing about the message or its bot attribution changed, SwiftUI
/// skips this body entirely and never touches the Markdown render cache.
struct ConversationMessageRow: View, Equatable {
    let message: ChatMessage
    let isStreamingMessage: Bool
    /// The live turn's ask (approval, clarify, compressing); nil keeps the busy face.
    let streamingMood: BotMood?
    let streamingText: StreamingText?
    let activeBotProfileID: String?
    let botsByID: [String: BotSummary]
    let avatarImages: [String: Data]
    let botRosterRevision: Int
    let themeRevision: Int
    let onImagePreview: (NSImage) -> Void
    let pendingAction: ConversationMessageActionKind?
    let areSessionActionsAvailable: Bool
    let isSpeaking: Bool
    let metrics: ConversationWorkspaceMetrics
    let actionTarget: MessageNavigatorTarget?
    let onCopy: () -> Void
    let onBranch: () -> Void
    let onReadAloud: () -> Void
    let onRefresh: () -> Void
    let onReply: () -> Void
    let showsPinAction: Bool
    let isPinAvailable: Bool
    let isPinned: Bool
    let onOpenInTab: (() -> Void)?
    let showsOpenInTabAction: Bool
    let onPin: () -> Void
    let forwardContent: ((BotSummary, @escaping () -> Void) -> AnyView)?
    @Environment(\.sessionPreviewWorkspace) private var previewWorkspace
    @State private var sendTarget: BotSummary?
    @State private var hoverPresentation: ConversationRowHoverPresentation
    #if DEBUG
        @Environment(\.conversationRowEvaluation) private var evaluation
    #endif

    let loadKanbanDetail: ((KanbanNotice) async -> KanbanTaskDetail?)?
    init(
        message: ChatMessage,
        isStreamingMessage: Bool,
        streamingMood: BotMood? = nil,
        streamingText: StreamingText?,
        activeBotProfileID: String?,
        botsByID: [String: BotSummary],
        avatarImages: [String: Data],
        botRosterRevision: Int,
        themeRevision: Int = DockThemeRuntime.revision,
        onImagePreview: @escaping (NSImage) -> Void,
        pendingAction: ConversationMessageActionKind? = nil,
        areSessionActionsAvailable: Bool = true,
        isSpeaking: Bool = false,
        metrics: ConversationWorkspaceMetrics = .resolve(isFullscreen: false),
        actionTarget: MessageNavigatorTarget? = nil,
        onCopy: @escaping () -> Void = {},
        onBranch: @escaping () -> Void = {},
        onReadAloud: @escaping () -> Void = {},
        onRefresh: @escaping () -> Void = {},
        onReply: @escaping () -> Void = {},
        showsPinAction: Bool = false,
        isPinAvailable: Bool = false,
        isPinned: Bool = false,
        onPin: @escaping () -> Void = {},
        onOpenInTab: (() -> Void)? = nil,
        forwardContent: ((BotSummary, @escaping () -> Void) -> AnyView)? = nil,
        loadKanbanDetail: ((KanbanNotice) async -> KanbanTaskDetail?)? = nil,
        hoverPresentation: ConversationRowHoverPresentation = ConversationRowHoverPresentation()
    ) {
        self.message = message
        self.isStreamingMessage = isStreamingMessage
        self.streamingMood = streamingMood
        self.streamingText = streamingText
        self.activeBotProfileID = activeBotProfileID
        self.botsByID = botsByID
        self.avatarImages = avatarImages
        self.botRosterRevision = botRosterRevision
        self.themeRevision = themeRevision
        self.onImagePreview = onImagePreview
        self.pendingAction = pendingAction
        self.areSessionActionsAvailable = areSessionActionsAvailable
        self.isSpeaking = isSpeaking
        self.metrics = metrics
        self.actionTarget = actionTarget
        self.onCopy = onCopy
        self.onBranch = onBranch
        self.onReadAloud = onReadAloud
        self.onRefresh = onRefresh
        self.onReply = onReply
        self.showsPinAction = showsPinAction
        self.isPinAvailable = isPinAvailable
        self.isPinned = isPinned
        self.onOpenInTab = onOpenInTab
        self.showsOpenInTabAction = onOpenInTab != nil
        self.onPin = onPin
        self.forwardContent = forwardContent
        self.loadKanbanDetail = loadKanbanDetail
        self._hoverPresentation = State(initialValue: hoverPresentation)
    }

    nonisolated static func == (lhs: ConversationMessageRow, rhs: ConversationMessageRow) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.contentRevision == rhs.message.contentRevision
            && lhs.message.role == rhs.message.role
            && lhs.message.images.elementsEqual(rhs.message.images, by: { $0 === $1 })
            && lhs.message.timestamp == rhs.message.timestamp
            && lhs.message.modelName == rhs.message.modelName
            && lhs.message.activity == rhs.message.activity
            && lhs.message.systemEvent == rhs.message.systemEvent
            && lhs.message.kanbanNotice == rhs.message.kanbanNotice
            && lhs.message.isBotHandoffReply == rhs.message.isBotHandoffReply
            && lhs.message.isSteering == rhs.message.isSteering
            && lhs.message.steeringStatus == rhs.message.steeringStatus
            && lhs.message.isError == rhs.message.isError
            && lhs.message.botProfileID == rhs.message.botProfileID
            && lhs.message.botDisplayName == rhs.message.botDisplayName
            && lhs.message.botMentions == rhs.message.botMentions
            && lhs.message.responseDuration == rhs.message.responseDuration
            && lhs.message.tokenCount == rhs.message.tokenCount
            && lhs.isStreamingMessage == rhs.isStreamingMessage
            && lhs.streamingMood == rhs.streamingMood
            && lhs.activeBotProfileID == rhs.activeBotProfileID
            && lhs.botRosterRevision == rhs.botRosterRevision
            && lhs.themeRevision == rhs.themeRevision
            && lhs.pendingAction == rhs.pendingAction
            && lhs.areSessionActionsAvailable == rhs.areSessionActionsAvailable
            && lhs.isSpeaking == rhs.isSpeaking
            && lhs.showsPinAction == rhs.showsPinAction
            && lhs.isPinAvailable == rhs.isPinAvailable
            && lhs.isPinned == rhs.isPinned
            && lhs.showsOpenInTabAction == rhs.showsOpenInTabAction
            && lhs.metrics == rhs.metrics
            && lhs.actionTarget == rhs.actionTarget
    }

    private func imageThumbnail(at index: Int, @ViewBuilder layout: (Image) -> some View) -> some View {
        let image = message.images[index]
        let thumbnailKey = ConversationThumbnailCache.key(
            messageID: message.id,
            index: index,
            imageCount: message.images.count,
            contentRevision: message.contentRevision
        )
        return Button {
            onImagePreview(image)
        } label: {
            layout(Image(nsImage: ConversationThumbnailCache.image(image, key: thumbnailKey)).resizable())
                .clipShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous))
        }
        .buttonStyle(.dockHover)
        .contentShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous))
        .help("Open image preview")
    }

    var body: some View {
        #if DEBUG
            let _ = evaluation?("message", -1)
        #endif
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                let fullText = GenerativeUIIntegration.displayUserText(message.text).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let replySplit = ReplyQuote.split(fullText)
                let userText = replySplit?.body ?? fullText
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                    // Attachments sit above the text surface instead of inside
                    // the bubble, keeping media visually distinct from copy.
                    // A single image keeps its aspect ratio; several become a
                    // grid of square tiles instead of a tall stack.
                    if message.images.count == 1 {
                        // Size the frame to the fitted image so wide shots don't
                        // sit centered in a 220pt square with a gap below.
                        let size = message.images[0].size
                        let scale = min(220 / max(size.width, 1), 220 / max(size.height, 1), 1)
                        imageThumbnail(at: 0) {
                            $0.scaledToFit().frame(width: size.width * scale, height: size.height * scale)
                        }
                    } else if message.images.count > 1 {
                        let tile: CGFloat = 104
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.fixed(tile), spacing: 6), count: min(message.images.count, 3)),
                            alignment: .trailing,
                            spacing: 6
                        ) {
                            ForEach(message.images.indices, id: \.self) { index in
                                imageThumbnail(at: index) { $0.scaledToFill().frame(width: tile, height: tile) }
                            }
                        }
                        .fixedSize()
                    }
                    if !userText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if let quote = replySplit?.quote { ReplyQuoteChip(quote: quote, showsAuthor: false) }
                            InlineBotMentionText(
                                text: userText,
                                botMentions: ComposerBotMention.rebasing(
                                    message.botMentions, from: message.text, to: userText),
                                themeRevision: themeRevision)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Color.dockPrimaryText)
                        .dockPadding(.horizontal, 14)
                        .dockPadding(.vertical, 10)
                        .background(
                            Self.userBubbleShape.fill(
                                DockSkinPresentation.current.transcript == .document
                                    ? Color.dockSurface : Color.dockUserMessageBubble)
                        )
                        .overlay {
                            Self.userBubbleShape
                                .stroke(
                                    message.isSteering
                                        ? Color.dockAccent.opacity(0.45)
                                        : DockSkinPresentation.current.transcript == .document
                                            ? .clear : Color.dockBorderStrong,
                                    lineWidth: 0.5
                                )
                                .allowsHitTesting(false)
                        }
                    }

                    HStack(spacing: 6) {
                        if message.isSteering {
                            Text(steeringLabel)
                                .dockFont(.metadata, weight: .medium)
                                .foregroundStyle(Color.dockAccent)
                        }
                        ConversationRowHoverTimestamp(text: message.timeLabel, hover: hoverPresentation)
                            .dockFont(.machineMetadata)
                            .foregroundStyle(Color.dockMetadataText)
                        HStack(spacing: 0) {
                            actionButton(.copy, action: onCopy)
                            if showsPinAction { actionButton(.pin, action: onPin, isAvailable: isPinAvailable) }
                        }
                    }
                    .dockPadding(.horizontal, 4)
                    .dockPadding(.top, 2)
                }
                .onHover { hoverPresentation.isHovering = $0 }
                .frame(maxWidth: metrics.userMessageWidthFraction * metrics.readingWidth, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    let attributedBotID =
                        SessionBotParticipants.authorID(message, activeProfileID: activeBotProfileID)
                    if let botProfileID = attributedBotID {
                        let bot = botsByID[botProfileID]
                        HStack(spacing: 7) {
                            if let bot {
                                BotAvatarView(
                                    bot: bot,
                                    imageData: avatarImages[bot.id],
                                    size: 24,
                                    mood: isStreamingMessage ? streamingMood : nil,
                                    orbits: isStreamingMessage
                                )
                            } else {
                                BotFaceMark(id: botProfileID, size: 24, animated: true)
                            }
                            let requester =
                                message.isBotHandoffReply
                                ? activeBotProfileID.flatMap { $0 == botProfileID ? nil : botsByID[$0] } : nil
                            if let bot, let previewWorkspace {
                                Button(bot.name) {
                                    SessionMessageTabs.shared.open(.bot(bot), in: previewWorkspace)
                                }
                                .buttonStyle(.dockLink)
                                .dockFont(.metadata, weight: .medium)
                                .help("Preview " + bot.name)
                                if let requester {
                                    Text("replied to " + requester.name)
                                        .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                                }
                            } else {
                                Text(message.botDisplayName ?? botProfileID)
                                    .dockFont(.metadata, weight: .medium).foregroundStyle(Color.dockSecondaryText)
                            }
                        }
                        .dockPadding(.horizontal, 4)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Message from \(bot?.name ?? message.botDisplayName ?? botProfileID)")
                    }

                    if let event = message.systemEvent, event.isFeed {
                        FeedEventRow(
                            event: event, line: FeedLine(message.text), timeLabel: message.timeLabel,
                            botsByID: botsByID, avatarImages: avatarImages)
                    } else if let event = message.systemEvent {
                        SystemEventCard(event: event, text: message.text, timeLabel: message.timeLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let notice = message.kanbanNotice {
                        KanbanNoticeCard(
                            notice: notice, botID: message.botProfileID ?? activeBotProfileID,
                            timeLabel: message.timeLabel, botsByID: botsByID, avatarImages: avatarImages,
                            loadDetail: loadKanbanDetail.map { load in { await load(notice) } })
                    } else if !message.text.isEmpty || isStreamingMessage
                        || !ArtifactService.deliveredFiles(in: message.activity).isEmpty
                    {
                        Group {
                            if isStreamingMessage, let streamingText {
                                // The row is an equatable boundary that does
                                // not observe live text. StreamingMessageText
                                // observes it and owns the native switch, so a
                                // long response can never freeze at the
                                // snapshot captured by the last row render.
                                StreamingMessageText(streaming: streamingText)
                            } else if message.isError {
                                DockCallout(
                                    tone: .danger,
                                    icon: .warningCircle,
                                    title: "Request could not be completed",
                                    message: message.text
                                )
                            } else if message.isBotHandoffReply {
                                // A teammate's answer, quoted: it informs this
                                // chat but is not the assistant speaking.
                                assistantBody
                                    .dockPadding(.leading, 12)
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(DockAccentColor.identity(for: message.botProfileID ?? "").fill)
                                            .frame(width: 2.5)
                                    }
                            } else {
                                assistantBody
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dockPadding(.horizontal, 4)
                        .dockPadding(.vertical, 6)
                        .foregroundStyle(Color.dockPrimaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if message.kanbanNotice != nil || message.systemEvent != nil {
                        EmptyView()
                    } else if !message.isError, message.hasBodyText {
                        messageActions
                    } else if isStreamingMessage, let streamingText {
                        StreamingResponseMetadata(
                            streaming: streamingText,
                            timestamp: message.timestamp,
                            timeLabel: message.timeLabel,
                            modelName: message.modelName,
                            responseDuration: message.responseDuration
                        )
                    } else if message.isError {
                        messageMetadata
                    }
                }
                .onHover { hoverPresentation.isHovering = $0 }
            }
        }
        .dockPadding(.horizontal, metrics.contentInset)
        .dockPadding(.vertical, message.systemEvent != nil || message.kanbanNotice != nil ? 1 : 8)
        .dockPadding(.top, message.role == .user ? 12 : 0)
    }

    /// The tail corner points toward the sender edge so consecutive prompts
    /// read as one side of the exchange without an avatar.
    private static var userBubbleShape: AnyShape {
        if DockSkinPresentation.current.transcript == .document {
            return AnyShape(DockThemeShape(cornerRadius: DockLayout.paneRadius, role: .pane))
        }
        return AnyShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 14,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 4,
                topTrailingRadius: 14,
                style: .continuous
            ))
    }

    private var steeringLabel: String {
        let status = (message.steeringStatus ?? "queued").lowercased()
        return "Steering · \(status)"
    }

    private enum AssistantBlock {
        case markdown(String)
        case image(String)
        case files([String])
    }

    /// Merges consecutive non-image attachments into one block so they render as a single card.
    private static func groupFiles(_ segments: [ChatMediaSegment]) -> [AssistantBlock] {
        var blocks: [AssistantBlock] = []
        for segment in segments {
            switch segment {
            case .markdown(let text): blocks.append(.markdown(text))
            case .media(let path) where ArtifactService.kind(for: path) == .image: blocks.append(.image(path))
            case .media(let path):
                if case .files(let paths)? = blocks.last {
                    blocks[blocks.count - 1] = .files(paths + [path])
                } else {
                    blocks.append(.files([path]))
                }
            }
        }
        return blocks
    }

    @ViewBuilder
    private var assistantBody: some View {
        GenerativeUIIntegration.renderReply(message.text) { standardAssistantBody }
    }

    @ViewBuilder
    private var standardAssistantBody: some View {
        let segments = ChatMediaSegment.split(
            message.text, delivered: ArtifactService.deliveredFiles(in: message.activity))
        if segments == [.markdown(message.text)] {
            messageMarkdownView(message.text)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.groupFiles(segments).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .markdown(let text):
                        messageMarkdownView(text)
                    case .image(let path):
                        ChatMediaAttachmentCard(path: path)
                    case .files(let paths):
                        VStack(spacing: 0) {
                            ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                                if index > 0 { Divider().overlay(Color.dockBorderLight) }
                                ChatMediaAttachmentCard(path: path, grouped: true)
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                                .dockSurfaceFill(Color.dockSurface2.opacity(0.55))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).stroke(
                                Color.dockBorderLight, lineWidth: 0.5))
                    }
                }
            }
        }
    }

    private func messageMarkdownView(_ markdown: String, hugsContent: Bool = false) -> some View {
        // Trailing blank lines would render as empty paragraphs and open a gap
        // above the action row.
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        // Every assistant reply uses the section host. Routing long replies
        // through one text view bypasses its viewport mounting and height cache.
        return Group {
            if hugsContent {
                NativeMarkdownMessageView(markdown: trimmed, themeRevision: themeRevision, hugsContent: hugsContent)
            } else {
                MarkdownMessageView(markdown: trimmed).equatable()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var messageActions: some View {
        HStack(spacing: 6) {
            actionButton(.copy, action: onCopy)
            actionButton(.refresh, action: onRefresh, isAvailable: areSessionActionsAvailable)
            moreMessageActions
            if isSpeaking {
                actionButton(.readAloud, action: onReadAloud)
            }
            messageMetadata
        }
        .dockButtonSize(.compact)
        .dockPopover(item: $sendTarget, arrowEdge: .bottom) { bot in
            if let forwardContent { forwardContent(bot) { sendTarget = nil } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message actions")
    }

    private var moreMessageActions: some View {
        DockMenu {
            Button(action: onReadAloud) {
                Label(isSpeaking ? "Stop reading aloud" : "Read aloud", icon: isSpeaking ? .stop : .speakerHigh)
            }
            .disabled(pendingAction == .readAloud || !areSessionActionsAvailable)
            Button(action: onBranch) {
                Label("Branch from this message", icon: .shuffleAngular)
            }
            .disabled(pendingAction != nil || !areSessionActionsAvailable)
            Button(action: onReply) { Label("Reply to this message", icon: .arrowBendUpLeft) }
            if showsPinAction {
                Button(action: onPin) {
                    HStack(spacing: 8) {
                        DockIcon(.pushPin, size: 12, weight: isPinned ? .fill : .regular)
                        Text(isPinned ? "Unpin message" : "Pin message")
                    }
                }
                .disabled(pendingAction == .pin || !isPinAvailable)
            }
            if let onOpenInTab {
                Button(action: onOpenInTab) { Label("Open message in new tab", icon: .arrowSquareOut) }
                    .disabled(isStreamingMessage)
            }
            sendToBotMenu
        } label: {
            ZStack {
                DockIcon(.dotsThree, size: 16, color: .dockSecondaryText)
                    .opacity(pendingAction != nil && pendingAction != .refresh ? 0 : 1)
                if pendingAction != nil && pendingAction != .refresh {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 28, height: 28)
        }
        .help("More message actions")
        .accessibilityLabel("More message actions")
    }

    @ViewBuilder
    private var sendToBotMenu: some View {
        let targets = botsByID.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if forwardContent != nil, message.hasBodyText, message.systemEvent == nil, !message.isError {
            DockMenu {
                ForEach(targets) { bot in
                    Button(bot.name) { sendTarget = bot }
                }
            } label: {
                Label("Forward to bot", icon: .paperPlaneTilt)
            }
            .help(targets.isEmpty ? "No bots available" : "Forward to bot")
            .disabled(!areSessionActionsAvailable || targets.isEmpty)
        }
    }

    private var messageMetadata: some View {
        HStack(spacing: 6) {
            if let durationLabel = message.durationLabel {
                HStack(spacing: 4) {
                    DockIcon(.timer, size: 12, color: .dockMetadataText)
                    Text(durationLabel)
                }
            }
            if let tokenCount = message.tokenCount {
                Text("· \(SessionTokenFormatting.format(tokenCount))")
                    .help("Tokens used by this turn, including tool calls and context")
            }
            if let modelName = message.modelName {
                Text("· \(modelName)")
            }
            ConversationRowHoverTimestamp(
                text: message.durationLabel != nil || message.tokenCount != nil || message.modelName != nil
                    ? "· \(message.timeLabel)" : message.timeLabel,
                hover: hoverPresentation,
                alwaysVisible: message.isError
            )
        }
        .dockFont(.machineMetadata)
        .foregroundStyle(Color.dockMetadataText)
        .lineLimit(1)
        .dockPadding(.leading, 4)
    }

    @ViewBuilder
    private func actionButton(
        _ kind: ConversationMessageActionKind,
        action: @escaping () -> Void,
        isAvailable: Bool = true
    ) -> some View {
        if kind == .copy {
            DockCopyButton(
                accessibilityLabel: kind.label,
                presentation: .icon,
                iconSize: 12,
                action: action
            )
            .buttonStyle(DockPressButtonStyle())
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        } else {
            let icon =
                kind == .readAloud && isSpeaking ? Ph.stop : kind.icon
            let label =
                kind == .pin && isPinned
                ? "Unpin message" : kind == .readAloud && isSpeaking ? "Stop reading aloud" : kind.label
            let isPending = pendingAction == kind
            let anotherMutationIsPending =
                pendingAction != nil
                && (kind == .branch || kind == .refresh)
                && !isPending
            let isActive = (kind == .readAloud && isSpeaking) || (kind == .pin && isPinned)
            let iconColor =
                isActive
                ? Color.dockPrimaryText
                : Color.dockSecondaryText
            Button(action: action) {
                if isPending {
                    ProgressView().controlSize(.small)
                } else {
                    DockIcon(icon, size: 12, weight: isActive ? .fill : .regular, color: iconColor)
                }
            }
            .buttonStyle(DockPressButtonStyle())
            .frame(width: 28, height: 28)
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .contentShape(Rectangle())
            .help(label)
            .accessibilityLabel(label)
            .accessibilityValue(isAvailable ? "Available" : "Unavailable until a conversation session is selected")
            .disabled(isPending || anotherMutationIsPending || !isAvailable)
        }
    }

}

/// Kanban wake notice as a signage card (DESIGN.md anatomy): status dot,
/// card title and id, then the status label in the tone hue with one detail
/// line. Clicking reveals the card's run chain (which bot handed off to
/// which) and the full handoff, fetched from the card because Hermes only
/// notifies terminal events and clips the notice to its first line.
/// A row Hermes produced itself: label and first line, full text on expand.
struct SystemEventCard: View {
    let event: SystemEvent
    let text: String
    let timeLabel: String
    @State var isExpanded = false
    @State var hoverPresentation = ConversationRowHoverPresentation()
    #if DEBUG
        @Environment(\.conversationRowEvaluation) private var evaluation
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        #if DEBUG
            let _ = evaluation?("system", -1)
        #endif
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let canExpand = firstLine != text || text.count > 90
        VStack(alignment: .leading, spacing: DockSpacing.micro) {
            Button {
                withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: DockSpacing.tight) {
                    DockIcon(event.tone.activityIcon, size: 12, weight: .fill, color: event.tone.color)
                    Text(event.label)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.dockSecondaryText)
                        .fixedSize()
                    if !isExpanded {
                        Self.inlineMarkdown(firstLine)
                            .foregroundStyle(Color.dockMetadataText)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                    Spacer(minLength: DockSpacing.control)
                    Text(timeLabel).foregroundStyle(Color.dockMetadataText).fixedSize()
                    if canExpand {
                        DockIcon(isExpanded ? .caretDown : .caretRight, size: 10, color: .dockMetadataText)
                    }
                }
                .dockFont(.machineMetadata)
                .dockPadding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    ConversationRowHoverBackground(hover: hoverPresentation, isExpanded: isExpanded)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .disabled(!canExpand)
            .onHover { hoverPresentation.isHovering = $0 }
            .help(canExpand ? (isExpanded ? "Collapse" : "Show full text") : "")

            if isExpanded {
                Self.inlineMarkdown(text)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .dockPadding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(event.tone.color.opacity(0.5)).frame(width: 2)
                    }
                    .dockPadding(.leading, 14)
                    .dockPadding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.label): \(text)")
    }

    /// Bold and code spans render; block markdown stays literal text.
    static func inlineMarkdown(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }
}

/// One plugin feed entry: tone icon, headline, the bots it names as avatar
/// chips, tags, then the card id and time. Click shows the quoted detail.
struct FeedEventRow: View {
    let event: SystemEvent
    let line: FeedLine
    let timeLabel: String
    let botsByID: [String: BotSummary]
    let avatarImages: [String: Data]
    @State var isExpanded = false
    @State var hoverPresentation = ConversationRowHoverPresentation()
    #if DEBUG
        @Environment(\.conversationRowEvaluation) private var evaluation
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Detail lines, or a headline too long for one line, can expand.
    private var canExpand: Bool { line.detail != nil || line.headline.count > 90 }

    var body: some View {
        #if DEBUG
            let _ = evaluation?("feed", -1)
        #endif
        VStack(alignment: .leading, spacing: DockSpacing.micro) {
            Button {
                guard canExpand else { return }
                withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: DockSpacing.tight) {
                    DockIcon(event.tone.activityIcon, size: 13, weight: .fill, color: event.tone.color)
                    ForEach(Array(line.bots.enumerated()), id: \.offset) { _, id in
                        BotChip(id: id, botsByID: botsByID, avatarImages: avatarImages)
                    }
                    SystemEventCard.inlineMarkdown(line.headline.isEmpty ? event.label : line.headline)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(isExpanded ? nil : 1)
                        .fixedSize(horizontal: false, vertical: isExpanded)
                        .layoutPriority(1)
                    ForEach(Array(line.tags.enumerated()), id: \.offset) { _, tag in
                        Text(tag).foregroundStyle(Color.dockSecondaryText).lineLimit(1).fixedSize()
                    }
                    Spacer(minLength: DockSpacing.control)
                    Text(event.label).fixedSize().help("Posted by the \(event.label) plugin")
                    if let id = line.id { Text(id).fixedSize() }
                    Text(timeLabel).fixedSize()
                    if canExpand {
                        DockIcon(isExpanded ? .caretDown : .caretRight, size: 10, color: .dockMetadataText)
                    }
                }
                .dockFont(.machineMetadata)
                .foregroundStyle(Color.dockMetadataText)
                .dockPadding(.horizontal, 8)
                .frame(height: isExpanded ? nil : 28)
                .clipped()
                .background(
                    ConversationRowHoverBackground(hover: hoverPresentation, isExpanded: isExpanded)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .onHover { hoverPresentation.isHovering = $0 }
            .help(canExpand ? (isExpanded ? "Hide details" : "Show details") : "")

            if isExpanded, let detail = line.detail {
                SystemEventCard.inlineMarkdown(detail)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .dockPadding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(event.tone.color.opacity(0.5)).frame(width: 2)
                    }
                    .dockPadding(.leading, 14)
                    .dockPadding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.label): \(line.headline)")
    }

}

extension DockStatusTone {
    /// Leading icon for one-line activity rows (feeds, kanban notices).
    var activityIcon: Ph {
        switch self {
        case .complete: .checkCircle
        case .working: .play
        case .review: .magnifyingGlass
        case .queued: .arrowsClockwise
        case .attention: .warningCircle
        default: .pulse
        }
    }
}

/// A bot named inline: avatar and name, or `@id` for an unknown bot.
struct BotChip: View {
    let id: String
    let botsByID: [String: BotSummary]
    let avatarImages: [String: Data]
    var displayName: String? = nil
    var showsPreview = false

    var body: some View {
        HStack(spacing: 4) {
            if let bot = botsByID[id] {
                BotAvatarView(bot: bot, imageData: avatarImages[bot.id], size: 16, orbits: false)
                Text(bot.name).underline(showsPreview)
            } else {
                BotFaceMark(id: id, size: 16, animated: true)
                Text(displayName ?? id).underline(showsPreview)
            }
        }
        .dockFont(.body, weight: .medium)
        .foregroundStyle(Color.dockSecondaryText)
        .lineLimit(1)
        .dockPadding(.leading, 2).dockPadding(.trailing, 6).dockPadding(.vertical, 1)
        .background(Capsule().fill(Color.dockPrimaryText.opacity(0.06)))
        .fixedSize()
    }
}

struct KanbanNoticeCard: View {
    let notice: KanbanNotice
    var botID: String?
    var timeLabel: String = ""
    var botsByID: [String: BotSummary] = [:]
    var avatarImages: [String: Data] = [:]
    var loadDetail: (() async -> KanbanTaskDetail?)?
    @State private var isExpanded = false
    @State private var isHovering = false
    @State private var card: KanbanTaskDetail?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DockSpacing.micro) {
            Button {
                withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: DockSpacing.tight) {
                    DockIcon(notice.tone.activityIcon, size: 13, weight: .fill, color: notice.tone.color)
                    if let botID {
                        BotChip(id: botID, botsByID: botsByID, avatarImages: avatarImages)
                    }
                    Text(notice.label)
                        .dockFont(.body, weight: .medium)
                        .foregroundStyle(notice.tone.color)
                        .fixedSize()
                    Text(notice.title ?? "Kanban \(notice.taskID)")
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !isExpanded, let detail = notice.detail {
                        Text(detail.split(separator: "\n").first.map(String.init) ?? detail)
                            .dockFont(.body)
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DockSpacing.control)
                    Text(notice.taskID).fixedSize()
                    Text(timeLabel).fixedSize()
                    DockIcon(isExpanded ? .caretDown : .caretRight, size: 10, color: .dockMetadataText)
                }
                .dockFont(.machineMetadata)
                .lineLimit(1)
                .foregroundStyle(Color.dockMetadataText)
                .dockPadding(.horizontal, 8)
                .frame(height: 28)
                .clipped()
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.dockPrimaryText.opacity(isHovering || isExpanded ? 0.05 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .help(isExpanded ? "Hide details" : "Show details")

            if isExpanded {
                VStack(alignment: .leading, spacing: DockSpacing.micro) {
                    if let runs = card?.runs, runs.count > 1 {
                        ForEach(runs) { run in
                            HStack(spacing: DockSpacing.tight) {
                                Text(run.profile ?? "worker").fontWeight(.medium).foregroundStyle(Color.dockPrimaryText)
                                Text(Self.outcomeLabel(run)).foregroundStyle(
                                    run.error == nil ? Color.dockSecondaryText : Color.dockWarning)
                                Spacer(minLength: DockSpacing.control)
                                if let at = run.endedAt ?? run.startedAt {
                                    Text(at.formatted(date: .omitted, time: .shortened)).foregroundStyle(
                                        Color.dockMetadataText)
                                }
                            }
                            .dockFont(.machineMetadata)
                            .help(run.error ?? run.summary ?? "")
                        }
                    }
                    if let card {
                        let step = [card.status, card.currentStepKey, card.assignee.map { "@\($0)" }]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        Text(step)
                            .dockFont(.machineMetadata)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    // Created/picked-up/unblocked carry no summary; show the task body instead.
                    if let text = card.flatMap(notice.fullSummary(in:)) ?? notice.detail ?? card?.body {
                        MarkdownMessageView(markdown: text.trimmingCharacters(in: .whitespacesAndNewlines))
                            .equatable()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .dockPadding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(notice.tone.color.opacity(0.5)).frame(width: 2)
                }
                .dockPadding(.leading, 14)
                .dockPadding(.bottom, 4)
                .task {
                    guard card == nil, let loadDetail else { return }
                    card = await loadDetail()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .dockEase(duration: 0.16)) { isHovering = hovering }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kanban \(notice.taskID): \(notice.label)\(notice.title.map { ", \($0)" } ?? "")")
    }

    /// `review_requested` → "Review requested"; falls back to the run status.
    static func outcomeLabel(_ run: KanbanRunSummary) -> String {
        let raw = (run.outcome ?? run.status).replacingOccurrences(of: "_", with: " ")
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}
