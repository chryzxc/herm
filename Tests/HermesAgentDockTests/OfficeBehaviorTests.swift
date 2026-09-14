import RealityKit
import Testing
@testable import HermesAgentDock

struct OfficeBehaviorTests {
    private func agent(_ statuses: [String], step: String? = nil) -> OfficePreviewAgentPresentation {
        let tasks = statuses.enumerated().map { index, status in
            OfficePreviewTaskData(KanbanTaskSummary(id: "task-\(index)", title: "Task", status: status,
                detail: nil, priority: nil, assignee: "bot", currentStepKey: step))
        }
        return .init(id: "bot", name: "Bot", tasks: OfficePreviewResolver.ordered(tasks))
    }

    @Test func availabilityAccountsForTheWholeKanbanQueue() {
        for statuses in [[], ["done"], ["completed", "done"]] {
            #expect(agent(statuses).hasNoPendingTasks)
            #expect(agent(statuses).canWander)
            #expect(agent(statuses).activitySymbol == "diamond.fill")
        }
        for status in ["todo", "scheduled", "ready", "triage", "review", "blocked", "running", "custom"] {
            #expect(!agent(["done", status]).hasNoPendingTasks)
        }
        #expect(agent(["todo", "scheduled"]).canWander)
        for status in ["running", "blocked", "review", "ready", "triage", "custom"] {
            #expect(!agent(["todo", status]).canWander)
        }
    }

    @Test func workIconUsesTheReportedStepWithoutChangingTasks() {
        #expect(agent(["running"], step: "verification").activitySymbol == "testtube.2")
        #expect(agent(["running"], step: "research").activitySymbol == "book.fill")
        #expect(agent(["running"]).activitySymbol == "desktopcomputer")
        #expect(agent(["scheduled"]).activitySymbol == "clock.fill")
        let snapshot = agent(["scheduled", "done"])
        _ = snapshot.canWander
        _ = snapshot.availabilityLabel
        #expect(snapshot.tasks.map(\.status) == ["scheduled", "done"])
    }

    @MainActor @Test func leisureSpotsHaveRoutesBackToActualWorkstations() throws {
        var layout = OfficePreviewLayout()
        let authored = OfficeDesignSceneBuilder().build(in: Entity())
        layout.authored = authored
        for index in authored.leisureSpots.indices {
            let leisure = OfficePreviewLayout.Node(slot: 0, index: 0, isStation: true, leisureIndex: index)
            let desk = layout.node(slot: 0, location: .desk)
            for (start, end) in [(desk, leisure), (leisure, desk)] {
                let route = layout.route(from: start, to: end)
                #expect(route.first == start, "Unreachable leisure spot \(index)")
                #expect(route.last == end)
                for node in route where !node.isStation { #expect(layout.isWalkable(layout.position(node))) }
            }
        }
    }
}
