import AppKit
import SwiftUI
import Testing
@testable import Herm

/// Renders the conversation surface to PNG for visual review. Opt-in: set
/// `CHAT_SNAPSHOT_DIR` to a writable directory.
@MainActor
struct ConversationRenderSnapshotTests {
    @Test func renderConversation() async throws {
        guard let dir = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_DIR"] else { return }
        let isFullscreen = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_FULLSCREEN"] == "1"
        let width: CGFloat = isFullscreen ? 980 : 560
        let metrics = ConversationWorkspaceMetrics.resolve(isFullscreen: isFullscreen)
        let model = DockModel(initialSessionID: "snapshot")
        let now = Date()
        let messages = [
            ChatMessage(role: .user, text: "Can you tighten the transcript scrolling and explain what changed?", timestamp: now),
            ChatMessage(
                role: .hermes,
                text: """
                ## Scrolling changes

                The transcript now **pages automatically** as you approach either edge, and the reader's position is held while rows mount.

                - History loads one page ahead of the viewport
                - Long replies keep their styled text across remounts
                - `ConversationScrollController` shifts the clip view in the same pass

                ```swift
                scrollController.shiftVisibleTop(by: delta)
                ```

                > Rows outside the window are evicted, so memory stays bounded.
                """,
                timestamp: now,
                modelName: "claude-sonnet-5",
                responseDuration: 12.4
            ),
            ChatMessage(role: .user, text: "Great, ship it.", timestamp: now, isSteering: true, steeringStatus: "APPLIED"),
            ChatMessage(role: .hermes, text: "The request could not reach the gateway.", timestamp: now, isError: true),
        ]
        model.messages = messages
        model.composer.text = ""

        let content = VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(messages) { message in
                        ConversationMessageRow(
                            message: message,
                            isStreamingMessage: false,
                            streamingText: nil,
                            activeBotProfileID: nil,
                            botsByID: [:],
                            avatarImages: [:],
                            botRosterRevision: 0,
                            onImagePreview: { _ in },
                            metrics: metrics
                        )
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: metrics.readingWidth)
                .frame(maxWidth: .infinity)
            }
            ChatComposerView(
                model: model,
                composer: model.composer,
                speechInput: SpeechInput(),
                botMode: BotModeModel(),
                onStop: {},
                isFullscreen: isFullscreen,
                metrics: metrics
            )
        }
        .frame(width: width, height: 900)
        .background(Color.dockCanvas)

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        let name = isFullscreen ? "chat-fullscreen.png" : "chat-compact.png"
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        window.orderOut(nil)
    }
}
