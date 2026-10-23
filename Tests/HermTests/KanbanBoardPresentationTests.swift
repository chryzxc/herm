import Foundation
import Testing

@testable import Herm

struct KanbanBoardPresentationTests {
    @Test func laneMappingNormalizesHermesStatuses() {
        #expect(KanbanBoardPresentation.lane(for: "in-progress") == .running)
        #expect(KanbanBoardPresentation.lane(for: "inprogress") == .running)
        #expect(KanbanBoardPresentation.lane(for: "archived") == .done)
        #expect(KanbanBoardPresentation.lane(for: "custom-state") == .todo)
    }

    @Test func snapshotBucketsTasksAndCountsInOneProjection() {
        let snapshot = KanbanBoardPresentation.makeSnapshot(
            tasks: [
                KanbanTaskSummary(
                    id: "1", title: "Running", status: "running", detail: nil, priority: nil, assignee: nil),
                KanbanTaskSummary(
                    id: "2", title: "Blocked", status: "blocked", detail: nil, priority: nil, assignee: nil),
                KanbanTaskSummary(
                    id: "3", title: "Done", status: "completed", detail: nil, priority: nil, assignee: nil),
            ], bots: [])

        #expect(snapshot.totalCount == 3)
        #expect(snapshot.tasks(in: .running).map(\.id) == ["1"])
        #expect(snapshot.tasks(in: .blocked).map(\.id) == ["2"])
        #expect(snapshot.tasks(in: .done).map(\.id) == ["3"])
    }

    @Test func botLookupIsCaseInsensitive() {
        let bot = BotSummary(
            id: "Forge",
            name: "Forge",
            title: nil,
            description: nil,
            model: nil,
            isActive: true,
            chat: nil,
            avatarURL: nil,
            preview: nil,
            lastActive: nil,
            isHidden: false,
            hasAvatar: false,
            isDefault: false
        )
        let snapshot = KanbanBoardPresentation.makeSnapshot(tasks: [], bots: [bot])

        #expect(snapshot.bot(for: " forge ")?.id == "Forge")
    }

    @Test func cardDetailRemovesProtocolMetadata() {
        let detail = KanbanBoardPresentation.cardDetail("TASK_ID: t_1\nOBJECTIVE: Ship it\n\nCheck tests")

        #expect(detail == "Ship it Check tests")
        #expect(KanbanBoardPresentation.cardDetail("TASK_ID: t_1") == nil)
    }

    @Test func emptyLaneExpansionIsIndependentAndTasksAutoExpand() {
        var state = KanbanLaneExpansionState()
        #expect(!state.isExpanded(.todo, hasTasks: false))
        #expect(!state.isExpanded(.ready, hasTasks: false))

        state.expandedEmptyLanes.insert(.todo)
        #expect(state.isExpanded(.todo, hasTasks: false))
        #expect(!state.isExpanded(.ready, hasTasks: false))
        #expect(state.isExpanded(.ready, hasTasks: true))
    }

    @Test func lanesWithWorkCollapseIndependentlyOfEmptyLanes() {
        var state = KanbanLaneExpansionState()
        state.collapse(.running, hasTasks: true)
        #expect(!state.isExpanded(.running, hasTasks: true))
        #expect(state.isExpanded(.review, hasTasks: true))

        state.expand(.running, hasTasks: true)
        #expect(state.isExpanded(.running, hasTasks: true))

        state.expand(.todo, hasTasks: false)
        #expect(state.isExpanded(.todo, hasTasks: false))
        state.collapse(.todo, hasTasks: false)
        #expect(!state.isExpanded(.todo, hasTasks: false))
    }

    @Test func compactAgeUsesMinuteResolution() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(KanbanBoardPresentation.compactAge(since: now.addingTimeInterval(-20), now: now) == "now")
        #expect(KanbanBoardPresentation.compactAge(since: now.addingTimeInterval(-5 * 60), now: now) == "5m")
        #expect(KanbanBoardPresentation.compactAge(since: now.addingTimeInterval(-8 * 3600), now: now) == "8h")
        #expect(KanbanBoardPresentation.compactAge(since: now.addingTimeInterval(-2 * 86400), now: now) == "2d")
        #expect(KanbanBoardPresentation.compactAge(since: now.addingTimeInterval(-21 * 86400), now: now) == "3w")
        #expect(KanbanBoardPresentation.compactAge(since: now.addingTimeInterval(60), now: now) == "now")
    }

    @Test func inspectorTabsAreStableAndReadable() {
        #expect(KanbanInspectorTab.allCases.map(\.rawValue) == ["Overview", "Activity"])
    }

    @Test func menuAndDragDestinationsRespectAvailableActions() {
        let unavailable = KanbanCardActionAvailability()
        #expect(unavailable.details)
        #expect(unavailable.destinations(for: "todo").isEmpty)
        let moves = KanbanCardActionAvailability(move: true)
        #expect(moves.destinations(for: "todo") == [.triage, .ready])
        #expect(moves.destinations(for: "scheduled") == [.triage, .todo, .ready])
        let all = KanbanCardActionAvailability(complete: true, block: true, move: true)
        #expect(all.destinations(for: "running") == [.triage, .todo, .ready, .blocked, .done])
        #expect(!all.destinations(for: "completed").contains(.done))
        #expect(!all.destinations(for: "blocked").contains(.blocked))
    }

    @Test func dropsFollowTheDesktopWorkflowRules() {
        typealias P = KanbanBoardPresentation
        #expect(P.dropOutcome(taskStatus: "todo", target: .ready) == .move(.ready))
        #expect(P.dropOutcome(taskStatus: "blocked", target: .todo) == .move(.todo))
        #expect(P.dropOutcome(taskStatus: "ready", target: .triage) == .move(.triage))
        #expect(P.dropOutcome(taskStatus: "running", target: .done) == .confirm(.complete))
        #expect(P.dropOutcome(taskStatus: "ready", target: .blocked) == .confirm(.block))
        #expect(P.dropOutcome(taskStatus: "in_progress", target: .running) == .none)
        for locked in [KanbanLane.running, .review, .scheduled] {
            guard case .refused = P.dropOutcome(taskStatus: "todo", target: locked) else {
                Issue.record("\(locked) must refuse drops")
                continue
            }
        }
        #expect(KanbanLane.ready.status == "ready")
    }
}
