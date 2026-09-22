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
    private let cork = NSColor(srgbRed: 0.48, green: 0.29, blue: 0.13, alpha: 1)
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
        // The building and the two-seat patio have a fixed footprint. Bot
        // count no longer expands the exterior into an empty field.
        navigation.minX = -24
        navigation.maxX = max(24, 24.5 + Float(max(0, capacity - 1) / 20) * 1.5)
        navigation.back = -14
        navigation.front = 28
        box(root, "exterior-ground", [navigation.maxX + 24, 0.12, 42], [(navigation.maxX - 24) / 2, -0.10, 7], green)
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
        // The server-room wall stays solid. East-wing windows are independent.
        for z in stride(from: Float(-8), through: 11, by: 4) {
            if z != 8 { window(root, at: [-27.84, 1.75, z], yaw: .pi / 2, blinds: false) }
            window(root, at: [27.84, 1.75, z], yaw: -.pi / 2, blinds: z > 7)
        }

        // Fourteen shared desks west, eight east, and one private office.
        for (index, x) in [Float(-25), -20, -15, -10].enumerated() {
            workstationPod(root, at: [x, 0, -7.5], variant: index, seatCount: index == 3 ? 2 : 4)
        }
        for (index, p) in [SIMD3<Float>(11, 0, -6.5), [16, 0, -6.5]].enumerated() {
            workstationPod(root, at: p, variant: index + 4)
        }
        mainAgentOffice(root)
        box(root, "expansion-bay-floor", [11.6, 0.025, 7.2], [13.6, 0.014, -6.5], steel)
        let baySign = group(root, "expansion-bay-sign", [9, 0.04, -3.2])
        baySign.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        roomLabel(baySign, title: "BOT WORKSHOP", at: .zero)
        for x: Float in [-23, -17, 11, 17] { cabinet(root, at: [x, 0, x < 0 ? -11.2 : -10.0]) }
        printer(root, at: [-9.5, 0, -10.6])

        // West-side focus suites open into a continuous, unobstructed corridor.
        for z: Float in [-3, 2.5, 8] { wall(root, from: [-28, z], to: [-22, z]) }
        for z: Float in [-3, 2.5] {
            wall(root, from: [-22, z], to: [-22, z + 3.5])
        }
        wall(root, from: [-22, 8], to: [-22, 8.5])
        wall(root, from: [-22, 10], to: [-22, 14])
        designStudio(root)
        verificationLab(root)
        serverRoom(root)
        // The former phone booth is now the adjoining operations console.
        wall(root, from: [-22, 10], to: [-18, 10])
        wall(root, from: [-18, 11.8], to: [-18, 14])
        operationsRoom(root)

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
        missionControl(root)
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
        outdoorArea(garden)
        for tree in garden.children.filter({ $0.name == "garden-tree" }) { tree.removeFromParent() }
        navigation.stations[.lounge] = navigation.stations[.lounge]?.map {
            .init(position: $0.position + [-11.5, 0, 14], approach: $0.approach + [-11.5, 0, 14], yaw: $0.yaw)
        }
        let landscape = group(root, "exterior-landscape", .zero)
        // All trees live in the lower entrance garden. The varied offsets are
        // deterministic so the scene feels organic without moving on refresh.
        for (position, scale) in [
            (SIMD3<Float>(-21, 0, 18), Float(0.72)),
            (SIMD3<Float>(-21, 0, 24.8), Float(0.58)),
            (SIMD3<Float>(20.5, 0, 24.8), Float(0.66)),
            (SIMD3<Float>(21, 0, 20.5), Float(0.78))
        ] {
            gardenTree(landscape, at: position, scale: scale)
        }
        navigation.leisureSpots = [
            .init(station: .init(position: [17.25, 0, 1], approach: [16.5, 0, 1], yaw: .pi / 2, seated: false), action: .coffee),
            .init(station: .init(position: [-8.8, 0, 0], approach: [-10, 0, 0], yaw: -.pi / 2), action: .reading),
            .init(station: .init(position: [-5, 0, 10], approach: [-5, 0, 9], yaw: 0, seated: false), action: .strolling),
            .init(station: .init(position: [-0.65, 0, 4], approach: [-0.65, 0, 3], yaw: .pi / 2, seated: false), action: .socializing),
            .init(station: .init(position: [0.65, 0, 4], approach: [0.65, 0, 3], yaw: -.pi / 2, seated: false), action: .socializing),
            .init(station: .init(position: [0, 0, -5], approach: [0, 0, -5], yaw: 0, seated: false), action: .strolling),
            .init(station: .init(position: [0, 0, 9], approach: [0, 0, 9], yaw: 0, seated: false), action: .strolling),
            .init(station: .init(position: [0, 0, 12], approach: [0, 0, 12], yaw: .pi, seated: false), action: .strolling)
        ]
        outdoorLandscape(landscape)
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
        for child in Array(root.children) where child.name != "entrance-garden" && child.name != "exterior-landscape" {
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
        navigation.leisureSpots = navigation.leisureSpots.map { $0.isOutdoor ? $0 : .init(station: station($0.station), action: $0.action) }
    }

    /// Static props share the builder's cached meshes/materials; no new update loops or lights.
    private func interiorDetails(_ root: Entity) {
        // A console and reading details fill the quiet end of the west corridor.
        table(root, size: [3, 0.1, 0.65], at: [-13.5, 0, 13.2], height: 0.85, color: wood)
        bookStack(root, at: [-14.3, 0.91, 13.2], count: 4)
        plant(root, at: [-12.5, 0.91, 13.2], height: 0.55)
        bookcase(root, at: [-9.3, 0, -2.35], yaw: 0)
        // Board supplies are physical stationery, not invented Hermes task cards.
        box(root, "whiteboard-marker-tray", [3.2, 0.06, 0.22], [-13.5, 0.72, -2.65], steel)
        for index in 0..<4 {
            box(root, "whiteboard-marker", [0.18, 0.035, 0.035], [-14.5 + Float(index) * 0.35, 0.77, -2.65], index.isMultiple(of: 2) ? blue : orange)
        }
        box(root, "whiteboard-eraser", [0.22, 0.06, 0.1], [-12.35, 0.78, -2.65], trim)
        for p: SIMD3<Float> in [[-16, 0.97, 3.9], [-11.5, 0.97, 4.55]] {
            bookStack(root, at: p, count: 2)
            penCup(root, at: p + [0.5, 0, 0])
        }
        box(root, "conference-speaker", [0.48, 0.08, 0.48], [24, 1.01, -0.7], trim, radius: 0.1)
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

    // Specialist rooms use the same cached geometry and obstacle capture as
    // the original office. Screens are physical props, with no invented telemetry.
    private func mainAgentOffice(_ root: Entity) {
        // Reuse the exterior and Mission Control walls. A two-unit doorway
        // opens west into the workshop corridor, clear of the neighboring pod.
        wall(root, from: [20, -12], to: [20, -9])
        wall(root, from: [20, -7], to: [20, -5])
        box(root, "main-office-floor", [7.7, 0.025, 6.7], [24, 0.014, -8.5], steel)
        let sign = group(root, "main-office-sign", [26.4, 2.55, -5.14], yaw: .pi)
        roomLabel(sign, title: "MAIN AGENT", at: .zero)
        let desk = group(root, "main-agent-desk", [24.5, 0, -9.6])
        table(desk, size: [3.2, 0.12, 1.3], at: .zero, height: 0.9, color: paper)
        box(desk, "desk-writing-mat", [2.1, 0.015, 0.9], [0, 0.97, 0], trim)
        for (index, x) in [Float(-0.48), 0.48].enumerated() {
            let display = group(desk, "main-office-monitor-\(index)", [x, 0.99, -0.23])
            oval(display, "monitor-foot", [0.36, 0.035, 0.25], [0, 0.02, 0], trim)
            box(display, "monitor-neck", [0.055, 0.22, 0.06], [0, 0.13, 0], steel)
            box(display, "monitor-bezel", [0.94, 0.52, 0.055], [0, 0.43, 0], trim)
            box(display, "monitor-display", [0.89, 0.47, 0.012], [0, 0.43, 0.034], NSColor(srgbRed: 0.13, green: 0.17, blue: 0.23, alpha: 1))
            display.findEntity(named: "monitor-display")?.name = index == 0 ? "work-screen-22" : "main-office-extended-screen"
        }
        detailedKeyboard(desk, at: [0, 0.98, 0.32])
        oval(desk, "main-office-mouse", [0.085, 0.045, 0.14], [0.52, 1, 0.32], trim)
        box(desk, "mouse-scroll-wheel", [0.012, 0.012, 0.025], [0.52, 1.024, 0.30], steel)
        // The laptop is the single computer, driving the two external monitors.
        let notebook = group(desk, "main-office-computer", [1.17, 0.98, 0.08], yaw: -0.15)
        laptop(notebook, at: .zero)
        let keys = group(notebook, "laptop-key-detail", [0, 0.035, -0.035])
        keys.scale = [0.65, 0.4, 0.65]
        detailedKeyboard(keys, at: .zero)
        box(notebook, "laptop-trackpad", [0.20, 0.008, 0.10], [0, 0.026, 0.13], steel)
        let cabinet = group(desk, "floor-detail", [1.08, 0, 0])
        box(cabinet, "desk-storage-cabinet", [0.65, 0.79, 0.85], [0, 0.41, 0], paper)
        box(cabinet, "cabinet-door-inset", [0.57, 0.70, 0.025], [0, 0.42, 0.44], steel)
        oval(cabinet, "cabinet-lock", [0.025, 0.025, 0.015], [0.18, 0.60, 0.46], trim)
        studioDeskAccessories(desk)
        studioCopier(root, at: [22.05, 0, -10.1])
        chair(root, at: [24.5, 0, -8], yaw: .pi, color: trim, highBack: true)
        navigation.stations[.desk, default: []].append(.init(position: [24.5, 0, -8], approach: [23.25, 0, -8], yaw: .pi))
        bookcase(root, at: [27.25, 0, -6.5], yaw: -.pi / 2)
        plant(root, at: [27, 0, -10.7], height: 1.6)
        floorLamp(root, at: [26.6, 0, -7.8])
        wallArt(root, at: [22, 1.7, -5.14], yaw: .pi, color: blue)
    }

    private func detailedKeyboard(_ root: Entity, at p: SIMD3<Float>) {
        let keyboard = group(root, "detailed-keyboard", p)
        box(keyboard, "keyboard-case", [0.69, 0.035, 0.25], .zero, trim, radius: 0.012)
        for row in 0..<4 {
            for column in 0..<13 {
                box(keyboard, "keycap", [0.039, 0.012, 0.038], [-0.3 + Float(column) * 0.05, 0.023, -0.09 + Float(row) * 0.05], steel, radius: 0.004)
            }
        }
        box(keyboard, "spacebar", [0.25, 0.012, 0.035], [-0.025, 0.023, 0.103], steel, radius: 0.004)
    }

    private func studioDeskAccessories(_ root: Entity) {
        // Compact speakers, dock, drawing tablet and camera from the reference.
        for x: Float in [-1.17, 1.17] {
            box(root, "desktop-speaker", [0.18, 0.30, 0.19], [x, 1.12, -0.43], paper, radius: 0.012)
            box(root, "speaker-grille", [0.14, 0.24, 0.018], [x, 1.13, -0.324], trim)
            oval(root, "speaker-cone", [0.08, 0.08, 0.012], [x, 1.13, -0.31], steel)
        }
        box(root, "monitor-dock", [0.25, 0.05, 0.13], [0, 1, -0.38], steel, radius: 0.01)
        box(root, "drawing-tablet", [0.38, 0.022, 0.27], [-0.87, 0.99, 0.38], trim, radius: 0.015)
        box(root, "tablet-stylus", [0.015, 0.015, 0.22], [-1.10, 1.01, 0.38], steel)
        box(root, "camera-body", [0.23, 0.15, 0.12], [-0.79, 1.05, 0.03], trim, radius: 0.018)
        oval(root, "camera-lens-barrel", [0.12, 0.12, 0.13], [-0.79, 1.06, 0.13], trim)
        oval(root, "camera-lens-glass", [0.085, 0.085, 0.018], [-0.79, 1.06, 0.2], blue)
        // Two articulated links make the microphone boom read as hardware.
        box(root, "microphone-clamp", [0.08, 0.16, 0.10], [-1.48, 0.96, 0.22], trim)
        accessoryArm(root, from: [-1.48, 1.04, 0.22], to: [-1.42, 1.42, -0.05])
        accessoryArm(root, from: [-1.42, 1.42, -0.05], to: [-0.92, 1.65, 0.13])
        oval(root, "microphone-capsule", [0.25, 0.09, 0.09], [-0.83, 1.60, 0.13], trim)
        oval(root, "microphone-grille", [0.10, 0.095, 0.095], [-0.69, 1.60, 0.13], steel)
    }

    private func accessoryArm(_ root: Entity, from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let arm = box(root, "articulated-arm", [0.025, simd_length(b - a), 0.025], (a + b) / 2, steel)
        arm.orientation = simd_quatf(from: [0, 1, 0], to: simd_normalize(b - a))
        oval(root, "arm-joint", [0.07, 0.07, 0.07], b, trim)
    }

    private func studioCopier(_ root: Entity, at p: SIMD3<Float>) {
        let copier = group(root, "office-printer", p)
        box(copier, "copier-cabinet", [1.15, 0.95, 0.95], [0, 0.48, 0], paper)
        box(copier, "copier-output-recess", [1.08, 0.18, 0.97], [0, 0.91, 0.01], trim)
        box(copier, "scanner-body", [1.22, 0.17, 1.0], [0, 1.08, 0], paper)
        box(copier, "scanner-lid", [0.84, 0.045, 0.75], [0.06, 1.19, -0.03], steel)
        let feeder = box(copier, "document-feeder", [0.62, 0.04, 0.5], [0.06, 1.28, -0.08], paper)
        feeder.orientation = simd_quatf(angle: -0.17, axis: [1, 0, 0])
        box(copier, "copier-touch-panel", [0.24, 0.14, 0.055], [0.40, 1.12, 0.53], trim)
        box(copier, "copier-control-glass", [0.19, 0.09, 0.012], [0.4, 1.12, 0.566], blue)
        box(copier, "output-paper", [0.42, 0.012, 0.3], [0, 0.85, 0.46], paper)
        // Reference-style task lamp sits on the copier's spare corner.
        oval(copier, "task-lamp-base", [0.24, 0.035, 0.24], [-0.43, 1.19, -0.3], trim)
        accessoryArm(copier, from: [-0.43, 1.21, -0.3], to: [-0.55, 1.64, -0.3])
        accessoryArm(copier, from: [-0.55, 1.64, -0.3], to: [-0.12, 1.94, -0.3])
        box(copier, "task-lamp-shade", [0.25, 0.14, 0.20], [-0.07, 1.9, -0.3], trim, radius: 0.035)
        box(copier, "task-lamp-diffuser", [0.20, 0.014, 0.15], [-0.07, 1.82, -0.3], paper)
    }

    private func designStudio(_ root: Entity) {
        box(root, "design-studio-floor", [5.7, 0.025, 5.2], [-25, 0.014, -0.25], wood)
        roomLabel(root, title: "DESIGN STUDIO", at: [-26.6, 2.64, -2.86])
        investigationBoard(root, at: [-25.9, 1.45, -2.84], yaw: 0)
        // Angled drawing surface, edge rail, scale model and drafting tools.
        let desk = group(root, "design-drafting-desk", [-25.8, 0, -0.4])
        table(desk, size: [2.3, 0.12, 1.3], at: .zero, height: 0.93, color: wood)
        let drawing = box(desk, "drawing-board", [2.15, 0.08, 1.18], [0, 1.04, 0], paper)
        drawing.orientation = simd_quatf(angle: 0.14, axis: [1, 0, 0])
        box(desk, "drafting-edge-rail", [2.15, 0.06, 0.035], [0, 1.0, 0.57], trim)
        box(desk, "drafting-ruler", [0.85, 0.015, 0.06], [-0.45, 1.17, -0.28], steel)
        box(desk, "model-plinth", [0.55, 0.05, 0.45], [0.55, 1.17, -0.2], wood)
        for i in 0..<3 {
            box(desk, "architectural-model", [0.12, 0.16 + Float(i) * 0.08, 0.28], [0.38 + Float(i) * 0.16, 1.27 + Float(i) * 0.04, -0.2], paper)
        }
        chair(root, at: [-25.8, 0, 1.05], yaw: .pi, color: orange)
        let swatches = group(root, "material-sample-board", [-23.35, 1.6, -2.83])
        box(swatches, "sample-backing", [1.15, 1.5, 0.05], .zero, paper)
        let colors = [wood, orange, steel, blue, green, cork]
        for (i, color) in colors.enumerated() {
            box(swatches, "material-swatch", [0.40, 0.34, 0.04], [-0.25 + Float(i % 2) * 0.5, 0.46 - Float(i / 2) * 0.46, 0.05], color)
        }
        // Flat-file cabinet doubles as a print and prototype work surface.
        let cabinet = group(root, "floor-detail", [-23.2, 0, -1.4])
        box(cabinet, "flat-file-cabinet", [1.25, 0.9, 0.75], [0, 0.45, 0], steel)
        for y: Float in [0.18, 0.36, 0.54, 0.72] {
            box(cabinet, "wide-drawing-drawer", [1.14, 0.14, 0.03], [0, y, 0.39], paper)
            box(cabinet, "drawing-drawer-pull", [0.28, 0.025, 0.04], [0, y, 0.42], trim)
        }
        penCup(cabinet, at: [0.35, 0.9, 0])
        bookStack(cabinet, at: [-0.3, 0.9, 0], count: 3)
        floorLamp(root, at: [-27.35, 0, 1.6])
    }

    private func verificationLab(_ root: Entity) {
        box(root, "verification-lab-floor", [5.7, 0.025, 5.2], [-25, 0.014, 5.25], steel)
        roomLabel(root, title: "QA / VERIFICATION", at: [-27.1, 2.6, 2.64])
        table(root, size: [4.4, 0.12, 0.95], at: [-25, 0, 3.4], height: 0.95, color: paper)
        for x: Float in [-26.35, -24.9] {
            let display = group(root, "lab-monitor", [x, 1.02, 3.25])
            monitor(display)
            box(root, "lab-keyboard", [0.5, 0.035, 0.2], [x, 1.04, 3.65], trim)
            chair(root, at: [x, 0, 4.85], yaw: .pi, color: steel)
        }
        // Upright phone/tablet fixtures and physical instrumentation.
        for i in 0..<3 {
            let device = group(root, "test-device", [-23.9 + Float(i) * 0.36, 1.03, 3.5])
            box(device, "device-stand", [0.28, 0.035, 0.28], .zero, trim)
            box(device, "device-frame", [0.23, 0.42, 0.035], [0, 0.22, -0.04], trim, radius: 0.02)
            box(device, "device-glass", [0.19, 0.34, 0.012], [0, 0.23, -0.015], blue)
        }
        let bench = group(root, "floor-detail", [-26.8, 0, 6.85])
        box(bench, "equipment-cart", [1.45, 0.75, 0.65], [0, 0.4, 0], paper)
        box(bench, "instrument-case", [0.85, 0.42, 0.48], [0, 0.99, 0], trim)
        box(bench, "instrument-glass", [0.49, 0.28, 0.025], [-0.1, 1, 0.25], blue)
        for y: Float in [0.91, 1.08] { oval(bench, "instrument-dial", [0.08, 0.08, 0.03], [0.3, y, 0.27], steel) }
        for x: Float in [-0.57, 0.57] { oval(bench, "cart-wheel", [0.13, 0.16, 0.13], [x, 0.08, 0], trim) }
        let tools = group(root, "lab-tool-wall", [-25, 1.85, 2.65])
        box(tools, "tool-panel", [3.4, 0.7, 0.04], .zero, trim)
        for i in 0..<9 {
            box(tools, "tool-hook", [0.025, 0.05, 0.05], [-1.4 + Float(i) * 0.35, 0.16, 0.045], steel)
            box(tools, "bench-tool", [0.055, 0.34, 0.055], [-1.4 + Float(i) * 0.35, -0.05, 0.08], i.isMultiple(of: 2) ? orange : steel)
        }
    }

    private func serverRoom(_ root: Entity) {
        box(root, "server-room-floor", [5.7, 0.025, 5.7], [-25, 0.014, 11], trim)
        roomLabel(root, title: "SERVER / OPERATIONS", at: [-27.2, 2.65, 8.14])
        for x: Float in [-26.8, -25.1, -23.4] {
            serverRack(root, at: [x, 0, 12.8], yaw: .pi)
            // Frame handles, perforated lower grille and patch leads.
            for y: Float in [0.4, 0.7, 1.0, 1.3, 1.6] {
                box(root, "rack-handle", [0.035, 0.12, 0.04], [x + 0.45, y, 12.33], trim)
            }
            for i in 0..<4 {
                box(root, "patch-lead", [0.025, 0.3, 0.025], [x - 0.32 + Float(i) * 0.18, 1.75, 12.31], i.isMultiple(of: 2) ? blue : orange)
            }
        }
        // Cable ladder is above the service aisle, never a floor obstacle.
        box(root, "overhead-cable-rail", [4.9, 0.06, 0.06], [-25.1, 2.5, 12.7], steel)
        box(root, "overhead-cable-rail", [4.9, 0.06, 0.06], [-25.1, 2.5, 13.1], steel)
        for i in 0..<13 { box(root, "cable-ladder-rung", [0.04, 0.035, 0.46], [-27.4 + Float(i) * 0.38, 2.5, 12.9], steel) }
        let power = group(root, "floor-detail", [-27, 0, 10.2])
        box(power, "backup-power-cabinet", [1.0, 1.3, 0.8], [0, 0.65, 0], steel)
        for y in stride(from: Float(0.2), through: 1.1, by: 0.13) {
            box(power, "power-vent", [0.75, 0.045, 0.025], [0, y, 0.42], trim)
        }
        box(root, "wall-cooling-unit", [0.25, 0.75, 1.25], [-27.7, 1.85, 11.2], paper)
        for i in 0..<7 { box(root, "cooling-louvre", [0.025, 0.04, 1.1], [-27.55, 1.6 + Float(i) * 0.08, 11.2], steel) }
        for z: Float in [10.5, 11.5, 12.5] {
            box(root, "service-aisle-inlay", [2.4, 0.004, 0.025], [-24.6, 0.03, z], steel)
        }
    }

    private func operationsRoom(_ root: Entity) {
        roomLabel(root, title: "OPERATIONS", at: [-21.4, 2.3, 10.14])
        table(root, size: [2.6, 0.12, 0.8], at: [-20, 0, 13.2], height: 0.9, color: steel)
        for x: Float in [-20.65, -19.35] {
            let display = group(root, "operations-monitor", [x, 0.98, 13.35], yaw: .pi)
            monitor(display)
            box(root, "operations-keyboard", [0.5, 0.035, 0.2], [x, 0.99, 13], trim)
        }
        chair(root, at: [-20, 0, 11.9], yaw: 0, color: trim)
    }

    private func missionControl(_ root: Entity) {
        roomLabel(root, title: "MISSION CONTROL", at: [21.65, 2.65, -4.85])
        // A tiled display wall has a different silhouette from desk monitors.
        for row in 0..<2 {
            for column in 0..<3 {
                let p = SIMD3<Float>(22.25 + Float(column) * 1.75, 1.35 + Float(row) * 0.64, -4.8)
                box(root, "mission-display-bezel", [1.68, 0.60, 0.09], p, trim)
                box(root, "mission-display-glass", [1.56, 0.48, 0.025], p + [0, 0, 0.06], blue)
            }
        }
        for z: Float in [-1.45, 1.15, 2.45] {
            for side: Float in [-1, 1] {
                let console = group(root, "mission-table-console", [24 + side * 0.5, 0.98, z], yaw: side < 0 ? -.pi / 2 : .pi / 2)
                box(console, "console-foot", [0.55, 0.025, 0.35], .zero, steel)
                let screen = box(console, "console-tablet", [0.5, 0.32, 0.035], [0, 0.15, 0], trim)
                screen.orientation = simd_quatf(angle: -.pi / 5, axis: [1, 0, 0])
            }
        }
    }

    private func roomLabel(_ root: Entity, title: String, at p: SIMD3<Float>) {
        let label = ModelEntity(mesh: .generateText(title, extrusionDepth: 0.002,
            font: .systemFont(ofSize: 0.18, weight: .semibold)), materials: [SimpleMaterial(color: trim, roughness: 1, isMetallic: false)])
        label.name = "room-sign-\(title)"
        label.position = p
        root.addChild(label)
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

    /// A physical corkboard inspired by an evidence wall: its notes, pins and
    /// thread give the quiet room a readable focal point without representing
    /// Hermes tasks or status.
    private func investigationBoard(_ root: Entity, at p: SIMD3<Float>, yaw: Float) {
        let board = group(root, "investigation-board", p, yaw: yaw)
        box(board, "investigation-board-frame", [3.5, 2.3, 0.12], .zero, trim)
        box(board, "investigation-board-cork", [3.30, 2.10, 0.035], [0, 0, 0.08], cork)
        box(board, "investigation-board-inner-frame-top", [3.36, 0.06, 0.07], [0, 1.09, 0.115], wood)
        box(board, "investigation-board-inner-frame-bottom", [3.36, 0.06, 0.07], [0, -1.09, 0.115], wood)
        box(board, "investigation-board-inner-frame-left", [0.06, 2.18, 0.07], [-1.68, 0, 0.115], wood)
        box(board, "investigation-board-inner-frame-right", [0.06, 2.18, 0.07], [1.68, 0, 0.115], wood)

        note(board, name: "investigation-note-a", position: [-1.06, 0.46, 0.125], size: [0.66, 0.82], color: paper, tilt: 0.12)
        note(board, name: "investigation-note-b", position: [0.30, 0.17, 0.128], size: [0.58, 0.72], color: paper, tilt: -0.04)
        note(board, name: "investigation-note-c", position: [1.04, -0.53, 0.13], size: [0.74, 0.86], color: paper, tilt: 0.13)
        note(board, name: "investigation-note-d", position: [-0.62, -0.48, 0.132], size: [0.54, 0.70], color: paper, tilt: -0.12)
        note(board, name: "investigation-sticky-a", position: [-0.94, -0.23, 0.142], size: [0.46, 0.42], color: NSColor(srgbRed: 0.80, green: 0.78, blue: 0.59, alpha: 1), tilt: 0.18)
        note(board, name: "investigation-sticky-b", position: [1.10, 0.63, 0.142], size: [0.36, 0.36], color: NSColor(srgbRed: 0.48, green: 0.33, blue: 0.67, alpha: 1), tilt: -0.13)

        thread(board, name: "investigation-thread-a", from: [-1.25, 0.83, 0.16], to: [0.20, 0.35, 0.16])
        thread(board, name: "investigation-thread-b", from: [0.20, 0.35, 0.16], to: [0.91, -0.25, 0.16])
        thread(board, name: "investigation-thread-c", from: [0.91, -0.25, 0.16], to: [1.25, -0.65, 0.16])
        pin(board, name: "investigation-pin-a", at: [-1.25, 0.83, 0.17], color: blue)
        pin(board, name: "investigation-pin-b", at: [0.20, 0.35, 0.17], color: orange)
        pin(board, name: "investigation-pin-c", at: [0.91, -0.25, 0.17], color: orange)
        pin(board, name: "investigation-pin-d", at: [1.25, -0.65, 0.17], color: NSColor(srgbRed: 0.55, green: 0.08, blue: 0.11, alpha: 1))
    }

    private func note(_ root: Entity, name: String, position: SIMD3<Float>, size: SIMD2<Float>, color: NSColor, tilt: Float) {
        let page = box(root, name, [size.x, size.y, 0.018], position, color)
        page.orientation = simd_quatf(angle: tilt, axis: [0, 0, 1])
    }

    private func thread(_ root: Entity, name: String, from: SIMD3<Float>, to: SIMD3<Float>) {
        let delta = to - from
        let strand = box(root, name, [simd_length(SIMD2<Float>(delta.x, delta.y)), 0.018, 0.012], (from + to) / 2, NSColor(srgbRed: 0.48, green: 0.05, blue: 0.08, alpha: 1), radius: 0.006)
        strand.orientation = simd_quatf(angle: atan2(delta.y, delta.x), axis: [0, 0, 1])
    }

    private func pin(_ root: Entity, name: String, at p: SIMD3<Float>, color: NSColor) {
        oval(root, name, [0.095, 0.095, 0.05], p, color)
        box(root, "\(name)-head", [0.045, 0.045, 0.035], p + [0, -0.06, 0], trim, radius: 0.012)
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

    private func serverRack(_ root: Entity, at p: SIMD3<Float>, yaw: Float = 0) {
        let rack = group(root, "server-rack", p, yaw: yaw)
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

    private func gardenTree(_ root: Entity, at p: SIMD3<Float>, scale: Float = 1) {
        let tree = group(root, "garden-tree", p)
        tree.scale = [scale, scale, scale]
        box(tree, "trunk", [0.4, 2.4, 0.4], [0, 1.2, 0], wood)
        for i in 0..<4 {
            let angle = Float(i) * .pi / 2
            box(tree, "tree-crown", [2, 2, 2], [sin(angle) * 0.65, 2.8 + Float(i % 2) * 0.4, cos(angle) * 0.65], green, radius: 0.6)
        }
    }

    /// One connected forecourt: shaded terrace, entrance promenade and a
    /// planted water court. Props share cached meshes and have no update loops.
    private func outdoorLandscape(_ root: Entity) {
        let stone = NSColor(srgbRed: 0.64, green: 0.64, blue: 0.59, alpha: 1)
        let gravel = NSColor(srgbRed: 0.43, green: 0.45, blue: 0.40, alpha: 1)
        let soil = NSColor(srgbRed: 0.22, green: 0.25, blue: 0.18, alpha: 1)
        // The lateral path connects both courts to the existing entrance patio.
        pavedCourt(root, name: "west-terrace-floor", center: [-12, 0, 18.5], size: [16, 7], color: stone)
        pavedCourt(root, name: "east-courtyard-floor", center: [11, 0, 20], size: [15, 7], color: stone)
        pavedCourt(root, name: "entrance-promenade-floor", center: [0, 0, 24.2], size: [4.4, 4.4], color: stone)
        pavedCourt(root, name: "west-link-floor", center: [-3.1, 0, 20.5], size: [1.8, 2], color: stone)
        pavedCourt(root, name: "east-link-floor", center: [2.85, 0, 20.5], size: [1.3, 2], color: stone)
        pavedCourt(root, name: "site-sidewalk-floor", center: [0, 0, 27], size: [45, 1.2], color: gravel)
        // Raised planting beds define the edges rather than isolated rocks.
        for (x, length) in [(Float(-13), Float(13)), (Float(11), Float(12))] {
            let bed = group(root, "campus-planting-bed", [x, 0, 24.5])
            box(bed, "bed-edging", [length, 0.18, 1.3], [0, 0.09, 0], steel, radius: 0.05)
            box(bed, "bed-soil", [length - 0.18, 0.035, 1.1], [0, 0.2, 0], soil)
            for index in 0..<Int(length / 1.2) {
                let offset = -length / 2 + 0.7 + Float(index) * 1.2
                landscapeShrub(bed, at: [offset, 0.22, 0], scale: index.isMultiple(of: 3) ? 0.8 : 0.55)
                for j in 0..<3 {
                    let stalk = group(bed, "ornamental-grass", [offset + Float(j - 1) * 0.18, 0.22, 0.25])
                    stalk.orientation = simd_quatf(angle: Float(j - 1) * 0.16, axis: [0, 0, 1])
                    box(stalk, "grass-stem", [0.035, 0.62, 0.035], [0, 0.31, 0], green)
                    oval(stalk, "grass-seed-head", [0.10, 0.22, 0.08], [0, 0.66, 0], cork)
                }
            }
        }
        pergola(root, at: [-12, 0, 18.3])
        campusBench(root, at: [-15, 0, 17], yaw: 0)
        campusBench(root, at: [-9, 0, 17], yaw: 0)
        campusBench(root, at: [-12, 0, 21], yaw: .pi)
        landscapePlanter(root, at: [-18.5, 0, 17.3], length: 2)
        landscapePlanter(root, at: [-5.4, 0, 17.3], length: 2)
        courtyardFountain(root, at: [10, 0, 20])
        campusBench(root, at: [6, 0, 20], yaw: .pi / 2)
        campusBench(root, at: [14, 0, 20], yaw: -.pi / 2)
        bikeRack(root, at: [19.5, 0, 18.3])
        bicycle(root, at: [19.2, 0, 17.6], color: blue)
        bicycle(root, at: [20.0, 0, 18.5], color: orange)
        entryDirectory(root, at: [-3.2, 0, 23])
        for x: Float in [-21, -4, 4, 21] {
            bollardLight(root, at: [x, 0, 25.7])
        }
        for x: Float in [-19, -5, 4, 18] { bollardLight(root, at: [x, 0, 22.7]) }
        for x: Float in [-3, 3] { bollardLight(root, at: [x, 0, 16.7]) }
        for x: Float in [-17.5, 17.5] {
            let bins = group(root, "campus-waste-station", [x, 0, 22.7])
            wasteBin(bins, at: [-0.28, 0, 0], color: steel)
            wasteBin(bins, at: [0.28, 0, 0], color: green)
        }
        // Drain channels and small joints add scale without textures or lights.
        for x: Float in [-2.25, 2.25] {
            box(root, "entrance-drain", [0.09, 0.012, 4.2], [x, 0.01, 24.2], trim)
            for z in stride(from: Float(22.2), through: 26.2, by: 0.3) {
                box(root, "drain-grate", [0.10, 0.008, 0.035], [x, 0.02, z], steel)
            }
        }
    }

    private func pavedCourt(_ root: Entity, name: String, center: SIMD3<Float>, size: SIMD2<Float>, color: NSColor) {
        box(root, name, [size.x, 0.04, size.y], center + [0, -0.02, 0], color)
        for x in stride(from: -size.x / 2 + 1, to: size.x / 2, by: 1) {
            box(root, "paver-joint", [0.016, 0.004, size.y], center + [x, 0.003, 0], steel)
        }
        for z in stride(from: -size.y / 2 + 1, to: size.y / 2, by: 1) {
            box(root, "paver-joint", [size.x, 0.004, 0.016], center + [0, 0.003, z], steel)
        }
    }

    private func campusBench(_ root: Entity, at position: SIMD3<Float>, yaw: Float) {
        let bench = group(root, "campus-bench", position, yaw: yaw)
        for x: Float in [-0.95, 0.95] {
            box(bench, "bench-leg", [0.12, 0.46, 0.65], [x, 0.23, 0], trim)
            box(bench, "bench-arm", [0.09, 0.07, 0.68], [x, 0.72, 0], trim)
            box(bench, "bench-back-post", [0.09, 0.8, 0.09], [x, 0.55, -0.28], trim)
        }
        for z: Float in [-0.24, -0.08, 0.08, 0.24] {
            box(bench, "bench-seat-slat", [2.3, 0.065, 0.13], [0, 0.48, z], wood, radius: 0.015)
        }
        for y: Float in [0.68, 0.86] {
            box(bench, "bench-back-slat", [2.3, 0.13, 0.07], [0, y, -0.29], wood, radius: 0.015)
        }
        let rotation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        navigation.leisureSpots.append(.init(station: .init(position: position,
            approach: position + rotation.act([0, 0, 1.1]), yaw: yaw), action: .reading, isOutdoor: true))
    }

    private func pergola(_ root: Entity, at p: SIMD3<Float>) {
        let shelter = group(root, "courtyard-pergola", p)
        for x: Float in [-4.2, 4.2] {
            for z: Float in [-2, 2] {
                box(shelter, "pergola-post", [0.20, 2.9, 0.20], [x, 1.45, z], wood)
                box(shelter, "post-footing", [0.32, 0.16, 0.32], [x, 0.08, z], steel)
            }
            box(shelter, "pergola-beam", [0.22, 0.22, 4.8], [x, 2.85, 0], wood)
        }
        for z in stride(from: Float(-2.2), through: 2.2, by: 0.55) {
            box(shelter, "pergola-slat", [9.2, 0.12, 0.16], [0, 3.03, z], wood)
        }
    }

    private func courtyardFountain(_ root: Entity, at p: SIMD3<Float>) {
        let fountain = group(root, "courtyard-fountain", p)
        box(fountain, "fountain-plinth", [3.7, 0.18, 2.9], [0, 0.09, 0], steel, radius: 0.08)
        box(fountain, "fountain-basin", [3.2, 0.36, 2.4], [0, 0.30, 0], paper, radius: 0.08)
        box(fountain, "reflecting-water", [2.9, 0.025, 2.1], [0, 0.49, 0], NSColor(srgbRed: 0.25, green: 0.44, blue: 0.47, alpha: 1), radius: 0.04)
        box(fountain, "fountain-monolith", [0.48, 1.1, 0.48], [0, 0.9, 0], steel, radius: 0.06)
        box(fountain, "fountain-cap", [0.56, 0.06, 0.56], [0, 1.47, 0], paper, radius: 0.03)
    }

    private func bicycle(_ root: Entity, at p: SIMD3<Float>, color: NSColor) {
        let bike = group(root, "parked-bicycle", p, yaw: .pi / 2)
        func bar(_ name: String, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ width: Float, _ color: NSColor) {
            let part = group(bike, name, (a + b) / 2)
            part.orientation = simd_quatf(from: [0, 1, 0], to: simd_normalize(b - a))
            box(part, name + "-tube", [width, simd_length(b - a), width], .zero, color, radius: width / 3)
        }
        for x: Float in [-0.65, 0.65] {
            for segment in 0..<16 {
                let a = Float(segment) * .pi / 8, b = Float(segment + 1) * .pi / 8
                bar("bicycle-tire", [x + cos(a) * 0.36, 0.39 + sin(a) * 0.36, 0],
                    [x + cos(b) * 0.36, 0.39 + sin(b) * 0.36, 0], 0.05, trim)
            }
            for angle: Float in [0, .pi / 2, .pi / 4, -.pi / 4] {
                let d = SIMD3<Float>(cos(angle) * 0.33, sin(angle) * 0.33, 0)
                bar("bicycle-spoke", [x, 0.39, 0] - d, [x, 0.39, 0] + d, 0.012, steel)
            }
        }
        let rear = SIMD3<Float>(-0.65, 0.39, 0), crank = SIMD3<Float>(-0.05, 0.36, 0)
        let saddle = SIMD3<Float>(-0.28, 0.95, 0), head = SIMD3<Float>(0.40, 0.98, 0)
        for (a, b) in [(rear, crank), (rear, saddle), (crank, saddle), (saddle, head), (crank, head), (head, SIMD3<Float>(0.65, 0.39, 0))] {
            bar("bicycle-frame", a, b, 0.045, color)
        }
        box(bike, "bicycle-saddle", [0.30, 0.065, 0.15], saddle + [0, 0.08, 0], trim, radius: 0.025)
        bar("handlebar-stem", head, head + [0, 0.18, 0], 0.04, steel)
        bar("handlebar", head + [0, 0.18, -0.22], head + [0, 0.18, 0.22], 0.04, trim)
        bar("kickstand", crank, crank + [-0.1, -0.32, 0.18], 0.025, steel)
    }

    private func landscapePlanter(_ root: Entity, at p: SIMD3<Float>, length: Float) {
        let planter = group(root, "landscape-planter", p)
        box(planter, "planter-body", [length, 0.52, 0.62], [0, 0.26, 0], wood, radius: 0.05)
        box(planter, "planter-soil", [length - 0.14, 0.04, 0.48], [0, 0.54, 0], trim)
        for index in 0..<5 {
            let x = -length / 2 + 0.28 + Float(index) * (length - 0.56) / 4
            plant(planter, at: [x, 0.53, 0], height: index.isMultiple(of: 2) ? 0.48 : 0.36)
        }
    }

    private func bikeRack(_ root: Entity, at p: SIMD3<Float>) {
        let rack = group(root, "bike-rack", p, yaw: .pi / 2)
        box(rack, "rack-rail", [2.0, 0.06, 0.06], [0, 0.22, 0], steel)
        for x: Float in [-0.72, -0.24, 0.24, 0.72] {
            let hoop = group(rack, "bike-rack-hoop", [x, 0, 0])
            box(hoop, "rack-upright", [0.05, 0.48, 0.05], [-0.16, 0.24, 0], steel)
            box(hoop, "rack-upright", [0.05, 0.48, 0.05], [0.16, 0.24, 0], steel)
            box(hoop, "rack-top", [0.37, 0.05, 0.05], [0, 0.48, 0], steel)
        }
    }

    private func entryDirectory(_ root: Entity, at p: SIMD3<Float>) {
        let sign = group(root, "entry-directory", p, yaw: .pi / 2)
        box(sign, "directory-base", [0.55, 0.10, 0.45], [0, 0.05, 0], trim, radius: 0.04)
        box(sign, "directory-post", [0.08, 1.2, 0.08], [0, 0.65, 0], steel)
        box(sign, "directory-panel", [0.75, 0.52, 0.07], [0, 1.28, 0], trim, radius: 0.025)
        box(sign, "directory-face", [0.63, 0.40, 0.012], [0, 1.28, 0.046], paper)
        for y: Float in [-0.11, 0, 0.11] { box(sign, "directory-line", [0.44, 0.025, 0.01], [0, 1.28 + y, 0.055], steel) }
    }

    private func bollardLight(_ root: Entity, at p: SIMD3<Float>) {
        let light = group(root, "landscape-light", p)
        box(light, "bollard-base", [0.22, 0.05, 0.22], [0, 0.025, 0], trim, radius: 0.025)
        box(light, "bollard-post", [0.09, 0.68, 0.09], [0, 0.34, 0], trim)
        box(light, "bollard-lens", [0.15, 0.16, 0.15], [0, 0.66, 0], paper, radius: 0.025)
        box(light, "bollard-cap", [0.20, 0.04, 0.20], [0, 0.76, 0], steel)
    }

    private func landscapeShrub(_ root: Entity, at p: SIMD3<Float>, scale: Float) {
        let shrub = group(root, "landscape-shrub", p)
        shrub.scale = [scale, scale, scale]
        oval(shrub, "shrub-base", [0.8, 0.5, 0.8], [0, 0.25, 0], green)
        oval(shrub, "shrub-left", [0.58, 0.42, 0.58], [-0.28, 0.48, 0], green)
        oval(shrub, "shrub-right", [0.58, 0.46, 0.58], [0.28, 0.48, 0.04], green)
        oval(shrub, "shrub-top", [0.52, 0.42, 0.52], [0, 0.68, -0.04], green)
    }

    private func landscapeStone(_ root: Entity, at p: SIMD3<Float>, scale: Float) {
        let stone = group(root, "landscape-stone", p)
        stone.scale = [scale, scale * 0.65, scale]
        oval(stone, "stone-body", [0.72, 0.35, 0.55], [0, 0.18, 0], steel)
        oval(stone, "stone-highlight", [0.42, 0.08, 0.28], [-0.10, 0.38, -0.06], paper)
    }

    private func outdoorArea(_ root: Entity) {
        let depth: Float = 6
        box(root, "patio-floor", [4.4, 0.035, depth], [11.5, -0.0175, 2 + depth / 2], steel)
        // The patio meets the office at z = 2; no overlapping path slab is needed.
        for z in stride(from: Float(3), through: 2 + depth, by: 1) { box(root, "paving-joint", [4.4, 0.003, 0.018], [11.5, 0.0015, z], plaster) }
        for x in stride(from: Float(9.5), through: 13.5, by: 1) { box(root, "paving-joint", [0.018, 0.003, depth], [x, 0.0015, 2 + depth / 2], plaster) }
        let tableCenter = SIMD3<Float>(11.5, 0, 5)
        table(root, size: [1.25, 0.10, 0.95], at: tableCenter, height: 0.75, color: wood)
        mug(root, at: tableCenter + [0.2, 0.82, 0], color: paper)
        for side: Float in [-1, 1] {
            let seat = tableCenter + [side * 1.15, 0, 0]
            let yaw: Float = side < 0 ? .pi / 2 : -.pi / 2
            gardenChair(root, at: seat, yaw: yaw)
            navigation.stations[.lounge, default: []].append(.init(position: seat, approach: seat + [0, 0, 0.85], yaw: yaw))
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
        let groups: Set<String> = ["wall", "glazed-partition", "open-door", "task-chair", "garden-chair", "garden-bench", "garden-tree", "raised-planter", "garden-light", "broad-leaf-plant", "filing-cabinet", "bookcase", "office-printer", "arcade-cabinet", "games-sofa", "visitor-armchair", "coffee-counter", "landscape-planter", "landscape-shrub", "landscape-light", "entry-directory", "bike-rack", "parked-bicycle", "campus-bench", "courtyard-fountain", "campus-planting-bed", "water-cooler", "waste-bin", "cleaning-cart", "staircase"]
        let parts: Set<String> = ["tabletop", "beanbag", "beanbag-back", "stall-partition", "vanity", "toilet-tank", "toilet-bowl", "coat-stand", "pergola-post", "post-footing", "cross-divider-x", "cross-divider-z"]
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
        let isWorkshop = variant >= 4
        let desktop = isWorkshop ? paper : NSColor(srgbRed: 0.41, green: 0.39, blue: 0.46, alpha: 1)
        box(pod, "cross-divider-x", [3.9, isWorkshop ? 0.4 : 1.1, 0.07], [0, isWorkshop ? 1.05 : 1.25, 0], isWorkshop ? blue : plaster)
        if !isWorkshop {
            box(pod, "cross-divider-z", [0.07, 1.1, 2.5], [0, 1.25, 0], plaster)
        } else {
            box(pod, "workshop-cable-spine", [3.8, 0.12, 0.26], [0, 0.68, 0], steel)
            for x: Float in [-1.65, 1.65] {
                box(pod, "modular-desk-end", [0.08, 0.78, 1.08], [x, 0.4, 0.64], steel)
                box(pod, "modular-desk-end", [0.08, 0.78, 1.08], [x, 0.4, -0.64], steel)
            }
        }
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

    private func chair(_ root: Entity, at p: SIMD3<Float>, yaw: Float, color: NSColor, highBack: Bool = false) {
        let chair = group(root, "task-chair", p, yaw: yaw)
        box(chair, "seat", [0.61, 0.13, 0.58], [0, 0.5, 0], color, radius: 0.06)
        box(chair, "back", [0.59, highBack ? 0.82 : 0.48, 0.12], [0, highBack ? 1.0 : 0.83, -0.25], color, radius: 0.05)
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
