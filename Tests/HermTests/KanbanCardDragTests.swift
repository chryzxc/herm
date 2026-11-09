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
}
