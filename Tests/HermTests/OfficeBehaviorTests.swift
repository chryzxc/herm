import RealityKit
import simd
import Testing
@testable import Herm

struct OfficeBehaviorTests {
    @Test func personalOfficeRemainsExclusiveAcrossMainSessionChanges() {
        var layout = OfficePreviewLayout()
        let bots = (0..<24).map { "bot-\($0)" }
        layout.reconcile(ids: bots, reserveMainOffice: true)
        #expect(!layout.slots.values.contains(22))
        layout.reconcile(ids: bots + ["main-a", "main-b"], mainAgentID: "main-a", reserveMainOffice: true)
        #expect(layout.slots["main-a"] == 22)
        let botSlots = bots.map { layout.slots[$0] }
        layout.reconcile(ids: bots + ["main-a", "main-b"], mainAgentID: "main-b", reserveMainOffice: true)
        #expect(layout.slots["main-b"] == 22)
        #expect(layout.slots["main-a"] != 22)
        #expect(botSlots == bots.map { layout.slots[$0] })
        #expect(Set(layout.slots.values).count == layout.slots.count)
        layout.reconcile(ids: bots, reserveMainOffice: true)
        #expect(!layout.slots.values.contains(22))
    }

    @Test func mainOfficeReservationDoesNotSkipSharedDesks() {
        var layout = OfficePreviewLayout()
        layout.reconcile(ids: ["main"], mainAgentID: "main", reserveMainOffice: true)
        layout.reconcile(ids: ["main", "bot"], mainAgentID: "main", reserveMainOffice: true)
        #expect(layout.slots["bot"] == 0)
    }

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
            #expect(agent(statuses).activitySymbol == .diamond)
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
        #expect(agent(["running"], step: "verification").activitySymbol == .testTube)
        #expect(agent(["running"], step: "research").activitySymbol == .books)
        #expect(agent(["running"]).activitySymbol == .desktop)
        #expect(agent(["scheduled"]).activitySymbol == .clock)
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

    @MainActor @Test func indoorLeisureSpotsAndSmallPatioHaveReachableCapacity() throws {
        let root = Entity()
        let authored = OfficeDesignSceneBuilder().build(in: root)
        #expect(Set(authored.leisureSpots.map(\.action)) == [.coffee, .reading, .strolling, .socializing, .charging, .tinkering, .browsing, .arcade])
        #expect(authored.stations[.lounge]?.count == 2)
        var layout = OfficePreviewLayout()
        layout.authored = authored
        let desk = layout.node(slot: 0, location: .desk)
        for index in authored.leisureSpots.indices {
            let activity = OfficePreviewLayout.Node(slot: 0, index: 0, isStation: true, leisureIndex: index)
            #expect(!layout.route(from: desk, to: activity).isEmpty)
        }
    }

    @MainActor @Test func idleActivitiesCoverTheWingsAndChatSpotsComeInFacingPairs() throws {
        let authored = OfficeDesignSceneBuilder().build(in: Entity())
        let spots = authored.leisureSpots
        // Maintenance bays, workbenches and shelves give idle bots somewhere
        // to be in every wing, not only the café and hall.
        #expect(spots.filter { $0.action == .charging }.count == 4)
        #expect(spots.filter { $0.action == .tinkering }.count >= 3)
        #expect(spots.filter { $0.action == .browsing }.count >= 3)
        #expect(spots.contains { !$0.isOutdoor && $0.station.position.x < -8 })
        #expect(spots.contains { !$0.isOutdoor && $0.station.position.x > 8 })
        var pairs = 0
        var index = 0
        while index + 1 < spots.count {
            let a = spots[index], b = spots[index + 1]
            if a.action == .socializing, b.action == .socializing {
                #expect(simd_distance(a.station.position, b.station.position) < 2)
                // Each partner faces the other.
                let toward = b.station.position - a.station.position
                #expect(abs(sin(a.station.yaw) * toward.x + cos(a.station.yaw) * toward.z) > 0.9)
                pairs += 1
                index += 2
            } else { index += 1 }
        }
        #expect(pairs >= 4)
    }

    @MainActor @Test func smoothedRoutesKeepEndpointsAndStayClear() throws {
        var layout = OfficePreviewLayout()
        layout.authored = OfficeDesignSceneBuilder().build(in: Entity())
        let desk = layout.node(slot: 0, location: .desk)
        for index in layout.authored!.leisureSpots.indices {
            let leisure = OfficePreviewLayout.Node(slot: 0, index: 0, isStation: true, leisureIndex: index)
            let route = layout.route(from: desk, to: leisure)
            let smooth = layout.smoothed(route, from: layout.position(desk))
            #expect(smooth.first == route.first)
            #expect(smooth.last == route.last)
            #expect(smooth.count <= route.count)
            // Every shortcut the smoother takes between grid nodes is walkable.
            for (a, b) in zip(smooth, smooth.dropFirst()) {
                guard let from = route.firstIndex(of: a), let to = route.firstIndex(of: b), to > from + 1 else { continue }
                #expect(layout.isClear(from: layout.position(a), to: layout.position(b)), "Blocked shortcut to spot \(index)")
            }
        }
    }
}
