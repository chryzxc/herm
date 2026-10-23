import Foundation
import RealityKit
import Testing

@testable import Herm

struct OfficeWorkZoneTests {
    @Test func strongestSignalChoosesTheRoomAndRecordsEvidence() {
        let step = OfficePreviewTaskData(
            task("a", title: "Write docs", step: "verify", skills: ["security-audit"], note: "deploy"))
        #expect(step.work == OfficeWorkClassification(kind: .testing, source: .step, signal: "verify"))
        let skill = OfficePreviewTaskData(
            task("b", title: "Write docs", step: "step_3", skills: ["notes-helper", "security-audit"]))
        #expect(skill.work.kind == .writing && skill.work.source == .skill && skill.work.signal == "notes-helper")
        let workflow = OfficePreviewTaskData(task("c", workflow: "web-research", note: "swift test"))
        #expect(workflow.work.kind == .research && workflow.work.source == .workflow)
        let event = OfficePreviewTaskData(task("d", note: "docker compose up"))
        #expect(event.work.kind == .infrastructure && event.work.source == .event)
        let title = OfficePreviewTaskData(task("e", title: "Pentest the login flow"))
        #expect(title.work.kind == .security && title.work.evidence == "Inferred from title")
        let fallback = OfficePreviewTaskData(task("f", title: "Ship it"))
        #expect(fallback.work == .fallback && fallback.work.evidence == "Default")
    }

    @Test func matchingUsesWholeWordsOnly() {
        #expect(OfficeWorkKind.matching("fix the latest contest attestation") == .coding)
        #expect(OfficeWorkKind.matching("write tests") == .testing)
        #expect(OfficeWorkKind.matching("write_migration_plan") == .infrastructure)
        #expect(OfficeWorkKind.matching("") == nil)
        #expect(OfficeWorkKind.matching("step 3") == nil)
    }

    @Test func mainSessionToolsMapToWorkKinds() {
        #expect(OfficeWorkKind.matching(tool: "web_search") == .research)
        #expect(OfficeWorkKind.matching(tool: "browser_navigate") == .research)
        #expect(OfficeWorkKind.matching(tool: "terminal") == .coding)
        #expect(OfficeWorkKind.matching(tool: "search_files") == .coding)
        #expect(OfficeWorkKind.matching(tool: "delegate_task") == .orchestration)
        #expect(OfficeWorkKind.matching(tool: "image_generate") == .design)
        let now = Date()
        let session = OfficeMainSession(
            id: "s", title: "Chat", state: "working", isCurrent: true,
            activities: [
                .init(id: "1", name: "terminal", timestamp: now.addingTimeInterval(-60)),
                .init(id: "2", name: "web_search", timestamp: now),
            ])
        let agent = OfficePreviewAgentPresentation(id: "main-session:s", name: "Nexus", tasks: [], mainSession: session)
        #expect(agent.work == .init(kind: .research, source: .tool, signal: "web_search"))
        // Room travel for the main agent is a later phase; it keeps its office.
        #expect(agent.location == .desk)
    }

    @Test func laneStillDecidesWhetherTheWorkRoomIsUsed() {
        for (status, location) in [
            ("running", OfficePreviewLocation.qaLab), ("review", .reviewTable), ("blocked", .desk),
            ("ready", .kanbanBoard), ("todo", .lounge), ("done", .lounge),
        ] {
            let agent = OfficePreviewAgentPresentation(
                id: "bot", name: "Bot", tasks: [OfficePreviewTaskData(task("t", status: status, step: "qa"))])
            #expect(agent.location == location, "\(status)")
            #expect((agent.work != nil) == (status == "running"))
        }
        let running = OfficePreviewAgentPresentation(
            id: "bot", name: "Bot", tasks: [OfficePreviewTaskData(task("t", step: "pentest"))])
        #expect(running.activitySymbol == .shieldCheck)
    }

    @MainActor @Test func noisySignalsSettleBeforeTheBotChangesRooms() {
        let bots = [bot("bot")]
        let start = Date(timeIntervalSince1970: 1_000)
        let simulation = OfficePreviewSimulation(
            bots: bots, tasks: [task("t", assignee: "bot", note: "running swift test")])
        #expect(simulation.agents.first?.location == .qaLab)
        simulation.update(bots: bots, tasks: [task("t", assignee: "bot", note: "reading the docs")], now: start)
        #expect(simulation.agents.first?.location == .qaLab)
        simulation.update(
            bots: bots, tasks: [task("t", assignee: "bot", note: "reading the docs")],
            now: start.addingTimeInterval(OfficeWorkStabilizer.settle))
        #expect(simulation.agents.first?.location == .library)
        // An explicit step moves the bot at once.
        simulation.update(
            bots: bots, tasks: [task("t", assignee: "bot", step: "deploy")], now: start.addingTimeInterval(21))
        #expect(simulation.agents.first?.location == .serverRoom)
        // A lane change resets the smoothing.
        simulation.update(
            bots: bots, tasks: [task("t", status: "review", assignee: "bot")], now: start.addingTimeInterval(22))
        simulation.update(
            bots: bots, tasks: [task("t", assignee: "bot", note: "docker build")], now: start.addingTimeInterval(23))
        #expect(simulation.agents.first?.location == .serverRoom)
    }

    @Test func workRoomSeatsAreStableExclusiveAndOverflowToDesks() {
        let agents = (0..<5).map {
            OfficePreviewAgentPresentation(
                id: "bot-\($0)", name: "Bot", tasks: [OfficePreviewTaskData(task("t\($0)", step: "verify"))])
        }
        let plan = OfficePreviewInteractionPlan.make(agents: agents, zoneCapacity: [.qaLab: 3])
        let seats = agents.compactMap { plan.stations[$0.id] }
        #expect(seats.count == 3)
        #expect(Set(seats) == [0, 1, 2])
        #expect(
            OfficePreviewInteractionPlan.make(agents: agents.reversed(), zoneCapacity: [.qaLab: 3]).stations
                == plan.stations)
        // Seats already held do not move when an unseated colleague leaves.
        let seated = agents.filter { plan.stations[$0.id] != nil }
        #expect(OfficePreviewInteractionPlan.make(agents: seated, zoneCapacity: [.qaLab: 3]).stations == plan.stations)
        #expect(OfficePreviewInteractionPlan.make(agents: agents).stations.isEmpty)
    }

    @MainActor @Test func everyWorkRoomHasReachableSeatsAfterTheWingsMove() {
        let authored = OfficeDesignSceneBuilder().build(in: Entity())
        var layout = OfficePreviewLayout()
        layout.authored = authored
        let desk = layout.node(slot: 0, location: .desk)
        var points: [SIMD3<Float>] = []
        for zone in OfficePreviewLocation.workZones {
            let stations = authored.stations[zone] ?? []
            #expect(!stations.isEmpty, "\(zone) has no seats")
            for (index, station) in stations.enumerated() {
                // The station must sit inside the compacted building, not 6.5m off.
                #expect(station.position.x > -22 && station.position.x < 22, "\(zone) \(index) at \(station.position)")
                points.append(station.position)
                let node = layout.node(slot: index, location: zone)
                for (start, end) in [(desk, node), (node, desk)] {
                    let route = layout.route(from: start, to: end)
                    #expect(route.first == start && route.last == end, "Unreachable \(zone) seat \(index)")
                }
            }
        }
        // No work seat overlaps another or a leisure spot.
        let leisure = authored.leisureSpots.map(\.station.position)
        for (index, point) in points.enumerated() {
            #expect(!points[(index + 1)...].contains { simd_distance($0, point) < 0.8 })
            #expect(!leisure.contains { simd_distance($0, point) < 0.8 })
        }
    }

    private func bot(_ id: String) -> BotSummary {
        BotSummary(
            id: id, name: id, title: nil, description: nil, model: nil, isActive: false,
            chat: nil, avatarURL: nil, preview: nil, lastActive: nil, isHidden: false,
            hasAvatar: false, isDefault: false)
    }

    private func task(
        _ id: String, title: String? = nil, status: String = "running", assignee: String? = nil,
        step: String? = nil, skills: [String] = [], workflow: String? = nil, note: String? = nil
    ) -> KanbanTaskSummary {
        KanbanTaskSummary(
            id: id, title: title ?? "Task \(id)", status: status, detail: nil, priority: nil, assignee: assignee,
            currentStepKey: step, latestEventNote: note, skills: skills, workflowTemplateID: workflow)
    }
}
