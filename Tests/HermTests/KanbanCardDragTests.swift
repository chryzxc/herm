import Foundation
import Testing

@testable import Herm

struct KanbanCardDragTests {
    @Test func insertionFollowsPointerWithoutChasingTheOpenGap() {
        let mids: [CGFloat] = [50, 150, 250]
        #expect(KanbanDragController.insertionIndex(pointerY: 10, rowMidYs: mids, openGap: nil, gapHeight: 100) == 0)
        #expect(KanbanDragController.insertionIndex(pointerY: 120, rowMidYs: mids, openGap: nil, gapHeight: 100) == 1)
        #expect(KanbanDragController.insertionIndex(pointerY: 900, rowMidYs: mids, openGap: nil, gapHeight: 100) == 3)
        // Gap open at 1 pushed rows 1+ down by 100; their natural mids are 150 and 250 again.
        #expect(
            KanbanDragController.insertionIndex(pointerY: 180, rowMidYs: [50, 250, 350], openGap: 1, gapHeight: 100)
                == 2)
        #expect(KanbanDragController.insertionIndex(pointerY: 120, rowMidYs: [], openGap: nil, gapHeight: 100) == 0)
    }

    @Test func placementMovesCardToItsDropSlot() {
        func task(_ id: String, _ status: String) -> KanbanTaskSummary {
            KanbanTaskSummary(id: id, title: id, status: status, detail: nil, priority: nil, assignee: nil)
        }
        let snapshot = KanbanBoardPresentation.makeSnapshot(
            tasks: [task("a", "triage"), task("b", "todo"), task("c", "todo")], bots: [])

        let placed = snapshot.placing("a", in: .todo, at: 1)
        #expect(placed.tasks(in: .triage).isEmpty)
        #expect(placed.tasks(in: .todo).map(\.id) == ["b", "a", "c"])
        #expect(snapshot.placing("a", in: .todo, at: 99).tasks(in: .todo).map(\.id) == ["b", "c", "a"])
        // Already in the lane (Hermes confirmed) or unknown: unchanged.
        #expect(snapshot.placing("b", in: .todo, at: 0).tasks(in: .todo).map(\.id) == ["b", "c"])
        #expect(snapshot.placing("zzz", in: .todo, at: 0).totalCount == 3)
    }

    @Test func insertionOnlyReadsRowsThroughTheDropSlot() {
        var visited = 0
        let heights = [50.0, 150.0, 250.0].lazy.map { height in
            visited += 1
            return CGFloat(height)
        }
        #expect(
            KanbanDragController.insertionIndex(
                pointerY: 100, rowMidYs: heights, openGap: nil, gapHeight: 0) == 1)
        #expect(visited == 2)
    }

    @MainActor
    @Test func interruptedDragClearsPreviewAndAllowsAnotherDrop() throws {
        let first = KanbanTaskSummary(
            id: "first", title: "First", status: "todo", detail: nil, priority: nil, assignee: nil)
        let second = KanbanTaskSummary(
            id: "second", title: "Second", status: "todo", detail: nil, priority: nil, assignee: nil)
        let drag = KanbanDragController()
        drag.tasks = [first, second]
        drag.actions.move = true
        drag.laneFrames = [.ready: CGRect(x: 100, y: 0, width: 100, height: 200)]
        drag.rowFrames = [
            first.id: CGRect(x: 0, y: 0, width: 80, height: 30),
            second.id: CGRect(x: 0, y: 40, width: 80, height: 30),
        ]
        var dropped: [String] = []
        drag.drop = { task, _ in dropped.append(task.id) }

        drag.dragChanged(task: first, lane: .todo, start: CGPoint(x: 10, y: 10), location: CGPoint(x: 110, y: 10))
        let interrupted = try #require(drag.session?.id)
        #expect(drag.target == .ready)
        drag.cancelDrag(interrupted)
        #expect(drag.session == nil)
        #expect(drag.target == nil)
        #expect(drag.placement == nil)
        #expect(dropped.isEmpty)

        drag.dragChanged(task: second, lane: .todo, start: CGPoint(x: 10, y: 50), location: CGPoint(x: 110, y: 50))
        drag.cancelDrag(interrupted)
        drag.dragEnded(taskID: first.id)
        #expect(drag.session?.task.id == second.id)
        drag.dragEnded(taskID: second.id)
        #expect(drag.session == nil)
        #expect(drag.placement == .init(taskID: second.id, lane: .ready, index: 0))
        #expect(dropped == [second.id])
    }
}
