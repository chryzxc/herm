import AppKit
import SwiftUI

enum ConversationMessageActionKind: String, CaseIterable, Identifiable {
    case branch
    case copy
    case readAloud
    case refresh

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .branch: "arrow.triangle.branch"
        case .copy: "doc.on.doc"
        case .readAloud: "speaker.wave.2"
        case .refresh: "arrow.clockwise"
        }
    }

    var label: String {
        switch self {
        case .branch: "Branch from this message"
        case .copy: "Copy message"
        case .readAloud: "Read message aloud"
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
    let onImagePreview: (NSImage) -> Void
    let isActionPending: Bool
    let areSessionActionsAvailable: Bool
    let isSpeaking: Bool
    let onCopy: () -> Void
    let onBranch: () -> Void
    let onReadAloud: () -> Void
    let onRefresh: () -> Void
    @State private var hoveredAction: ConversationMessageActionKind?

    init(
        message: ChatMessage,
        isStreamingMessage: Bool,
        streamingText: StreamingText?,
        activeBotProfileID: String?,
        botsByID: [String: BotSummary],
        avatarImages: [String: Data],
        botRosterRevision: Int,
        onImagePreview: @escaping (NSImage) -> Void,
        isActionPending: Bool = false,
        areSessionActionsAvailable: Bool = true,
        isSpeaking: Bool = false,
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
        self.onImagePreview = onImagePreview
        self.isActionPending = isActionPending
        self.areSessionActionsAvailable = areSessionActionsAvailable
        self.isSpeaking = isSpeaking
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
            && lhs.isStreamingMessage == rhs.isStreamingMessage
            && lhs.activeBotProfileID == rhs.activeBotProfileID
            && lhs.botRosterRevision == rhs.botRosterRevision
            && lhs.isActionPending == rhs.isActionPending
            && lhs.areSessionActionsAvailable == rhs.areSessionActionsAvailable
            && lhs.isSpeaking == rhs.isSpeaking
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
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .help("Open image preview")
                            }
                        }
                    }
                    if message.isSteering || !userText.isEmpty {
                        VStack(alignment: .trailing, spacing: 6) {
                            if message.isSteering {
                                Text("STEERING · \(message.steeringStatus ?? "QUEUED")")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.dockAccent)
                            }
                            if !userText.isEmpty {
                                MarkdownMessageView(markdown: userText)
                                    .equatable()
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Color.dockPrimaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        // Use opaque slate-navy user message bubble background to eliminate eye strain
                        .background(Color.dockUserMessageBubble)
                        .clipShape(MessageBubbleShape(isUser: true))
                        .overlay(
                            MessageBubbleShape(isUser: true)
                                .stroke(Color.dockBorderStrong, lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(0.12), radius: 4)
                    }

                    Text(message.timeLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockMetadataText)
                        .padding(.horizontal, 4)
                }
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
                                    LucideImage(systemName: BotAvatarPresentation.symbol(for: botProfileID))
                                        .font(.system(size: 8, weight: .semibold))
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(.white.opacity(0.96))
                                }
                                .frame(width: 24, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 24 * 0.28, style: .continuous))
                            }
                            Text(bot?.name ?? message.botDisplayName ?? botProfileID)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.dockAccent)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Message from \(bot?.name ?? message.botDisplayName ?? botProfileID)")
                    }

                    if !message.text.isEmpty || isStreamingMessage {
                        Group {
                            if isStreamingMessage, let streamingText {
                                StreamingMessageText(streaming: streamingText)
                            } else if message.isError {
                                HStack(alignment: .top, spacing: 10) {
                                    LucideImage(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(Color.dockWarning)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Request could not be completed")
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(message.text)
                                            .font(.system(size: 13))
                                            .textSelection(.enabled)
                                    }
                                }
                            } else {
                                MarkdownMessageView(markdown: message.text)
                                    .equatable()
                            }
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .foregroundStyle(Color.dockPrimaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Use opaque charcoal-indigo AI message bubble (DESIGN.md) to eliminate high-contrast glare
                            .background(message.isError ? Color.dockWarning.opacity(0.10) : Color.dockMessageBubble)
                            .clipShape(MessageBubbleShape(isUser: false))
                            .overlay(
                                MessageBubbleShape(isUser: false)
                                    .stroke(message.isError ? Color.dockWarning.opacity(0.55) : Color.dockBorder, lineWidth: 0.5)
                            )
                    }

                    if !message.isError, message.hasBodyText {
                        messageActions
                    } else if message.isError {
                        messageMetadata
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var messageActions: some View {
        HStack(spacing: -8) {
            ForEach(ConversationMessageActionKind.allCases) { kind in
                actionButton(
                    kind,
                    action: { perform(kind) },
                    isAvailable: kind == .copy || areSessionActionsAvailable
                )
            }
            messageMetadata
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message actions")
    }

    private var messageMetadata: some View {
        HStack(spacing: 6) {
            Text(message.timeLabel)
            if let durationLabel = message.durationLabel {
                LucideLabel(durationLabel, icon: "stopwatch")
            }
            if let modelName = message.modelName {
                Text("· \(modelName)")
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Color.dockMetadataText)
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
        let icon = kind == .readAloud && isSpeaking ? "stop.fill" : kind.icon
        let label = kind == .readAloud && isSpeaking ? "Stop reading aloud" : kind.label
        return Button(action: action) {
            if isActionPending {
                ProgressView().controlSize(.small)
            } else {
                LucideIcon(
                    name: .from(systemName: icon),
                    size: 13,
                    color: Color.dockMetadataText
                )
            }
        }
        .buttonStyle(DockPressButtonStyle())
        // Compact the action strip while retaining a 44pt interactive area.
        .frame(width: 36, height: 36)
        .padding(4)
        .contentShape(Rectangle())
        .help(label)
        .overlay(alignment: .top) {
            if hoveredAction == kind {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockPrimaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.dockControlSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .fixedSize()
                    .offset(y: -25)
                    .allowsHitTesting(false)
                    .zIndex(2)
            }
        }
        .onHover { hovering in
            hoveredAction = hovering ? kind : nil
        }
        .accessibilityLabel(label)
        .accessibilityValue(isAvailable ? "Available" : "Unavailable until a conversation session is selected")
        .disabled(isActionPending || !isAvailable)
    }

}
