import Testing
@testable import HermesAgentDock

struct OfficeMainSessionTests {
    @MainActor @Test func simultaneousConversationsHaveIndependentActivityAndNoBotTasks() {
        let simulation = OfficePreviewSimulation(sessions: [
            .init(id: "one", title: "Code", state: "working", isCurrent: true, activities: []),
            .init(id: "two", title: "Review", state: "needs_approval", isCurrent: false, activities: []),
            .init(id: "old", title: "Old", state: "idle", isCurrent: false, activities: [])
        ])
        #expect(simulation.agents.count == 2)
        #expect(simulation.agents.map(\.name) == ["Nexus · Code", "Nexus · Review"])
        #expect(simulation.agents[0].phase == .implementing)
        #expect(simulation.agents[1].phase == .waiting)
        #expect(simulation.agents.allSatisfy { $0.location == .desk && !$0.hasNoPendingTasks && $0.tasks.isEmpty })
        #expect(simulation.board.allSatisfy { $0.tasks.isEmpty })
        let id = simulation.agents[0].id
        simulation.update(bots: [], tasks: [], sessions: [
            .init(id: "one", title: "Renamed", state: "idle", isCurrent: true, activities: [])
        ])
        #expect(simulation.agents[0].id == id)
        #expect(simulation.agents[0].canWander)
        #expect(!simulation.agents[0].hasNoPendingTasks)
    }

    @MainActor @Test func defaultNexusProfileIsNotDuplicatedAsAWorker() {
        let nexus = BotSummary(id: "nexus", name: "Nexus", title: "Orchestrator", description: nil, model: nil,
            isActive: true, chat: nil, avatarURL: nil, preview: nil, lastActive: nil, isHidden: false,
            hasAvatar: false, isDefault: true)
        let simulation = OfficePreviewSimulation(bots: [nexus], sessions: [
            .init(id: "chat", title: "Feature", state: "working", isCurrent: true, activities: [])
        ])
        #expect(simulation.agents.count == 1)
        #expect(simulation.agents[0].name == "Nexus · Feature")
        #expect(simulation.agents[0].mainSession?.id == "chat")
    }

    @MainActor @Test func unknownStateDoesNotPretendToWorkOrWander() {
        let simulation = OfficePreviewSimulation(sessions: [
            .init(id: "one", title: "Chat", state: "offline", isCurrent: true, activities: [])
        ])
        #expect(simulation.agents[0].activityLane == .unknown)
        #expect(!simulation.agents[0].canWander)
        #expect(simulation.agents[0].activitySymbol == "questionmark")
    }
}
