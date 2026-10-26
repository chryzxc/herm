import AppKit
import SwiftUI
import Testing

@testable import Herm

/// Opt-in native render for visual review, using the production notch view.
@MainActor
struct EdgeNotchRenderSnapshotTests {
    @Test func renderQuickReplyStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["QUICK_REPLY_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = DockThemeStore.shared
        let previousTheme = DockThemeRuntime.current
        let previousAppearance = NSApplication.shared.appearance
        defer {
            DockThemeRuntime.current = previousTheme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = previousAppearance
        }
        let model = DockModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, initialSessionID: "snapshot")
        let control = ControlCenterModel()
        control.providerQuotas = [
            ProviderQuotaSnapshot(
                provider: "codex", displayName: "Codex (Christian)", model: nil, updatedAt: .now,
                windows: [
                    ProviderQuotaWindow(
                        id: "weekly", label: "Weekly", remainingPercent: 0,
                        remainingDisplay: nil, limitDisplay: nil, resetsAt: nil, resetsDisplay: nil)
                ], safeDetail: nil)
        ]
        let session = HermesSession(
            id: "reply-snapshot", profileID: "default", title: "Audit tests and create draft PR",
            preview: "", startedAt: nil, messageCount: 2, source: "herm")
        let task = EdgeNotchTask(
            id: session.id, title: session.displayTitle, phase: .working,
            statusLabel: "Working", detail: nil, updatedAt: .now.addingTimeInterval(-1920),
            isCurrent: false, isStatusCurrent: true, session: session)
        for theme in ["clean", "island", "glass", "mono", "eInk", "warmLight"] {
            DockThemeRuntime.current = try #require(DockThemeID(rawValue: theme))
            DockThemeRuntime.revision &+= 1
            let dark = ["island", "glass", "mono"].contains(theme)
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width in [CGFloat(320), CGFloat(368)] {
                for mode in ["empty", "draft", "pending", "failed"] {
                    let state = EdgeNotchState(store: QuickDraftStore())
                    state.expanded = true
                    state.tasks = [task]
                    state.selectQuickTarget(session, task: task)
                    state.composing = true
                    state.quickDraft =
                        mode == "empty" ? "" : "Please summarize the test failures before making changes."
                    state.quickSending = mode == "pending"
                    state.quickResult =
                        mode == "failed" ? "The reply could not be sent. Your draft is saved; try again." : nil
                    model.status = .idle
                    let view = EdgeTaskPreview(
                        tasks: state.tasks, isOffline: false,
                        reply: { _ in }, quickState: state, quickModel: model, quotaControl: control,
                        openDock: {}, openTask: { _ in }
                    )
                    .frame(width: width, height: 288)
                    .background(Color.dockCanvas)
                    .dockThemedRoot()
                    .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 288)
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSApplication.shared.appearance
                    window.contentView = host
                    window.orderFrontRegardless()
                    defer { window.orderOut(nil) }
                    for _ in 0..<3 {
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try #require(rep.representation(using: .png, properties: [:])).write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent(
                            "reply-\(theme)-\(Int(width))-\(mode).png"))
                }
            }
        }
    }

    @Test func renderQuickMessageStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["QUICK_MESSAGE_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = DockThemeStore.shared
        let previousTheme = DockThemeRuntime.current
        let previousAppearance = NSApplication.shared.appearance
        defer {
            DockThemeRuntime.current = previousTheme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = previousAppearance
        }
        let root = URL(fileURLWithPath: directory).appendingPathComponent("drafts")
        defer { try? FileManager.default.removeItem(at: root) }
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let model = DockModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, initialSessionID: "snapshot")
        let control = ControlCenterModel()
        control.providerQuotas = [
            ProviderQuotaSnapshot(
                provider: "codex", displayName: "Codex", model: nil, updatedAt: .now,
                windows: [
                    ProviderQuotaWindow(
                        id: "weekly", label: "Weekly", remainingPercent: 0,
                        remainingDisplay: nil, limitDisplay: nil, resetsAt: nil, resetsDisplay: nil)
                ], safeDetail: nil)
        ]
        for theme in ["clean", "island", "glass", "mono", "storm", "warmLight"] {
            DockThemeRuntime.current = try #require(DockThemeID(rawValue: theme))
            DockThemeRuntime.revision &+= 1
            let dark = ["island", "glass", "mono", "storm"].contains(theme)
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width in [CGFloat(320), CGFloat(368), CGFloat(560)] {
                for mode in ["empty", "draft", "long", "pending", "failed", "offline"] {
                    let state = EdgeNotchState(
                        store: QuickDraftStore(directory: root.appendingPathComponent(UUID().uuidString)))
                    state.switchQuickProfile("default")
                    state.expanded = true
                    state.composing = true
                    state.quickDraft =
                        mode == "empty" ? "" : "Please summarize the test failures before making changes."
                    if mode == "long" { state.quickDraft = String(repeating: state.quickDraft + "\n", count: 8) }
                    state.quickSending = mode == "pending"
                    state.quickResult =
                        mode == "failed" ? "The message could not be sent. Your draft is saved; try again." : nil
                    model.status = mode == "offline" ? .offline : .idle
                    let height: CGFloat = EdgeNotchState.quickMessageHeight
                    let view = Group {
                        if width == 368 {
                            EdgeNotchView(state: state, controlCenter: control, quickMessageModel: model, openDock: {})
                        } else {
                            EdgeQuickMessageView(model: model, control: control, state: state, close: {}, openDock: {})
                        }
                    }
                    .frame(width: width, height: height)
                    .background(Color.dockCanvas)
                    .dockThemedRoot()
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .transaction {
                        $0.disablesAnimations = true
                        $0.animation = nil
                    }
                    let host = NSHostingView(rootView: view)
                    host.frame = CGRect(x: 0, y: 0, width: width, height: height)
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSApplication.shared.appearance
                    window.contentView = host
                    window.orderFrontRegardless()
                    defer { window.orderOut(nil) }
                    for _ in 0..<3 {
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    let text = try #require(editor(in: host))
                    let container = try #require(text.textContainer)
                    let textHeight = try #require(text.layoutManager).usedRect(for: container).height
                    let viewportHeight = try #require(text.enclosingScrollView).contentView.bounds.height
                    if mode == "draft" { #expect(textHeight <= viewportHeight + 0.5) }
                    if mode == "long" { #expect(textHeight > viewportHeight) }
                    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try #require(rep.representation(using: .png, properties: [:])).write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent(
                            "message-\(theme)-\(Int(width))-\(mode).png"))
                    state.draftStore.flush()
                }
            }
        }
    }

    @Test func renderDisplayStyles() async throws {
        guard let dir = ProcessInfo.processInfo.environment["NOTCH_SNAPSHOT_DIR"] else { return }
        let activities: [(String, EdgeNotchActivity)] = [
            ("Idle", .init()),
            ("Working", .init(status: .working)),
            ("Attention", .init(status: .needsApproval)),
            ("Completed", .init(responseCompleted: true)),
            ("Offline", .init(status: .offline)),
            ("Attention + work", .init(status: .needsApproval, runningCount: 1)),
            ("Update + work", .init(status: .working, unread: true)),
        ]
        let content = VStack(spacing: 16) {
            NotchDisplaySettings()
            Divider()
            ForEach(NotchDisplayStyle.allCases) { style in
                HStack(spacing: 12) {
                    Text(style.title).frame(width: 90, alignment: .leading)
                    ForEach(activities.indices, id: \.self) { index in
                        VStack(spacing: 8) {
                            EdgeNotchStatusIndicator(activity: activities[index].1, style: style)
                                .frame(width: 22, height: 72)
                                .background {
                                    EdgeNotchShape(side: .right).fill(Color.dockCanvas)
                                        .overlay { EdgeNotchShape(side: .right).stroke(Color.dockBorderStrong) }
                                }
                            Text(activities[index].0).font(.system(size: 11))
                        }
                        .frame(width: 90)
                    }
                }
            }
        }
        .padding(24)
        .foregroundStyle(Color.dockPrimaryText)
        .background(Color.dockCanvas)
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("display-styles.png"))
    }

    @Test func renderTaskSources() async throws {
        guard let dir = ProcessInfo.processInfo.environment["NOTCH_SNAPSHOT_DIR"] else { return }
        let state = EdgeNotchState()
        state.expanded = true
        state.tasks = [
            EdgeNotchTask(
                id: "session", title: "Improve the conversation workspace", phase: .working,
                statusLabel: "Working", detail: "Running swift test", updatedAt: nil,
                isCurrent: true, isStatusCurrent: true, session: nil),
            EdgeNotchTask(
                id: "finished", title: "Review the latest changes", phase: .finished,
                statusLabel: "New response", detail: "Review complete. The changes are ready to inspect.",
                updatedAt: .now.addingTimeInterval(-120),
                isCurrent: false, isStatusCurrent: true,
                session: HermesSession(
                    id: "finished", title: "Review the latest changes", preview: "", startedAt: nil, messageCount: 2,
                    source: "herm")),
        ]
        var kanban = EdgeKanbanActivity()
        let running = KanbanTaskSummary(
            id: "card", boardSlug: "Herm", title: "Include Kanban activity in the notch preview",
            status: "running", detail: nil, priority: nil, assignee: "Builder")
        let blocked = KanbanTaskSummary(
            id: "blocked", boardSlug: "Herm", title: "Verify the release build",
            status: "blocked", detail: nil, priority: nil, assignee: "Reviewer")
        let review = KanbanTaskSummary(
            id: "review", boardSlug: "Herm", title: "Tighten notch spacing",
            status: "review", detail: nil, priority: nil, assignee: "Builder")
        _ = kanban.ingest([running, blocked])
        _ = kanban.ingest([running, review, blocked])
        state.tasks = EdgeNotchTask.merged(state.tasks + kanban.rows(isCurrent: true))
        let control = ControlCenterModel()
        let model = DockModel(initialSessionID: "snapshot-chat")
        model.currentSessionTitle = "Herm notch improvements"
        state.bots = [
            BotSummary(
                id: "Builder", name: "Builder", title: nil, description: nil,
                model: nil, isActive: false, chat: nil, avatarURL: nil, preview: nil,
                lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false)
        ]
        let tasks = state.tasks
        for name in [
            "tasks", "tasks-top", "tasks-top-empty", "tasks-many", "tasks-empty", "kanban-unavailable",
            "quick-message", "quick-reply",
        ] {
            state.side = name.contains("top") ? .top : .right
            state.tasks = tasks
            if name == "tasks-many" {
                state.tasks = EdgeNotchTask.merged(
                    tasks
                        + (0..<200).map { index in
                            EdgeNotchTask(
                                id: "attention-\(index)", title: "Review background task \(index)", phase: .attention,
                                statusLabel: "Needs your attention", detail: "Review the result before continuing.",
                                updatedAt: .now.addingTimeInterval(Double(-index * 60)), isCurrent: false,
                                isStatusCurrent: true, session: nil)
                        })
            }
            state.selectQuickTarget(nil)
            if name.contains("empty") || name.contains("unavailable") { state.tasks = [] }
            state.kanbanUnavailable = name.contains("unavailable")
            state.composing = name == "quick-message" || name == "quick-reply"
            if name == "quick-reply", let task = tasks.first(where: { $0.id == "finished" }) {
                state.selectQuickTarget(task.session, task: task)
            }
            state.quickDraft = "Review the latest changes and summarize anything that needs attention."
            let size = state.panelSize
            let content = EdgeNotchView(state: state, controlCenter: control, quickMessageModel: model, openDock: {})
                .frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
