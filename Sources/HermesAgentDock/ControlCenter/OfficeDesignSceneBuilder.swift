import AppKit
import RealityKit
import simd

/// Original furniture with navigation captured from the rendered geometry.
@MainActor
final class OfficeDesignSceneBuilder {
    private let plaster = NSColor(srgbRed: 0.76, green: 0.80, blue: 0.87, alpha: 1)
    private let trim = NSColor(srgbRed: 0.19, green: 0.17, blue: 0.21, alpha: 1)
    private let floor = NSColor(srgbRed: 0.48, green: 0.39, blue: 0.37, alpha: 1)
    private let wood = NSColor(srgbRed: 0.39, green: 0.25, blue: 0.21, alpha: 1)
    private let paper = NSColor(srgbRed: 0.88, green: 0.88, blue: 0.85, alpha: 1)
    private let blue = NSColor(srgbRed: 0.28, green: 0.40, blue: 0.61, alpha: 1)
    private let orange = NSColor(srgbRed: 0.67, green: 0.30, blue: 0.17, alpha: 1)
    private let green = NSColor(srgbRed: 0.31, green: 0.43, blue: 0.16, alpha: 1)
    private let steel = NSColor(srgbRed: 0.48, green: 0.54, blue: 0.62, alpha: 1)
    private var meshes: [String: MeshResource] = [:]
    private var materials: [NSColor: SimpleMaterial] = [:]
    private var navigation = OfficeDesignNavigation()

    @discardableResult
    func build(in root: Entity, capacity: Int = 8) -> OfficeDesignNavigation {
        root.name = "authored-office-design"
        navigation = OfficeDesignNavigation()
        navigation.minX = -27
        navigation.maxX = 27
        navigation.back = -18
        navigation.front = max(32, Float((capacity + 3) / 4) * 4 + 21)
        box(root, "exterior-ground", [54, 0.12, navigation.front + 18], [0, -0.10, (navigation.front - 18) / 2], green)
        box(root, "west-wing-floor", [20, 0.18, 26], [-18, -0.09, 1], floor)
        box(root, "connecting-hall-floor", [3, 0.18, 26], [0, -0.09, 1], floor)
        box(root, "east-wing-floor", [20, 0.18, 28], [18, -0.09, 2], floor)
        wall(root, from: [-28, -12], to: [-8, -12])
        wall(root, from: [-1.5, -12], to: [1.5, -12])
        wall(root, from: [8, -12], to: [28, -12])
        wall(root, from: [28, -12], to: [28, 16])
        wall(root, from: [28, 16], to: [8, 16], height: 0.65)
        wall(root, from: [8, 14], to: [8, 16], height: 0.65)
        wall(root, from: [-28, -12], to: [-28, 14])
        wall(root, from: [-28, 14], to: [-8, 14], height: 0.65)
        for x in stride(from: Float(-25), through: -10, by: 3) { window(root, at: [x, 1.75, -11.84], yaw: 0, blinds: Int(x).isMultiple(of: 2)) }
        for x in stride(from: Float(10), through: 26, by: 3) { window(root, at: [x, 1.75, -11.84], yaw: 0, blinds: Int(x).isMultiple(of: 2)) }
        for z in stride(from: Float(-8), through: 11, by: 4) {
            window(root, at: [-27.84, 1.75, z], yaw: .pi / 2, blinds: z > 7)
            window(root, at: [27.84, 1.75, z], yaw: -.pi / 2, blinds: z > 7)
        }

        // Fourteen desks west, twelve east; all seats face their own keyboard.
        for (index, x) in [Float(-25), -20, -15, -10].enumerated() {
            workstationPod(root, at: [x, 0, -7.5], variant: index, seatCount: index == 3 ? 2 : 4)
        }
        for (index, p) in [SIMD3<Float>(11, 0, -6.5), [16, 0, -6.5], [24, 0, -8.5]].enumerated() {
            workstationPod(root, at: p, variant: index + 4)
        }
        for x: Float in [-23, -17, 11, 17] { cabinet(root, at: [x, 0, x < 0 ? -11.2 : -10.0]) }
        printer(root, at: [-9.5, 0, -10.6])

        // West-side focus suites open into a continuous, unobstructed corridor.
        for z: Float in [-3, 2.5, 8] { wall(root, from: [-28, z], to: [-22, z]) }
        for z: Float in [-3, 2.5] {
            wall(root, from: [-22, z], to: [-22, z + 3.5])
        }
        wall(root, from: [-22, 8], to: [-22, 8.5])
        wall(root, from: [-22, 10], to: [-22, 14])
        collaborationTable(root, center: [-25, 0, -0.25], seats: 4)
        collaborationTable(root, center: [-25, 0, 5.25], seats: 4)
        roomRug(root, name: "quiet-room-floor", center: [-25, 11], size: [5.7, 5.7])
        let quiet = group(root, "games-sofa", [-26.5, 0, 11], yaw: .pi / 2)
        couch(quiet, width: 2.1, color: orange)
        bookcase(root, at: [-24, 0, 8.6], yaw: 0)
        table(root, size: [0.7, 0.1, 1.1], at: [-24.2, 0, 11], height: 0.5, color: paper)
        // Phone booth: acoustic enclosure, small writing shelf and handset.
        wall(root, from: [-22, 10], to: [-18, 10])
        wall(root, from: [-18, 11.8], to: [-18, 14])
        table(root, size: [1.5, 0.1, 0.6], at: [-20, 0, 13.2], height: 1.05, color: wood)
        box(root, "phone-booth-handset", [0.12, 0.09, 0.36], [-20, 1.16, 13.2], trim)
        for x in stride(from: Float(-21.5), through: -18.5, by: 0.3) { box(root, "acoustic-slat", [0.10, 1.5, 0.08], [x, 1.5, 10.13], wood) }

        // Kanban room: two collaboration tables and a wall of planning boards.
        glassWall(root, from: [-19, -3], to: [-8, -3])
        glassWall(root, from: [-19, -3], to: [-19, 5.5])
        glassWall(root, from: [-19, 7.5], to: [-19, 8])
        glassWall(root, from: [-19, 8], to: [-12, 8])
        glassWall(root, from: [-10, 8], to: [-8, 8])
        glassWall(root, from: [-8, -3], to: [-8, 3])
        glassWall(root, from: [-8, 5], to: [-8, 8])
        collaborationTable(root, center: [-16, 0, 3], seats: 4)
        collaborationTable(root, center: [-11.5, 0, 3], seats: 6)
        planningBoard(root, at: [-13.5, 1.6, -2.8], width: 7)
        let kanbanSofa = group(root, "games-sofa", [-8.8, 0, 0], yaw: -.pi / 2)
        couch(kanbanSofa, width: 2, color: blue)

        // East wing: boardroom, café, storage and four restroom cubicles.
        wall(root, from: [20, -5], to: [28, -5])
        glassWall(root, from: [20, -5], to: [20, 2.5])
        glassWall(root, from: [20, 4.5], to: [20, 6])
        wall(root, from: [20, 6], to: [28, 6])
        collaborationTable(root, center: [24, 0, 0.5], seats: 10, registerReview: true)
        box(root, "boardroom-display-frame", [3, 1.5, 0.12], [24, 1.8, -4.8], trim)
        box(root, "boardroom-display", [2.8, 1.3, 0.03], [24, 1.8, -4.72], blue)
        wall(root, from: [8, -2], to: [20, -2])
        wall(root, from: [8, -2], to: [8, 1])
        wall(root, from: [8, 3], to: [8, 14])
        wall(root, from: [8, 8], to: [12, 8])
        wall(root, from: [14, 8], to: [17, 8])
        wall(root, from: [19, 8], to: [20, 8])
        wall(root, from: [15, 8], to: [15, 16])
        wall(root, from: [20, 6], to: [20, 10])
        wall(root, from: [20, 12], to: [20, 16])
        collaborationTable(root, center: [12.5, 0, 4.5], seats: 8)
        pantry(root, at: [18.5, 0, 1])
        for x: Float in [9.2, 11.2, 13.2] { storageShelf(root, at: [x, 0, 12.7]) }
        serverRack(root, at: [9.5, 0, 15.2])
        printer(root, at: [13.2, 0, 15.2])
        restrooms(root)
        for p: SIMD3<Float> in [[-26.5, 0, -10.5], [-17.5, 0, 6.7], [-9, 0, 7], [27, 0, -3.8], [26.5, 0, 4.5]] { plant(root, at: p, height: 1.6) }

        // Preserve the outdoor hangout, connected directly to the main entrance.
        box(root, "entrance-path-floor", [3, 0.035, 2], [0, -0.0175, 15], steel)
        let garden = group(root, "entrance-garden", [-11.5, 0, 14])
        outdoorArea(garden, capacity: max(12, capacity))
        for tree in garden.children.filter({ $0.name == "garden-tree" }) { tree.removeFromParent() }
        navigation.stations[.lounge] = navigation.stations[.lounge]?.map {
            .init(position: $0.position + [-11.5, 0, 14], approach: $0.approach + [-11.5, 0, 14], yaw: $0.yaw)
        }
        for p: SIMD3<Float> in [[-31, 0, -9], [-31, 0, 9], [31, 0, -10], [31, 0, 12], [-14, 0, 20], [14, 0, 23]] { gardenTree(root, at: p) }
        navigation.leisureSpots = [
            .init(station: .init(position: [17.25, 0, 1], approach: [16.5, 0, 1], yaw: .pi / 2, seated: false), action: .coffee),
            .init(station: .init(position: [-26.5, 0, 11], approach: [-25.25, 0, 11], yaw: .pi / 2), action: .reading),
            .init(station: .init(position: [-6, 0, 18], approach: [-6, 0, 17], yaw: 0, seated: false), action: .strolling),
            .init(station: .init(position: [7, 0, 21], approach: [7, 0, 20], yaw: -.pi / 2, seated: false), action: .socializing)
        ]
        for slot in 0..<capacity {
            if slot < 12 {
                let p = SIMD3<Float>(-17 + Float(slot % 6) * 1.2, 0, -1 + Float(slot / 6))
                navigation.stations[.kanbanBoard, default: []].append(.init(position: p, approach: p, yaw: .pi, seated: false))
            }
            if slot < 8 {
                let waiting = SIMD3<Float>(0, 0, 4 + Float(slot))
                navigation.stations[.waitingArea, default: []].append(.init(position: waiting, approach: waiting, yaw: .pi / 2, seated: false))
            }
        }
        interiorDetails(root)
        bringWingsTogether(root)
        captureObstacles(in: root)
        return navigation
    }

    /// Move intact furnished wings inward, rather than scaling chairs, doors or agents.
    private func bringWingsTogether(_ root: Entity) {
        let west = Entity(), east = Entity()
        west.name = "west-wing"
        east.name = "east-wing"
        for child in Array(root.children) where child.name != "entrance-garden" {
            if child.position.x <= -8 { west.addChild(child) }
            else if child.position.x >= 8 { east.addChild(child) }
        }
        west.position.x = 6.5
        east.position.x = -6.5
        root.addChild(west)
        root.addChild(east)
        func move(_ p: SIMD3<Float>) -> SIMD3<Float> {
            p + [p.x <= -8 ? 6.5 : (p.x >= 8 ? -6.5 : 0), 0, 0]
        }
        func station(_ s: OfficeDesignNavigation.Station) -> OfficeDesignNavigation.Station {
            .init(position: move(s.position), approach: move(s.approach), yaw: s.yaw, seated: s.seated)
        }
        for location in [OfficePreviewLocation.desk, .reviewTable, .kanbanBoard] {
            navigation.stations[location] = navigation.stations[location]?.map(station)
        }
        navigation.leisureSpots = navigation.leisureSpots.map { .init(station: station($0.station), action: $0.action) }
    }

    /// Static props share the builder's cached meshes/materials; no new update loops or lights.
    private func interiorDetails(_ root: Entity) {
        // A console and reading details fill the quiet end of the west corridor.
        table(root, size: [3, 0.1, 0.65], at: [-13.5, 0, 13.2], height: 0.85, color: wood)
        bookStack(root, at: [-14.3, 0.91, 13.2], count: 4)
        plant(root, at: [-12.5, 0.91, 13.2], height: 0.55)
        floorLamp(root, at: [-27, 0, 12.9])
        bookStack(root, at: [-24.2, 0.56, 10.9], count: 2)
        mug(root, at: [-24.2, 0.56, 11.35], color: blue)
        box(root, "quiet-sofa-pillow", [0.18, 0.38, 0.4], [-26.25, 0.8, 10.5], paper, radius: 0.06)
        wallArt(root, at: [-27.85, 1.8, 12.8], yaw: .pi / 2, color: orange)
        penCup(root, at: [-20.55, 1.11, 13.2])
        box(root, "phone-notebook", [0.35, 0.04, 0.4], [-19.55, 1.13, 13.2], blue)

        for z: Float in [-2.85, 2.65] {
            wallArt(root, at: [-25, 1.8, z], yaw: 0, color: blue)
            box(root, "wall-shelf", [1.5, 0.07, 0.3], [-23.25, 1.6, z + 0.12], wood)
            bookStack(root, at: [-23.45, 1.64, z + 0.12], count: 3)
        }
        // Board supplies are physical stationery, not invented Hermes task cards.
        box(root, "whiteboard-marker-tray", [3.2, 0.06, 0.22], [-13.5, 0.72, -2.65], steel)
        for index in 0..<4 {
            box(root, "whiteboard-marker", [0.18, 0.035, 0.035], [-14.5 + Float(index) * 0.35, 0.77, -2.65], index.isMultiple(of: 2) ? blue : orange)
        }
        box(root, "whiteboard-eraser", [0.22, 0.06, 0.1], [-12.35, 0.78, -2.65], trim)
        for p: SIMD3<Float> in [[-16, 0.97, 3.9], [-11.5, 0.97, 4.55], [-25, 0.97, 0.55], [-25, 0.97, 6.05]] {
            bookStack(root, at: p, count: 2)
            penCup(root, at: p + [0.5, 0, 0])
        }
        box(root, "conference-speaker", [0.48, 0.08, 0.48], [24, 1.01, -0.7], trim, radius: 0.1)
        for z: Float in [-1.7, 1.1, 2.4] { mug(root, at: [24.55, 0.97, z], color: paper) }
        laptop(root, at: [24, 0.98, -2.05])
        wallArt(root, at: [25.6, 1.8, 5.85], yaw: .pi, color: green)

        // Café crockery, food display and recycling station.
        for z: Float in [3, 4.5, 6] {
            oval(root, "cafe-plate", [0.42, 0.035, 0.42], [12.2, 0.98, z], paper)
            mug(root, at: [12.9, 0.97, z], color: blue)
        }
        box(root, "napkin-holder", [0.23, 0.16, 0.18], [12.6, 1.03, 5.25], wood)
        box(root, "napkins", [0.2, 0.22, 0.04], [12.6, 1.12, 5.25], paper)
        table(root, size: [2.6, 0.1, 0.7], at: [11, 0, -1.25], height: 0.9, color: wood)
        oval(root, "fruit-bowl", [0.65, 0.17, 0.5], [10.5, 1.04, -1.25], paper)
        for i in 0..<5 { oval(root, "fruit", [0.17, 0.18, 0.17], [10.3 + Float(i % 3) * 0.16, 1.15, -1.35 + Float(i / 3) * 0.19], i.isMultiple(of: 2) ? orange : green) }
        for i in 0..<4 { oval(root, "stacked-plate", [0.4, 0.035, 0.4], [11.65, 0.98 + Float(i) * 0.04, -1.25], paper) }
        for x: Float in [14.5, 15.25] { wasteBin(root, at: [x, 0, -1.35], color: x < 15 ? green : blue) }
        wallArt(root, at: [13.5, 1.9, -1.86], yaw: 0, color: orange)

        // Practical service-room props and bathroom accessories.
        for x: Float in [9.5, 10.5] {
            let cartons = group(root, "floor-detail", [x, 0, 9.2])
            for row in 0..<2 {
                box(cartons, "supply-carton", [0.7, 0.42, 0.6], [0, 0.21 + Float(row) * 0.43, 0], wood)
                box(cartons, "packing-tape", [0.1, 0.025, 0.62], [0, 0.43 + Float(row) * 0.43, 0], paper)
            }
        }
        for x: Float in [23, 25] {
            box(root, "soap-dispenser", [0.15, 0.22, 0.12], [x + 0.6, 1.06, 6.7], blue)
            box(root, "soap-pump", [0.16, 0.035, 0.04], [x + 0.6, 1.2, 6.7], steel)
        }
        box(root, "paper-towel-dispenser", [0.55, 0.45, 0.2], [26.6, 1.4, 6.2], paper)
        box(root, "paper-towel", [0.3, 0.25, 0.025], [26.6, 1.08, 6.32], paper)
        wasteBin(root, at: [26.6, 0, 7.1], color: steel)
        for i in 0..<4 { box(root, "toilet-roll", [0.15, 0.16, 0.22], [20.3 + Float(i) * 2, 0.85, 13.3], paper, radius: 0.06) }
    }

    private func bookStack(_ root: Entity, at p: SIMD3<Float>, count: Int) {
        for index in 0..<count {
            let book = group(root, "closed-book", p + [0, Float(index) * 0.065, 0], yaw: Float(index % 3 - 1) * 0.10)
            box(book, "book-cover", [0.4, 0.06, 0.29], [0, 0.03, 0], index.isMultiple(of: 2) ? blue : wood)
            box(book, "book-pages", [0.38, 0.038, 0.275], [0.015, 0.03, 0.005], paper)
        }
    }

    private func penCup(_ root: Entity, at p: SIMD3<Float>) {
        box(root, "pencil-cup", [0.12, 0.15, 0.12], p + [0, 0.075, 0], steel)
        for i in 0..<3 { box(root, "pencil", [0.018, 0.24, 0.018], p + [-0.035 + Float(i) * 0.035, 0.15, 0], i.isMultiple(of: 2) ? orange : blue) }
    }

    private func wallArt(_ root: Entity, at p: SIMD3<Float>, yaw: Float, color: NSColor) {
        let art = group(root, "framed-art", p, yaw: yaw)
        box(art, "art-frame", [1.45, 1.05, 0.07], .zero, wood)
        box(art, "art-mat", [1.32, 0.92, 0.025], [0, 0, 0.05], paper)
        box(art, "art-color-field", [0.72, 0.65, 0.012], [-0.18, 0.03, 0.072], color)
        oval(art, "art-disc", [0.48, 0.48, 0.018], [0.27, -0.1, 0.09], steel)
    }

    private func floorLamp(_ root: Entity, at p: SIMD3<Float>) {
        let lamp = group(root, "floor-detail", p)
        oval(lamp, "lamp-base", [0.42, 0.07, 0.42], [0, 0.04, 0], trim)
        box(lamp, "lamp-stem", [0.04, 1.6, 0.04], [0, 0.8, 0], steel)
        box(lamp, "lamp-shade", [0.58, 0.4, 0.58], [0, 1.6, 0], paper, radius: 0.08)
    }

    private func wasteBin(_ root: Entity, at p: SIMD3<Float>, color: NSColor) {
        let bin = group(root, "waste-bin", p)
        box(bin, "bin-body", [0.45, 0.65, 0.45], [0, 0.325, 0], color, radius: 0.05)
        box(bin, "bin-lid", [0.48, 0.07, 0.48], [0, 0.69, 0], trim, radius: 0.04)
        box(bin, "bin-opening", [0.26, 0.015, 0.17], [0, 0.735, 0], steel)
    }

    private func roomRug(_ root: Entity, name: String, center: SIMD2<Float>, size: SIMD2<Float>) {
        box(root, name, [size.x, 0.025, size.y], [center.x, 0.014, center.y], NSColor(srgbRed: 0.38, green: 0.37, blue: 0.46, alpha: 1))
    }

    private func collaborationTable(_ root: Entity, center: SIMD3<Float>, seats: Int, registerReview: Bool = false) {
        let pairs = seats / 2
        table(root, size: [1.7, 0.12, Float(pairs) * 1.3], at: center, height: 0.9, color: paper)
        for row in 0..<pairs {
            let z = (Float(row) - Float(pairs - 1) / 2) * 1.3
            for side: Float in [-1, 1] {
                let p = center + SIMD3<Float>(side * 1.55, 0, z)
                let yaw: Float = side < 0 ? .pi / 2 : -.pi / 2
                chair(root, at: p, yaw: yaw, color: blue)
                box(root, "meeting-notepad", [0.3, 0.025, 0.4], center + [side * 0.45, 0.98, z], wood)
                if registerReview { navigation.stations[.reviewTable, default: []].append(.init(position: p, approach: p + [side, 0, 0], yaw: yaw)) }
            }
        }
        plant(root, at: center + [0, 0.98, 0], height: 0.4)
    }

    private func planningBoard(_ root: Entity, at p: SIMD3<Float>, width: Float) {
        box(root, "planning-board-frame", [width, 1.7, 0.10], p, trim)
        box(root, "planning-board-surface", [width - 0.12, 1.58, 0.025], p + [0, 0, 0.065], paper)
        for column in 0..<5 {
            let x = -width / 2 + 0.7 + Float(column) * (width - 1.2) / 4
            box(root, "planning-column", [0.025, 1.4, 0.015], p + [x - 0.4, 0, 0.087], steel)
        }
    }

    private func serverRack(_ root: Entity, at p: SIMD3<Float>) {
        let rack = group(root, "server-rack", p)
        box(rack, "rack-case", [1.2, 2.1, 0.8], [0, 1.05, 0], trim)
        for row in 0..<7 {
            box(rack, "server-unit", [1.06, 0.22, 0.04], [0, 0.25 + Float(row) * 0.26, 0.43], steel)
            box(rack, "server-indicator", [0.04, 0.04, 0.025], [-0.35, 0.25 + Float(row) * 0.26, 0.46], green)
        }
    }

    private func storageShelf(_ root: Entity, at p: SIMD3<Float>) {
        let shelf = group(root, "storage-shelf", p)
        for x: Float in [-0.7, 0.7] { box(shelf, "shelf-upright", [0.06, 2.2, 0.7], [x, 1.1, 0], steel) }
        for y: Float in [0.2, 0.85, 1.5, 2.15] {
            box(shelf, "shelf-deck", [1.45, 0.06, 0.7], [0, y, 0], steel)
            if y < 2 { for x: Float in [-0.35, 0.35] {
                box(shelf, "archive-box", [0.55, 0.42, 0.55], [x, y + 0.24, 0], wood)
                box(shelf, "archive-label", [0.23, 0.12, 0.015], [x, y + 0.25, 0.285], paper)
            } }
        }
    }

    private func pantry(_ root: Entity, at p: SIMD3<Float>) {
        let counter = group(root, "coffee-counter", p, yaw: -.pi / 2)
        box(counter, "pantry-base", [4, 0.9, 0.75], [0, 0.45, 0], wood)
        box(counter, "countertop", [4.1, 0.1, 0.85], [0, 0.95, 0], paper)
        box(counter, "sink-basin", [0.8, 0.04, 0.5], [-1.2, 1.015, 0], steel)
        box(counter, "sink-tap", [0.05, 0.35, 0.05], [-1.2, 1.2, -0.25], steel)
        box(counter, "espresso-machine", [0.6, 0.5, 0.45], [0, 1.28, 0], trim, radius: 0.03)
        mug(counter, at: [0, 1.03, 0.28], color: paper)
        box(counter, "microwave", [0.7, 0.45, 0.5], [1.25, 1.25, 0], steel)
        box(counter, "microwave-window", [0.5, 0.28, 0.03], [1.2, 1.25, 0.27], trim)
        let fridge = group(root, "refrigerator", [18.5, 0, 5])
        box(fridge, "fridge-body", [0.9, 1.9, 0.85], [0, 0.95, 0], paper, radius: 0.04)
        box(fridge, "fridge-seam", [0.91, 0.025, 0.025], [0, 1.3, 0.44], steel)
        box(fridge, "fridge-handle", [0.05, 0.45, 0.05], [-0.3, 0.9, 0.48], steel)
    }

    private func restrooms(_ root: Entity) {
        roomRug(root, name: "restroom-floor", center: [24, 10.6], size: [7.7, 8.8])
        for index in 0..<4 {
            let x = Float(21 + index * 2)
            box(root, "stall-partition", [0.08, 2.1, 3], [x - 0.9, 1.05, 13.4], plaster)
            box(root, "toilet-tank", [0.65, 0.85, 0.3], [x, 0.425, 14.4], paper, radius: 0.05)
            oval(root, "toilet-bowl", [0.7, 0.45, 0.95], [x, 0.3, 13.9], paper)
            oval(root, "toilet-seat", [0.5, 0.025, 0.65], [x, 0.54, 13.9], trim)
            box(root, "stall-partition", [1.2, 1.9, 0.08], [x - 0.25, 1.05, 11.9], trim)
        }
        box(root, "vanity", [4, 0.9, 0.75], [24, 0.45, 6.7], wood)
        for x: Float in [23, 25] {
            oval(root, "washbasin", [0.85, 0.12, 0.55], [x, 0.95, 6.7], paper)
            box(root, "mirror", [1.2, 1, 0.04], [x, 1.8, 6.15], steel)
        }
    }

    private func gardenTree(_ root: Entity, at p: SIMD3<Float>) {
        let tree = group(root, "garden-tree", p)
        box(tree, "trunk", [0.4, 2.4, 0.4], [0, 1.2, 0], wood)
        for i in 0..<4 {
            let angle = Float(i) * .pi / 2
            box(tree, "tree-crown", [2, 2, 2], [sin(angle) * 0.65, 2.8 + Float(i % 2) * 0.4, cos(angle) * 0.65], green, radius: 0.6)
        }
    }

    private func outdoorArea(_ root: Entity, capacity: Int) {
        let depth = max(11, Float((capacity + 3) / 4) * 4 + 3)
        box(root, "patio-floor", [8, 0.035, depth], [11.5, -0.0175, 2 + depth / 2], steel)
        // The patio meets the office at z = 2; no overlapping path slab is needed.
        for z in stride(from: Float(3), through: 2 + depth, by: 1) { box(root, "paving-joint", [8, 0.003, 0.018], [11.5, 0.0015, z], plaster) }
        for x in stride(from: Float(8.5), through: 15, by: 1) { box(root, "paving-joint", [0.018, 0.003, depth], [x, 0.0015, 2 + depth / 2], plaster) }
        for index in 0..<((capacity + 3) / 4) {
            let p = SIMD3<Float>(10.5, 0, 6 + Float(index) * 4)
            table(root, size: [1.5, 0.10, 1.1], at: p, height: 0.75, color: wood)
            mug(root, at: p + [0.3, 0.82, 0], color: paper)
            for i in 0..<4 {
                let x: Float = i.isMultiple(of: 2) ? -1.5 : 1.5
                let z: Float = i < 2 ? -0.75 : 0.75
                let seat = p + SIMD3<Float>(x, 0, z)
                let yaw: Float = x < 0 ? .pi / 2 : -.pi / 2
                gardenChair(root, at: seat, yaw: yaw)
                navigation.stations[.lounge, default: []].append(.init(position: seat, approach: seat + [0, 0, z < 0 ? -1 : 1], yaw: yaw))
            }
        }
        for z: Float in [5, 10] {
            let bench = group(root, "garden-bench", [14.6, 0, z], yaw: -.pi / 2)
            for i in 0..<5 { box(bench, "bench-seat-slat", [2.1, 0.065, 0.1], [0, 0.48, -0.22 + Float(i) * 0.11], wood, radius: 0.015) }
            for y: Float in [0.76, 0.94] { box(bench, "bench-back-slat", [2.1, 0.14, 0.06], [0, y, -0.3], wood, radius: 0.015) }
            for x: Float in [-0.85, 0.85] {
                box(bench, "bench-leg", [0.08, 0.5, 0.5], [x, 0.25, 0], trim)
                box(bench, "bench-back-support", [0.07, 0.9, 0.07], [x, 0.55, -0.3], trim)
            }
        }
        let trees: [SIMD2<Float>] = [[-14, -11], [-15, 0], [-14, 10], [-7, 15], [3, 15], [19, -12], [20, 2], [20, 12]]
        for p in trees {
            let tree = group(root, "garden-tree", [p.x, 0, p.y])
            box(tree, "trunk", [0.35, 2.1, 0.35], [0, 1.05, 0], wood, radius: 0.05)
            for i in 0..<4 {
                let angle = Float(i) * .pi / 2
                box(tree, "tree-crown", [1.6, 1.6, 1.6], [sin(angle) * 0.65, 2.4 + Float(i % 2) * 0.5, cos(angle) * 0.65], green, radius: 0.5)
            }
            box(tree, "tree-bed", [2.6, 0.10, 2.6], [0, 0.05, 0], wood, radius: 0.2)
        }
        for z: Float in [3.5, 12] {
            let bed = group(root, "raised-planter", [14.5, 0, z])
            box(bed, "planter-box", [1.8, 0.5, 0.7], [0, 0.25, 0], wood)
            for x: Float in [-0.6, 0, 0.6] { plant(bed, at: [x, 0.5, 0], height: 0.7) }
        }
        for z: Float in [3, 8, 13] {
            let lamp = group(root, "garden-light", [16.5, 0, z])
            box(lamp, "light-post", [0.1, 1.1, 0.1], [0, 0.55, 0], trim)
            box(lamp, "light-diffuser", [0.23, 0.23, 0.23], [0, 1.16, 0], paper, radius: 0.04)
            box(lamp, "light-cap", [0.3, 0.05, 0.3], [0, 1.3, 0], trim)
        }
    }

    private func gardenChair(_ root: Entity, at p: SIMD3<Float>, yaw: Float) {
        let chair = group(root, "garden-chair", p, yaw: yaw)
        for i in 0..<4 { box(chair, "seat-slat", [0.62, 0.06, 0.11], [0, 0.5, -0.19 + Float(i) * 0.13], wood, radius: 0.01) }
        for y: Float in [0.76, 0.94] { box(chair, "back-slat", [0.62, 0.12, 0.05], [0, y, -0.29], wood, radius: 0.01) }
        for x: Float in [-0.27, 0.27] {
            for z: Float in [-0.25, 0.25] { box(chair, "chair-leg", [0.05, z < 0 ? 1 : 0.5, 0.05], [x, z < 0 ? 0.5 : 0.25, z], trim) }
        }
    }

    private func captureObstacles(in root: Entity) {
        let groups: Set<String> = ["wall", "glazed-partition", "open-door", "task-chair", "garden-chair", "garden-bench", "garden-tree", "raised-planter", "garden-light", "broad-leaf-plant", "filing-cabinet", "bookcase", "office-printer", "arcade-cabinet", "games-sofa", "visitor-armchair", "coffee-counter", "water-cooler", "waste-bin", "cleaning-cart", "staircase"]
        let parts: Set<String> = ["tabletop", "beanbag", "beanbag-back", "stall-partition", "vanity", "toilet-tank", "toilet-bowl", "coat-stand", "cross-divider-x", "cross-divider-z"]
        func visit(_ node: Entity) {
            if ["server-rack", "storage-shelf", "refrigerator", "reception-desk", "floor-detail"].contains(node.name) {
                let bounds = node.visualBounds(relativeTo: root)
                navigation.obstacles.append(.init(name: node.name, center: [bounds.center.x, bounds.center.z], size: [bounds.extents.x, bounds.extents.z]))
                return
            }
            if groups.contains(node.name) || parts.contains(node.name) {
                let bounds = node.visualBounds(relativeTo: root)
                if bounds.min.y < 1.6 { navigation.obstacles.append(.init(name: node.name, center: [bounds.center.x, bounds.center.z], size: [bounds.extents.x, bounds.extents.z])) }
                return
            }
            for child in node.children { visit(child) }
        }
        visit(root)
    }

    private func workstationPod(_ root: Entity, at p: SIMD3<Float>, variant: Int, seatCount: Int = 4) {
        let pod = group(root, "four-person-workstation", p)
        let desktop = NSColor(srgbRed: 0.41, green: 0.39, blue: 0.46, alpha: 1)
        box(pod, "cross-divider-x", [3.9, 1.1, 0.07], [0, 1.25, 0], plaster)
        box(pod, "cross-divider-z", [0.07, 1.1, 2.5], [0, 1.25, 0], plaster)
        for index in 0..<seatCount {
            let side: Float = index < 2 ? -1 : 1
            let x: Float = index.isMultiple(of: 2) ? -1 : 1
            let station = group(pod, "workstation-\(index)", [x, 0, side * 0.625], yaw: side < 0 ? .pi : 0)
            table(station, size: [1.8, 0.09, 1.05], at: .zero, height: 0.88, color: desktop)
            box(station, "drawer-unit", [0.45, 0.77, 0.75], [-0.59, 0.40, 0], trim)
            for y: Float in [0.22, 0.45, 0.68] {
                box(station, "drawer-front", [0.41, 0.20, 0.04], [-0.59, y, 0.40], steel)
                box(station, "drawer-label", [0.12, 0.05, 0.012], [-0.59, y, 0.425], paper)
            }
            let screen = group(station, "angled-monitor", [0.12, 0.94, -0.16], yaw: x * 0.22)
            monitor(screen)
            screen.findEntity(named: "monitor-display")?.name = "work-screen-\(navigation.stations[.desk, default: []].count)"
            box(station, "keyboard", [0.49, 0.035, 0.20], [0.12, 0.96, 0.25], trim)
            for row in 0..<3 {
                for key in 0..<9 { box(station, "key", [0.035, 0.01, 0.038], [-0.065 + Float(key) * 0.046, 0.983, 0.19 + Float(row) * 0.05], steel) }
            }
            box(station, "mouse-pad", [0.25, 0.015, 0.26], [0.56, 0.95, 0.23], trim)
            oval(station, "mouse", [0.08, 0.045, 0.12], [0.56, 0.98, 0.23], paper)
            box(station, "phone", [0.25, 0.07, 0.28], [-0.56, 0.98, -0.10], paper)
            box(station, "phone-display", [0.16, 0.015, 0.1], [-0.56, 1.025, -0.15], steel)
            box(station, "handset", [0.07, 0.06, 0.29], [-0.68, 1.04, -0.1], trim)
            mug(station, at: [0.65, 0.95, -0.29], color: index == 1 ? orange : paper)
            penCup(station, at: [-0.78, 0.94, -0.36])
            if (index + variant).isMultiple(of: 2) {
                bookStack(station, at: [-0.52, 0.94, 0.33], count: 2)
            } else {
                box(station, "photo-frame", [0.21, 0.25, 0.05], [0.54, 1.065, -0.37], wood)
                box(station, "photo-insert", [0.16, 0.19, 0.015], [0.54, 1.065, -0.335], blue)
            }
            let colors = [trim, blue, NSColor(srgbRed: 0.59, green: 0.56, blue: 0.37, alpha: 1), blue]
            chair(station, at: [0, 0, 1.125], yaw: .pi, color: colors[(index + variant) % 4])
            let seat = p + SIMD3<Float>(x, 0, side * 1.75)
            navigation.stations[.desk, default: []].append(.init(position: seat, approach: seat + [seat.x < p.x ? -1 : 1, 0, 0], yaw: side < 0 ? 0 : .pi))
        }
    }

    private func chair(_ root: Entity, at p: SIMD3<Float>, yaw: Float, color: NSColor) {
        let chair = group(root, "task-chair", p, yaw: yaw)
        box(chair, "seat", [0.61, 0.13, 0.58], [0, 0.5, 0], color, radius: 0.06)
        box(chair, "back", [0.59, 0.48, 0.12], [0, 0.83, -0.25], color, radius: 0.05)
        box(chair, "lift", [0.07, 0.38, 0.07], [0, 0.26, 0], steel)
        for x: Float in [-0.35, 0.35] {
            box(chair, "arm-support", [0.05, 0.20, 0.05], [x, 0.59, -0.05], trim)
            box(chair, "arm", [0.07, 0.05, 0.38], [x, 0.7, -0.02], trim)
        }
        for i in 0..<5 {
            let spoke = group(chair, "wheel-spoke", .zero, yaw: Float(i) * .pi * 2 / 5)
            box(spoke, "spoke", [0.05, 0.045, 0.34], [0, 0.10, 0.17], steel)
            oval(spoke, "wheel", [0.1, 0.10, 0.08], [0, 0.065, 0.33], trim)
        }
    }

    private func couch(_ root: Entity, width: Float, color: NSColor) {
        box(root, "sofa-base", [width, 0.3, 0.9], [0, 0.32, 0], wood, radius: 0.03)
        box(root, "sofa-back", [width, 0.72, 0.18], [0, 0.66, -0.38], color, radius: 0.05)
        let count = width > 2 ? 3 : 1
        let cushionWidth = (width - 0.3) / Float(count)
        for i in 0..<count {
            let x = -width / 2 + 0.15 + cushionWidth * (Float(i) + 0.5)
            box(root, "seat-cushion", [cushionWidth - 0.035, 0.2, 0.66], [x, 0.55, 0.05], color, radius: 0.06)
            box(root, "back-cushion", [cushionWidth - 0.035, 0.46, 0.15], [x, 0.79, -0.24], color, radius: 0.055)
        }
        for x in [-width / 2 + 0.075, width / 2 - 0.075] { box(root, "sofa-arm", [0.15, 0.46, 0.92], [x, 0.55, 0], color, radius: 0.04) }
    }

    private func plant(_ root: Entity, at p: SIMD3<Float>, height: Float) {
        let plant = group(root, "broad-leaf-plant", p)
        let scale = height / 1.8
        plant.scale = [scale, scale, scale]
        box(plant, "planter", [0.45, 0.45, 0.45], [0, 0.225, 0], wood, radius: 0.06)
        for i in 0..<7 {
            let stem = group(plant, "leaf-stem", [0, 0.35, 0], yaw: Float(i) * 2.4)
            let stalk = box(stem, "stalk", [0.025, 1.05, 0.025], [0, 0.52, 0.15], green)
            stalk.orientation = simd_quatf(angle: 0.28, axis: [1, 0, 0])
            let leaf = box(stem, "broad-leaf", [0.25, 0.025, 0.75], [0, 0.9 + Float(i % 3) * 0.2, 0.34], green, radius: 0.01)
            leaf.orientation = simd_quatf(angle: -0.7 + Float(i % 3) * 0.18, axis: [1, 0, 0])
            box(stem, "leaf-vein", [0.012, 0.013, 0.57], [0, 1.03 + Float(i % 3) * 0.15, 0.38], NSColor(srgbRed: 0.49, green: 0.57, blue: 0.24, alpha: 1))
        }
    }

    private func cabinet(_ root: Entity, at p: SIMD3<Float>, yaw: Float = 0) {
        let cabinet = group(root, "filing-cabinet", p, yaw: yaw)
        box(cabinet, "cabinet-body", [1, 1.55, 0.65], [0, 0.775, 0], trim)
        for i in 0..<4 {
            let y = 0.22 + Float(i) * 0.36
            box(cabinet, "drawer", [0.88, 0.31, 0.035], [0, y, 0.345], wood)
            box(cabinet, "handle", [0.24, 0.035, 0.035], [0, y + 0.035, 0.38], steel)
        }
        for i in 0..<5 { box(cabinet, "binder", [0.10, 0.3, 0.3], [-0.34 + Float(i) * 0.13, 1.71, 0], i.isMultiple(of: 2) ? blue : paper) }
    }

    private func bookcase(_ root: Entity, at p: SIMD3<Float>, yaw: Float) {
        let shelf = group(root, "bookcase", p, yaw: yaw)
        box(shelf, "back", [1.4, 2.1, 0.07], [0, 1.05, -0.2], wood)
        for x: Float in [-0.7, 0.7] { box(shelf, "side", [0.07, 2.1, 0.5], [x, 1.05, 0], trim) }
        for row in 0..<5 {
            let y = 0.12 + Float(row) * 0.48
            box(shelf, "shelf", [1.4, 0.06, 0.5], [0, y, 0], trim)
            for i in 0..<8 {
                let colors = [blue, orange, green, paper]
                box(shelf, "book", [0.105, 0.29 + Float(i % 3) * 0.035, 0.3], [-0.56 + Float(i) * 0.15, y + 0.2, 0], colors[(i + row) % 4])
            }
        }
    }

    private func printer(_ root: Entity, at p: SIMD3<Float>) {
        let printer = group(root, "office-printer", p)
        box(printer, "body", [0.8, 1.05, 0.7], [0, 0.525, 0], plaster)
        for y: Float in [0.3, 0.55, 0.8] { box(printer, "paper-drawer", [0.7, 0.025, 0.015], [0, y, 0.36], steel) }
        box(printer, "scanner", [0.85, 0.12, 0.75], [0, 1.12, 0], paper)
        box(printer, "scanner-glass", [0.6, 0.015, 0.48], [0, 1.19, 0], trim)
        box(printer, "output-tray", [0.65, 0.07, 0.55], [0, 0.85, 0.4], trim)
    }

    private func arcade(_ root: Entity, at p: SIMD3<Float>, yaw: Float) {
        let arcade = group(root, "arcade-cabinet", p, yaw: yaw)
        box(arcade, "cabinet", [0.8, 1.9, 0.65], [0, 0.95, 0], trim)
        box(arcade, "screen", [0.63, 0.64, 0.025], [0, 1.32, 0.34], blue)
        box(arcade, "marquee", [0.7, 0.18, 0.03], [0, 1.77, 0.34], paper)
        box(arcade, "controls", [0.84, 0.12, 0.45], [0, 0.92, 0.4], orange)
        box(arcade, "joystick", [0.04, 0.15, 0.04], [-0.2, 1.05, 0.45], steel)
        oval(arcade, "joystick-ball", [0.1, 0.1, 0.1], [-0.2, 1.13, 0.45], trim)
        for x: Float in [0.1, 0.25] { oval(arcade, "button", [0.09, 0.025, 0.09], [x, 1, 0.45], blue) }
    }

    private func beanbag(_ root: Entity, at p: SIMD3<Float>, color: NSColor) {
        box(root, "beanbag", [1.3, 0.75, 1.2], p + [0, 0.38, 0], color, radius: 0.3)
        box(root, "beanbag-back", [1.05, 0.6, 0.6], p + [0, 0.75, -0.24], color, radius: 0.25)
    }

    private func monitor(_ root: Entity) {
        box(root, "monitor-base", [0.36, 0.035, 0.24], [0, 0.02, 0], trim)
        box(root, "monitor-neck", [0.065, 0.25, 0.07], [0, 0.15, 0], steel)
        box(root, "monitor-bezel", [0.73, 0.48, 0.07], [0, 0.42, 0], trim)
        box(root, "monitor-display", [0.66, 0.4, 0.012], [0, 0.42, 0.041], NSColor(srgbRed: 0.13, green: 0.17, blue: 0.23, alpha: 1))
    }

    private func laptop(_ root: Entity, at p: SIMD3<Float>) {
        box(root, "laptop-base", [0.6, 0.035, 0.42], p, steel)
        box(root, "laptop-keyboard", [0.51, 0.015, 0.2], p + [0, 0.026, -0.035], trim)
        box(root, "laptop-lid", [0.6, 0.4, 0.035], p + [0, 0.2, -0.2], trim)
        box(root, "laptop-screen", [0.53, 0.33, 0.01], p + [0, 0.2, -0.177], blue)
    }

    private func mug(_ root: Entity, at p: SIMD3<Float>, color: NSColor) {
        box(root, "mug", [0.12, 0.15, 0.12], p + [0, 0.075, 0], color, radius: 0.025)
        box(root, "coffee", [0.085, 0.01, 0.085], p + [0, 0.152, 0], wood)
        box(root, "mug-handle", [0.065, 0.07, 0.03], p + [0.085, 0.08, 0], color, radius: 0.01)
    }

    private func table(_ root: Entity, size: SIMD3<Float>, at p: SIMD3<Float>, height: Float, color: NSColor) {
        box(root, "tabletop", size, p + [0, height, 0], color, radius: 0.025)
        for x in [-size.x / 2 + 0.13, size.x / 2 - 0.13] {
            for z in [-size.z / 2 + 0.13, size.z / 2 - 0.13] { box(root, "table-leg", [0.075, height, 0.075], p + [x, height / 2, z], trim) }
        }
    }

    private func wall(_ root: Entity, from a: SIMD2<Float>, to b: SIMD2<Float>, height: Float = 2.9) {
        let d = b - a
        let center = (a + b) / 2
        let wall = group(root, "wall", [center.x, 0, center.y], yaw: -atan2(d.y, d.x))
        if abs(d.x) > 0.01 && abs(d.y) > 0.01 {
            // Narrow segments retain the angled outline in the navigation grid.
            // A single axis-aligned bounding box would block an entire wedge of rooms.
            wall.name = "angled-wall"
            let count = Int(ceil(simd_length(d) / 0.25))
            for index in 0..<count {
                let start = a + d * (Float(index) / Float(count))
                let end = a + d * (Float(index + 1) / Float(count))
                navigation.obstacles.append(.init(name: "angled-wall", center: (start + end) / 2,
                    size: [abs(end.x - start.x) + 0.24, abs(end.y - start.y) + 0.24]))
            }
        }
        box(wall, "plaster-wall", [simd_length(d), height, 0.18], [0, height / 2, 0], plaster)
        box(wall, "wall-cap", [simd_length(d) + 0.05, 0.075, 0.23], [0, height, 0], paper)
        box(wall, "skirting", [simd_length(d), 0.14, 0.22], [0, 0.07, 0], paper)
    }

    private func glassWall(_ root: Entity, from a: SIMD2<Float>, to b: SIMD2<Float>) {
        let d = b - a
        let center = (a + b) / 2
        let length = simd_length(d)
        let frame = group(root, "glazed-partition", [center.x, 0, center.y], yaw: -atan2(d.y, d.x))
        for y: Float in [0.1, 2.45, 2.9] { box(frame, "frame-rail", [length, 0.07, 0.08], [0, y, 0], trim) }
        let panels = Int(ceil(length / 1.5))
        for i in 0...panels {
            let x = -length / 2 + Float(i) * length / Float(panels)
            box(frame, "frame-upright", [0.075, 2.9, 0.08], [x, 1.45, 0], trim)
        }
        let glass = SimpleMaterial(color: NSColor(srgbRed: 0.69, green: 0.79, blue: 0.85, alpha: 0.10), roughness: 0.7, isMetallic: false)
        let pane = ModelEntity(mesh: .generateBox(size: [length - 0.1, 2.75, 0.018]), materials: [glass])
        pane.position = [0, 1.45, 0]
        frame.addChild(pane)
    }

    private func window(_ root: Entity, at p: SIMD3<Float>, yaw: Float, blinds: Bool) {
        let window = group(root, "window", p, yaw: yaw)
        box(window, "window-trim", [1.9, 1.35, 0.08], .zero, trim)
        box(window, "green-view", [1.74, 1.17, 0.02], [0, 0, 0.055], green)
        for x: Float in [-0.45, 0, 0.45] { box(window, "mullion", [0.035, 1.2, 0.03], [x, 0, 0.08], trim) }
        box(window, "crossbar", [1.76, 0.04, 0.03], [0, -0.12, 0.08], trim)
        box(window, "sill", [2.04, 0.08, 0.23], [0, -0.7, 0.1], paper)
        let slats = blinds ? 13 : 3
        for row in 0..<slats { box(window, "blind-slat", [1.82, 0.065, 0.06], [0, 0.58 - Float(row) * 0.078, 0.12], paper) }
        box(window, "blind-rail", [2.03, 0.10, 0.15], [0, 0.75, 0.1], trim)
    }

    private func door(_ root: Entity, position: SIMD3<Float>, yaw: Float) {
        let door = group(root, "open-door", position, yaw: yaw)
        box(door, "door-leaf", [1.25, 2.45, 0.09], [0.625, 1.225, 0], trim)
        box(door, "door-panel", [1.03, 2.19, 0.015], [0.625, 1.225, 0.055], wood)
        box(door, "door-handle", [0.16, 0.04, 0.06], [1.1, 1.1, 0.10], steel)
    }

    @discardableResult
    private func group(_ root: Entity, _ name: String, _ p: SIMD3<Float>, yaw: Float = 0) -> Entity {
        let entity = Entity()
        entity.name = name
        entity.position = p
        entity.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        root.addChild(entity)
        return entity
    }

    @discardableResult
    private func box(_ root: Entity, _ name: String, _ size: SIMD3<Float>, _ p: SIMD3<Float>, _ color: NSColor, radius: Float = 0) -> ModelEntity {
        let key = "\(size)-\(radius)"
        let mesh: MeshResource
        if let cached = meshes[key] { mesh = cached }
        else { mesh = .generateBox(size: size, cornerRadius: radius); meshes[key] = mesh }
        let material: SimpleMaterial
        if let cached = materials[color] { material = cached }
        else { material = SimpleMaterial(color: color, roughness: 1, isMetallic: false); materials[color] = material }
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = name
        entity.position = p
        root.addChild(entity)
        if name.hasSuffix("floor") || name == "exterior-ground" { entity.generateCollisionShapes(recursive: false) }
        return entity
    }

    private func oval(_ root: Entity, _ name: String, _ size: SIMD3<Float>, _ p: SIMD3<Float>, _ color: NSColor) {
        let key = "sphere"
        let mesh = meshes[key] ?? MeshResource.generateSphere(radius: 0.5)
        meshes[key] = mesh
        let entity = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: color, roughness: 1, isMetallic: false)])
        entity.name = name
        entity.scale = size
        entity.position = p
        root.addChild(entity)
    }
}
