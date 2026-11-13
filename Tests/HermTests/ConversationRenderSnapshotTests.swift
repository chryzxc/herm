import AppKit
import SwiftUI
import Testing

@testable import Herm

/// Renders the conversation surface to PNG for visual review. Opt-in: set
/// `CHAT_SNAPSHOT_DIR` to a writable directory.
@MainActor
struct ConversationRenderSnapshotTests {
    @Test func renderDeliveryMetadata() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let oldTheme = DockThemeRuntime.current
        defer {
            DockThemeRuntime.current = oldTheme
            DockThemeRuntime.revision &+= 1
        }
        let states: [MessageDeliveryStatus?] = [.sending, .accepted, .queued, nil, .unconfirmed]
        var count = 0
        for theme: DockThemeID in [.warmLight, .island, .glass, .mono, .notebook] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            let sizes: [CGFloat] = [420, 980]
            let variants = sizes.flatMap { width in
                [DockWorkspaceScale.defaultTextSize, DockWorkspaceScale.compactTextSize].map { (width, $0) }
            }
            for (width, scale) in variants {
                let view = VStack(alignment: .trailing, spacing: 4) {
                    ForEach(states.indices, id: \.self) { index in
                        ConversationMessageRow(
                            message: ChatMessage(
                                role: .user,
                                text: String(repeating: "A longer message with delivery metadata. ", count: 3)),
                            isStreamingMessage: false, streamingText: nil, activeBotProfileID: nil,
                            botsByID: [:], avatarImages: [:], botRosterRevision: 0, onImagePreview: { _ in },
                            delivery: states[index], deliveryCheckAvailable: true)
                    }
                    ConversationMessageRow(
                        message: ChatMessage(role: .user, text: "Checking status"),
                        isStreamingMessage: false, streamingText: nil, activeBotProfileID: nil,
                        botsByID: [:], avatarImages: [:], botRosterRevision: 0, onImagePreview: { _ in },
                        delivery: .unconfirmed, deliveryChecking: true,
                        deliveryCheckNote: String(repeating: "Status unavailable. ", count: 5),
                        deliveryCheckAvailable: true)
                }
                .frame(width: width, height: 1000, alignment: .top)
                .background(Color.dockCanvas)
                .dockThemedRoot()
                .environment(\.dockWorkspaceScale, CGFloat(scale))

                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(
                    to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("delivery-\(theme.rawValue)-\(Int(width))-\(scale).png"))
                window.orderOut(nil)
                count += 1
            }
        }
        print("Emitted \(count) delivery images")
        #expect(count == 20)
    }

    @Test func hoveredDeliveryTimestampHasVisibleGap() async throws {
        let app = NSApplication.shared
        let old = app.value(forKey: "accessibilityEnhancedUserInterface")
        let oldTheme = DockThemeRuntime.current
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer {
            app.setValue(old, forKey: "accessibilityEnhancedUserInterface")
            DockThemeRuntime.current = oldTheme
            DockThemeRuntime.revision &+= 1
        }
        func elements(_ element: AnyObject) -> [AnyObject] {
            [element] + (element.accessibilityChildren?() ?? []).flatMap { elements($0 as AnyObject) }
        }
        let themes: [DockThemeID] = [.warmLight, .notebook]
        let variants = themes.flatMap { theme in
            [DockWorkspaceScale.defaultTextSize, DockWorkspaceScale.compactTextSize].flatMap { scale in
                [true, false].map { (theme, scale, $0) }
            }
        }
        var timestampPositions: [String: CGFloat] = [:]
        for (theme, scale, hasStatus) in variants {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            let hover = ConversationRowHoverPresentation()
            hover.isHovering = true
            let message = ChatMessage(
                role: .user, text: "Hover metadata", timestamp: Date(timeIntervalSince1970: 1_700_000_000))
            let view = ConversationMessageRow(
                message: message, isStreamingMessage: false, streamingText: nil, activeBotProfileID: nil,
                botsByID: [:], avatarImages: [:], botRosterRevision: 0, onImagePreview: { _ in },
                delivery: hasStatus ? .queued : nil, hoverPresentation: hover
            )
            .frame(width: 980, height: 200)
            .environment(\.dockWorkspaceScale, CGFloat(scale))
            .background(Color.dockCanvas)
            .dockThemedRoot()
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 980, height: 200)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            let labels = elements(host).filter { $0.accessibilityRole?() == .staticText }
            #expect(labels.count == (hasStatus ? 2 : 1))
            let timeFrame = try #require(labels.last?.accessibilityFrame?())
            let key = "\(theme.rawValue)-\(scale)"
            if hasStatus {
                let statusFrame = try #require(labels.first?.accessibilityFrame?())
                #expect(timeFrame.minX - statusFrame.maxX >= 3)
                timestampPositions[key] = timeFrame.minX
            } else {
                #expect(timeFrame.minX == timestampPositions[key])
            }
            if let directory = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(
                    to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("hover-\(key)-\(hasStatus).png"))
            }
        }
    }

    @Test func deliveryRecoveryAccessibility() async throws {
        let app = NSApplication.shared
        let old = app.value(forKey: "accessibilityEnhancedUserInterface")
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { app.setValue(old, forKey: "accessibilityEnhancedUserInterface") }
        var activations = 0
        let message = ChatMessage(role: .user, text: String(repeating: "A longer message. ", count: 5))
        let view = VStack {
            ConversationMessageRow(
                message: message, isStreamingMessage: false, streamingText: nil, activeBotProfileID: nil,
                botsByID: [:], avatarImages: [:], botRosterRevision: 0, onImagePreview: { _ in },
                delivery: .unconfirmed, deliveryCheckNote: String(repeating: "Status unavailable. ", count: 5),
                deliveryCheckAvailable: true, onCheckDelivery: { activations += 1 })
            ConversationMessageRow(
                message: message, isStreamingMessage: false, streamingText: nil, activeBotProfileID: nil,
                botsByID: [:], avatarImages: [:], botRosterRevision: 0, onImagePreview: { _ in },
                delivery: .unconfirmed, deliveryChecking: true, deliveryCheckAvailable: true,
                onCheckDelivery: { activations += 1 })
        }.frame(width: 420, height: 400).dockThemedRoot()
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func elements(_ element: AnyObject) -> [AnyObject] {
            [element] + (element.accessibilityChildren?() ?? []).flatMap { elements($0 as AnyObject) }
        }
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        let buttons = elements(host).filter { $0.accessibilityRole?() == .button }
        let check = try #require(buttons.first { ($0.accessibilityLabel?() ?? "").contains("Check status") })
        #expect(check.isAccessibilityEnabled?() == true)
        #expect(check.accessibilityPerformPress?() == true)
        #expect(activations == 1)
        let checking = try #require(buttons.first { ($0.accessibilityLabel?() ?? "").contains("Checking") })
        #expect(checking.isAccessibilityEnabled?() == false)
        #expect(activations == 1)
        let frame = try #require(check.accessibilityFrame?())
        let bounds = window.convertToScreen(window.contentRect(forFrameRect: window.frame))
        #expect(bounds.contains(frame))
    }

    @Test func renderMentionActivity() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_BOT_ACTIVITY_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = DockThemeStore.shared
        let oldTheme = DockThemeRuntime.current
        defer {
            DockThemeRuntime.current = oldTheme
            DockThemeRuntime.revision &+= 1
        }
        let bot = BotSummary(
            id: "default", name: "Nexus", title: nil, description: nil, model: nil, isActive: true, chat: nil,
            avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false, isDefault: true)
        for theme: DockThemeID in [.warmLight, .island, .glass, .mono] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            let view = VStack(alignment: .leading, spacing: 12) {
                BotCrewRow(
                    from: bot, partners: [], since: Date().addingTimeInterval(-45), repliesToUser: true,
                    steps: [bot.id: "Read Sources/Herm/Conversation/ConversationTranscriptView.swift"])
                BotCrewRow(
                    from: bot, partners: [], since: Date().addingTimeInterval(-80), repliesToUser: true,
                    steps: [bot.id: "Waiting for approval"])
            }
            .padding(16)
            .frame(width: 352, height: 360, alignment: .topLeading)
            .background(Color.dockCanvas)
            .dockThemedRoot()
            .environment(\.colorScheme, theme == .warmLight ? .light : .dark)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 352, height: 360)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: theme == .warmLight ? .aqua : .darkAqua)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("mention-\(theme.rawValue).png"))
        }
    }

    @Test func renderConversation() async throws {
        guard let dir = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_DIR"] else { return }
        let savedTheme = DockThemeRuntime.current
        let savedRevision = DockThemeRuntime.revision
        defer {
            DockThemeRuntime.current = savedTheme
            DockThemeRuntime.revision = savedRevision
        }
        if let raw = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_THEME"], let theme = DockThemeID(rawValue: raw)
        {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
        }
        let isFullscreen = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_FULLSCREEN"] == "1"
        let showsSidebar = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_SIDEBAR"] == "1"
        let isEmpty = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_EMPTY"] == "1"
        let width: CGFloat = showsSidebar ? 1200 : isFullscreen ? 980 : 420
        let metrics = ConversationWorkspaceMetrics.resolve(isFullscreen: isFullscreen)
        let model = DockModel(initialSessionID: "snapshot")
        let now = Date()
        let messages = [
            ChatMessage(
                role: .user, text: "Can you tighten the transcript scrolling and explain what changed?", timestamp: now),
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
            ChatMessage(
                role: .user, text: "Great, ship it.", timestamp: now, isSteering: true, steeringStatus: "APPLIED"),
            ChatMessage(role: .hermes, text: "The request could not reach the gateway.", timestamp: now, isError: true),
        ]
        model.messages = isEmpty ? [] : messages
        model.composer.text = ""

        let botMode = BotModeModel()
        let speech = SpeechInput()
        let composer = ChatComposerView(
            model: model, composer: model.composer, speechInput: speech,
            botMode: botMode, onStop: {}, isFullscreen: isFullscreen, metrics: metrics)
        let navigation = SessionNavigationState()
        navigation.hasRequestedSessionIndex = true
        let suiteName = "SkinSnapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let themeStore = DockThemeStore(defaults: defaults)
        themeStore.selectedThemeID = DockThemeRuntime.current
        let content = HStack(spacing: 0) {
            if showsSidebar {
                SessionNavQueue(
                    model: model, botMode: botMode,
                    workspaceStore: WorkspaceStore(
                        fileURL: URL(fileURLWithPath: dir).appendingPathComponent("empty-workspace.json")),
                    controlCenter: ControlCenterModel(), agentUpdateService: HermesUpdateService(),
                    navigationState: navigation, dockThemeStore: themeStore,
                    sessionPendingDeletion: .constant(nil), activeSessionID: nil, activeGlobalTab: nil,
                    isArtifactsActive: false, isBotsActive: false, isPullRequestsActive: false, isIssuesActive: false,
                    onNewConversation: {}, onSelectSession: { _ in }, onSelectTask: { _ in }, onOpenGlobal: { _ in },
                    onOpenArtifacts: {}, onOpenBots: {}, onOpenBotChat: { _, _ in },
                    onOpenPullRequests: {}, onOpenIssues: {},
                    showsFullscreenToggle: false, isFullscreen: true, onFullscreenToggle: {}, onSelectProfile: { _ in }
                )
                .frame(width: 250)
            }
            ConversationComposerLayout(showsWelcome: isEmpty, hermFaceID: nil) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.messages) { message in
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
            } composer: {
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
