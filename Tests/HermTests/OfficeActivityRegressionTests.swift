import Foundation
import RealityKit
import Testing
@testable import Herm

@MainActor
struct OfficeActivityRegressionTests {
    @Test func everyIdleBotHasADistinctReachableHomeIncludingOverflow() {
        var layout = OfficePreviewLayout()
        layout.reconcile(ids: (0..<64).map { "bot-\($0)" }, reserveMainOffice: true)
        layout.authored = OfficeDesignSceneBuilder().build(in: Entity(), capacity: layout.capacity)
        let homes = layout.slots.values.map { layout.station(slot: $0, location: .desk) }
        #expect(Set(homes).count == 64)
        for slot in layout.slots.values {
            let home = layout.node(slot: slot, location: .desk)
            let position = layout.position(home)
            #expect(position.x > layout.minX && position.x < layout.maxX)
            #expect(position.z > layout.back && position.z < layout.front)
            let destination = OfficePreviewLayout.Node(slot: slot, index: 0, isStation: true, leisureIndex: 5)
            #expect(!layout.route(from: home, to: destination).isEmpty, "Home \(slot) cannot reach the central hall")
        }
    }

    @Test func everyLeisureActivityCanBeReachedAndExited() {
        var layout = OfficePreviewLayout()
        layout.authored = OfficeDesignSceneBuilder().build(in: Entity(), capacity: 24)
        let home = layout.node(slot: 0, location: .desk)
        for index in layout.authored!.leisureSpots.indices {
            let activity = OfficePreviewLayout.Node(slot: 0, index: 0, isStation: true, leisureIndex: index)
            #expect(!layout.route(from: home, to: activity).isEmpty, "Cannot enter leisure spot \(index)")
            #expect(!layout.route(from: activity, to: home).isEmpty, "Cannot leave leisure spot \(index)")
        }
    }

    @Test func exteriorModelsRegisterObstaclesAndLeaveTheEntranceOpen() {
        let root = Entity()
        var layout = OfficePreviewLayout()
        layout.authored = OfficeDesignSceneBuilder().build(in: root, capacity: 24)
        for name in ["courtyard-pergola", "campus-bench", "courtyard-fountain", "parked-bicycle",
                     "campus-planting-bed", "site-sidewalk-floor", "entrance-promenade-floor"] {
            #expect(root.findEntity(named: name) != nil)
        }
        for name in ["campus-bench", "courtyard-fountain", "parked-bicycle", "campus-planting-bed", "pergola-post"] {
            #expect(layout.authored!.obstacles.contains { $0.name == name })
        }
        #expect(!layout.isWalkable([10, 0, 20]))
        #expect(layout.isWalkable([0, 0, 25]))
        #expect(layout.authored!.leisureSpots.filter(\.isOutdoor).count == 5)
        for spot in layout.authored!.leisureSpots where spot.isOutdoor {
            #expect(spot.station.position.z >= 17)
        }
    }

    @Test func interactionsPairOnlyColleaguesInTheSameReportedBoardAndPhase() {
        func agent(_ id: String, board: String?, status: String) -> OfficePreviewAgentPresentation {
            .init(id: id, name: id, tasks: [.init(KanbanTaskSummary(id: id, boardSlug: board,
                title: id, status: status, detail: nil, priority: nil, assignee: id))])
        }
        let agents = [agent("a", board: "app", status: "review"), agent("b", board: "app", status: "review"),
                      agent("c", board: "other", status: "review"), agent("d", board: "app", status: "running"),
                      agent("e", board: nil, status: "review"), agent("f", board: nil, status: "review"),
                      agent("g", board: "app", status: "ready"), agent("h", board: "app", status: "triage")]
        let plan = OfficePreviewInteractionPlan.make(agents: agents)
        #expect(plan.partners == ["a": "b", "b": "a", "g": "h", "h": "g"])
        #expect(plan.stations["a"] != plan.stations["b"])
        #expect(plan.stations["d"] == nil)
        #expect(OfficePreviewInteractionPlan.make(agents: agents.reversed()).partners == plan.partners)
        #expect(OfficePreviewInteractionPlan.make(agents: agents.reversed()).stations == plan.stations)
    }

    @Test func defaultProfileRemainsVisibleWhenNoMainSessionRepresentsIt() {
        let bot = BotSummary(id: "nexus", name: "Nexus", title: nil, description: nil, model: nil,
            isActive: false, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
            isHidden: false, hasAvatar: false, isDefault: true)
        let simulation = OfficePreviewSimulation(bots: [bot])
        #expect(simulation.agents.map(\.id) == ["nexus"])
        simulation.update(bots: [bot], tasks: [], sessions: [
            .init(id: "chat", title: "Chat", state: "idle", isCurrent: true, activities: [])
        ])
        #expect(simulation.agents.map(\.id) == ["main-session:chat"])
    }
}
