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
        onRefresh: @escaping () -> Void = {}
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

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                let userText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                    // Attachments sit above the text surface instead of inside
                    // the bubble, keeping media visually distinct from copy.
                    if !message.images.isEmpty {
                        VStack(alignment: .trailing, spacing: 6) {
                            ForEach(Array(message.images.enumerated()), id: \.offset) { index, image in
                                let thumbnailKey = ConversationThumbnailCache.key(
                                    messageID: message.id,
                                    index: index,
                                    imageCount: message.images.count,
                                    contentRevision: message.contentRevision
                                )
                                Button {
                                    onImagePreview(image)
                                } label: {
                                    Image(nsImage: ConversationThumbnailCache.image(image, key: thumbnailKey))
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: 220, maxHeight: 220)
                                        .clipShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .contentShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous))
                                .help("Open image preview")
                            }
                        }
                    }
                    if !userText.isEmpty {
                        messageMarkdownView(userText)
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
                    let attributedBotID = message.botProfileID ?? activeBotProfileID
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

                    if !message.text.isEmpty || isStreamingMessage {
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

                    if !message.isError, message.hasBodyText {
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
        .padding(.vertical, 8)
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
        let segments = ChatMediaSegment.split(message.text)
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
    private func messageMarkdownView(_ markdown: String) -> some View {
        NativeMarkdownMessageView(markdown: markdown, themeRevision: themeRevision)
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
                DockIconLabel(durationLabel, icon: .timer)
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

    private func actionButton(
        _ kind: ConversationMessageActionKind,
        action: @escaping () -> Void,
        isAvailable: Bool = true
    ) -> some View {
        let icon = kind == .readAloud && isSpeaking ? .stop : kind.icon
        let label = kind == .readAloud && isSpeaking ? "Stop reading aloud" : kind.label
        let isPending = pendingAction == kind
        let anotherMutationIsPending = pendingAction != nil
            && (kind == .branch || kind == .refresh)
            && !isPending
        let iconColor = kind == .readAloud && isSpeaking
            ? Color.dockAccent
            : Color.dockSecondaryText
        return Button(action: action) {
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
