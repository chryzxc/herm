import AppKit
import SwiftUI
import Testing
@testable import Herm

/// Opt-in native render for visual review, using the production notch view.
@MainActor
struct EdgeNotchRenderSnapshotTests {
    @Test func renderDisplayStyles() async throws {
        guard let dir = ProcessInfo.processInfo.environment["NOTCH_SNAPSHOT_DIR"] else { return }
        let activities: [(String, EdgeNotchActivity)] = [
            ("Idle", .init()),
            ("Working", .init(status: .working)),
            ("Attention", .init(status: .needsApproval)),
            ("Completed", .init(responseCompleted: true)),
            ("Offline", .init(status: .offline)),
            ("Attention + work", .init(status: .needsApproval, runningCount: 1)),
            ("Update + work", .init(status: .working, unread: true))
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
            EdgeNotchTask(id: "session", title: "Improve the conversation workspace", phase: .working,
                statusLabel: "Working", detail: "Running swift test", updatedAt: nil,
                isCurrent: true, isStatusCurrent: true, session: nil),
            EdgeNotchTask(id: "finished", title: "Review the latest changes", phase: .finished,
                statusLabel: "New response", detail: "Review complete. The changes are ready to inspect.", updatedAt: .now.addingTimeInterval(-120),
                isCurrent: false, isStatusCurrent: true,
                session: HermesSession(id: "finished", title: "Review the latest changes", preview: "", startedAt: nil, messageCount: 2, source: "herm"))
        ]
        var kanban = EdgeKanbanActivity()
        let running = KanbanTaskSummary(id: "card", boardSlug: "Herm", title: "Include Kanban activity in the notch preview",
            status: "running", detail: nil, priority: nil, assignee: "Builder")
        let blocked = KanbanTaskSummary(id: "blocked", boardSlug: "Herm", title: "Verify the release build",
            status: "blocked", detail: nil, priority: nil, assignee: "Reviewer")
        let review = KanbanTaskSummary(id: "review", boardSlug: "Herm", title: "Tighten notch spacing",
            status: "review", detail: nil, priority: nil, assignee: "Builder")
        _ = kanban.ingest([running, blocked])
        _ = kanban.ingest([running, review, blocked])
        state.tasks = EdgeNotchTask.merged(state.tasks + kanban.rows(isCurrent: true))
        let control = ControlCenterModel()
        let model = DockModel(initialSessionID: "snapshot-chat")
        model.currentSessionTitle = "Herm notch improvements"
        state.bots = [BotSummary(id: "Builder", name: "Builder", title: nil, description: nil,
            model: nil, isActive: false, chat: nil, avatarURL: nil, preview: nil,
            lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false)]
        let tasks = state.tasks
        for name in ["tasks", "tasks-many", "tasks-empty", "kanban-unavailable", "quick-message", "quick-reply"] {
            state.tasks = tasks
            if name == "tasks-many" {
                state.tasks = EdgeNotchTask.merged(tasks + (0..<200).map { index in
                    EdgeNotchTask(id: "attention-\(index)", title: "Review background task \(index)", phase: .attention,
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
            let content = EdgeNotchView(state: state, controlCenter: control, quickMessageModel: model, openDock: {})
                .frame(width: 368, height: 360)
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 368, height: 360)
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
