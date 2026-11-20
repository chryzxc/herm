import Testing
import simd

@testable import Herm

struct OfficeNavigationCacheTests {
    @MainActor
    @Test func backgroundPlanPreservesWaypointsAndHonorsOccupiedDestination() async {
        var layout = OfficePreviewLayout()
        var floor = OfficeDesignNavigation()
        floor.stations[.desk] = [.init(position: [0, 0, 0], approach: [0, 0, 0], yaw: 0)]
        floor.stations[.reviewTable] = [.init(position: [2, 0, 0], approach: [2, 0, 0], yaw: 0)]
        layout.authored = floor
        let start = layout.node(slot: 0, location: .desk)
        let end = layout.node(slot: 0, location: .reviewTable)
        let path = layout.route(from: start, to: end)
        #expect(await layout.canReach(from: start, to: end))
        let steps = await layout.walkingSteps(from: start, to: end, avoiding: [])
        #expect(steps.last == end)
        #expect(steps == Array(layout.smoothed(path, from: layout.position(start), avoiding: []).dropFirst()))
        let approach = OfficePreviewLayout.Node(slot: end.slot, index: end.index, isStation: false, isApproach: true)
        #expect(await layout.walkingSteps(from: start, to: end, avoiding: [layout.position(approach)]).isEmpty)
    }

    @Test func cachedWalkabilityMatchesGeometryAfterRosterGrowthAndCopy() {
        let original = OfficePreviewLayout()
        var expanded = original
        expanded.reconcile(ids: (0..<20).map { "agent-\($0)" })
        #expect(original.capacity == 8)
        #expect(expanded.capacity == 20)
        for layout in [original, expanded] {
            let obstacles = layout.walls + layout.furniture
            for x in stride(from: layout.minX, through: layout.maxX, by: 0.5) {
                for z in stride(from: layout.back, through: layout.front, by: 0.5) {
                    let inside =
                        x >= layout.minX + 0.6 && x <= layout.maxX - 0.6
                        && z >= layout.back + 0.6 && z <= layout.front - 0.6
                        && !(x > 12 && z > layout.hallBottom + 5)
                    let expected = inside && !obstacles.contains { $0.contains([x, z], clearance: 0.36) }
                    #expect(layout.isWalkable([x, 0, z]) == expected)
                }
            }
        }
    }
}
