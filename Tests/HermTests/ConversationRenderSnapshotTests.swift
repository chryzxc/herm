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
        let savedTheme = DockThemeRuntime.current, savedRevision = DockThemeRuntime.revision
        defer { DockThemeRuntime.current = savedTheme; DockThemeRuntime.revision = savedRevision }
        if let raw = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_THEME"], let theme = DockThemeID(rawValue: raw) {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
        }
        let isFullscreen = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_FULLSCREEN"] == "1"
        let showsSidebar = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_SIDEBAR"] == "1"
        let width: CGFloat = showsSidebar ? 1200 : isFullscreen ? 980 : 420
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

        let botMode = BotModeModel()
        let speech = SpeechInput()
        let composer = ChatComposerView(model: model, composer: model.composer, speechInput: speech,
                                        botMode: botMode, onStop: {}, isFullscreen: isFullscreen, metrics: metrics)
        let navigation = MissionControlNavigationState()
        navigation.hasRequestedSessionIndex = true
        let suiteName = "SkinSnapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let themeStore = DockThemeStore(defaults: defaults)
        themeStore.selectedThemeID = DockThemeRuntime.current
        let content = HStack(spacing: 0) {
            if showsSidebar {
                MissionControlQueue(
                    model: model, botMode: botMode,
                    workspaceStore: WorkspaceStore(fileURL: URL(fileURLWithPath: dir).appendingPathComponent("empty-workspace.json")),
                    controlCenter: ControlCenterModel(), agentUpdateService: HermesUpdateService(),
                    navigationState: navigation, dockThemeStore: themeStore,
                    sessionPendingDeletion: .constant(nil), activeSessionID: nil, activeGlobalTab: nil,
                    isArtifactsActive: false, isBotsActive: false, isPullRequestsActive: false, isIssuesActive: false,
                    onNewConversation: {}, onSelectSession: { _ in }, onSelectTask: { _ in }, onOpenGlobal: { _ in },
                    onOpenArtifacts: {}, onOpenBots: {}, onOpenPullRequests: {}, onOpenIssues: {},
                    showsFullscreenToggle: false, isFullscreen: true, onFullscreenToggle: {}, onSelectProfile: { _ in }
                )
                .frame(width: 250)
            }
            VStack(spacing: 0) {
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
            composer
            }
        }
        .frame(width: width, height: 900)
        .background(Color.dockCanvas)
        .dockThemedRoot()

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
        let name = showsSidebar ? "desktop-sidebar.png" : isFullscreen ? "chat-fullscreen.png" : "chat-compact.png"
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        window.orderOut(nil)
    }
}
