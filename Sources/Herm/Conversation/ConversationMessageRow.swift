import AppKit
import SwiftUI

enum ConversationMessageActionKind: String, CaseIterable, Identifiable {
    case copy
    case readAloud
    case branch
    case refresh

    var id: String { rawValue }

    var icon: Ph {
        switch self {
        case .copy: .copy
        case .readAloud: .speakerHigh
        case .branch: .gitBranch
        case .refresh: .arrowClockwise
        }
    }

    var label: String {
        switch self {
        case .copy: "Copy message"
        case .readAloud: "Read message aloud"
        case .branch: "Branch from this message"
        case .refresh: "Refresh this response"
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
    let onCopy: () -> Void
    let onBranch: () -> Void
    let onReadAloud: () -> Void
    let onRefresh: () -> Void
    let loadKanbanDetail: ((KanbanNotice) async -> KanbanTaskDetail?)?
    init(
        message: ChatMessage,
        isStreamingMessage: Bool,
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
        onCopy: @escaping () -> Void = {},
        onBranch: @escaping () -> Void = {},
        onReadAloud: @escaping () -> Void = {},
        onRefresh: @escaping () -> Void = {},
        loadKanbanDetail: ((KanbanNotice) async -> KanbanTaskDetail?)? = nil
    ) {
        self.message = message
        self.isStreamingMessage = isStreamingMessage
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
        self.onCopy = onCopy
        self.onBranch = onBranch
        self.onReadAloud = onReadAloud
        self.onRefresh = onRefresh
        self.loadKanbanDetail = loadKanbanDetail
    }

    nonisolated static func == (lhs: ConversationMessageRow, rhs: ConversationMessageRow) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.contentRevision == rhs.message.contentRevision
            && lhs.message.role == rhs.message.role
            && lhs.message.images.count == rhs.message.images.count
            && lhs.message.isSteering == rhs.message.isSteering
            && lhs.message.steeringStatus == rhs.message.steeringStatus
            && lhs.message.isError == rhs.message.isError
            && lhs.message.botProfileID == rhs.message.botProfileID
            && lhs.message.botDisplayName == rhs.message.botDisplayName
            && lhs.message.responseDuration == rhs.message.responseDuration
            && lhs.message.tokenCount == rhs.message.tokenCount
            && lhs.isStreamingMessage == rhs.isStreamingMessage
            && lhs.activeBotProfileID == rhs.activeBotProfileID
            && lhs.botRosterRevision == rhs.botRosterRevision
            && lhs.themeRevision == rhs.themeRevision
            && lhs.pendingAction == rhs.pendingAction
            && lhs.areSessionActionsAvailable == rhs.areSessionActionsAvailable
            && lhs.isSpeaking == rhs.isSpeaking
            && lhs.metrics == rhs.metrics
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
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous))
        .help("Open image preview")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                let userText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        imageThumbnail(at: 0) { $0.scaledToFit().frame(width: size.width * scale, height: size.height * scale) }
                    } else if message.images.count > 1 {
                        let tile: CGFloat = 104
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(tile), spacing: 6), count: min(message.images.count, 3)),
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
                        messageMarkdownView(userText, hugsContent: true)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(Color.dockPrimaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Self.userBubbleShape.fill(Color.dockUserMessageBubble))
                            .overlay {
                                Self.userBubbleShape
                                    .stroke(
                                        message.isSteering ? Color.dockAccent.opacity(0.45) : Color.dockBorderStrong,
                                        lineWidth: 0.5
                                    )
                                    .allowsHitTesting(false)
                            }
                    }

                    HStack(spacing: 6) {
                        if message.isSteering {
                            Text(steeringLabel)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.dockAccent)
                        }
                        actionButton(.copy, action: onCopy)
                        Text(message.timeLabel)
                            .font(DockTypography.machineMetadata)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                }
                .frame(maxWidth: metrics.userMessageWidthFraction * metrics.readingWidth, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    let attributedBotID = message.systemEvent == nil && message.kanbanNotice == nil ? message.botProfileID ?? activeBotProfileID : nil
                    if let botProfileID = attributedBotID {
                        let bot = botsByID[botProfileID]
                        HStack(spacing: 7) {
                            if let bot {
                                BotAvatarView(
                                    bot: bot,
                                    imageData: avatarImages[bot.id],
                                    size: 24
                                )
                            } else {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 24 * 0.28, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: BotAvatarPresentation.palette(for: botProfileID),
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                    Circle()
                                        .stroke(.white.opacity(0.20), lineWidth: 0.6)
                                        .frame(width: 15, height: 15)
                                    DockIcon(BotAvatarPresentation.symbol(for: botProfileID))
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.96))
                                }
                                .frame(width: 24, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 24 * 0.28, style: .continuous))
                            }
                            Text(bot?.name ?? message.botDisplayName ?? botProfileID)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.dockSecondaryText)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Message from \(bot?.name ?? message.botDisplayName ?? botProfileID)")
                    }

                    if let event = message.systemEvent, event.isFeed {
                        FeedEventRow(event: event, line: FeedLine(message.text), timeLabel: message.timeLabel,
                                     botsByID: botsByID, avatarImages: avatarImages)
                    } else if let event = message.systemEvent {
                        SystemEventCard(event: event, text: message.text)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        messageMetadata
                    } else if let notice = message.kanbanNotice {
                        KanbanNoticeCard(notice: notice, botID: message.botProfileID ?? activeBotProfileID,
                                         timeLabel: message.timeLabel, botsByID: botsByID, avatarImages: avatarImages,
                                         loadDetail: loadKanbanDetail.map { load in { await load(notice) } })
                    } else if !message.text.isEmpty || isStreamingMessage || !ArtifactService.deliveredFiles(in: message.activity).isEmpty {
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
                            } else {
                                assistantBody
                            }
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 6)
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
            }
        }
        .padding(.horizontal, metrics.contentInset)
        .padding(.vertical, message.systemEvent?.isFeed == true || message.kanbanNotice != nil ? 1 : 8)
    }

    /// The tail corner points toward the sender edge so consecutive prompts
    /// read as one side of the exchange without an avatar.
    private static let userBubbleShape = UnevenRoundedRectangle(
        topLeadingRadius: 14,
        bottomLeadingRadius: 14,
        bottomTrailingRadius: 4,
        topTrailingRadius: 14,
        style: .continuous
    )

    private var steeringLabel: String {
        let status = (message.steeringStatus ?? "queued").lowercased()
        return "Steering · \(status)"
    }

    @ViewBuilder
    private var assistantBody: some View {
        let segments = ChatMediaSegment.split(message.text, delivered: ArtifactService.deliveredFiles(in: message.activity))
        if segments == [.markdown(message.text)] {
            messageMarkdownView(message.text)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .markdown(let text):
                        messageMarkdownView(text)
                    case .media(let path):
                        ChatMediaAttachmentCard(path: path)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageMarkdownView(_ markdown: String, hugsContent: Bool = false) -> some View {
        // Trailing blank lines would render as empty paragraphs and open a gap
        // above the action row.
        NativeMarkdownMessageView(
            markdown: markdown.trimmingCharacters(in: .whitespacesAndNewlines),
            themeRevision: themeRevision,
            hugsContent: hugsContent
        )
            .fixedSize(horizontal: false, vertical: true)
    }

    private var messageActions: some View {
        HStack(spacing: 0) {
            ForEach(ConversationMessageActionKind.allCases) { kind in
                actionButton(
                    kind,
                    action: { perform(kind) },
                    isAvailable: kind == .copy || areSessionActionsAvailable
                )
            }
            Rectangle()
                .fill(Color.dockBorderLight)
                .frame(width: 1, height: 12)
                .padding(.horizontal, 6)
            messageMetadata
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message actions")
    }

    private var messageMetadata: some View {
        HStack(spacing: 6) {
            Text(message.timeLabel)
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
        }
        .font(DockTypography.machineMetadata)
        .foregroundStyle(Color.dockMetadataText)
        .lineLimit(1)
        .padding(.leading, 4)
    }

    private func perform(_ kind: ConversationMessageActionKind) {
        switch kind {
        case .branch: onBranch()
        case .copy: onCopy()
        case .readAloud: onReadAloud()
        case .refresh: onRefresh()
        }
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
            let icon = kind == .readAloud && isSpeaking ? Ph.stop : kind.icon
            let label = kind == .readAloud && isSpeaking ? "Stop reading aloud" : kind.label
            let isPending = pendingAction == kind
            let anotherMutationIsPending = pendingAction != nil
                && (kind == .branch || kind == .refresh)
                && !isPending
            let iconColor = kind == .readAloud && isSpeaking
                ? Color.dockAccent
                : Color.dockSecondaryText
            Button(action: action) {
                if isPending {
                    ProgressView().controlSize(.small)
                } else {
                    DockIcon(icon, size: 12, color: iconColor)
                }
            }
            .buttonStyle(DockPressButtonStyle())
            .frame(width: 28, height: 28)
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
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let canExpand = firstLine != text || text.count > 120
        Button {
            withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DockSpacing.tight) {
                DockStatusDot(tone: event.tone)
                (Text(event.label).foregroundStyle(event.tone.color).fontWeight(.medium)
                    + Text(" · ") + Self.inlineMarkdown(isExpanded ? text : firstLine))
                    .foregroundStyle(Color.dockSecondaryText)
                    .font(DockTypography.body)
                    .lineLimit(isExpanded ? nil : 1)
                    .fixedSize(horizontal: false, vertical: isExpanded)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canExpand)
        .help(canExpand ? (isExpanded ? "Collapse" : "Show full text") : "")
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 520, alignment: .leading)
        .dockSignageCard(tone: event.tone, highlighted: false)
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
    @State private var isExpanded = false
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Detail lines, or a headline too long for one line, can expand.
    private var canExpand: Bool { line.detail != nil || line.headline.count > 90 }

    var body: some View {
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
                        .font(DockTypography.body)
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
                .font(DockTypography.machineMetadata)
                .foregroundStyle(Color.dockMetadataText)
                .padding(.horizontal, 8)
                .frame(height: isExpanded ? nil : 28)
                .clipped()
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.dockPrimaryText.opacity(isHovering || isExpanded ? 0.05 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(canExpand ? (isExpanded ? "Hide details" : "Show details") : "")

            if isExpanded, let detail = line.detail {
                SystemEventCard.inlineMarkdown(detail)
                    .font(DockTypography.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(event.tone.color.opacity(0.5)).frame(width: 2)
                    }
                    .padding(.leading, 14)
                    .padding(.bottom, 4)
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

    var body: some View {
        HStack(spacing: 4) {
            if let bot = botsByID[id] {
                BotAvatarView(bot: bot, imageData: avatarImages[bot.id], size: 16)
                Text(bot.name)
            } else {
                Text("@" + id)
            }
        }
        .font(DockTypography.machineMetadata.weight(.medium))
        .foregroundStyle(Color.dockSecondaryText)
        .lineLimit(1)
        .padding(.leading, 2).padding(.trailing, 6).padding(.vertical, 1)
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
                        .font(DockTypography.body.weight(.medium))
                        .foregroundStyle(notice.tone.color)
                        .fixedSize()
                    Text(notice.title ?? "Kanban \(notice.taskID)")
                        .font(DockTypography.body.weight(.semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !isExpanded, let detail = notice.detail {
                        Text(detail.split(separator: "\n").first.map(String.init) ?? detail)
                            .font(DockTypography.body)
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DockSpacing.control)
                    Text(notice.taskID).fixedSize()
                    Text(timeLabel).fixedSize()
                    DockIcon(isExpanded ? .caretDown : .caretRight, size: 10, color: .dockMetadataText)
                }
                .font(DockTypography.machineMetadata)
                .lineLimit(1)
                .foregroundStyle(Color.dockMetadataText)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .clipped()
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.dockPrimaryText.opacity(isHovering || isExpanded ? 0.05 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide details" : "Show details")

            if isExpanded {
                VStack(alignment: .leading, spacing: DockSpacing.micro) {
                    if let runs = card?.runs, runs.count > 1 {
                        ForEach(runs) { run in
                            HStack(spacing: DockSpacing.tight) {
                                Text(run.profile ?? "worker").fontWeight(.medium).foregroundStyle(Color.dockPrimaryText)
                                Text(Self.outcomeLabel(run)).foregroundStyle(run.error == nil ? Color.dockSecondaryText : Color.dockWarning)
                                Spacer(minLength: DockSpacing.control)
                                if let at = run.endedAt ?? run.startedAt {
                                    Text(at.formatted(date: .omitted, time: .shortened)).foregroundStyle(Color.dockMetadataText)
                                }
                            }
                            .font(DockTypography.machineMetadata)
                            .help(run.error ?? run.summary ?? "")
                        }
                    }
                    if let text = card.flatMap(notice.fullSummary(in:)) ?? notice.detail {
                        Text(text)
                            .font(DockTypography.body)
                            .foregroundStyle(Color.dockSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(notice.tone.color.opacity(0.5)).frame(width: 2)
                }
                .padding(.leading, 14)
                .padding(.bottom, 4)
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
