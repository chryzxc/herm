import RealityKit
import Testing

@testable import Herm

struct OfficeGardenNavigationTests {
    @MainActor @Test func compactWingsAndRoomsConnectToMainEntrance() throws {
        let root = Entity()
        var authored = OfficeDesignSceneBuilder().build(in: root)
        #expect(root.findEntity(named: "investigation-board") != nil)
        #expect(root.findEntity(named: "investigation-board-cork") != nil)
        #expect(root.findEntity(named: "investigation-thread-a") != nil)
        #expect(root.findEntity(named: "investigation-pin-a") != nil)
        #expect(root.findEntity(named: "bike-rack") != nil)
        #expect(root.findEntity(named: "entry-directory") != nil)
        #expect(root.findEntity(named: "landscape-planter") != nil)
        func countWestWallWindows(in node: Entity) -> Int {
            let ownCount = node.name == "window" && node.visualBounds(relativeTo: root).center.x < -20 ? 1 : 0
            return ownCount + node.children.reduce(0) { $0 + countWestWallWindows(in: $1) }
        }
        #expect(countWestWallWindows(in: root) == 4)
        #expect(root.findEntity(named: "staircase") == nil)
        #expect(root.findEntity(named: "reception-desk") == nil)
        let west = try #require(root.findEntity(named: "west-wing-floor")).visualBounds(relativeTo: root)
        let east = try #require(root.findEntity(named: "east-wing-floor")).visualBounds(relativeTo: root)
        #expect(abs(east.max.x - west.min.x - 43) < 0.01)
        #expect(abs(east.min.x - west.max.x - 3) < 0.01)
        #expect(abs(east.max.z - 16) < 0.01)
        #expect(root.findEntity(named: "east-wing-floor") != nil)
        let exteriorTrees =
            root.findEntity(named: "exterior-landscape")?.children.filter { $0.name == "garden-tree" } ?? []
        #expect(exteriorTrees.count == 4)
        for tree in exteriorTrees {
            let bounds = tree.visualBounds(relativeTo: root)
            #expect(
                bounds.max.x < west.min.x || bounds.min.x > east.max.x || bounds.max.z < west.min.z
                    || bounds.min.z > east.max.z)
        }
        #expect(authored.stations[.desk]?.filter { $0.position.x < 0 }.count == 14)
        #expect(authored.stations[.desk]?.filter { $0.position.x > 0 }.count == 9)
        #expect(authored.stations[.reviewTable]?.count == 10)
        for slot in 0..<23 { #expect(root.findEntity(named: "work-screen-\(slot)") != nil) }
        let destinations: [SIMD3<Float>] = [
            [-23, 0, 1.75], [-23, 0, 7.25], [-23.25, 0, 10], [-19, 0, 11],
            [-17, 0, -1], [0, 0, 3.5], [0, 0, -1.5], [16, 0, 3],
            [12, 0, 10], [22, 0, 10], [21.5, 0, 4], [17, 0, 15],
            // Reach the usable interior of each converted specialist room,
            // not only its doorway: studio, QA, server aisle and Security Ops,
            // in front of its two console chairs.
            [-23.5, 0, 0.5], [-24, 0, 6], [-25, 0, 11], [-20, 0, 11.1],
        ].map { p in p + SIMD3<Float>(p.x <= -8 ? 6.5 : (p.x >= 8 ? -6.5 : 0), 0, 0) }
        authored.stations[.waitingArea] = destinations.map { .init(position: $0, approach: $0, yaw: 0, seated: false) }
        var layout = OfficePreviewLayout()
        layout.authored = authored
        for index in destinations.indices {
            let destination = layout.node(slot: index, location: .waitingArea)
            let route = layout.route(from: layout.node(slot: 0, location: .desk), to: destination)
            #expect(!route.isEmpty, "Room entrance unreachable: \(destinations[index])")
            for node in route where !node.isStation { #expect(layout.isWalkable(layout.position(node))) }
        }
    }

    @Test func navigationCacheTracksGeometryAndLiveOccupancy() {
        var layout = OfficePreviewLayout()
        var authored = OfficeDesignNavigation()
        authored.stations[.desk] = [.init(position: [0, 0, 0], approach: [0, 0, 0], yaw: 0)]
        authored.stations[.lounge] = [.init(position: [2, 0, 0], approach: [2, 0, 0], yaw: 0)]
        layout.authored = authored
        let desk = layout.node(slot: 0, location: .desk)
        let lounge = layout.node(slot: 0, location: .lounge)
        let expected = layout.route(from: desk, to: lounge)
        #expect(!expected.isEmpty)
        // Repeated occupancy changes must neither poison the geometry cache nor
        // leave a route through a bot that is still occupying the destination.
        for _ in 0..<100 {
            #expect(layout.route(from: desk, to: lounge, avoiding: [[2, 0, 0]]).isEmpty)
            #expect(layout.route(from: desk, to: lounge) == expected)
        }
        layout.authored?.obstacles = [.init(name: "moved-furniture", center: [2, 0], size: [1, 1])]
        #expect(layout.route(from: desk, to: lounge).isEmpty)
        layout.authored?.obstacles = []
        #expect(layout.route(from: desk, to: lounge) == expected)
    }

    @MainActor @Test func overlappingFloorSurfacesHaveSeparateHeights() {
        let root = Entity()
        OfficeDesignSceneBuilder().build(in: root)
        var surfaces: [Entity] = []
        func collect(_ node: Entity) {
            if node.name.hasSuffix("floor") || node.name == "exterior-ground" { surfaces.append(node) }
            for child in node.children { collect(child) }
        }
        collect(root)
        for (index, first) in surfaces.enumerated() {
            let a = first.visualBounds(relativeTo: root)
            for second in surfaces.dropFirst(index + 1) {
                let b = second.visualBounds(relativeTo: root)
                let overlapX = min(a.max.x, b.max.x) - max(a.min.x, b.min.x)
                let overlapZ = min(a.max.z, b.max.z) - max(a.min.z, b.min.z)
                if overlapX > 0.001 && overlapZ > 0.001 {
                    #expect(
                        abs(a.max.y - b.max.y) > 0.01,
                        "Coplanar floors: \(first.name) and \(second.name)")
                }
            }
        }
    }

    @MainActor @Test func desksConnectToOutdoorSeatingThroughRenderedDoorway() throws {
        var layout = OfficePreviewLayout()
        layout.authored = OfficeDesignSceneBuilder().build(in: Entity(), capacity: 26)
        #expect(layout.authored?.stations[.desk]?.count == 23)
        #expect(layout.authored?.stations[.lounge]?.count == 2)
        for slot in 0..<2 {
            let desk = layout.node(slot: slot, location: .desk)
            let patio = layout.node(slot: slot, location: .lounge)
            for (from, to) in [(desk, patio), (patio, desk)] {
                let route = layout.route(from: from, to: to)
                #expect(!route.isEmpty, "No route for slot \(slot)")
                #expect(route.first == from)
                #expect(route.last == to)
                for node in route where !node.isStation {
                    #expect(
                        layout.isWalkable(layout.position(node)),
                        "Blocked node for slot \(slot): \(layout.position(node))")
                }
                for (a, b) in zip(route, route.dropFirst()) where !a.isStation && !b.isStation {
                    let start = layout.position(a)
                    let end = layout.position(b)
                    for fraction: Float in [0.25, 0.5, 0.75] {
                        #expect(layout.isWalkable(start + (end - start) * fraction))
                    }
                }
                let crossings = route.map { layout.position($0) }.filter { abs($0.z - 14) < 0.01 }
                #expect(crossings.contains { $0.x > -1.5 && $0.x < 1.5 })
            }
        }
    }

    @MainActor @Test func meetingSeatsHaveAnUnblockedExitToThePatio() {
        var layout = OfficePreviewLayout()
        layout.authored = OfficeDesignSceneBuilder().build(in: Entity(), capacity: 12)
        for slot in 0..<2 {
            let start = layout.node(slot: slot, location: .reviewTable)
            let end = layout.node(slot: slot, location: .lounge)
            let route = layout.route(from: start, to: end)
            #expect(route.first == start, "Meeting seat \(slot) cannot exit")
            #expect(route.last == end)
            for node in route where !node.isStation { #expect(layout.isWalkable(layout.position(node))) }
        }
    }
}
