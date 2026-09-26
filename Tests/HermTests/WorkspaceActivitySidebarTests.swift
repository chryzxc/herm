import AppKit
import SwiftUI
import Testing
@testable import Herm

struct WorkspaceActivitySidebarTests {
    @MainActor
    @Test func kanbanBoardScrollsLanesHorizontallyAndCardsPerLane() throws {
        let capabilities = [
            "kanban.taskDetails", "kanban.complete", "kanban.block", "kanban.archive", "kanban.unblock"
        ].map {
            CapabilityState(id: $0, title: $0, detail: "test", isAvailable: true, recovery: nil)
        }
        let control = ControlCenterModel(capabilities: capabilities)
        let tasks = (0..<24).map { index in
            KanbanTaskSummary(
                id: "task-\(index)",
                title: "Trailing card \(index)",
                status: index == 23 ? "done" : "running",
                detail: "Representative card content that must remain reachable.",
                priority: "1",
                assignee: "forge"
            )
        }
        control.setKanbanTasksForTesting(tasks)
        let sidebar = WorkspaceActivitySidebar(
            model: DockModel(),
            botMode: BotModeModel(),
            store: WorkspaceStore(fileURL: URL(fileURLWithPath: "/tmp/hermes-agent-dock-kanban-tests.json")),
            control: control,
            workflow: DeveloperWorkflowModel(),
            initialMode: .kanban,
            agentUpdateService: HermesUpdateService()
        )

        let hostingView = NSHostingView(rootView: sidebar)
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 520)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.display()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        // Opening the tab starts a refresh that clears the board without a
        // Hermes runtime; seed again once that has settled.
        control.setKanbanTasksForTesting(tasks)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        hostingView.layoutSubtreeIfNeeded()

        let scrollViews = descendants(of: hostingView).compactMap { $0 as? NSScrollView }
        // The board scrolls horizontally to reach trailing lanes.
        let boardScrollView = try #require(scrollViews.first {
            $0.hasHorizontalScroller && !$0.hasVerticalScroller
        })
        #expect(boardScrollView.documentView!.frame.width > boardScrollView.contentView.bounds.width)

        // A lane with more cards than fit scrolls vertically on its own.
        let laneScrollView = try #require(scrollViews.first {
            $0.hasVerticalScroller && !$0.hasHorizontalScroller
                && $0.documentView != nil
                && $0.documentView!.frame.height > $0.contentView.bounds.height
        })
        #expect(laneScrollView.frame.height <= hostingView.frame.height)
        window.close()
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
