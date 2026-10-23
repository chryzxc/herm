import AppKit
import SwiftUI
import Testing

@testable import Herm

struct WorkspaceActivitySidebarTests {
    @MainActor
    @Test func kanbanBoardScrollsLanesHorizontallyAndCardsPerLane() throws {
        let capabilities = [
            "kanban.taskDetails", "kanban.complete", "kanban.block", "kanban.archive", "kanban.unblock",
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
            store: WorkspaceStore(fileURL: URL(fileURLWithPath: "/tmp/herm-kanban-tests.json")),
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
        // ARC owns the window; the default release-on-close over-releases it
        // and crashes the test runner on the next autorelease-pool drain.
        window.isReleasedWhenClosed = false
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
        let boardScrollView = try #require(
            scrollViews.first {
                $0.hasHorizontalScroller && !$0.hasVerticalScroller
            })
        #expect(boardScrollView.documentView!.frame.width > boardScrollView.contentView.bounds.width)

        // A lane with more cards than fit scrolls vertically on its own.
        let laneScrollView = try #require(
            scrollViews.first {
                $0.hasVerticalScroller && !$0.hasHorizontalScroller
                    && $0.documentView != nil
                    && $0.documentView!.frame.height > $0.contentView.bounds.height
            })
        #expect(laneScrollView.frame.height <= hostingView.frame.height)
        window.close()
    }

    @MainActor
    @Test func pluginsPageBuildsAndRendersInWorkspace() throws {
        let sidebar = WorkspaceActivitySidebar(
            model: DockModel(), botMode: BotModeModel(),
            store: WorkspaceStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("herm-plugins-\(UUID().uuidString).json")),
            control: ControlCenterModel(), workflow: DeveloperWorkflowModel(),
            initialMode: .capabilities, agentUpdateService: HermesUpdateService()
        )
        let pages = [
            AnyView(sidebar),
            AnyView(
                WorkflowIntegrationView(
                    destination: IntegrationDestination(profileID: nil),
                    client: sidebar.model.controlRPCClient, pageSection: .constant(.plugins)
                )),
        ]
        for page in pages {
            let host = NSHostingView(rootView: page)
            host.frame = NSRect(x: 0, y: 0, width: 1000, height: 650)
            let window = NSWindow(
                contentRect: host.frame, styleMask: .borderless,
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.display()
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        }
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
