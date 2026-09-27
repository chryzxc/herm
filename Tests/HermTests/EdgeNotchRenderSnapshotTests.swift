import AppKit
import SwiftUI
import Testing
@testable import Herm

/// Opt-in native render for visual review, using the production notch view.
@MainActor
struct EdgeNotchRenderSnapshotTests {
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
        _ = kanban.ingest([running, blocked])
        var review = running
        review.status = "review"
        _ = kanban.ingest([review, blocked])
        state.tasks += kanban.rows(isCurrent: true)
        let control = ControlCenterModel()
        let model = DockModel(initialSessionID: "snapshot-chat")
        model.currentSessionTitle = "Herm notch improvements"
        state.bots = [BotSummary(id: "Builder", name: "Builder", title: nil, description: nil,
            model: nil, isActive: false, chat: nil, avatarURL: nil, preview: nil,
            lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false)]
        let tasks = state.tasks
        for name in ["activity", "kanban", "activity-empty", "kanban-unavailable", "quick-message", "quick-reply"] {
            state.tasks = tasks
            state.selectQuickTarget(nil)
            state.selectTaskSource(name.hasPrefix("kanban") ? .kanban : .activity)
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
