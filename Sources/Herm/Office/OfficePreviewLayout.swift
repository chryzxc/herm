import Foundation
import simd

/// A compact shared floor plan. Geometry and navigation consume the same walls,
/// furniture footprints and station coordinates.
struct OfficePreviewLayout {
    var authored: OfficeDesignNavigation? {
        didSet {
            navigationObstacles = walls + furniture
            rebuildBlockedGrid()
        }
    }
    // One bounded geometry cache, replaced whenever the authored room changes.
    // Moving bots remain live obstacles and are never stored in this cache.
    private var blockedGrid = Set<SIMD2<Int>>()
    private var navigationObstacles: [Footprint] = []

    init() {
        navigationObstacles = walls + furniture
    }

    private mutating func rebuildBlockedGrid() {
        blockedGrid.removeAll(keepingCapacity: true)
        guard let authored else { return }
        for obstacle in authored.obstacles {
            let low = obstacle.center - obstacle.size / 2 - SIMD2<Float>(repeating: 0.36)
            let high = obstacle.center + obstacle.size / 2 + SIMD2<Float>(repeating: 0.36)
            let x0 = Int((max(minX, low.x) * 4).rounded(.up))
            let x1 = Int((min(maxX, high.x) * 4).rounded(.down))
            let z0 = Int((max(back, low.y) * 4).rounded(.up))
            let z1 = Int((min(front, high.y) * 4).rounded(.down))
            guard x0 <= x1, z0 <= z1 else { continue }
            for x in x0...x1 {
                for z in z0...z1 where obstacle.contains([Float(x) / 4, Float(z) / 4], clearance: 0.36) {
                    blockedGrid.insert([x, z])
                }
            }
        }
    }
    private(set) var slots: [String: Int] = [:]
    private(set) var capacity = 8
    var deskRows: Int { (capacity + 7) / 8 }
    var workBottom: Float { max(2, max(-3 + Float(deskRows - 1) * 6 + 3, -5.5 + Float((capacity + 1) / 2) * 1.5)) }
    var hallBottom: Float { workBottom + 2 }
    var front: Float { authored?.front ?? (hallBottom + Float((capacity + 3) / 4) * 3.8 + 2) }
    var minX: Float { authored?.minX ?? -10 }
    var maxX: Float { authored?.maxX ?? 16 }
    var back: Float { authored?.back ?? -8 }
    var width: Float { maxX - minX }
    var depth: Float { front - back }
    var center: SIMD3<Float> { [(minX + maxX) / 2, 0.55, (front + back) / 2] }

    /// The authored office reserves its final physical desk for one main
    /// session. Other sessions/bots retain unique shared or overflow slots.
    mutating func reconcile(ids: [String], mainAgentID: String? = nil, reserveMainOffice: Bool = false) {
        let previousCapacity = capacity
        var next = reserveMainOffice ? 0 : (slots.values.max() ?? -1) + 1
        if reserveMainOffice {
            for id in Array(slots.keys) where slots[id] == 22 && id != mainAgentID {
                while next == 22 || slots.values.contains(next) { next += 1 }
                slots[id] = next
                next += 1
            }
            if let mainAgentID, ids.contains(mainAgentID) { slots[mainAgentID] = 22 }
        }
        for id in Set(ids).sorted() where slots[id] == nil {
            if reserveMainOffice {
                while next == 22 || slots.values.contains(next) { next += 1 }
            }
            slots[id] = next
            next += 1
        }
        capacity = max(8, (slots.values.max() ?? -1) + 1)
        if capacity != previousCapacity, authored == nil { navigationObstacles = walls + furniture }
    }

    func station(slot: Int, location: OfficePreviewLocation) -> SIMD3<Float> {
        if let authored { return authored.station(slot: slot, location: location).position }
        switch location {
        case .desk:
            let pod = slot / 4
            let x: Float = pod.isMultiple(of: 2) ? 3 : 10
            return [x + (slot.isMultiple(of: 2) ? -0.85 : 0.85), 0,
                    -3 + Float(pod / 2) * 6 + (slot % 4 < 2 ? -1.3 : 1.3)]
        case .reviewTable:
            return [slot.isMultiple(of: 2) ? -8 : -3, 0, -5.5 + Float(slot / 2) * 1.5]
        case .kanbanBoard:
            return [slot.isMultiple(of: 2) ? -8.5 : -6.5, 0, hallBottom + 1.5 + Float(slot / 2) * 1.5]
        case .waitingArea:
            return [slot.isMultiple(of: 2) ? -3.5 : -1.5, 0, hallBottom + 1.5 + Float(slot / 2) * 1.5]
        case .lounge:
            return [3.2 + (slot.isMultiple(of: 2) ? -0.8 : 0.8), 0,
                    hallBottom + 2 + Float(slot / 4) * 3.8 + (slot % 4 < 2 ? -1.05 : 1.05)]
        default:
            // Work rooms are authored-only; the generated fallback office uses desks.
            return station(slot: slot, location: .desk)
        }
    }

    func yaw(slot: Int, location: OfficePreviewLocation) -> Float {
        if let authored { return authored.station(slot: slot, location: location).yaw }
        if location == .reviewTable { return slot.isMultiple(of: 2) ? .pi / 2 : -.pi / 2 }
        if location == .desk || location == .lounge || location.isWorkZone { return slot % 4 < 2 ? 0 : .pi }
        return .pi
    }

    func deskPosition(slot: Int) -> SIMD3<Float> {
        station(slot: slot, location: .desk) + [0, 0, slot % 4 < 2 ? 0.85 : -0.85]
    }

    struct Footprint {
        let name: String
        let center: SIMD2<Float>
        let size: SIMD2<Float>
        func contains(_ point: SIMD2<Float>, clearance: Float = 0) -> Bool {
            abs(point.x - center.x) < size.x / 2 + clearance &&
            abs(point.y - center.y) < size.y / 2 + clearance
        }
    }

    var walls: [Footprint] {
        if let authored { return authored.obstacles }
        return [
            // A glazed meeting room opens onto the central cross corridor.
            Footprint(name: "meeting-front", center: [-6.25, workBottom], size: [7.5, 0.15]),
            Footprint(name: "meeting-divider", center: [-0.5, (back + workBottom) / 2], size: [0.15, workBottom - back]),
            Footprint(name: "planning-help-divider", center: [-5, (hallBottom + front) / 2], size: [0.15, front - hallBottom]),
            Footprint(name: "help-lounge-divider", center: [0, (hallBottom + front) / 2], size: [0.15, front - hallBottom]),
            // The front rooms have open doorways facing the cross corridor.
            Footprint(name: "planning-front", center: [-9.25, hallBottom], size: [1.5, 0.15]),
            Footprint(name: "help-front", center: [-4.25, hallBottom], size: [1.5, 0.15]),
            Footprint(name: "lounge-front", center: [5.5, hallBottom], size: [7, 0.15])
        ]
    }

    var furniture: [Footprint] {
        if authored != nil { return [] }
        var result = [
            Footprint(name: "conference-table", center: [-5.5, -5.5 + Float((capacity + 1) / 2 - 1) * 0.75],
                      size: [2.6, Float((capacity + 1) / 2) * 1.5]),
            Footprint(name: "coffee-counter", center: [14, hallBottom + 2], size: [2.2, 0.7])
        ]
        for group in 0..<((capacity + 3) / 4) {
            result.append(Footprint(name: "lounge-table", center: [3.2, hallBottom + 2 + Float(group) * 3.8], size: [1.5, 0.65]))
        }
        result += fixtures
        for slot in 0..<capacity {
            let desk = deskPosition(slot: slot)
            result.append(Footprint(name: "desk-\(slot)", center: [desk.x, desk.z], size: [1.55, 0.82]))
            // Seating is an obstacle to general paths; the dedicated last
            // approach segment is allowed to mount the reserved chair.
            for location in [OfficePreviewLocation.desk, .reviewTable, .lounge] {
                let seat = station(slot: slot, location: location)
                result.append(Footprint(name: "seat-\(slot)-\(location)", center: [seat.x, seat.z], size: [0.6, 0.6]))
            }
        }
        return result
    }

    var fixtures: [Footprint] {
        [
            Footprint(name: "plant", center: [14.5, -5.5], size: [0.8, 0.8]),
            Footprint(name: "plant", center: [-8.8, -7], size: [0.8, 0.8]),
            Footprint(name: "plant", center: [10.8, front - 1.5], size: [0.8, 0.8]),
            Footprint(name: "shelf", center: [14.5, -2], size: [1.25, 0.42]),
            Footprint(name: "shelf", center: [-2.5, front - 1], size: [1.25, 0.42]),
            Footprint(name: "shelf", center: [-7.5, front - 1], size: [1.25, 0.42])
        ]
    }

    func isWalkable(_ point: SIMD3<Float>) -> Bool {
        guard point.x >= minX + 0.6, point.x <= maxX - 0.6,
              point.z >= back + 0.6, point.z <= front - 0.6 else { return false }
        // L-shaped cutaway: the coffee nook ends before the front lounge.
        if authored == nil && point.x > 12 && point.z > hallBottom + 5 { return false }
        return !navigationObstacles.contains { $0.contains([point.x, point.z], clearance: 0.36) }
    }

    /// Straight-line clearance against the cached obstacle grid. Every grid
    /// cell touching the sampled point must be free, so a shortcut never
    /// clips a corner the A* search would have walked around.
    func isClear(from a: SIMD3<Float>, to b: SIMD3<Float>, avoiding occupied: [SIMD3<Float>] = []) -> Bool {
        let length = simd_length(SIMD2<Float>(b.x - a.x, b.z - a.z))
        let steps = max(1, Int((length / 0.1).rounded(.up)))
        for step in 0...steps {
            let p = a + (b - a) * (Float(step) / Float(steps))
            guard p.x >= minX + 0.6, p.x <= maxX - 0.6, p.z >= back + 0.6, p.z <= front - 0.6 else { return false }
            if authored == nil {
                if !isWalkable(p) { return false }
            } else {
                let x0 = Int((p.x * 4).rounded(.down)), z0 = Int((p.z * 4).rounded(.down))
                for cell in [SIMD2<Int>(x0, z0), [x0 + 1, z0], [x0, z0 + 1], [x0 + 1, z0 + 1]] where blockedGrid.contains(cell) { return false }
            }
            if occupied.contains(where: { abs($0.x - p.x) < 0.8 && abs($0.z - p.z) < 0.8 }) { return false }
        }
        return true
    }

    /// Removes grid staircase corners: keeps each node only when the walk
    /// from the previous kept point to the following node is obstructed.
    /// The first node, stations, approaches and the destination are always kept.
    func smoothed(_ route: [Node], from start: SIMD3<Float>, avoiding occupied: [SIMD3<Float>] = []) -> [Node] {
        guard route.count > 2 else { return route }
        var result: [Node] = []
        var anchor = start
        var index = 0
        while index < route.count {
            let node = route[index]
            let isFixed = index == 0 || node.isStation || node.isApproach || index == route.count - 1
            if !isFixed, index + 1 < route.count, isClear(from: anchor, to: position(route[index + 1]), avoiding: occupied) {
                index += 1
                continue
            }
            result.append(node)
            anchor = position(node)
            index += 1
        }
        return result
    }

    struct Node: Hashable, Codable {
        let slot: Int
        let index: Int
        let isStation: Bool
        var isApproach: Bool = false
        var grid: SIMD2<Int> = .zero
        var leisureIndex: Int? = nil
        var connectorPosition: SIMD3<Float>? = nil
    }
    static let locations = OfficePreviewLocation.allCases

    func node(slot: Int, location: OfficePreviewLocation) -> Node {
        Node(slot: slot, index: Self.locations.firstIndex(of: location)!, isStation: true)
    }
    func position(_ node: Node) -> SIMD3<Float> {
        if let point = node.connectorPosition { return point }
        if let index = node.leisureIndex, let authored, authored.leisureSpots.indices.contains(index) {
            let station = authored.leisureSpots[index].station
            return node.isApproach ? station.approach : station.position
        }
        if node.isStation || node.isApproach {
            let base = station(slot: node.slot, location: Self.locations[node.index])
            if node.isStation { return base }
            if let authored { return authored.station(slot: node.slot, location: Self.locations[node.index]).approach }
            // Enter armless seats from their side, never through a backrest.
            if Self.locations[node.index] == .reviewTable { return base + [0, 0, 0.75] }
            if [.desk, .lounge].contains(Self.locations[node.index]) || Self.locations[node.index].isWorkZone {
                return base + [node.slot.isMultiple(of: 2) ? -1 : 1, 0, 0]
            }
            return base + [1, 0, 0]
        }
        return [Float(node.grid.x) / 4, 0, Float(node.grid.y) / 4]
    }

    /// A* on a quarter-unit grid. Every segment is checked against the same
    /// furniture and wall footprints used by the renderer.
    func route(from start: Node, to end: Node, avoiding occupied: [SIMD3<Float>] = []) -> [Node] {
        if start == end { return [start] }
        let first = start.isStation ? Node(slot: start.slot, index: start.index, isStation: false, isApproach: true, leisureIndex: start.leisureIndex) : start
        let last = Node(slot: end.slot, index: end.index, isStation: false, isApproach: true, leisureIndex: end.leisureIndex)
        func grid(_ point: SIMD3<Float>) -> SIMD2<Int> { [Int((point.x * 4).rounded()), Int((point.z * 4).rounded())] }
        let source = grid(position(first)), goal = grid(position(last))
        func heuristic(_ p: SIMD2<Int>) -> Int { abs(p.x - goal.x) + abs(p.y - goal.y) }
        let obstacles = authored == nil ? navigationObstacles : []
        func allowed(_ p: SIMD2<Int>) -> Bool {
            let x = Float(p.x) / 4, z = Float(p.y) / 4
            guard x >= minX + 0.6, x <= maxX - 0.6, z >= back + 0.6, z <= front - 0.6 else { return false }
            if authored == nil && x > 12 && z > hallBottom + 5 { return false }
            if blockedGrid.contains(p) || obstacles.contains(where: { $0.contains([x, z], clearance: 0.36) }) { return false }
            return !occupied.contains { abs($0.x - x) < 0.8 && abs($0.z - z) < 0.8 }
        }
        // An occupied destination cannot be reached. Don't flood-search the
        // entire office while waiting for the other bot to leave its approach.
        guard allowed(goal) else { return [] }
        // A binary heap keeps larger rosters from doing linear queue scans
        // for every step of a route search.
        struct Candidate {
            let point: SIMD2<Int>
            let score: Int
            let estimate: Int
        }
        var open: [Candidate] = []
        func precedes(_ a: Candidate, _ b: Candidate) -> Bool {
            a.score + a.estimate == b.score + b.estimate
                ? a.estimate < b.estimate : a.score + a.estimate < b.score + b.estimate
        }
        func push(_ value: Candidate) {
            open.append(value)
            var index = open.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard precedes(open[index], open[parent]) else { break }
                open.swapAt(index, parent)
                index = parent
            }
        }
        func pop() -> Candidate {
            if open.count == 1 { return open.removeLast() }
            let value = open[0]
            open[0] = open.removeLast()
            var index = 0
            while index * 2 + 1 < open.count {
                let left = index * 2 + 1, right = left + 1
                let child = right < open.count && precedes(open[right], open[left]) ? right : left
                guard precedes(open[child], open[index]) else { break }
                open.swapAt(index, child)
                index = child
            }
            return value
        }
        push(Candidate(point: source, score: 0, estimate: heuristic(source)))
        var costs = [source: 0]
        var previous: [SIMD2<Int>: SIMD2<Int>] = [:]
        var closed = Set<SIMD2<Int>>()
        while !open.isEmpty {
            let candidate = pop()
            let current = candidate.point
            guard !closed.contains(current), candidate.score == costs[current] else { continue }
            if current == goal {
                var points = [goal]
                while let parent = previous[points.last!] { points.append(parent) }
                points.reverse()
                let gridNodes = points.map { Node(slot: -1, index: 0, isStation: false, grid: $0) }
                // Authored seats are not grid-aligned. Keep the rounded grid
                // endpoints and join them with checked orthogonal connectors;
                // replacing them with the seat approach creates diagonal cuts.
                func connector(from a: SIMD3<Float>, to b: SIMD3<Float>) -> [Node]? {
                    if a == b { return [] }
                    for bend in [SIMD3<Float>(b.x, 0, a.z), SIMD3<Float>(a.x, 0, b.z)] {
                        let segments = [(a, bend), (bend, b)]
                        let clear = segments.allSatisfy { start, end in
                            [Float(0), 0.25, 0.5, 0.75, 1].allSatisfy { fraction in
                                let p = start + (end - start) * fraction
                                return isWalkable(p) && !occupied.contains { abs($0.x - p.x) < 0.8 && abs($0.z - p.z) < 0.8 }
                            }
                        }
                        if clear {
                            return bend == a || bend == b ? [] : [Node(slot: -1, index: 0, isStation: false, connectorPosition: bend)]
                        }
                    }
                    return nil
                }
                guard let head = connector(from: position(first), to: position(gridNodes[0])),
                      let tail = connector(from: position(gridNodes[gridNodes.count - 1]), to: position(last)) else { return [] }
                var nodes: [Node] = start.isStation ? [start, first] : [first]
                for node in head + gridNodes + tail {
                    if position(nodes.last!) != position(node) { nodes.append(node) }
                }
                if nodes.last == last { /* already at the destination approach */ }
                else if position(nodes.last!) == position(last) && nodes.last != first { nodes[nodes.count - 1] = last }
                else { nodes.append(last) }
                nodes.append(end)
                return nodes
            }
            closed.insert(current)
            for delta in [SIMD2<Int>(1,0), [-1,0], [0,1], [0,-1]] {
                let candidate = current &+ delta
                guard !closed.contains(candidate), allowed(candidate) else { continue }
                let score = costs[current, default: 0] + 1
                if score < costs[candidate, default: .max] {
                    previous[candidate] = current
                    costs[candidate] = score
                    push(Candidate(point: candidate, score: score, estimate: heuristic(candidate)))
                }
            }
        }
        return []
    }
}
