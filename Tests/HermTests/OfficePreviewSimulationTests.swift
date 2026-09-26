import Foundation
import Testing
@testable import Herm

struct OfficePreviewSimulationTests {
    @MainActor @Test func canonicalSnapshotsDetermineActivityWithoutScriptedAdvancement() throws {
        let bots = [bot("profile-atlas")]
        let task = task("blocked-task", status: "blocked", assignee: "profile-atlas")
        let simulation = OfficePreviewSimulation(bots: bots, tasks: [task])
        let blocked = try #require(simulation.agents.first)
        #expect(blocked.phase == .waiting)
        #expect(blocked.location == .desk)
        #expect(blocked.phase.isSeated)
        #expect(blocked.monitorStatus == "Blocked")
        #expect(blocked.monitorTitle == task.title)

        // Reapplying a snapshot, including when a renderer changes its motion
        // preference, must not advance or replace the canonical activity.
        simulation.update(bots: bots, tasks: [task])
        #expect(simulation.agents == [blocked])
        simulation.update(bots: bots, tasks: [])
        let resting = try #require(simulation.agents.first)
        #expect(resting.id == blocked.id)
        #expect(resting.phase == .resting)
        #expect(resting.location == .lounge)
        #expect(resting.taskData == nil)
        #expect(resting.monitorStatus == "No assigned task")
    }

    @Test func cameraResetRestoresWorkspaceTargetAfterFocus() {
        var camera = OfficePreviewCameraState()
        camera.orbitTarget = [4, 0.55, 3]
        camera.distance = 11
        camera.reset()
        #expect(camera.orbitTarget == OfficePreviewCameraState.target)
        #expect(camera.distance == 17)
    }

    @Test func toonGaitIsDistanceDrivenAndRepeats() {
        let rest = OfficePreviewWalkPose(distance: 0)
        #expect(rest.legAngle == 0)
        #expect(rest.bounce == 0)
        let first = OfficePreviewWalkPose(distance: OfficePreviewWalkPose.strideLength / 4)
        let opposite = OfficePreviewWalkPose(distance: OfficePreviewWalkPose.strideLength * 0.75)
        #expect(first.leftLift > 0)
        #expect(first.rightLift == 0)
        #expect(opposite.leftLift == 0)
        #expect(opposite.rightLift > 0)
        #expect(abs(first.legAngle + opposite.legAngle) < 0.0001)
        let repeated = OfficePreviewWalkPose(distance: OfficePreviewWalkPose.strideLength * 1.25)
        #expect(abs(first.legAngle - repeated.legAngle) < 0.0001)
        #expect(first.bounce <= 0.0401)
        #expect(first.leftLift >= 0.08)
        #expect(first.legAngle >= 0.49)
        #expect(abs(first.footTravel + opposite.footTravel) < 0.0001)
        #expect(rest.footTravel == 0)
    }

    @Test func gaitCounterSwingsArmsAndScalesWithSpeed() {
        let stride = OfficePreviewWalkPose(distance: OfficePreviewWalkPose.strideLength / 4)
        // Arms swing opposite the leg on the same side, with a forward lean.
        #expect(stride.armAngle * stride.legAngle < 0)
        #expect(stride.lean > 0)
        let slow = OfficePreviewWalkPose(distance: OfficePreviewWalkPose.strideLength / 4, amount: 0.5)
        #expect(abs(slow.legAngle - stride.legAngle * 0.5) < 0.0001)
        let stopped = OfficePreviewWalkPose(distance: OfficePreviewWalkPose.strideLength / 4, amount: 0)
        #expect(stopped.legAngle == 0 && stopped.armAngle == 0 && stopped.bounce == 0 && stopped.leftLift == 0)
    }

    @Test func cameraDefaultsMatchTheIsometricOverview() {
        let camera = OfficePreviewCameraState()
        #expect(camera.azimuth == OfficePreviewCameraState.defaultAzimuth)
        #expect(camera.elevation == OfficePreviewCameraState.defaultElevation)
        #expect(camera.distance == OfficePreviewCameraState.defaultDistance)
        #expect(camera.position.y > OfficePreviewCameraState.target.y)
    }

    @Test func cameraRotationAndZoomAreClamped() {
        var camera = OfficePreviewCameraState()
        camera.applyDrag(deltaX: 100_000, deltaY: 100_000)
        #expect(camera.azimuth >= 0 && camera.azimuth < 2 * .pi)
        #expect(camera.elevation == OfficePreviewCameraState.elevationRange.min)
        camera.applyDrag(deltaX: -100_000, deltaY: -100_000)
        #expect(camera.azimuth >= 0 && camera.azimuth < 2 * .pi)
        #expect(camera.elevation == OfficePreviewCameraState.elevationRange.max)
        camera.applyZoom(delta: 100_000)
        #expect(camera.distance == OfficePreviewCameraState.distanceRange.min)
        camera.applyZoom(delta: -100_000)
        #expect(camera.distance == OfficePreviewCameraState.distanceRange.max)
    }

    @Test func cameraGroundPanMovesAndClampsTheOrbitTarget() {
        var camera = OfficePreviewCameraState()
        let originalTarget = camera.orbitTarget
        camera.applyGroundPan(deltaX: 100, deltaY: 50)
        #expect(camera.orbitTarget != originalTarget)
        camera.applyGroundPan(deltaX: 100_000, deltaY: 100_000)
        #expect(OfficePreviewCameraState.panXRange.contains(camera.orbitTarget.x))
        #expect(OfficePreviewCameraState.panZRange.contains(camera.orbitTarget.z))
        camera.applyGroundPan(deltaX: -100_000, deltaY: -100_000)
        #expect(OfficePreviewCameraState.panXRange.contains(camera.orbitTarget.x))
        #expect(OfficePreviewCameraState.panZRange.contains(camera.orbitTarget.z))
    }

    @Test func cameraResetRestoresDefaults() {
        var camera = OfficePreviewCameraState()
        camera.applyDrag(deltaX: 240, deltaY: -120)
        camera.applyZoom(delta: 80)
        camera.reset()
        #expect(camera == OfficePreviewCameraState())
    }

    @Test func rosterUsesStableVisibleBotIDsAndExactAssigneeMatching() throws {
        let bots = [bot("profile-nova", name: "Nova"), bot("profile-atlas", name: "Atlas"),
                    bot("hidden", hidden: true), bot("profile-atlas", name: "Atlas")]
        let tasks = [
            task("owned", status: "running", assignee: "profile-atlas"),
            task("name-match", status: "running", assignee: "Atlas"),
            task("case-match", status: "running", assignee: "PROFILE-ATLAS"),
            task("unassigned", status: "todo"),
            task("unknown-owner", status: "running", assignee: "missing"),
            task("hidden-owner", status: "running", assignee: "hidden")
        ]
        let agents = OfficePreviewResolver.agents(bots: bots, tasks: tasks)
        #expect(agents.map(\.id) == ["hidden", "profile-atlas", "profile-nova"])
        let atlas = try #require(agents.first(where: { $0.id == "profile-atlas" }))
        #expect(atlas.name == "Atlas")
        #expect(atlas.tasks.map(\.id) == ["owned"])
        #expect(agents.first(where: { $0.id == "hidden" })?.tasks.map(\.id) == ["hidden-owner"])
        #expect(agents.last?.tasks.isEmpty == true)
        #expect(agents.last?.location == .lounge)
        let reordered = OfficePreviewResolver.agents(bots: Array(bots.reversed()), tasks: Array(tasks.reversed()))
        #expect(reordered == agents)
        #expect(reordered.map(\.identitySeed) == agents.map(\.identitySeed))
        #expect(Set(OfficePreviewResolver.board(tasks: tasks).flatMap(\.tasks).map(\.id)) == Set(tasks.map(\.id)))
    }

    @Test func noBotsDoesNotInventPreviewCharacters() {
        let tasks = [task("unowned", status: "todo")]
        #expect(OfficePreviewResolver.agents(bots: [], tasks: tasks).isEmpty)
        #expect(OfficePreviewResolver.board(tasks: tasks).flatMap(\.tasks).map(\.id) == ["unowned"])
    }

    @Test func taskPrioritySelectsOnePrimaryAndPreservesTheQueue() throws {
        let statuses = ["done", "scheduled", "triage", "blocked", "review", "running", "ready", "todo"]
        let tasks = statuses.map { task($0, status: $0, assignee: "bot") }
        let agent = try #require(OfficePreviewResolver.agents(bots: [bot("bot")], tasks: tasks).first)
        #expect(agent.taskData?.id == "running")
        #expect(agent.tasks.map(\.id) == ["running", "review", "blocked", "ready", "triage", "scheduled", "todo", "done"])
        #expect(agent.tasks.count == tasks.count)
    }

    @Test func primaryTaskTiesUseEventThenStartThenTitleThenID() throws {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let tasks = [
            task("missing-date", title: "A", status: "running", assignee: "bot"),
            task("old-event", title: "A", status: "running", assignee: "bot", startedAt: new, latestEventAt: old),
            task("old-start", title: "A", status: "running", assignee: "bot", startedAt: old, latestEventAt: new),
            task("title-z", title: "Z", status: "running", assignee: "bot", startedAt: new, latestEventAt: new),
            task("id-z", title: "A", status: "running", assignee: "bot", startedAt: new, latestEventAt: new),
            task("id-a", title: "A", status: "running", assignee: "bot", startedAt: new, latestEventAt: new)
        ]
        let expected = ["id-a", "id-z", "title-z", "old-start", "old-event", "missing-date"]
        for snapshot in [tasks, Array(tasks.reversed())] {
            let agent = try #require(OfficePreviewResolver.agents(bots: [bot("bot")], tasks: snapshot).first)
            #expect(agent.tasks.map(\.id) == expected)
        }
    }

    @Test func allKanbanAliasesResolveToTheExpectedOfficeAction() {
        let groups: [([String], OfficePreviewLane, OfficePreviewPhase, OfficePreviewLocation)] = [
            (["running", "active", "working", "in_progress", "in-progress", "inprogress", " RUNNING\n"], .running, .implementing, .desk),
            (["review", "waiting", "pending"], .review, .reviewing, .reviewTable),
            (["blocked", "failed", "error"], .blocked, .waiting, .desk),
            (["triage"], .triage, .planning, .kanbanBoard),
            (["ready"], .ready, .planning, .kanbanBoard),
            (["todo"], .todo, .resting, .lounge),
            (["scheduled"], .scheduled, .resting, .lounge),
            (["done", "completed", "complete", "archived"], .done, .resting, .lounge),
            (["custom-status", ""], .unknown, .resting, .lounge)
        ]
        for (aliases, lane, phase, location) in groups {
            for alias in aliases {
                let data = OfficePreviewTaskData(task(alias, status: alias))
                #expect(data.lane == lane)
                #expect(data.phase == phase)
                #expect(data.lane.location == location)
                #expect(data.status == alias)
            }
        }
    }

    @Test func reportedStepOverridesOlderEventsAndOnlyChangesRunningActions() {
        let explicitStep = OfficePreviewTaskData(task("step", status: "running", currentStepKey: "implement", latestEventNote: "swift test"))
        #expect(explicitStep.phase == .implementing)
        let verification = OfficePreviewTaskData(task("test", status: "running", currentStepKey: "verification"))
        #expect(verification.phase == .testing)
        let reading = OfficePreviewTaskData(task("read", status: "running", currentStepKey: "research", latestEventNote: "swift test"))
        #expect(reading.phase == .reading)
        let fallback = OfficePreviewTaskData(task("fallback", status: "running", latestEventNote: "Running tests"))
        #expect(fallback.phase == .testing)
        let kindFallback = OfficePreviewTaskData(task("kind", status: "running", latestEventKind: "inspect"))
        #expect(kindFallback.phase == .reading)
        let blocked = OfficePreviewTaskData(task("blocked", status: "blocked", currentStepKey: "testing"))
        #expect(blocked.phase == .waiting)
        let unrelated = OfficePreviewTaskData(task("unrelated", status: "running", latestEventNote: "Update latest result"))
        #expect(unrelated.phase == .implementing)
    }

    @Test func boardIncludesEveryLaneAndPreservesFullLiveCardDetails() throws {
        let timestamp = Date(timeIntervalSince1970: 120)
        let richTask = KanbanTaskSummary(
            id: "task-42", boardSlug: "engineering", title: "Ship billing dashboard", status: "todo",
            detail: "Build the billing dashboard filters.", priority: "high", assignee: "missing-profile",
            startedAt: timestamp, currentStepKey: "plan", latestEventKind: "note",
            latestEventNote: "Awaiting owner", latestEventAt: timestamp
        )
        let tasks = [richTask, task("todo-2", status: "todo"), task("custom", status: "custom")]
        let board = OfficePreviewResolver.board(tasks: tasks)
        #expect(Set(board.map(\.lane)) == Set(OfficePreviewLane.allCases))
        #expect(board.first(where: { $0.lane == .todo })?.tasks.count == 2)
        #expect(board.first(where: { $0.lane == .running })?.tasks.count == 0)
        #expect(board.first(where: { $0.lane == .unknown })?.tasks.count == 1)
        let card = try #require(board.flatMap(\.tasks).first(where: { $0.id == richTask.id }))
        #expect(card.title == richTask.title)
        #expect(card.boardSlug == richTask.boardSlug)
        #expect(card.status == richTask.status)
        #expect(card.detail == richTask.detail)
        #expect(card.assignee == richTask.assignee)
        #expect(card.priority == richTask.priority)
        #expect(card.currentStepKey == richTask.currentStepKey)
        #expect(card.latestEventKind == richTask.latestEventKind)
        #expect(card.latestEventNote == richTask.latestEventNote)
        #expect(card.latestEventAt == timestamp)
        #expect(card.startedAt == timestamp)
        #expect(OfficePreviewResolver.board(tasks: []).count == 8)
    }

    @Test func unknownStatusRemainsExplicitInTheInspector() throws {
        let agent = try #require(OfficePreviewResolver.agents(bots: [bot("bot")], tasks: [task("task", status: "custom-stage", assignee: "bot")]).first)
        #expect(agent.monitorStatus == "Unknown status")
        #expect(agent.bubbleText == "Unknown status")
        #expect(agent.taskData?.status == "custom-stage")
        #expect(agent.location == .lounge)
    }

    @Test func roomSlotsSurviveReorderingAdditionRemovalAndReturn() {
        var layout = OfficePreviewLayout()
        layout.reconcile(ids: ["nova", "atlas"])
        let original = layout.slots
        var reordered = OfficePreviewLayout()
        reordered.reconcile(ids: ["atlas", "nova"])
        #expect(reordered.slots == original)
        layout.reconcile(ids: ["atlas", "nova", "new-bot"])
        #expect(layout.slots["atlas"] == original["atlas"])
        #expect(layout.slots["nova"] == original["nova"])
        let expanded = layout.slots
        layout.reconcile(ids: ["new-bot"])
        layout.reconcile(ids: ["nova", "atlas", "new-bot"])
        #expect(layout.slots == expanded)
        #expect(Set(layout.slots.values).count == 3)
    }

    @Test func roomExpandsInDepthWithExclusiveStationsAndSharedRooms() {
        var layout = OfficePreviewLayout()
        let originalWidth = layout.width
        let originalDepth = layout.depth
        layout.reconcile(ids: (0..<48).map { "bot-\($0)" })
        #expect(layout.capacity >= 48)
        #expect(layout.width == originalWidth)
        #expect(layout.depth > originalDepth)
        #expect(layout.slots.count == 48)
        var occupied = Set<SIMD3<Float>>()
        for slot in layout.slots.values {
            // Work rooms are authored-only and fall back to the desk here.
            for location in OfficePreviewLocation.allCases where !location.isWorkZone {
                let point = layout.station(slot: slot, location: location)
                #expect(occupied.insert(point).inserted)
                #expect(point.x > layout.minX && point.x < layout.maxX)
                #expect(point.z > layout.back && point.z < layout.front)
            }
        }
    }

    @Test func workPodsAndActivityRoomsOccupyDistinctAreas() {
        var layout = OfficePreviewLayout()
        layout.reconcile(ids: (0..<12).map { "bot-\($0)" })
        let desks = (0..<12).map { layout.station(slot: $0, location: .desk) }
        #expect(Set(desks.map(\.x)).count == 4)
        #expect(Set(desks.map(\.z)).count == 4)
        for slot in 0..<12 {
            let desk = layout.station(slot: slot, location: .desk)
            let meeting = layout.station(slot: slot, location: .reviewTable)
            let planning = layout.station(slot: slot, location: .kanbanBoard)
            let help = layout.station(slot: slot, location: .waitingArea)
            let lounge = layout.station(slot: slot, location: .lounge)
            #expect(desk.x > 0 && desk.z < layout.workBottom)
            #expect(meeting.x < -0.5 && meeting.z < layout.workBottom)
            #expect(planning.x < -5 && planning.z > layout.hallBottom)
            #expect(help.x > -5 && help.x < 0 && help.z > layout.hallBottom)
            #expect(lounge.x > 0 && lounge.z > layout.hallBottom)
        }
    }

    @Test func routesConnectEveryActivityThroughWalkableSpace() throws {
        var layout = OfficePreviewLayout()
        layout.reconcile(ids: (0..<48).map { "bot-\($0)" })
        for slot in [0, 3, 23, 47] {
            // Work rooms are authored-only; OfficeWorkZoneTests routes to them.
            let locations = OfficePreviewLocation.allCases.filter { !$0.isWorkZone }
            for from in locations {
                for to in locations {
                    let start = layout.node(slot: slot, location: from)
                    let end = layout.node(slot: slot, location: to)
                    let route = layout.route(from: start, to: end)
                    #expect(route.first == start)
                    #expect(route.last == end)
                    #expect(Set(route).count == route.count)
                    for node in route where !node.isStation {
                        #expect(layout.isWalkable(layout.position(node)))
                    }
                    for (current, next) in zip(route, route.dropFirst()) {
                        let delta = layout.position(next) - layout.position(current)
                        #expect(delta.y == 0)
                        #expect(delta.x == 0 || delta.z == 0)
                        if !current.isStation && !next.isStation {
                            // Check between graph points as well as at them, so
                            // a route cannot jump across a wall or furniture.
                            for fraction: Float in [0.25, 0.5, 0.75] {
                                #expect(layout.isWalkable(layout.position(current) + delta * fraction))
                            }
                        }
                    }
                    if from != to {
                        let penultimate = try #require(route.dropLast().last)
                        #expect(penultimate.isApproach)
                        #expect(route.dropFirst().first?.isApproach == true)
                        #expect(route.dropFirst().dropLast().allSatisfy { !$0.isStation })
                    }
                }
            }
        }
    }

    @Test func routingDetoursAroundReservedCorridorPositions() throws {
        var layout = OfficePreviewLayout()
        layout.reconcile(ids: ["atlas", "nova"])
        let start = layout.node(slot: 0, location: .desk)
        let end = layout.node(slot: 0, location: .lounge)
        let original = layout.route(from: start, to: end)
        let middle = try #require(original.filter { !$0.isStation && !$0.isApproach }.dropFirst(8).first)
        let occupied = layout.position(middle)
        let detour = layout.route(from: start, to: end, avoiding: [occupied])
        #expect(detour.first == start)
        #expect(detour.last == end)
        for node in detour where !node.isStation {
            let point = layout.position(node)
            #expect(abs(point.x - occupied.x) >= 0.8 || abs(point.z - occupied.z) >= 0.8)
        }
    }

    private func bot(_ id: String, name: String = "Office Bot", hidden: Bool = false) -> BotSummary {
        BotSummary(id: id, name: name, title: nil, description: nil, model: nil, isActive: false,
                   chat: nil, avatarURL: nil, preview: nil, lastActive: nil, isHidden: hidden,
                   hasAvatar: false, isDefault: false)
    }

    private func task(_ id: String, title: String? = nil, status: String, assignee: String? = nil,
                      startedAt: Date? = nil, latestEventAt: Date? = nil, currentStepKey: String? = nil,
                      latestEventKind: String? = nil, latestEventNote: String? = nil) -> KanbanTaskSummary {
        KanbanTaskSummary(id: id, title: title ?? id, status: status, detail: nil, priority: nil,
                          assignee: assignee, startedAt: startedAt, currentStepKey: currentStepKey,
                          latestEventKind: latestEventKind, latestEventNote: latestEventNote,
                          latestEventAt: latestEventAt)
    }
}
