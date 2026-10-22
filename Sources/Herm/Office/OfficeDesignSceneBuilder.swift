import AppKit
import RealityKit
import simd

/// Original furniture with navigation captured from the rendered geometry.
@MainActor
final class OfficeDesignSceneBuilder {
    // Materials follow the Dock theme: see OfficeScenePalette.
    private let palette: OfficeScenePalette
    private let plaster: NSColor, trim: NSColor, floor: NSColor, wood: NSColor, oak: NSColor, cork: NSColor
    private let paper: NSColor, blue: NSColor, orange: NSColor, green: NSColor, lawn: NSColor, steel: NSColor
    private let lilac: NSColor, signInk: NSColor, glow: NSColor, neon: NSColor, violet: NSColor

    init(palette: OfficeScenePalette = .current()) {
        self.palette = palette
        plaster = palette.plaster; trim = palette.trim; floor = palette.floor; wood = palette.wood
        oak = palette.frame; cork = palette.cork; paper = palette.paper; blue = palette.fabric
        orange = palette.coral; green = palette.leaf; lawn = palette.lawn; steel = palette.steel
        lilac = palette.roomFloor; signInk = palette.signInk; glow = palette.lamp
        neon = palette.neon; violet = palette.neonAlt
    }

    private let caution = NSColor(srgbRed: 0.98, green: 0.78, blue: 0.26, alpha: 1)
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
        box(root, "exterior-ground", [navigation.maxX + 24, 0.12, 42], [(navigation.maxX - 24) / 2, -0.10, 7], lawn)
        box(root, "west-wing-floor", [20, 0.18, 26], [-18, -0.09, 1], floor)
        box(root, "connecting-hall-floor", [3, 0.18, 26], [0, -0.09, 1], floor)
        box(root, "east-wing-floor", [20, 0.18, 28], [18, -0.09, 2], floor)
        floorGrid(root)
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
        for x: Float in [-23.5, -20.5, -17.5, -14.5, -11.5, 11.5, 14.5, 17.5] { wallSconce(root, at: [x, 2.25, -11.86]) }
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
        box(root, "expansion-bay-floor", [11.6, 0.025, 7.2], [13.6, 0.014, -6.5], finish(0.78, 0.78, 0.76))
        for z: Float in [-9.9, -3.1] { box(root, "safety-line", [11.4, 0.006, 0.07], [13.6, 0.03, z], caution) }
        roomLabel(root, number: 2, title: "Assembly Bay", subtitle: "Builds & releases", at: [10.2, -12])
        assemblyCradle(root, at: [13.9, 0, -10.8])
        robotArm(root, at: [16.3, 0, -10.8], yaw: .pi)
        for x: Float in [12.7, 15.1] { workStation(.assemblyBay, [x, 0, -9.6], approach: [x, 0, -9.0], yaw: .pi, seated: false) }
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

        // The glazed room beside the entrance hall is the café.
        glassWall(root, from: [-19, -3], to: [-8, -3])
        glassWall(root, from: [-19, -3], to: [-19, 5.5])
        glassWall(root, from: [-19, 7.5], to: [-19, 8])
        glassWall(root, from: [-19, 8], to: [-12, 8])
        glassWall(root, from: [-10, 8], to: [-8, 8])
        glassWall(root, from: [-8, -3], to: [-8, 3])
        glassWall(root, from: [-8, 5], to: [-8, 8])
        cafe(root)
        library(root)

        // East wing: mission control, planning, parts, games and maintenance.
        wall(root, from: [20, -5], to: [28, -5])
        glassWall(root, from: [20, -5], to: [20, 2.5])
        glassWall(root, from: [20, 4.5], to: [20, 6])
        wall(root, from: [20, 6], to: [28, 6])
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
        planningRoom(root)
        partsDepot(root)
        gameRoom(root)
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
            .init(station: .init(position: [-14.5, 0, -1.2], approach: [-14.5, 0, -0.5], yaw: .pi, seated: false), action: .coffee),
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
                // Two stand-up rows face the kanban wall in the planning room.
                let p = SIMD3<Float>(10.25 + Float(slot % 6) * 1.5, 0, -0.75 + Float(slot / 6) * 1.25)
                navigation.stations[.kanbanBoard, default: []].append(.init(position: p, approach: p, yaw: .pi, seated: false))
            }
            if slot < 8 {
                let waiting = SIMD3<Float>(0, 0, 4 + Float(slot))
                navigation.stations[.waitingArea, default: []].append(.init(position: waiting, approach: waiting, yaw: .pi / 2, seated: false))
            }
        }
        interiorDetails(root)
        roomProps(root)
        ceilingLights(root)
        roomActivities()
        bringWingsTogether(root)
        neonSign(root, text: "Ship it together", at: [0, 2.0, -11.86])
        // One parked delivery drone hovers over the central hall; static, no loops.
        drone(root, at: [0, 2.6, -4], yaw: 0.4)
        countryside(root)
        captureObstacles(in: root)
        return navigation
    }

    /// Everyday fixtures that make each room read as a working office:
    /// safety kit, floor markings, storage and a café corner. Wall-mounted
    /// or decals, except two corner items registered as obstacles.
    private func roomProps(_ root: Entity) {
        // Planning: water cooler and an extinguisher by the door.
        waterCooler(root, at: [9.0, 0, -1.35])
        fireExtinguisher(root, at: [10.25, 0, -1.87], yaw: 0)
        // Maintenance: caution stripes at each charging pad and an extinguisher.
        for index in 0..<4 {
            let x = Float(21 + index * 2)
            for segment in 0..<4 {
                box(root, "caution-stripe", [0.2, 0.006, 0.1], [x - 0.3 + Float(segment) * 0.2, 0.012, 13.45], segment.isMultiple(of: 2) ? caution : signInk)
            }
        }
        fireExtinguisher(root, at: [27.3, 0, 6.12], yaw: 0)
        // Assembly Bay: painted safety line around the robot arm's reach.
        for (size, p) in [(SIMD3<Float>(2.5, 0.006, 0.07), SIMD3<Float>(16.25, 0.012, -9.75)),
                          ([0.07, 0.006, 1.9], [15.0, 0.012, -10.7]),
                          ([0.07, 0.006, 1.9], [17.5, 0.012, -10.7])] {
            box(root, "safety-line", size, p, caution)
        }
        // QA Lab: a wall rail of small-parts bins beside the repair stand.
        let bins = group(root, "parts-bin-rail", [-27.88, 1.35, 5.9], yaw: .pi / 2)
        box(bins, "bin-rail", [1.1, 0.05, 0.04], [0, 0.14, 0], steel)
        for i in 0..<4 {
            let x = -0.39 + Float(i) * 0.26
            box(bins, "parts-bin", [0.22, 0.16, 0.2], [x, 0.04, 0.11], [blue, orange, green, paper][i], radius: 0.02)
            box(bins, "bin-label", [0.1, 0.04, 0.006], [x, 0.05, 0.213], paper)
        }
        // Server Room: cable spool in the corner and an extinguisher by the door.
        let spool = group(root, "floor-detail", [-27.2, 0, 8.85])
        for side: Float in [-1, 1] { oval(spool, "spool-flange", [0.08, 0.62, 0.62], [side * 0.2, 0.31, 0], wood) }
        oval(spool, "spool-cable", [0.38, 0.44, 0.44], [0, 0.31, 0], blue)
        box(spool, "cable-tail", [0.03, 0.03, 0.4], [0.05, 0.03, 0.4], blue)
        fireExtinguisher(root, at: [-22.12, 0, 11.2], yaw: -.pi / 2)
        // Main Agent office: framed art beside the doorway.
        wallArt(root, at: [20.12, 1.7, -10.6], yaw: .pi / 2, color: orange)
    }

    /// A seat or standing spot a running bot uses for its work kind.
    private func workStation(_ location: OfficePreviewLocation, _ p: SIMD3<Float>, approach: SIMD3<Float>, yaw: Float, seated: Bool = true) {
        navigation.stations[location, default: []].append(.init(position: p, approach: approach, yaw: yaw, seated: seated))
    }

    private func fireExtinguisher(_ root: Entity, at p: SIMD3<Float>, yaw: Float) {
        let red = NSColor(srgbRed: 0.84, green: 0.25, blue: 0.22, alpha: 1)
        let unit = group(root, "fire-extinguisher", p, yaw: yaw)
        box(unit, "extinguisher-bracket", [0.2, 0.06, 0.05], [0, 0.95, 0.03], steel)
        box(unit, "extinguisher-body", [0.16, 0.48, 0.16], [0, 0.72, 0.12], red, radius: 0.07)
        box(unit, "extinguisher-valve", [0.07, 0.07, 0.07], [0, 1.0, 0.12], trim, radius: 0.015)
        box(unit, "extinguisher-handle", [0.14, 0.02, 0.04], [0.02, 1.05, 0.12], trim)
        box(unit, "extinguisher-hose", [0.025, 0.3, 0.025], [0.09, 0.84, 0.16], signInk)
        box(unit, "extinguisher-sign", [0.18, 0.18, 0.01], [0, 1.35, 0.006], red)
        box(unit, "extinguisher-sign-glyph", [0.05, 0.11, 0.004], [0, 1.35, 0.013], paper)
    }

    private func waterCooler(_ root: Entity, at p: SIMD3<Float>) {
        let cooler = group(root, "floor-detail", p)
        box(cooler, "cooler-cabinet", [0.36, 0.95, 0.36], [0, 0.475, 0], paper, radius: 0.03)
        box(cooler, "cooler-tap-panel", [0.26, 0.2, 0.02], [0, 0.78, 0.18], trim, radius: 0.02)
        box(cooler, "cooler-tap", [0.05, 0.05, 0.05], [-0.06, 0.76, 0.2], blue)
        box(cooler, "cooler-tap", [0.05, 0.05, 0.05], [0.06, 0.76, 0.2], orange)
        box(cooler, "cooler-drip-tray", [0.24, 0.03, 0.08], [0, 0.6, 0.2], steel)
        let bottle = box(cooler, "cooler-bottle", [0.3, 0.42, 0.3], [0, 1.16, 0], palette.glass.withAlphaComponent(1), radius: 0.12)
        bottle.model?.materials = [SimpleMaterial(color: palette.water.withAlphaComponent(0.55), roughness: 0.2, isMetallic: false)]
        box(cooler, "cooler-bottle-neck", [0.12, 0.06, 0.12], [0, 0.96, 0], blue, radius: 0.03)
        for i in 0..<2 { box(cooler, "paper-cup", [0.06, 0.08, 0.06], [0.24, 0.04 + Float(i) * 0.075, 0.1], paper, radius: 0.015) }
    }

    /// Idle bots use every room: charging bays, workbenches, shelves and
    /// extra chat corners. Appended after the original spots so existing
    /// indices stay stable. Coordinates are pre-shift, like the rooms.
    private func roomActivities() {
        func spot(_ p: SIMD3<Float>, _ approach: SIMD3<Float>, _ yaw: Float, _ action: OfficeDesignNavigation.LeisureAction) {
            navigation.leisureSpots.append(.init(station: .init(position: p, approach: approach, yaw: yaw, seated: false), action: action))
        }
        for index in 0..<4 {
            let x = Float(21 + index * 2)
            spot([x, 0, 13.85], [x + 0.5, 0, 12.75], .pi, .charging)
        }
        spot([-25.5, 0, 6.85], [-24.7, 0, 6.85], -.pi / 2, .tinkering)
        spot([13.9, 0, -9.7], [13.9, 0, -9.2], .pi, .tinkering)
        spot([23, 0, 7.6], [23, 0, 8.2], .pi, .tinkering)
        spot([9.2, 0, 11.6], [9.2, 0, 11.1], 0, .browsing)
        spot([13.2, 0, 11.6], [13.2, 0, 11.1], 0, .browsing)
        spot([-25, 0, 11.3], [-25, 0, 10.8], 0, .browsing)
        for (a, b) in [(SIMD3<Float>(-0.65, 0, -8), SIMD3<Float>(0.65, 0, -8)),
                       ([9.9, 0, 10.4], [11.1, 0, 10.4]),
                       ([22.4, 0, 9.6], [23.6, 0, 9.6])] {
            spot(a, a, .pi / 2, .socializing)
            spot(b, b, -.pi / 2, .socializing)
        }
        for z: Float in [9.7, 14.4] { spot([16.6, 0, z], [17.1, 0, z], -.pi / 2, .arcade) }
        // Library armchairs are seated reading spots.
        for (x, yaw) in [(Float(-16.2), Float.pi / 2), (-13.2, -.pi / 2)] {
            navigation.leisureSpots.append(.init(station: .init(position: [x, 0, 11.4], approach: [x, 0, 12.5], yaw: yaw), action: .reading))
        }
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
        // The patio is already placed inside the unmoved entrance garden.
        for location in OfficePreviewLocation.allCases where location != .lounge {
            navigation.stations[location] = navigation.stations[location]?.map(station)
        }
        navigation.leisureSpots = navigation.leisureSpots.map { $0.isOutdoor ? $0 : .init(station: station($0.station), action: $0.action) }
    }

    /// Static props share the builder's cached meshes/materials; no new update loops or lights.
    private func interiorDetails(_ root: Entity) {
        // A docked courier drone rests on the quiet west-corridor console.
        table(root, size: [3, 0.1, 0.65], at: [-10.5, 0, 13.2], height: 0.85, color: wood)
        drone(root, at: [-11.3, 1.05, 13.2], yaw: 0.3, scale: 0.55)
        plant(root, at: [-9.5, 0.91, 13.2], height: 0.55)
        wallArt(root, at: [25.6, 1.8, 5.85], yaw: .pi, color: green)

        // Parts Depot crates by the storage shelves.
        for x: Float in [9.5, 10.5] {
            let crates = group(root, "floor-detail", [x, 0, 9.2])
            for row in 0..<2 {
                box(crates, "parts-crate", [0.7, 0.42, 0.6], [0, 0.21 + Float(row) * 0.43, 0], row == 0 ? orange : steel, radius: 0.03)
                box(crates, "crate-label", [0.3, 0.12, 0.02], [0, 0.26 + Float(row) * 0.43, 0.305], paper)
            }
        }
        wasteBin(root, at: [26.6, 0, 7.1], color: steel)
    }

    // Specialist rooms use the same cached geometry and obstacle capture as
    // the original office. Screens are physical props, with no invented telemetry.
    private func mainAgentOffice(_ root: Entity) {
        // Reuse the exterior and Mission Control walls. A two-unit doorway
        // opens west into the workshop corridor, clear of the neighboring pod.
        wall(root, from: [20, -12], to: [20, -9])
        wall(root, from: [20, -7], to: [20, -5])
        box(root, "main-office-floor", [7.7, 0.025, 6.7], [24, 0.014, -8.5], finish(0.80, 0.64, 0.52))
        box(root, "office-rug", [3.8, 0.01, 2.8], [24.5, 0.032, -8.7], finish(0.98, 0.95, 0.90))
        bookcase(root, at: [21.3, 0, -5.55], yaw: .pi)
        pottedTree(root, at: [21.0, 0, -11.2], height: 2)
        roomLabel(root, number: 1, title: "Main Agent", subtitle: "Orchestrator's office", at: [21.2, -12])
        let desk = group(root, "main-agent-desk", [24.5, 0, -9.6])
        table(desk, size: [3.2, 0.12, 1.3], at: .zero, height: 0.9, color: paper)
        box(desk, "desk-writing-mat", [2.1, 0.015, 0.9], [0, 0.97, 0], trim)
        for (index, x) in [Float(-0.48), 0.48].enumerated() {
            let display = group(desk, "main-office-monitor-\(index)", [x, 0.99, -0.23])
            oval(display, "monitor-foot", [0.36, 0.035, 0.25], [0, 0.02, 0], trim)
            box(display, "monitor-neck", [0.055, 0.22, 0.06], [0, 0.13, 0], steel)
            box(display, "monitor-bezel", [0.94, 0.52, 0.055], [0, 0.43, 0], trim)
            box(display, "monitor-display", [0.89, 0.47, 0.012], [0, 0.43, 0.034], palette.idleScreen)
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
        robotTrophy(root, at: [26.6, 0, -6.4])
        plant(root, at: [27, 0, -10.7], height: 1.6)
        floorLamp(root, at: [26.6, 0, -7.8])
        wallArt(root, at: [24.5, 1.7, -5.14], yaw: .pi, color: blue)
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
        glowBox(copier, "task-lamp-diffuser", [0.20, 0.014, 0.15], [-0.07, 1.82, -0.3], glow)
    }

    private func designStudio(_ root: Entity) {
        box(root, "design-studio-floor", [5.7, 0.025, 5.2], [-25, 0.014, -0.25], finish(0.90, 0.72, 0.52))
        for i in 0..<9 { box(root, "plank-seam", [5.6, 0.004, 0.02], [-25, 0.029, -2.6 + Float(i) * 0.55], wood) }
        easel(root, at: [-27.2, 0, 0.2])
        slatPanel(root, at: [-25.4, 1.45, 2.36], width: 2.6, height: 1.9, yaw: .pi)
        roomLabel(root, number: 4, title: "Design Studio", subtitle: "UI & visuals", at: [-27.6, -3])
        investigationBoard(root, at: [-25.9, 1.45, -2.84], yaw: 0)
        // Angled drawing surface, edge rail, scale model and drafting tools.
        let desk = group(root, "design-drafting-desk", [-25.8, 0, -0.4])
        table(desk, size: [2.3, 0.12, 1.3], at: .zero, height: 0.93, color: wood)
        let drawing = box(desk, "drawing-board", [2.15, 0.08, 1.18], [0, 1.04, 0], paper)
        drawing.orientation = simd_quatf(angle: 0.14, axis: [1, 0, 0])
        box(desk, "drafting-edge-rail", [2.15, 0.06, 0.035], [0, 1.0, 0.57], trim)
        box(desk, "drafting-ruler", [0.85, 0.015, 0.06], [-0.45, 1.17, -0.28], steel)
        box(desk, "model-plinth", [0.55, 0.05, 0.45], [0.55, 1.17, -0.2], wood)
        // A hand-built prototype of the crew's robot sits on the plinth.
        for x: Float in [-0.06, 0.06] { box(desk, "prototype-leg", [0.07, 0.1, 0.08], [0.55 + x, 1.25, -0.2], steel, radius: 0.02) }
        box(desk, "prototype-body", [0.22, 0.2, 0.17], [0.55, 1.39, -0.2], paper, radius: 0.06)
        box(desk, "prototype-head", [0.28, 0.21, 0.23], [0.55, 1.6, -0.2], paper, radius: 0.08)
        box(desk, "prototype-visor", [0.21, 0.11, 0.02], [0.55, 1.6, -0.08], signInk, radius: 0.03)
        for x: Float in [-0.155, 0.155] { box(desk, "prototype-headphone", [0.04, 0.13, 0.1], [0.55 + x, 1.61, -0.2], orange, radius: 0.015) }
        chair(root, at: [-25.8, 0, 1.05], yaw: .pi, color: orange)
        workStation(.designStudio, [-25.8, 0, 1.05], approach: [-25.8, 0, 1.9], yaw: .pi)
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
        box(root, "verification-lab-floor", [5.7, 0.025, 5.2], [-25, 0.014, 5.25], finish(0.84, 0.94, 0.90))
        box(root, "esd-mat", [4.4, 0.006, 1.4], [-25, 0.03, 4.4], finish(0.40, 0.62, 0.58))
        roomLabel(root, number: 5, title: "QA Lab", subtitle: "Tests & verification", at: [-27.6, 2.5])
        table(root, size: [4.4, 0.12, 0.95], at: [-25, 0, 3.4], height: 0.95, color: paper)
        for x: Float in [-26.35, -24.9] {
            let display = group(root, "lab-monitor", [x, 1.02, 3.25])
            monitor(display)
            box(root, "lab-keyboard", [0.5, 0.035, 0.2], [x, 1.04, 3.65], trim)
            chair(root, at: [x, 0, 4.85], yaw: .pi, color: steel)
            workStation(.qaLab, [x, 0, 4.85], approach: [x, 0, 5.75], yaw: .pi)
        }
        // A standing spot at the test-device fixtures.
        workStation(.qaLab, [-23.55, 0, 4.4], approach: [-23.55, 0, 5.3], yaw: .pi, seated: false)
        // Upright phone/tablet fixtures and physical instrumentation.
        for i in 0..<3 {
            let device = group(root, "test-device", [-23.9 + Float(i) * 0.36, 1.03, 3.5])
            box(device, "device-stand", [0.28, 0.035, 0.28], .zero, trim)
            box(device, "device-frame", [0.23, 0.42, 0.035], [0, 0.22, -0.04], trim, radius: 0.02)
            box(device, "device-glass", [0.19, 0.34, 0.012], [0, 0.23, -0.015], blue)
        }
        repairStand(root, at: [-26.8, 0, 6.85])
        let tools = group(root, "lab-tool-wall", [-25, 1.85, 2.65])
        box(tools, "tool-panel", [3.4, 0.7, 0.04], .zero, trim)
        for i in 0..<9 {
            box(tools, "tool-hook", [0.025, 0.05, 0.05], [-1.4 + Float(i) * 0.35, 0.16, 0.045], steel)
            box(tools, "bench-tool", [0.055, 0.34, 0.055], [-1.4 + Float(i) * 0.35, -0.05, 0.08], i.isMultiple(of: 2) ? orange : steel)
        }
    }

    private func serverRoom(_ root: Entity) {
        box(root, "server-room-floor", [5.7, 0.025, 5.7], [-25, 0.014, 11], finish(0.82, 0.84, 0.88))
        // Raised-floor tiles, with perforated tiles along the cold aisle.
        for i in 0..<9 {
            box(root, "raised-tile-seam", [5.6, 0.004, 0.025], [-25, 0.029, 8.4 + Float(i) * 0.6], steel)
            box(root, "raised-tile-seam", [0.025, 0.004, 5.6], [-27.6 + Float(i) * 0.6, 0.029, 11], steel)
        }
        for i in 0..<5 { box(root, "perforated-tile", [0.56, 0.005, 0.56], [-26.7 + Float(i) * 0.9, 0.03, 11.7], trim) }
        roomLabel(root, number: 6, title: "Server Room", subtitle: "Deploys & infrastructure", at: [-27.6, 8])
        for x: Float in [-26.8, -25.1, -23.4] {
            serverRack(root, at: [x, 0, 12.8], yaw: .pi)
            // The middle rack's aisle is already a browsing leisure spot.
            if x != -25.1 { workStation(.serverRoom, [x, 0, 11.75], approach: [x, 0, 11.1], yaw: 0, seated: false) }
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
        roomLabel(root, number: 7, title: "Security Ops", subtitle: "Audits & pentests", at: [-21.8, 10])
        box(root, "operations-floor", [3.8, 0.025, 3.8], [-20, 0.014, 12], finish(0.52, 0.56, 0.72))
        table(root, size: [2.6, 0.12, 0.8], at: [-20, 0, 13.2], height: 0.9, color: steel)
        for x: Float in [-20.65, -19.35] {
            let display = group(root, "operations-monitor", [x, 0.98, 13.35], yaw: .pi)
            monitor(display)
            box(root, "operations-keyboard", [0.5, 0.035, 0.2], [x, 0.99, 13], trim)
            chair(root, at: [x, 0, 12.0], yaw: 0, color: trim)
            workStation(.securityOps, [x, 0, 12.0], approach: [x, 0, 11.1], yaw: 0)
        }
    }

    private func missionControl(_ root: Entity) {
        box(root, "mission-control-floor", [7.8, 0.025, 10.8], [24, 0.014, 0.5], finish(0.56, 0.62, 0.80))
        roomLabel(root, number: 8, title: "Mission Control", subtitle: "Planning & delegation", at: [20.6, -5])
        // A tiled display wall has a different silhouette from desk monitors.
        for row in 0..<2 {
            for column in 0..<3 {
                let p = SIMD3<Float>(22.25 + Float(column) * 1.75, 1.35 + Float(row) * 0.64, -4.8)
                box(root, "mission-display-bezel", [1.68, 0.60, 0.09], p, trim)
                glowBox(root, "mission-display-glass", [1.56, 0.48, 0.025], p + [0, 0, 0.06], palette.windowView)
            }
        }
        // Coordinators stand at the display wall, clear of the console rows.
        for x: Float in [22.25, 24.0, 25.75] {
            workStation(.missionWall, [x, 0, -4.1], approach: [x, 0, -3.9], yaw: .pi, seated: false)
        }
        // Two tiers of five consoles face the wall: the ten review seats.
        for z: Float in [-2.6, 0.6] {
            table(root, size: [5.4, 0.1, 0.8], at: [24.3, 0, z], height: 0.78, color: oak)
            box(root, "console-modesty-panel", [5.3, 0.5, 0.04], [24.3, 0.45, z - 0.36], wood)
            for i in 0..<5 {
                let x = 22.2 + Float(i) * 1.05
                let display = group(root, "console-monitor", [x, 0.83, z - 0.12])
                monitor(display)
                box(root, "console-keyboard", [0.46, 0.03, 0.18], [x, 0.85, z + 0.2], trim, radius: 0.01)
                let seat = SIMD3<Float>(x, 0, z + 1)
                chair(root, at: seat, yaw: .pi, color: blue)
                navigation.stations[.reviewTable, default: []].append(.init(position: seat, approach: [x, 0, z < 0 ? -0.75 : 2.5], yaw: .pi))
            }
        }
        // A viewing sofa at the back of the room, facing the display wall.
        let sofa = group(root, "games-sofa", [24.3, 0, 5.25], yaw: .pi)
        couch(sofa, width: 2.4, color: orange)
        box(root, "mission-rug", [3.4, 0.01, 1.9], [24.3, 0.032, 4.3], finish(0.95, 0.92, 0.88))
        slatPanel(root, at: [21.9, 1.45, 5.88], width: 2.6, height: 2.0, yaw: .pi)
    }

    /// A numbered hanging sign above a wall line, tilted toward the default
    /// camera. Unlit so it stays legible from the whole-office view.
    /// A hanging sign: a numbered badge, the room name, and what bots do there.
    private func roomLabel(_ root: Entity, number: Int, title: String, subtitle: String, at p: SIMD2<Float>) {
        let accents = DockAccentColor.allCases.map(\.signageColor)
        func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
            let rounded = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.rounded)
            return rounded.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size, weight: weight)
        }
        let titleMesh = MeshResource.generateText(title, extrusionDepth: 0.004, font: font(0.34, .bold))
        let subtitleMesh = MeshResource.generateText(subtitle, extrusionDepth: 0.004, font: font(0.17, .semibold))
        let numberMesh = MeshResource.generateText("\(number)", extrusionDepth: 0.004, font: font(0.34, .bold))
        let height: Float = 0.92, badge: Float = 0.64, padding: Float = 0.14
        let textWidth = max(titleMesh.bounds.extents.x, subtitleMesh.bounds.extents.x)
        let width = padding + badge + 0.24 + textWidth + 0.32
        let sign = group(root, "room-sign", [p.x, 3.3, p.y])
        let face = group(sign, "room-sign-face", .zero)
        face.orientation = simd_quatf(angle: -0.32, axis: [1, 0, 0])
        glowBox(face, "sign-panel", [width, height, 0.08], [width / 2, 0, 0], signInk, radius: 0.18)
        let accent = accents[(number - 1) % accents.count]
        // An accent edge along the bottom reads like the reference's lit trim.
        glowBox(face, "sign-trim", [width - 0.3, 0.035, 0.02], [width / 2, -height / 2 + 0.07, 0.045], accent)
        glowBox(face, "sign-badge", [badge, badge, 0.03], [padding + badge / 2, 0, 0.05], accent, radius: 0.14)
        let digits = ModelEntity(mesh: numberMesh, materials: [unlit(signInk)])
        digits.position = [padding + badge / 2 - numberMesh.bounds.center.x, -numberMesh.bounds.center.y, 0.07]
        face.addChild(digits)
        let textX = padding + badge + 0.24
        let label = ModelEntity(mesh: titleMesh, materials: [unlit(paper)])
        label.name = "room-sign-\(title)"
        label.position = [textX - titleMesh.bounds.min.x, 0.1 - titleMesh.bounds.center.y, 0.05]
        face.addChild(label)
        let caption = ModelEntity(mesh: subtitleMesh, materials: [unlit(accent)])
        caption.position = [textX - subtitleMesh.bounds.min.x, -0.2 - subtitleMesh.bounds.center.y, 0.05]
        face.addChild(caption)
        // Two slim hangers tie the sign to the wall cap below it.
        for x in [width * 0.18, width * 0.82] { box(sign, "sign-hanger", [0.03, 0.42, 0.03], [x, -0.56, -0.08], trim) }
    }

    /// Soft neon lettering on the back wall of the entrance hall.
    private func neonSign(_ root: Entity, text: String, at p: SIMD3<Float>) {
        let rounded = NSFont.systemFont(ofSize: 0.42, weight: .medium).fontDescriptor.withDesign(.rounded)
        let font = rounded.flatMap { NSFont(descriptor: $0, size: 0.42) } ?? .systemFont(ofSize: 0.42, weight: .medium)
        let mesh = MeshResource.generateText(text, extrusionDepth: 0.02, font: font)
        let sign = group(root, "neon-sign", p)
        let letters = ModelEntity(mesh: mesh, materials: [unlit(neon)])
        letters.position = [-mesh.bounds.center.x, -mesh.bounds.center.y, 0.03]
        sign.addChild(letters)
        glowBox(sign, "neon-halo", [mesh.bounds.extents.x + 0.5, mesh.bounds.extents.y + 0.35, 0.01], .zero,
                signInk, radius: 0.12)
    }

    /// The campus sits in open countryside that runs to the horizon: meadow,
    /// an access road and car park, a site hedge, farm fields, a pond, tree
    /// clumps and hazy hills. It is static scenery, merged by the batcher, and
    /// lies outside the walkable site so it never becomes an obstacle.
    private func countryside(_ root: Entity) {
        let land = group(root, "countryside", .zero)
        let meadow = lawn.blended(withFraction: 0.25, of: green) ?? lawn
        let asphalt = trim.blended(withFraction: 0.45, of: steel) ?? trim
        let haze = palette.background
        var seed: UInt32 = 0x5BD1_E995
        func random() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24)
        }
        // The meadow sits just under the site slab, so the slab reads as a low curb.
        box(land, "countryside-meadow", [1000, 0.1, 1000], [0, -0.17, 0], meadow)
        // A kerbed hedge frames the back and sides of the site.
        box(land, "site-hedge", [49.6, 0.9, 0.8], [0, 0.33, -14.6], green, radius: 0.3)
        for x: Float in [-24.6, 24.6] { box(land, "site-hedge", [0.8, 0.9, 41.6], [x, 0.33, 6.6], green, radius: 0.3) }

        // The access road leaves the sidewalk and meets a country road.
        box(land, "access-road", [6, 0.03, 13], [0, -0.1, 34], asphalt)
        box(land, "country-road", [700, 0.03, 8], [0, -0.1, 44.5], asphalt)
        for z in stride(from: Float(29.5), through: 38.5, by: 3) { box(land, "road-marking", [0.16, 0.01, 1.5], [0, -0.08, z], paper) }
        for x in stride(from: Float(-300), through: 300, by: 5) { box(land, "road-marking", [2.2, 0.01, 0.18], [x, -0.08, 44.5], paper) }
        for z: Float in [40.3, 48.7] { box(land, "road-verge", [700, 0.06, 0.4], [0, -0.09, z], palette.stone) }

        // Car park beside the access road, with parked cars in marked bays.
        box(land, "car-park", [16, 0.03, 9], [-12, -0.1, 34.4], asphalt)
        for index in 0...8 { box(land, "bay-line", [0.12, 0.01, 4], [-19.5 + Float(index) * 1.9, -0.08, 32.4], paper) }
        let carColors = [paper, orange, blue, steel, wood, paper]
        for (index, bay) in [0, 1, 3, 4, 6, 7].enumerated() {
            parkedCar(land, at: [-18.55 + Float(bay) * 1.9, 0, 32.2], yaw: index.isMultiple(of: 2) ? 0 : .pi, color: carColors[index])
        }
        // East of the road: a small lawn with a tree row screening the road.
        for x in stride(from: Float(-40), through: 40, by: 8) where abs(x) > 5 { gardenTree(land, at: [x, 0, 39.6], scale: 0.62) }

        // Farm fields: striped crops with a soil border.
        let crops = [green, cork, lawn.blended(withFraction: 0.5, of: cork) ?? cork]
        for (index, field) in [(SIMD2<Float>(-70, 80), SIMD2<Float>(46, 30)), ([20, 82], [52, 28]), ([88, 70], [40, 34]),
                               ([-95, 10], [34, 44]), ([80, -10], [38, 40]), ([-60, -70], [50, 34]), ([40, -75], [44, 30])].enumerated() {
            box(land, "field-soil", [field.1.x, 0.04, field.1.y], [field.0.x, -0.11, field.0.y], palette.soil)
            let crop = crops[index % crops.count]
            let rows = Int(field.1.y / 2.2)
            for row in 0..<rows {
                let z = field.0.y - field.1.y / 2 + 1.3 + Float(row) * 2.2
                box(land, "field-crop", [field.1.x - 1.6, 0.35, 1.2], [field.0.x, 0.06, z], crop, radius: 0.15)
            }
        }

        // A pond with a stony rim behind the site.
        oval(land, "pond-rim", [30, 0.2, 18], [-48, -0.12, -40], palette.stone)
        oval(land, "pond-water", [27, 0.2, 15.5], [-48, -0.08, -40], palette.water)

        // Tree clumps scattered across the meadow, clear of roads and fields.
        var placed = 0
        while placed < 110 {
            let angle = random() * 2 * .pi
            let radius = 36 + random() * 150
            let p = SIMD3<Float>(cos(angle) * radius, 0, sin(angle) * radius)
            let nearRoad = abs(p.z - 44.5) < 8 || (abs(p.x) < 8 && p.z > 20)
            let onSite = p.x > -30 && p.x < 30 && p.z > -20 && p.z < 50
            let inField = [(SIMD2<Float>(-70, 80), SIMD2<Float>(46, 30)), ([20, 82], [52, 28]), ([88, 70], [40, 34]),
                           ([-95, 10], [34, 44]), ([80, -10], [38, 40]), ([-60, -70], [50, 34]), ([40, -75], [44, 30]), ([-48, -40], [34, 22])]
                .contains { abs(p.x - $0.0.x) < $0.1.x / 2 + 3 && abs(p.z - $0.0.y) < $0.1.y / 2 + 3 }
            guard !nearRoad, !onSite, !inField else { continue }
            countryTree(land, at: p, scale: 0.8 + random() * 0.9, conifer: random() < 0.35)
            placed += 1
        }

        // Rolling hills ring the horizon, hazier with distance.
        for index in 0..<30 {
            let angle = Float(index) / 30 * 2 * .pi + random() * 0.1
            let far = index.isMultiple(of: 2)
            let radius: Float = (far ? 300 : 240) + random() * 30
            let width: Float = 90 + random() * 70
            let height: Float = (far ? 38 : 22) + random() * 18
            let tone = meadow.blended(withFraction: far ? 0.7 : 0.45, of: haze) ?? meadow
            let hill = oval(land, "horizon-hill", [width, height * 2, width * 0.6], [cos(angle) * radius, -2, sin(angle) * radius], tone)
            hill.orientation = simd_quatf(angle: -angle + .pi / 2, axis: [0, 1, 0])
        }
    }

    /// A low-poly country tree: round crowns, or a stacked conifer.
    private func countryTree(_ root: Entity, at p: SIMD3<Float>, scale: Float, conifer: Bool) {
        let tree = group(root, "country-tree", p)
        tree.scale = SIMD3(repeating: scale)
        box(tree, "trunk", [0.5, 2.4, 0.5], [0, 1.2, 0], wood)
        if conifer {
            let needles = green.blended(withFraction: 0.25, of: trim) ?? green
            for (i, size) in [Float(3.6), 2.8, 1.9].enumerated() {
                oval(tree, "conifer-tier", [size, 2.2, size], [0, 2.4 + Float(i) * 1.3, 0], needles)
            }
        } else {
            oval(tree, "tree-crown", [3.6, 3.2, 3.6], [0, 3.6, 0], green)
            oval(tree, "tree-crown", [2.4, 2.2, 2.4], [0.9, 4.6, 0.4], lawn.blended(withFraction: 0.5, of: green) ?? green)
        }
    }

    private func parkedCar(_ root: Entity, at p: SIMD3<Float>, yaw: Float, color: NSColor) {
        let car = group(root, "parked-car", p, yaw: yaw)
        box(car, "car-body", [1.7, 0.55, 3.9], [0, 0.45, 0], color, radius: 0.2)
        box(car, "car-cabin", [1.5, 0.5, 2.1], [0, 0.95, -0.2], color, radius: 0.18)
        box(car, "car-glass", [1.54, 0.3, 2.0], [0, 0.98, -0.2], palette.windowView, radius: 0.1)
        for x: Float in [-0.78, 0.78] { for z: Float in [-1.25, 1.25] {
            box(car, "car-wheel", [0.24, 0.62, 0.62], [x, 0.31, z], trim, radius: 0.2)
        } }
        glowBox(car, "car-lamp", [1.3, 0.1, 0.04], [0, 0.55, 1.95], glow)
    }

    // MARK: Room programmes
    // Every room has its own floor finish and signature furniture, so the
    // rooms read as distinct places from the overview camera.

    /// A room finish: a distinctive hue settled toward the base floor so it
    /// stays calm in both themes.
    private func finish(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        let hue = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        return hue.blended(withFraction: palette.isDark ? 0.6 : 0.18, of: floor) ?? hue
    }

    /// Room 3: a bright café in the glazed room beside the entrance hall.
    private func cafe(_ root: Entity) {
        box(root, "cafe-floor", [10.8, 0.025, 10.8], [-13.5, 0.014, 2.5], finish(0.97, 0.92, 0.84))
        let tiles = group(root, "cafe-tiles", [-13.5, 0, 2.5])
        let tile = finish(0.88, 0.62, 0.50)
        for i in 0..<12 { for j in 0..<12 where (i + j).isMultiple(of: 2) {
            box(tiles, "checker-tile", [0.88, 0.004, 0.88], [-4.95 + Float(i) * 0.9, 0.029, -4.95 + Float(j) * 0.9], tile)
        } }
        roomLabel(root, number: 3, title: "Café", subtitle: "Breaks & chats", at: [-18.4, -3])
        // Coffee bar along the north glass, slatted oak front and a pastry case.
        let bar = group(root, "coffee-counter", [-14.5, 0, -2.25])
        box(bar, "bar-base", [5, 0.95, 0.7], [0, 0.475, 0], wood, radius: 0.03)
        for i in 0..<21 { box(bar, "bar-slat", [0.1, 0.82, 0.03], [-2.4 + Float(i) * 0.24, 0.47, 0.36], oak) }
        box(bar, "bar-top", [5.1, 0.07, 0.8], [0, 0.985, 0], paper, radius: 0.02)
        box(bar, "espresso-machine", [0.8, 0.46, 0.45], [-1.3, 1.25, -0.1], steel, radius: 0.05)
        box(bar, "espresso-face", [0.66, 0.16, 0.02], [-1.3, 1.3, 0.13], trim)
        for x: Float in [-0.2, 0.2] {
            box(bar, "espresso-group", [0.1, 0.08, 0.1], [-1.3 + x, 1.1, 0.16], trim, radius: 0.02)
            box(bar, "espresso-cup", [0.08, 0.07, 0.08], [-1.3 + x, 1.055, 0.18], paper, radius: 0.02)
        }
        box(bar, "grinder-body", [0.22, 0.34, 0.24], [-0.55, 1.19, -0.12], trim, radius: 0.04)
        oval(bar, "grinder-hopper", [0.2, 0.22, 0.2], [-0.55, 1.45, -0.12], wood)
        let case_ = box(bar, "pastry-case", [1.0, 0.36, 0.5], [0.45, 1.2, 0], paper, radius: 0.03)
        case_.model?.materials = [SimpleMaterial(color: palette.glass.withAlphaComponent(0.35), roughness: 0.2, isMetallic: false)]
        for i in 0..<4 { oval(bar, "pastry", [0.18, 0.08, 0.14], [0.1 + Float(i) * 0.23, 1.07, 0.02], i.isMultiple(of: 2) ? orange : wood) }
        for i in 0..<4 { box(bar, "cup-stack", [0.09, 0.07, 0.09], [1.3, 1.055 + Float(i) * 0.07, -0.15], paper, radius: 0.02) }
        box(bar, "charging-shelf", [0.8, 0.06, 0.4], [1.95, 1.05, -0.08], steel)
        for i in 0..<3 { batteryPack(bar, at: [1.7 + Float(i) * 0.25, 1.09, -0.08], color: i == 1 ? orange : green) }
        for x: Float in [-16.2, -14.5, -12.8] { pendantLamp(root, at: [x, 2.15, -2.1]) }
        let menu = group(root, "cafe-menu-board", [-14.5, 2.05, -2.82])
        for x: Float in [-0.7, 0.7] { box(menu, "menu-hanger", [0.02, 0.35, 0.02], [x, 0.7, 0], trim) }
        box(menu, "menu-frame", [1.7, 1.05, 0.05], .zero, wood)
        box(menu, "menu-slate", [1.55, 0.9, 0.02], [0, 0, 0.025], signInk)
        box(menu, "menu-heading", [0.7, 0.07, 0.006], [-0.3, 0.33, 0.038], paper)
        for row in 0..<5 {
            box(menu, "menu-line", [0.55 + Float(row % 2) * 0.2, 0.03, 0.006], [-0.34 + Float(row % 2) * 0.1, 0.18 - Float(row) * 0.12, 0.038], paper)
            box(menu, "menu-price", [0.14, 0.03, 0.006], [0.55, 0.18 - Float(row) * 0.12, 0.038], caution)
        }
        oval(menu, "menu-doodle", [0.18, 0.14, 0.006], [0.52, 0.34, 0.038], orange)
        for x: Float in [-16.1, -12.9] { barStool(root, at: [x, 0, -1.4]) }
        let fridge = group(root, "refrigerator", [-9.5, 0, -2.3])
        box(fridge, "fridge-body", [0.9, 1.9, 0.85], [0, 0.95, 0], paper, radius: 0.04)
        box(fridge, "fridge-seam", [0.91, 0.025, 0.025], [0, 1.3, 0.44], steel)
        box(fridge, "fridge-handle", [0.05, 0.45, 0.05], [-0.3, 0.9, 0.48], steel)
        waterCooler(root, at: [-18.4, 0, -2.4])
        // Bistro tables under pendants, and two booths along the west glass.
        for p: SIMD3<Float> in [[-15.4, 0, 2], [-12.2, 0, 2], [-15.4, 0, 5], [-12.2, 0, 5]] {
            bistroTable(root, at: p)
            pendantLamp(root, at: p + [0, 2.1, 0])
        }
        for z: Float in [1.2, 4.2] { booth(root, at: [-18.25, 0, z]) }
        // Reading corner by the hall door.
        let sofa = group(root, "games-sofa", [-8.8, 0, 0], yaw: -.pi / 2)
        couch(sofa, width: 2, color: blue)
        box(root, "lounge-rug", [1.9, 0.01, 2.9], [-9.3, 0.036, 0], finish(0.72, 0.68, 0.90))
        let side = group(root, "floor-detail", [-8.75, 0, -1.45])
        box(side, "side-table", [0.5, 0.55, 0.5], [0, 0.275, 0], oak, radius: 0.04)
        mug(side, at: [0, 0.55, 0], color: orange)
        floorLamp(root, at: [-8.75, 0, 1.5])
        musicPlayer(root, at: [-11, 0, -2.5])
    }

    /// The lounge record player, wired to the Hermes Spotify plugin. Its
    /// collision volume keeps it out of the static batch so the scene can
    /// hit-test it for hover and animate the named parts below.
    private func musicPlayer(_ root: Entity, at p: SIMD3<Float>) {
        let player = group(root, "music-player", p)
        box(player, "music-cabinet", [1.0, 0.62, 0.44], [0, 0.31, 0], wood, radius: 0.03)
        box(player, "music-cabinet-shelf", [0.9, 0.42, 0.02], [0, 0.3, 0.215], trim)
        for i in 0..<6 {
            box(player, "vinyl-sleeve", [0.03, 0.34, 0.3], [-0.36 + Float(i) * 0.05, 0.3, 0.05], [orange, blue, green, paper, violet, orange][i])
        }
        box(player, "turntable-plinth", [0.56, 0.08, 0.4], [-0.12, 0.66, 0], signInk, radius: 0.02)
        let platter = group(player, "music-platter", [-0.16, 0.71, 0])
        oval(platter, "vinyl-record", [0.32, 0.015, 0.32], .zero, trim)
        oval(platter, "vinyl-label", [0.11, 0.02, 0.11], .zero, orange)
        box(platter, "vinyl-shine", [0.02, 0.018, 0.1], [0, 0, 0.1], paper)
        let arm = box(player, "tonearm", [0.025, 0.02, 0.24], [0.06, 0.73, -0.02], steel)
        arm.orientation = simd_quatf(angle: 0.35, axis: [0, 1, 0])
        box(player, "amplifier", [0.26, 0.12, 0.3], [0.32, 0.68, 0], steel, radius: 0.02)
        for x: Float in [0.25, 0.39] { oval(player, "amplifier-knob", [0.05, 0.05, 0.02], [x, 0.68, 0.155], signInk) }
        for side: Float in [-1, 1] {
            let speaker = group(player, "music-speaker", [side * 0.8, 0, 0])
            box(speaker, "speaker-cabinet", [0.34, 0.95, 0.34], [0, 0.475, 0], signInk, radius: 0.03)
            let woofer = group(speaker, "speaker-woofer", [0, 0.32, 0.175])
            oval(woofer, "woofer-cone", [0.25, 0.25, 0.04], .zero, trim)
            oval(woofer, "woofer-cap", [0.08, 0.08, 0.05], .zero, steel)
            let tweeter = group(speaker, "speaker-tweeter", [0, 0.72, 0.175])
            oval(tweeter, "tweeter-dome", [0.11, 0.11, 0.04], .zero, steel)
            // Bass pressure waves that push out of the woofer on each beat.
            for _ in 0..<2 {
                let wave = ModelEntity(mesh: OfficeLowPolyMesh.ring(thickness: 0.08), materials: [unlit(neon)])
                wave.name = "bass-wave"
                wave.position = [0, 0.32, 0.2]
                wave.isEnabled = false
                speaker.addChild(wave)
            }
        }
        for i in 0..<3 {
            let note = group(player, "music-note", [0, 1.2, 0])
            note.isEnabled = false
            glowBox(note, "note-head", [0.08, 0.06, 0.03], .zero, i == 1 ? violet : neon, radius: 0.025)
            glowBox(note, "note-stem", [0.014, 0.14, 0.014], [0.035, 0.07, 0], i == 1 ? violet : neon)
        }
        // A bobbing marker, light beam and floor ping tell people this piece is interactive.
        let beacon = OfficeScenePalette.interactionBeacon
        let marker = group(player, "interaction-indicator", [0, 1.55, 0])
        let gem = glowBox(marker, "indicator-gem", [0.42, 0.42, 0.42], .zero, beacon, radius: 0.07)
        gem.orientation = simd_quatf(angle: .pi / 4, axis: [0, 0, 1]) * simd_quatf(angle: .pi / 4, axis: [1, 0, 0])
        let beam = glowBox(player, "indicator-beam", [0.12, 2.6, 0.12], [0, 2.5, 0], beacon)
        var beamMaterial = UnlitMaterial(color: beacon)
        beamMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.55))
        beam.model?.materials = [beamMaterial]
        let ping = ModelEntity(mesh: OfficeLowPolyMesh.ring(thickness: 0.05), materials: [unlit(beacon)])
        ping.name = "indicator-ping"
        ping.position = [0, 0.04, 0.2]
        ping.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        player.addChild(ping)
        let halo = oval(player, "indicator-halo", [2.1, 0.01, 0.75], [0, 0.03, 0], neon)
        var haloMaterial = UnlitMaterial(color: neon)
        haloMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.22))
        halo.model?.materials = [haloMaterial]
        player.components.set(CollisionComponent(shapes: [
            ShapeResource.generateBox(size: [2.0, 1.8, 0.6]).offsetBy(translation: [0, 0.9, 0])
        ]))
    }

    /// Room 9: the planning room. A kanban wall with two stand-up rows, a
    /// sticky-note wall, a roadmap strip and a round huddle table.
    private func planningRoom(_ root: Entity) {
        box(root, "planning-floor", [11.8, 0.025, 9.8], [14, 0.014, 3], finish(0.82, 0.78, 0.96))
        roomLabel(root, number: 9, title: "Planning", subtitle: "Kanban board", at: [9.4, -2])
        box(root, "planning-rug", [7.4, 0.01, 3.4], [14, 0.03, 2.9], finish(0.90, 0.78, 0.66))
        pottedTree(root, at: [8.9, 0, 7.1], height: 1.9)
        planningBoard(root, at: [14, 1.6, -1.83], width: 8)
        for column in 0..<5 {
            for row in 0..<3 where (column + row) % 4 != 3 {
                box(root, "board-sticky", [0.34, 0.3, 0.012], [10.2 + Float(column) * 1.7, 2.05 - Float(row) * 0.43, -1.745], stickyColors[(column + row) % 3])
            }
        }
        box(root, "whiteboard-marker-tray", [3.2, 0.06, 0.22], [14, 0.72, -1.7], steel)
        for index in 0..<4 {
            box(root, "whiteboard-marker", [0.18, 0.035, 0.035], [13 + Float(index) * 0.35, 0.77, -1.7], index.isMultiple(of: 2) ? blue : orange)
        }
        // Sticky-note wall on the south partition.
        let wallBoard = group(root, "sticky-wall", [10, 1.55, 7.87], yaw: .pi)
        box(wallBoard, "sticky-wall-cork", [3.4, 1.3, 0.04], .zero, cork)
        for i in 0..<18 {
            let note = box(wallBoard, "sticky-note", [0.32, 0.3, 0.012], [-1.35 + Float(i % 6) * 0.54, 0.4 - Float(i / 6) * 0.4, 0.03], stickyColors[(i * 7) % 3])
            note.orientation = simd_quatf(angle: Float(i % 3 - 1) * 0.06, axis: [0, 0, 1])
        }
        // Roadmap strip on the west wall: swimlanes of coloured bars.
        let roadmap = group(root, "roadmap-strip", [8.12, 1.6, 5.5], yaw: .pi / 2)
        box(roadmap, "roadmap-backing", [4.2, 0.95, 0.03], .zero, paper)
        for lane in 0..<4 {
            box(roadmap, "roadmap-lane", [4.0, 0.006, 0.01], [0, 0.34 - Float(lane) * 0.22, 0.02], steel)
            for bar in 0..<2 {
                let start = -1.7 + Float((lane * 3 + bar * 5) % 7) * 0.42
                box(roadmap, "roadmap-bar", [0.9 + Float(bar) * 0.3, 0.1, 0.012], [start + 0.45, 0.24 - Float(lane) * 0.22, 0.025],
                    [blue, orange, green, caution][(lane + bar) % 4], radius: 0.03)
            }
        }
        // Standing table for quick syncs; a round huddle table with chairs.
        let standing = group(root, "floor-detail", [11.2, 0, 5.2])
        table(standing, size: [2.2, 0.08, 0.9], at: .zero, height: 1.05, color: oak)
        for x: Float in [-0.6, 0.1] { box(standing, "sticky-pad", [0.2, 0.03, 0.2], [x, 1.11, 0.1], stickyColors[x < 0 ? 0 : 1]) }
        laptop(standing, at: [0.6, 1.11, 0])
        let huddle = group(root, "floor-detail", [17, 0, 5.3])
        oval(huddle, "huddle-top", [1.3, 0.06, 1.3], [0, 0.76, 0], paper)
        box(huddle, "huddle-pedestal", [0.12, 0.72, 0.12], [0, 0.37, 0], trim)
        oval(huddle, "huddle-foot", [0.6, 0.04, 0.6], [0, 0.02, 0], trim)
        for i in 0..<4 {
            let angle = Float(i) * .pi / 2 + .pi / 4
            chair(huddle, at: [sin(angle) * 1.0, 0, cos(angle) * 1.0], yaw: angle + .pi, color: blue)
        }
        plant(huddle, at: [0, 0.79, 0], height: 0.4)
        rollingWhiteboard(root, at: [19.35, 0, -0.9])
        pottedTree(root, at: [19.3, 0, 7.3], height: 2.1)
    }

    /// Room 10: warehouse racking, a loaded pallet and a packing bench.
    private func partsDepot(_ root: Entity) {
        box(root, "parts-depot-floor", [6.8, 0.025, 7.8], [11.5, 0.014, 12], finish(0.78, 0.75, 0.70))
        for z: Float in [11.0, 14.2] { box(root, "aisle-line", [6.6, 0.006, 0.07], [11.5, 0.03, z], caution) }
        roomLabel(root, number: 10, title: "Parts Depot", subtitle: "Supplies", at: [8.4, 8])
        for x: Float in [9.2, 11.2, 13.2] { storageShelf(root, at: [x, 0, 12.7]) }
        let pallet = group(root, "floor-detail", [9.6, 0, 15.1])
        for x: Float in [-0.5, 0, 0.5] { box(pallet, "pallet-runner", [0.12, 0.1, 1.0], [x, 0.05, 0], wood) }
        for z: Float in [-0.4, -0.13, 0.13, 0.4] { box(pallet, "pallet-deck", [1.2, 0.04, 0.18], [0, 0.12, z], wood) }
        for i in 0..<5 {
            let x: Float = i < 3 ? -0.36 + Float(i) * 0.36 : -0.18 + Float(i - 3) * 0.36
            box(pallet, "carton", [0.34, 0.3, 0.8], [x, i < 3 ? 0.29 : 0.59, 0], i.isMultiple(of: 2) ? cork : paper, radius: 0.015)
        }
        let truck = group(root, "floor-detail", [11.1, 0, 15.3])
        strut(truck, "hand-truck-rail", from: [-0.18, 0.05, 0], to: [-0.18, 1.2, -0.12], width: 0.04, color: orange)
        strut(truck, "hand-truck-rail", from: [0.18, 0.05, 0], to: [0.18, 1.2, -0.12], width: 0.04, color: orange)
        box(truck, "hand-truck-toe", [0.42, 0.03, 0.26], [0, 0.03, 0.12], steel)
        box(truck, "hand-truck-grip", [0.4, 0.04, 0.04], [0, 1.2, -0.12], trim)
        for x: Float in [-0.24, 0.24] { oval(truck, "hand-truck-wheel", [0.06, 0.22, 0.22], [x, 0.11, -0.05], trim) }
        let bench = group(root, "floor-detail", [13.4, 0, 15.25])
        table(bench, size: [1.9, 0.08, 0.75], at: .zero, height: 0.9, color: oak)
        box(bench, "packing-box", [0.5, 0.3, 0.4], [-0.45, 1.09, 0], cork, radius: 0.01)
        box(bench, "tape-dispenser", [0.22, 0.14, 0.1], [0.2, 1.01, 0.1], trim, radius: 0.02)
        oval(bench, "tape-roll", [0.14, 0.14, 0.05], [0.2, 1.1, 0.1], caution)
        oval(bench, "kraft-roll", [0.9, 0.16, 0.16], [0.45, 1.02, -0.2], paper)
    }

    /// Room 12: ping-pong, two arcade cabinets, a beanbag and a dartboard.
    private func gameRoom(_ root: Entity) {
        box(root, "game-room-floor", [4.8, 0.025, 7.8], [17.5, 0.014, 12], finish(0.60, 0.84, 0.78))
        roomLabel(root, number: 12, title: "Game Room", subtitle: "Downtime", at: [15.4, 8])
        let pong = group(root, "floor-detail", [17.5, 0, 12])
        let felt = NSColor(srgbRed: 0.24, green: 0.50, blue: 0.44, alpha: 1)
        box(pong, "pong-top", [1.5, 0.06, 2.7], [0, 0.76, 0], felt, radius: 0.01)
        box(pong, "pong-centre-line", [0.02, 0.004, 2.66], [0, 0.792, 0], paper)
        box(pong, "pong-edge-line", [1.46, 0.004, 0.02], [0, 0.792, 1.33], paper)
        box(pong, "pong-edge-line", [1.46, 0.004, 0.02], [0, 0.792, -1.33], paper)
        box(pong, "pong-net", [1.62, 0.15, 0.015], [0, 0.865, 0], paper)
        for x: Float in [-0.62, 0.62] { for z: Float in [-1.1, 1.1] { box(pong, "pong-leg", [0.06, 0.73, 0.06], [x, 0.365, z], trim) } }
        oval(pong, "pong-paddle", [0.16, 0.02, 0.2], [0.3, 0.8, 0.9], orange)
        oval(pong, "pong-paddle", [0.16, 0.02, 0.2], [-0.35, 0.8, -1.0], blue)
        oval(pong, "pong-ball", [0.04, 0.04, 0.04], [0.1, 0.81, 0.4], paper)
        pendantLamp(root, at: [17.5, 2.2, 11.3])
        pendantLamp(root, at: [17.5, 2.2, 12.7])
        for z: Float in [9.7, 14.4] { arcade(root, at: [15.55, 0, z], yaw: .pi / 2) }
        beanbag(root, at: [19.05, 0, 15.0], color: orange)
        let dart = group(root, "dartboard", [19.89, 1.7, 14.0], yaw: -.pi / 2)
        box(dart, "dart-cabinet", [0.78, 0.78, 0.05], .zero, wood, radius: 0.03)
        for (i, size) in [Float(0.56), 0.4, 0.24, 0.08].enumerated() {
            oval(dart, "dart-ring", [size, size, 0.02], [0, 0, 0.04 + Float(i) * 0.004], [signInk, orange, paper, orange][i])
        }
    }

    /// Room 13: an open library nook in the west corridor.
    private func library(_ root: Entity) {
        box(root, "library-rug", [5.4, 0.01, 3.2], [-14.7, 0.018, 11.4], finish(0.72, 0.82, 0.64))
        for x: Float in [-17.2, -15.8, -14.4] {
            bookcase(root, at: [x, 0, 8.55], yaw: 0)
            workStation(.library, [x, 0, 9.45], approach: [x, 0, 10.2], yaw: .pi, seated: false)
        }
        armchair(root, at: [-16.2, 0, 11.4], yaw: .pi / 2, color: orange)
        armchair(root, at: [-13.2, 0, 11.4], yaw: -.pi / 2, color: blue)
        let side = group(root, "floor-detail", [-14.7, 0, 11.4])
        oval(side, "side-table-top", [0.6, 0.05, 0.6], [0, 0.5, 0], oak)
        box(side, "side-table-stem", [0.07, 0.48, 0.07], [0, 0.25, 0], trim)
        bookStack(side, at: [0, 0.53, 0], count: 2)
        floorLamp(root, at: [-17.1, 0, 12.5])
        pottedTree(root, at: [-8.9, 0, 13.4], height: 2)
    }

    /// Every room without its own pendants gets linear ceiling lights, so
    /// the office reads as lit from inside at night.
    private func ceilingLights(_ root: Entity) {
        for x: Float in [-25, -20, -15, -10] { ceilingLight(root, at: [x, -7.5], length: 2.2) }
        for p: SIMD2<Float> in [[-25, -0.25], [-25, 5.25], [-25, 11], [-20, 12]] { ceilingLight(root, at: p) }
        for z: Float in [0.5, 6.5] { ceilingLight(root, at: [-20.5, z], yaw: .pi / 2) }
        for z: Float in [0.5, 7.5] { ceilingLight(root, at: [0, z], yaw: .pi / 2) }
        for x: Float in [11, 16] { ceilingLight(root, at: [x, -6.5], length: 2.2) }
        for p: SIMD2<Float> in [[24, -8.5], [24, -2], [24, 3], [14, 3], [11.5, 12], [24, 9.5]] { ceilingLight(root, at: p) }
    }

    /// A slim linear pendant. The whole bar glows so it reads from the high
    /// camera; the pool below stands in for its light.
    private func ceilingLight(_ root: Entity, at p: SIMD2<Float>, length: Float = 1.6, yaw: Float = 0) {
        let light = group(root, "ceiling-light", [p.x, 2.55, p.y], yaw: yaw)
        for x in [-length * 0.4, length * 0.4] { box(light, "ceiling-light-cable", [0.012, 0.32, 0.012], [x, 0.19, 0], trim) }
        glowBox(light, "ceiling-light-diffuser", [length, 0.06, 0.14], .zero, glow, radius: 0.02)
        for x in [-length / 2, length / 2] { box(light, "ceiling-light-cap", [0.04, 0.08, 0.17], [x, 0, 0], trim) }
        lightPool(root, at: [p.x, 0, p.y], radius: 1.3 + length * 0.5)
    }

    private func pendantLamp(_ root: Entity, at p: SIMD3<Float>) {
        box(root, "pendant-cord", [0.02, 2.9 - p.y, 0.02], [p.x, (2.9 + p.y) / 2, p.z], trim)
        box(root, "pendant-shade", [0.42, 0.22, 0.42], p + [0, 0.05, 0], oak, radius: 0.1)
        glowBox(root, "pendant-bulb", [0.28, 0.04, 0.28], p + [0, -0.07, 0], glow, radius: 0.06)
        lightPool(root, at: p, radius: 1.1)
    }

    private func barStool(_ root: Entity, at p: SIMD3<Float>) {
        let stool = group(root, "floor-detail", p)
        oval(stool, "stool-seat", [0.42, 0.08, 0.42], [0, 0.72, 0], orange)
        box(stool, "stool-post", [0.05, 0.68, 0.05], [0, 0.36, 0], steel)
        box(stool, "stool-ring", [0.32, 0.025, 0.32], [0, 0.3, 0], steel, radius: 0.1)
        oval(stool, "stool-foot", [0.38, 0.03, 0.38], [0, 0.015, 0], trim)
    }

    private func bistroTable(_ root: Entity, at p: SIMD3<Float>) {
        let set = group(root, "floor-detail", p)
        oval(set, "bistro-top", [0.9, 0.05, 0.9], [0, 0.76, 0], paper)
        box(set, "bistro-pedestal", [0.07, 0.72, 0.07], [0, 0.37, 0], trim)
        oval(set, "bistro-foot", [0.46, 0.03, 0.46], [0, 0.015, 0], trim)
        mug(set, at: [0.16, 0.785, 0.1], color: orange)
        oval(set, "bistro-plate", [0.28, 0.02, 0.28], [-0.14, 0.79, -0.08], paper)
        for side: Float in [-1, 1] {
            let seat = group(set, "cafe-chair", [side * 0.72, 0, 0], yaw: side < 0 ? .pi / 2 : -.pi / 2)
            box(seat, "cafe-chair-seat", [0.46, 0.06, 0.44], [0, 0.47, 0], oak, radius: 0.03)
            box(seat, "cafe-chair-back", [0.44, 0.36, 0.05], [0, 0.7, -0.2], oak, radius: 0.03)
            for x: Float in [-0.18, 0.18] { for z: Float in [-0.17, 0.17] { box(seat, "cafe-chair-leg", [0.035, 0.45, 0.035], [x, 0.225, z], trim) } }
        }
    }

    private func booth(_ root: Entity, at p: SIMD3<Float>) {
        let booth = group(root, "floor-detail", p)
        for side: Float in [-1, 1] {
            box(booth, "booth-bench", [1.2, 0.44, 0.5], [0, 0.22, side * 0.85], wood, radius: 0.03)
            box(booth, "booth-cushion", [1.14, 0.1, 0.46], [0, 0.49, side * 0.83], blue, radius: 0.04)
            box(booth, "booth-back", [1.2, 0.75, 0.14], [0, 0.8, side * 1.05], blue, radius: 0.05)
        }
        box(booth, "booth-table", [1.0, 0.06, 0.8], [0, 0.74, 0], oak, radius: 0.02)
        box(booth, "booth-pedestal", [0.08, 0.7, 0.08], [0, 0.36, 0], trim)
        mug(booth, at: [0.2, 0.77, 0.15], color: paper)
        pendantLamp(root, at: p + [0, 2.1, 0])
    }

    private func armchair(_ root: Entity, at p: SIMD3<Float>, yaw: Float, color: NSColor) {
        let chair = group(root, "visitor-armchair", p, yaw: yaw)
        box(chair, "armchair-base", [0.9, 0.3, 0.85], [0, 0.3, 0], color, radius: 0.08)
        box(chair, "armchair-cushion", [0.66, 0.14, 0.66], [0, 0.5, 0.06], color, radius: 0.06)
        box(chair, "armchair-back", [0.9, 0.62, 0.18], [0, 0.72, -0.34], color, radius: 0.08)
        for x: Float in [-0.4, 0.4] { box(chair, "armchair-arm", [0.14, 0.34, 0.8], [x, 0.58, 0], color, radius: 0.06) }
        for x: Float in [-0.36, 0.36] { for z: Float in [-0.34, 0.34] { box(chair, "armchair-leg", [0.05, 0.16, 0.05], [x, 0.08, z], oak) } }
    }

    private func rollingWhiteboard(_ root: Entity, at p: SIMD3<Float>) {
        let board = group(root, "floor-detail", p, yaw: -.pi / 2)
        box(board, "rolling-board", [1.6, 1.0, 0.04], [0, 1.45, 0], paper)
        box(board, "rolling-board-frame", [1.66, 0.05, 0.06], [0, 1.97, 0], steel)
        box(board, "rolling-board-frame", [1.66, 0.05, 0.06], [0, 0.93, 0], steel)
        for x: Float in [-0.8, 0.8] {
            box(board, "rolling-board-leg", [0.05, 1.95, 0.05], [x, 0.98, 0], steel)
            box(board, "rolling-board-foot", [0.06, 0.04, 0.55], [x, 0.06, 0], steel)
            for z: Float in [-0.24, 0.24] { oval(board, "caster", [0.07, 0.07, 0.07], [x, 0.035, z], trim) }
        }
        for i in 0..<3 { box(board, "board-scribble", [0.5 - Float(i) * 0.1, 0.03, 0.006], [-0.3 + Float(i) * 0.05, 1.7 - Float(i) * 0.18, 0.025], [blue, orange, blue][i]) }
    }

    private func easel(_ root: Entity, at p: SIMD3<Float>) {
        let easel = group(root, "floor-detail", p, yaw: .pi / 2)
        strut(easel, "easel-leg", from: [-0.35, 0, 0.15], to: [0, 1.9, 0], width: 0.04, color: oak)
        strut(easel, "easel-leg", from: [0.35, 0, 0.15], to: [0, 1.9, 0], width: 0.04, color: oak)
        strut(easel, "easel-leg", from: [0, 0, -0.45], to: [0, 1.8, -0.02], width: 0.04, color: oak)
        box(easel, "easel-ledge", [0.8, 0.04, 0.1], [0, 0.85, 0.14], oak)
        let canvas = box(easel, "easel-canvas", [0.78, 0.95, 0.03], [0, 1.35, 0.1], paper)
        canvas.orientation = simd_quatf(angle: -0.08, axis: [1, 0, 0])
        box(easel, "canvas-arch", [0.3, 0.42, 0.01], [-0.12, 1.28, 0.13], orange, radius: 0.12)
        oval(easel, "canvas-sun", [0.18, 0.18, 0.01], [0.2, 1.55, 0.125], green)
    }

    private func slatPanel(_ root: Entity, at p: SIMD3<Float>, width: Float, height: Float, yaw: Float) {
        let panel = group(root, "slat-panel", p, yaw: yaw)
        box(panel, "slat-backing", [width, height, 0.02], .zero, trim)
        let count = Int(width / 0.13)
        for i in 0..<count { box(panel, "wood-slat", [0.08, height, 0.05], [-width / 2 + 0.07 + Float(i) * 0.13, 0, 0.035], oak) }
    }

    /// A low-poly potted tree, like the ones in the reference studio.
    private func pottedTree(_ root: Entity, at p: SIMD3<Float>, height: Float) {
        let tree = group(root, "broad-leaf-plant", p)
        box(tree, "planter", [0.5, 0.5, 0.5], [0, 0.25, 0], paper, radius: 0.08)
        box(tree, "planter-soil", [0.42, 0.02, 0.42], [0, 0.5, 0], wood)
        strut(tree, "tree-trunk", from: [0, 0.5, 0], to: [0.04, height * 0.72, 0], width: 0.06, color: wood)
        for (i, o) in [SIMD3<Float>(0, 0.8, 0), [-0.2, 0.66, 0.1], [0.2, 0.7, -0.1], [0.04, 0.93, 0.06]].enumerated() {
            let size: Float = i == 3 ? 0.42 : 0.6
            oval(tree, "tree-canopy", [size, size * 0.9, size], [o.x, o.y * height, o.z], green)
        }
    }

    /// A robot on a two-post service lift, with its access panel off.
    private func serviceLift(_ root: Entity, at p: SIMD3<Float>) {
        let lift = group(root, "floor-detail", p)
        box(lift, "lift-plate", [1.6, 0.05, 1.5], [0, 0.025, 0], steel)
        for x: Float in [-0.72, 0.72] {
            box(lift, "lift-post", [0.16, 2.2, 0.16], [x, 1.1, 0], caution, radius: 0.02)
            box(lift, "lift-arm", [0.5, 0.06, 0.1], [x * 0.75, 0.72, -0.4], steel)
            box(lift, "lift-arm", [0.5, 0.06, 0.1], [x * 0.75, 0.72, 0.4], steel)
        }
        box(lift, "lift-crossbar", [1.6, 0.1, 0.12], [0, 2.22, 0], caution)
        box(lift, "lift-platform", [1.1, 0.08, 1.2], [0, 0.78, 0], trim)
        box(lift, "robot-body", [0.6, 0.55, 0.45], [0, 1.1, 0], paper, radius: 0.18)
        box(lift, "robot-head", [0.68, 0.5, 0.52], [0, 1.62, 0], paper, radius: 0.2)
        box(lift, "robot-visor", [0.5, 0.26, 0.02], [0, 1.64, 0.26], signInk, radius: 0.08)
        box(lift, "robot-access-hole", [0.26, 0.22, 0.01], [0, 1.1, 0.227], trim, radius: 0.04)
        box(lift, "robot-panel", [0.26, 0.22, 0.03], [0.4, 0.83, 0.4], paper, radius: 0.04)
        strut(lift, "diagnostic-lead", from: [0, 1.08, 0.23], to: [0.5, 0.84, 0.55], width: 0.02, color: orange)
    }

    private func toolChest(_ root: Entity, at p: SIMD3<Float>) {
        let chest = group(root, "floor-detail", p, yaw: .pi / 2)
        let red = NSColor(srgbRed: 0.82, green: 0.30, blue: 0.27, alpha: 1)
        box(chest, "chest-body", [0.95, 1.0, 0.5], [0, 0.56, 0], red, radius: 0.03)
        for i in 0..<5 {
            box(chest, "chest-drawer", [0.86, 0.14, 0.02], [0, 0.2 + Float(i) * 0.17, 0.26], red.blended(withFraction: 0.2, of: .black) ?? red)
            box(chest, "chest-pull", [0.5, 0.025, 0.03], [0, 0.24 + Float(i) * 0.17, 0.28], steel)
        }
        box(chest, "chest-top", [0.98, 0.04, 0.52], [0, 1.08, 0], trim)
        for x: Float in [-0.38, 0.38] { oval(chest, "caster", [0.09, 0.09, 0.09], [x, 0.05, 0.14], trim) }
        box(chest, "torque-wrench", [0.5, 0.04, 0.05], [0.05, 1.12, 0], steel)
    }

    // MARK: Robot-crew props
    // Present-day equipment a robot team would plausibly own: workshop
    // hardware, chargers and delivery robots. All static, no update loops.

    /// Two-metre floor tiles and painted walkway lines down the central hall.
    private func floorGrid(_ root: Entity) {
        for (center, size) in [(SIMD2<Float>(-18, 1), SIMD2<Float>(20, 26)), (SIMD2<Float>(18, 2), SIMD2<Float>(20, 28))] {
            for x in stride(from: center.x - size.x / 2 + 2, to: center.x + size.x / 2, by: 2) {
                box(root, "floor-seam", [0.02, 0.004, size.y], [x, 0.002, center.y], trim)
            }
            for z in stride(from: center.y - size.y / 2 + 2, to: center.y + size.y / 2, by: 2) {
                box(root, "floor-seam", [size.x, 0.004, 0.02], [center.x, 0.002, z], trim)
            }
        }
        for x: Float in [-1.2, 1.2] { box(root, "walkway-line", [0.07, 0.004, 25.5], [x, 0.003, 1.2], orange) }
    }

    /// A robot shell mid-assembly on a work platform, head hanging from a hoist.
    private func assemblyCradle(_ root: Entity, at p: SIMD3<Float>) {
        let cradle = group(root, "floor-detail", p)
        box(cradle, "assembly-platform", [1.4, 0.16, 1.1], [0, 0.08, 0], trim, radius: 0.04)
        for x: Float in [-0.62, 0.62] { box(cradle, "hoist-upright", [0.07, 2.0, 0.07], [x, 1.08, -0.4], steel) }
        box(cradle, "hoist-beam", [1.32, 0.08, 0.1], [0, 2.08, -0.4], steel)
        box(cradle, "hoist-boom", [0.08, 0.08, 0.5], [0, 2.0, -0.15], steel)
        box(cradle, "hoist-cable", [0.02, 0.32, 0.02], [0, 1.8, 0.05], trim)
        for x: Float in [-0.12, 0.12] { box(cradle, "shell-leg", [0.13, 0.4, 0.15], [x, 0.36, 0.05], paper, radius: 0.05) }
        box(cradle, "shell-torso", [0.5, 0.46, 0.38], [0, 0.8, 0.05], paper, radius: 0.12)
        box(cradle, "open-hatch", [0.24, 0.2, 0.02], [0, 0.82, 0.245], trim)
        box(cradle, "hanging-head", [0.56, 0.42, 0.46], [0, 1.43, 0.05], paper, radius: 0.14)
        // Unpowered: the visor has no eyes yet.
        box(cradle, "hanging-visor", [0.44, 0.24, 0.02], [0, 1.43, 0.285], signInk, radius: 0.06)
        for side: Float in [-1, 1] { box(cradle, "loose-arm", [0.36, 0.1, 0.1], [side * 0.42, 0.21, 0.42], paper, radius: 0.04) }
    }

    /// A bolted-down industrial arm reaching toward the assembly platform.
    private func robotArm(_ root: Entity, at p: SIMD3<Float>, yaw: Float) {
        let arm = group(root, "floor-detail", p, yaw: yaw)
        oval(arm, "arm-base", [0.8, 0.2, 0.8], [0, 0.1, 0], trim)
        box(arm, "arm-turret", [0.5, 0.35, 0.5], [0, 0.37, 0], orange, radius: 0.1)
        let shoulder = SIMD3<Float>(0, 0.62, 0), elbow = SIMD3<Float>(0.3, 1.55, 0), wrist = SIMD3<Float>(0.95, 1.3, 0)
        strut(arm, "arm-upper", from: shoulder, to: elbow, width: 0.18, color: orange)
        strut(arm, "arm-fore", from: elbow, to: wrist, width: 0.14, color: orange)
        for joint in [shoulder, elbow, wrist] { oval(arm, "arm-joint", [0.26, 0.26, 0.26], joint, trim) }
        box(arm, "gripper-palm", [0.1, 0.08, 0.2], wrist + [0.1, -0.08, 0], steel)
        for z: Float in [-0.07, 0.07] { box(arm, "gripper-finger", [0.04, 0.16, 0.035], wrist + [0.14, -0.18, z], steel) }
        glowBox(arm, "arm-status-light", [0.12, 0.04, 0.02], [0, 0.45, 0.26], green)
    }

    /// A retro tin robot on a plinth: the main agent's desk trophy.
    private func robotTrophy(_ root: Entity, at p: SIMD3<Float>) {
        let trophy = group(root, "floor-detail", p)
        box(trophy, "trophy-plinth", [0.8, 0.9, 0.8], [0, 0.45, 0], wood, radius: 0.04)
        box(trophy, "trophy-plaque", [0.4, 0.1, 0.02], [0, 0.7, 0.41], orange)
        for x: Float in [-0.1, 0.1] { box(trophy, "tin-leg", [0.1, 0.24, 0.12], [x, 1.02, 0], steel) }
        box(trophy, "tin-body", [0.42, 0.42, 0.3], [0, 1.35, 0], steel)
        oval(trophy, "tin-dial", [0.12, 0.12, 0.03], [0, 1.38, 0.155], orange)
        for x: Float in [-0.26, 0.26] { box(trophy, "tin-arm", [0.08, 0.3, 0.08], [x, 1.3, 0], trim) }
        box(trophy, "tin-head", [0.34, 0.28, 0.28], [0, 1.72, 0], steel)
        for x: Float in [-0.08, 0.08] { oval(trophy, "tin-eye", [0.08, 0.08, 0.03], [x, 1.74, 0.145], paper) }
        box(trophy, "tin-mouth", [0.16, 0.03, 0.02], [0, 1.64, 0.145], trim)
        box(trophy, "tin-antenna", [0.02, 0.18, 0.02], [0, 1.95, 0], trim)
        oval(trophy, "tin-antenna-ball", [0.07, 0.07, 0.07], [0, 2.06, 0], orange)
    }

    /// A small quadcopter, hovering or parked. Never a floor obstacle.
    private func drone(_ root: Entity, at p: SIMD3<Float>, yaw: Float = 0, scale: Float = 1) {
        let drone = group(root, "service-drone", p, yaw: yaw)
        drone.scale = [scale, scale, scale]
        box(drone, "drone-body", [0.46, 0.18, 0.46], .zero, paper, radius: 0.08)
        box(drone, "drone-camera", [0.14, 0.1, 0.1], [0, -0.1, 0.2], signInk, radius: 0.03)
        for index in 0..<4 {
            let angle = Float.pi / 4 + Float(index) * .pi / 2
            let tip = SIMD3<Float>(cos(angle) * 0.5, 0.04, sin(angle) * 0.5)
            strut(drone, "drone-arm", from: [cos(angle) * 0.15, 0.04, sin(angle) * 0.15], to: tip, width: 0.05, color: trim)
            box(drone, "drone-motor", [0.08, 0.08, 0.08], tip + [0, 0.04, 0], trim, radius: 0.03)
            oval(drone, "drone-rotor", [0.34, 0.015, 0.34], tip + [0, 0.1, 0], steel)
        }
        glowBox(drone, "drone-light", [0.06, 0.03, 0.02], [0, 0.02, 0.24], green)
    }

    private func dataSlate(_ root: Entity, at p: SIMD3<Float>, yaw: Float) {
        let slate = group(root, "tablet", p, yaw: yaw)
        box(slate, "tablet-case", [0.3, 0.02, 0.22], [0, 0.01, 0], trim, radius: 0.008)
        box(slate, "tablet-screen", [0.26, 0.004, 0.18], [0, 0.022, 0], blue)
    }

    private func batteryPack(_ root: Entity, at p: SIMD3<Float>, color: NSColor) {
        let pack = group(root, "battery-pack", p)
        box(pack, "battery-body", [0.16, 0.24, 0.1], [0, 0.12, 0], color, radius: 0.02)
        box(pack, "battery-label", [0.165, 0.06, 0.105], [0, 0.12, 0], paper)
        box(pack, "battery-terminal", [0.04, 0.03, 0.04], [0, 0.255, 0], steel)
    }

    /// A robot on a turntable under a task lamp, for inspection and repair.
    private func repairStand(_ root: Entity, at p: SIMD3<Float>) {
        let stand = group(root, "floor-detail", p)
        oval(stand, "turntable", [1.2, 0.12, 1.2], [0, 0.06, 0], trim)
        oval(stand, "turntable-top", [1.05, 0.03, 1.05], [0, 0.13, 0], steel)
        for x: Float in [-0.11, 0.11] { box(stand, "patient-leg", [0.13, 0.36, 0.15], [x, 0.33, 0], paper, radius: 0.05) }
        box(stand, "patient-body", [0.46, 0.42, 0.34], [0, 0.72, 0], paper, radius: 0.12)
        box(stand, "patient-head", [0.56, 0.42, 0.44], [0, 1.16, 0], paper, radius: 0.14)
        box(stand, "patient-visor", [0.44, 0.24, 0.02], [0, 1.17, 0.22], signInk, radius: 0.06)
        for x: Float in [-0.09, 0.09] { glowBox(stand, "patient-eye", [0.06, 0.07, 0.01], [x, 1.18, 0.235], palette.activeScreen) }
        for x: Float in [-0.3, 0.3] { box(stand, "patient-headphone", [0.07, 0.24, 0.2], [x, 1.17, 0], blue, radius: 0.03) }
        box(stand, "lamp-post", [0.06, 1.9, 0.06], [0.55, 0.95, -0.45], steel)
        accessoryArm(stand, from: [0.55, 1.9, -0.45], to: [0.15, 1.95, -0.1])
        box(stand, "task-lamp-shade", [0.25, 0.14, 0.2], [0.1, 1.9, -0.05], trim, radius: 0.035)
        glowBox(stand, "task-lamp-diffuser", [0.2, 0.014, 0.15], [0.1, 1.82, -0.05], glow)
    }

    /// A wall-backed charging bay; the bot backs onto the contact plate.
    private func chargingCradle(_ root: Entity, at p: SIMD3<Float>) {
        let cradle = group(root, "charging-cradle", p)
        oval(cradle, "charging-pad", [0.9, 0.04, 0.8], [0, 0.02, 0], steel)
        box(cradle, "charging-backplate", [0.9, 1.6, 0.12], [0, 0.85, 0.4], trim, radius: 0.04)
        box(cradle, "contact-plate", [0.4, 0.3, 0.05], [0, 0.85, 0.33], steel, radius: 0.02)
        box(cradle, "charging-cable", [0.04, 0.6, 0.04], [0.32, 1.1, 0.32], signInk)
        glowBox(cradle, "charging-indicator", [0.16, 0.05, 0.01], [0, 1.45, 0.335], green)
    }

    /// A lattice radio mast with a dish and a red aircraft-warning lamp.
    private func radioMast(_ root: Entity, at p: SIMD3<Float>) {
        let mast = group(root, "radio-mast", p)
        box(mast, "mast-footing", [1.3, 0.2, 1.3], [0, 0.1, 0], trim, radius: 0.05)
        let top: Float = 6, base: Float = 0.5, peak: Float = 0.12
        for (x, z) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
            strut(mast, "mast-leg", from: [x * base, 0.2, z * base], to: [x * peak, top, z * peak], width: 0.06, color: steel)
        }
        for level in 1..<6 {
            let y = 0.2 + Float(level) * (top - 0.2) / 6
            let w = base + (peak - base) * (y - 0.2) / (top - 0.2)
            for (a, b) in [([-w, -w], [w, -w]), ([w, -w], [w, w]), ([w, w], [-w, w]), ([-w, w], [-w, -w])] as [(SIMD2<Float>, SIMD2<Float>)] {
                strut(mast, "mast-brace", from: [a.x, y, a.y], to: [b.x, y, b.y], width: 0.035, color: steel)
            }
        }
        let dish = oval(mast, "mast-dish", [0.9, 0.9, 0.16], [0, 4.6, 0.45], paper)
        dish.orientation = simd_quatf(angle: -0.5, axis: [1, 0, 0])
        box(mast, "mast-rod", [0.03, 0.9, 0.03], [0, top + 0.45, 0], steel)
        glowOval(mast, "mast-warning-lamp", [0.14, 0.14, 0.14], [0, top + 0.95, 0], NSColor(srgbRed: 1, green: 0.32, blue: 0.28, alpha: 1))
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
        glowBox(lamp, "lamp-shade", [0.58, 0.4, 0.58], [0, 1.6, 0], glow, radius: 0.08)
        lightPool(root, at: p, radius: 1.7)
    }

    /// A warm wall sconce between windows, washing the wall and floor below.
    private func wallSconce(_ root: Entity, at p: SIMD3<Float>) {
        let sconce = group(root, "wall-sconce", p)
        box(sconce, "sconce-plate", [0.16, 0.30, 0.03], [0, 0, 0], oak, radius: 0.03)
        glowBox(sconce, "sconce-shade", [0.26, 0.20, 0.16], [0, 0.03, 0.1], glow, radius: 0.06)
        lightPool(root, at: [p.x, 0, p.z + 0.9], radius: 1.4)
    }

    /// A soft pool of lamplight on the floor. It is a radial-gradient decal
    /// rather than a dynamic light, so it costs one transparent quad.
    private func lightPool(_ root: Entity, at p: SIMD3<Float>, radius: Float) {
        guard let material = poolMaterial else { return }
        let key = "pool-\(radius)"
        let mesh = meshes[key] ?? MeshResource.generatePlane(width: radius * 2, depth: radius * 2)
        meshes[key] = mesh
        let pool = ModelEntity(mesh: mesh, materials: [material])
        pool.name = "light-pool"
        pool.position = [p.x, 0.075, p.z]
        root.addChild(pool)
    }

    private lazy var poolMaterial: UnlitMaterial? = {
        guard #available(macOS 15.0, *) else { return nil }
        let size = 128
        // RGBA with explicit row bytes: a one-channel image's padded rows are
        // read with the wrong stride and the pool smears into diagonal stripes.
        let space = CGColorSpace(name: CGColorSpace.linearSRGB)!
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let gradient = CGGradient(colorsSpace: space,
                                        colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.35, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray,
                                        locations: [0, 0.45, 1]) else { return nil }
        let center = CGPoint(x: size / 2, y: size / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(size / 2), options: [])
        guard let image = context.makeImage(),
              let texture = try? TextureResource(image: image, options: .init(semantic: .raw)) else { return nil }
        var material = UnlitMaterial(color: palette.glowPool)
        material.blending = .transparent(opacity: .init(scale: palette.isDark ? 0.75 : 0.38, texture: .init(texture)))
        return material
    }()

    private func wasteBin(_ root: Entity, at p: SIMD3<Float>, color: NSColor) {
        let bin = group(root, "waste-bin", p)
        box(bin, "bin-body", [0.45, 0.65, 0.45], [0, 0.325, 0], color, radius: 0.05)
        box(bin, "bin-lid", [0.48, 0.07, 0.48], [0, 0.69, 0], trim, radius: 0.04)
        box(bin, "bin-opening", [0.26, 0.015, 0.17], [0, 0.735, 0], steel)
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
                box(shelf, "archive-box", [0.55, 0.42, 0.55], [x, y + 0.24, 0], x < 0 ? wood : orange, radius: 0.03)
                box(shelf, "archive-label", [0.23, 0.12, 0.015], [x, y + 0.25, 0.285], paper)
            } }
        }
    }


    private func restrooms(_ root: Entity) {
        box(root, "restroom-floor", [7.7, 0.025, 8.8], [24, 0.014, 10.6], finish(0.70, 0.72, 0.75))
        serviceLift(root, at: [26.5, 0, 8.9])
        toolChest(root, at: [20.42, 0, 7.6])
        // Robots recharge rather than wash up: four charging bays and a
        // tool bench take the place of stalls and basins.
        roomLabel(root, number: 11, title: "Maintenance", subtitle: "Charging & repairs", at: [20.6, 6])
        for index in 0..<4 {
            let x = Float(21 + index * 2)
            box(root, "stall-partition", [0.08, 2.1, 3], [x - 0.9, 1.05, 13.4], plaster)
            chargingCradle(root, at: [x, 0, 14.0])
            // A half-front leaves a doorway so bots can back onto the pad.
            box(root, "stall-partition", [0.8, 1.9, 0.08], [x - 0.45, 1.05, 11.9], trim)
        }
        box(root, "vanity", [4, 0.9, 0.75], [24, 0.45, 6.7], wood)
        box(root, "tool-bench-top", [4.1, 0.08, 0.85], [24, 0.94, 6.7], paper)
        for x: Float in [23, 25] {
            box(root, "tool-pegboard", [1.6, 1, 0.04], [x, 1.8, 6.15], cork)
            for i in 0..<4 { box(root, "hanging-tool", [0.06, 0.34, 0.04], [x - 0.5 + Float(i) * 0.33, 1.78, 6.2], i.isMultiple(of: 2) ? orange : steel) }
        }
        box(root, "oil-can", [0.16, 0.24, 0.16], [22.6, 1.1, 6.8], orange, radius: 0.05)
        box(root, "oil-can-spout", [0.03, 0.03, 0.18], [22.6, 1.25, 6.9], steel)
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
        let stone = palette.stone
        let gravel = palette.gravel
        let soil = palette.soil
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
        bikeRack(root, at: [21.0, 0, 18.3])
        bicycle(root, at: [19.25, 0, 17.8], color: blue)
        bicycle(root, at: [20.05, 0, 18.8], color: orange)
        radioMast(root, at: [22.6, 0, 16.9])
        entryDirectory(root, at: [-3.2, 0, 23])
        for x: Float in [-21, -4, 4, 21] {
            bollardLight(root, at: [x, 0, 25.7])
        }
        for x: Float in [-19, -5, 4, 18] { bollardLight(root, at: [x, 0, 22.7]) }
        for x: Float in [-3, 3] { bollardLight(root, at: [x, 0, 16.7]) }
        // Street lamps ring the site so the lawn and paths stay lit at night.
        for x: Float in [-18, -9, 9, 18] { streetLamp(root, at: [x, 0, 27.4], yaw: .pi) }
        for z: Float in [-8, 0, 8] {
            streetLamp(root, at: [-23, 0, z], yaw: .pi / 2)
            streetLamp(root, at: [23, 0, z], yaw: -.pi / 2)
        }
        for x: Float in [-12, 0, 12] { streetLamp(root, at: [x, 0, -13.2], yaw: 0) }
        streetLamp(root, at: [-19.6, 0, 20.5], yaw: .pi / 2)
        streetLamp(root, at: [16.8, 0, 17.2], yaw: -.pi / 2)
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
        // Solar panels roof the terrace instead of open slats.
        let cells = palette.isDark ? palette.idleScreen : palette.fabric
        for row in 0..<4 {
            for side: Float in [-2.2, 2.2] {
                let panel = box(shelter, "solar-panel", [4.2, 0.05, 1.12], [side, 3.08, -1.8 + Float(row) * 1.2], cells)
                panel.orientation = simd_quatf(angle: -0.16, axis: [1, 0, 0])
                for x: Float in [-1.4, -0.7, 0, 0.7, 1.4] { box(panel, "solar-cell-line", [0.015, 0.012, 1.12], [x, 0.03, 0], steel) }
                box(panel, "solar-cell-line", [4.2, 0.012, 0.015], [0, 0.03, 0], steel)
            }
        }
    }

    private func courtyardFountain(_ root: Entity, at p: SIMD3<Float>) {
        let fountain = group(root, "courtyard-fountain", p)
        box(fountain, "fountain-plinth", [3.7, 0.18, 2.9], [0, 0.09, 0], steel, radius: 0.08)
        box(fountain, "fountain-basin", [3.2, 0.36, 2.4], [0, 0.30, 0], paper, radius: 0.08)
        box(fountain, "reflecting-water", [2.9, 0.025, 2.1], [0, 0.49, 0], palette.water, radius: 0.04)
        box(fountain, "fountain-monolith", [0.48, 1.1, 0.48], [0, 0.9, 0], steel, radius: 0.06)
        box(fountain, "fountain-cap", [0.56, 0.06, 0.56], [0, 1.47, 0], paper, radius: 0.03)
        // The office mascot: a large bust of the crew's robot.
        box(fountain, "mascot-neck", [0.22, 0.14, 0.22], [0, 1.56, 0], steel)
        box(fountain, "mascot-head", [1.0, 0.76, 0.84], [0, 2.0, 0], paper, radius: 0.24)
        box(fountain, "mascot-visor", [0.8, 0.44, 0.02], [0, 2.02, 0.42], signInk, radius: 0.12)
        for x: Float in [-0.17, 0.17] { glowBox(fountain, "mascot-eye", [0.1, 0.13, 0.01], [x, 2.04, 0.435], palette.activeScreen, radius: 0.03) }
        box(fountain, "mascot-headband", [1.12, 0.08, 0.16], [0, 2.42, 0], orange, radius: 0.03)
        for x: Float in [-0.54, 0.54] { box(fountain, "mascot-earcup", [0.14, 0.4, 0.34], [x, 2.02, 0], orange, radius: 0.06) }
    }

    /// A sidewalk delivery robot, parked where the bicycles used to be.
    private func bicycle(_ root: Entity, at p: SIMD3<Float>, color: NSColor) {
        let rover = group(root, "parked-bicycle", p, yaw: .pi / 2)
        box(rover, "rover-chassis", [0.95, 0.34, 0.66], [0, 0.4, 0], paper, radius: 0.1)
        box(rover, "rover-lid", [0.8, 0.22, 0.58], [-0.04, 0.66, 0], color, radius: 0.08)
        box(rover, "rover-face", [0.02, 0.14, 0.4], [0.48, 0.44, 0], signInk)
        for z: Float in [-0.09, 0.09] { glowBox(rover, "rover-eye", [0.012, 0.05, 0.05], [0.495, 0.45, z], palette.activeScreen) }
        for x: Float in [-0.32, 0, 0.32] {
            for z: Float in [-0.35, 0.35] { oval(rover, "rover-wheel", [0.24, 0.24, 0.1], [x, 0.13, z], trim) }
        }
        box(rover, "rover-flag-pole", [0.015, 0.7, 0.015], [-0.38, 1.1, 0.24], steel)
        box(rover, "rover-flag", [0.16, 0.1, 0.01], [-0.3, 1.4, 0.24], orange)
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

    /// A curbside charging post for the delivery robots.
    private func bikeRack(_ root: Entity, at p: SIMD3<Float>) {
        let dock = group(root, "bike-rack", p, yaw: .pi / 2)
        box(dock, "dock-pad", [2.0, 0.04, 0.9], [0, 0.02, 0], steel)
        for x: Float in [-0.9, 0.9] {
            box(dock, "charging-post", [0.2, 0.9, 0.2], [x, 0.45, -0.3], trim, radius: 0.04)
            glowBox(dock, "charging-post-light", [0.12, 0.05, 0.01], [x, 0.75, -0.195], green)
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
        glowBox(light, "bollard-lens", [0.15, 0.16, 0.15], [0, 0.66, 0], glow, radius: 0.025)
        box(light, "bollard-cap", [0.20, 0.04, 0.20], [0, 0.76, 0], steel)
        lightPool(root, at: p, radius: 0.9)
    }

    /// A campus street lamp: a tall post whose arm holds a lantern over the
    /// path. Like the other lamps it lays a glow pool rather than a light.
    private func streetLamp(_ root: Entity, at p: SIMD3<Float>, yaw: Float) {
        let lamp = group(root, "landscape-light", p, yaw: yaw)
        box(lamp, "street-lamp-base", [0.32, 0.28, 0.32], [0, 0.14, 0], trim, radius: 0.04)
        box(lamp, "street-lamp-post", [0.1, 3.3, 0.1], [0, 1.9, 0], trim)
        box(lamp, "street-lamp-arm", [0.06, 0.06, 0.66], [0, 3.5, 0.3], trim)
        glowBox(lamp, "street-lamp-lantern", [0.34, 0.26, 0.3], [0, 3.42, 0.62], glow, radius: 0.04)
        box(lamp, "street-lamp-cap", [0.44, 0.06, 0.4], [0, 3.58, 0.62], trim, radius: 0.03)
        lightPool(root, at: p + simd_quatf(angle: yaw, axis: [0, 1, 0]).act([0, 0, 0.62]), radius: 3)
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
        let groups: Set<String> = ["wall", "glazed-partition", "open-door", "task-chair", "garden-chair", "garden-bench", "garden-tree", "raised-planter", "garden-light", "broad-leaf-plant", "filing-cabinet", "bookcase", "office-printer", "arcade-cabinet", "games-sofa", "visitor-armchair", "coffee-counter", "music-player", "landscape-planter", "landscape-shrub", "landscape-light", "entry-directory", "bike-rack", "parked-bicycle", "campus-bench", "courtyard-fountain", "campus-planting-bed", "water-cooler", "waste-bin", "cleaning-cart", "staircase", "charging-cradle", "radio-mast"]
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
        let desktop = isWorkshop ? paper : oak
        if !isWorkshop {
            // Floor-standing cubicle panels with a trim cap: a shared spine,
            // a centre divider and short end panels that frame each desk
            // without reaching the seat approaches.
            box(pod, "cross-divider-x", [3.9, 1.5, 0.07], [0, 0.75, 0], plaster)
            box(pod, "panel-cap", [3.94, 0.05, 0.11], [0, 1.525, 0], trim, radius: 0.02)
            // A two-seat pod only frames its occupied half; the open face of
            // the spine gets a low credenza instead of an empty cubicle.
            let depth: Float = seatCount > 2 ? 2.5 : 1.25
            let centre: Float = seatCount > 2 ? 0 : -0.625
            box(pod, "cross-divider-z", [0.07, 1.5, depth], [0, 0.75, centre], plaster)
            box(pod, "panel-cap", [0.11, 0.05, depth], [0, 1.525, centre], trim, radius: 0.02)
            if seatCount <= 2 { credenza(pod, at: [0, 0, 0.3]) }
            for side: Float in seatCount > 2 ? [-1, 1] : [-1] {
                for x: Float in [-1.94, 1.94] {
                    box(pod, "cross-divider-z", [0.07, 1.2, 0.9], [x, 0.6, side * 0.55], plaster)
                    box(pod, "panel-cap", [0.11, 0.05, 0.9], [x, 1.225, side * 0.55], trim, radius: 0.02)
                    box(pod, "panel-foot", [0.3, 0.04, 0.07], [x, 0.02, side * 0.95], steel)
                }
            }
        } else {
            box(pod, "cross-divider-x", [3.9, 0.4, 0.07], [0, 1.05, 0], blue)
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
            if !isWorkshop { box(station, "cubicle-tackboard", [0.62, 0.5, 0.02], [-0.6, 1.2, -0.58], cork, radius: 0.01) }
            personalize(station, monitor: screen, persona: navigation.stations[.desk, default: []].count % 6, pinboard: !isWorkshop)
            let colors = [trim, blue, NSColor(srgbRed: 0.59, green: 0.56, blue: 0.37, alpha: 1), blue]
            chair(station, at: [0, 0, 1.125], yaw: .pi, color: colors[(index + variant) % 4])
            let seat = p + SIMD3<Float>(x, 0, side * 1.75)
            navigation.stations[.desk, default: []].append(.init(position: seat, approach: seat + [seat.x < p.x ? -1 : 1, 0, 0], yaw: side < 0 ? 0 : .pi))
        }
    }

    /// A low honey-oak storage credenza with plants and binders.
    private func credenza(_ root: Entity, at p: SIMD3<Float>) {
        let unit = group(root, "storage-shelf", p)
        box(unit, "credenza-body", [3.4, 0.72, 0.46], [0, 0.38, 0], oak, radius: 0.03)
        box(unit, "credenza-top", [3.46, 0.04, 0.5], [0, 0.76, 0], paper, radius: 0.01)
        for i in 0..<4 {
            box(unit, "credenza-door", [0.78, 0.6, 0.02], [-1.26 + Float(i) * 0.84, 0.38, 0.235], wood, radius: 0.02)
            box(unit, "credenza-pull", [0.02, 0.16, 0.03], [-0.92 + Float(i) * 0.84, 0.46, 0.25], trim)
        }
        for x: Float in [-1.6, 1.6] { box(unit, "credenza-leg", [0.05, 0.06, 0.4], [x, 0.03, 0], trim) }
        plant(unit, at: [-1.3, 0.78, 0], height: 0.45)
        for i in 0..<5 {
            box(unit, "binder", [0.07, 0.3, 0.26], [-0.25 + Float(i) * 0.08, 0.93, -0.05], [blue, orange, green, paper, blue][i], radius: 0.01)
        }
        bookStack(unit, at: [0.55, 0.78, 0], count: 3)
        succulent(unit, at: [1.35, 0.78, 0])
    }

    // MARK: Cubicle personalization

    /// Six desk personas rotate across the office so neighbouring cubicles
    /// never match. Everything is static: shared meshes, no loops or lights.
    private func personalize(_ s: Entity, monitor: Entity, persona: Int, pinboard: Bool) {
        let top: Float = 0.94
        let pin: Float = -0.565
        switch persona {
        case 0: // Plant lover
            succulent(s, at: [-0.62, top, -0.3])
            cactus(s, at: [0.76, top, -0.34])
            mug(s, at: [-0.55, top, 0.28], color: green)
            if pinboard { botanicalPrint(s, at: [-0.6, 1.2, pin]) }
        case 1: // Gamer
            headphoneStand(s, at: [-0.62, top, -0.28])
            figurine(s, at: [0.74, top, -0.3])
            box(s, "soda-can", [0.07, 0.13, 0.07], [-0.52, top + 0.065, 0.3], orange, radius: 0.03)
            box(s, "soda-can-lid", [0.06, 0.01, 0.06], [-0.52, top + 0.135, 0.3], steel, radius: 0.02)
            if pinboard { pixelPoster(s, at: [-0.6, 1.2, pin]) }
        case 2: // Organizer
            inboxTray(s, at: [-0.6, top, -0.24])
            penCup(s, at: [0.76, top, -0.34])
            mug(s, at: [-0.55, top, 0.28], color: paper)
            stickyNotes(monitor)
            if pinboard { calendar(s, at: [-0.6, 1.2, pin]) }
        case 3: // Traveler
            globe(s, at: [-0.62, top, -0.28])
            waterBottle(s, at: [0.74, top, -0.32])
            backpack(s, at: [0.78, 0, 0.66])
            if pinboard { postcards(s, at: [-0.6, 1.2, pin]) }
        case 4: // Maker
            box(s, "phone", [0.25, 0.07, 0.28], [-0.56, 0.98, -0.10], paper)
            box(s, "phone-display", [0.16, 0.015, 0.1], [-0.56, 1.025, -0.15], steel)
            box(s, "handset", [0.07, 0.06, 0.29], [-0.68, 1.04, -0.1], trim)
            deskFan(s, at: [0.72, top, -0.3])
            puzzleCube(s, at: [-0.5, top, 0.3])
            stickyNotes(monitor)
            if pinboard { blueprint(s, at: [-0.6, 1.2, pin]) }
        default: // Reader
            deskLamp(s, at: [-0.66, top, -0.3])
            bookStack(s, at: [-0.52, top, 0.3], count: 3)
            mug(s, at: [0.68, top, -0.3], color: orange)
            if pinboard { pinnedPhoto(s, at: [-0.6, 1.2, pin]) }
        }
    }

    private var stickyColors: [NSColor] {
        [NSColor(srgbRed: 1, green: 0.86, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.98, green: 0.66, blue: 0.72, alpha: 1),
         NSColor(srgbRed: 0.62, green: 0.88, blue: 0.76, alpha: 1)]
    }

    private func succulent(_ root: Entity, at p: SIMD3<Float>) {
        let plant = group(root, "desk-succulent", p)
        box(plant, "succulent-pot", [0.13, 0.1, 0.13], [0, 0.05, 0], orange, radius: 0.02)
        box(plant, "succulent-soil", [0.11, 0.01, 0.11], [0, 0.1, 0], wood)
        for i in 0..<6 {
            let leaf = group(plant, "succulent-leaf", [0, 0.12, 0], yaw: Float(i) * .pi / 3)
            let blade = oval(leaf, "succulent-blade", [0.045, 0.035, 0.1], [0, 0, 0.04], green)
            blade.orientation = simd_quatf(angle: -0.5, axis: [1, 0, 0])
        }
        oval(plant, "succulent-core", [0.05, 0.06, 0.05], [0, 0.14, 0], green)
    }

    private func cactus(_ root: Entity, at p: SIMD3<Float>) {
        let plant = group(root, "desk-cactus", p)
        box(plant, "cactus-pot", [0.1, 0.09, 0.1], [0, 0.045, 0], paper, radius: 0.02)
        oval(plant, "cactus-body", [0.07, 0.24, 0.07], [0, 0.2, 0], green)
        oval(plant, "cactus-arm", [0.035, 0.09, 0.035], [0.05, 0.23, 0], green)
        oval(plant, "cactus-flower", [0.035, 0.02, 0.035], [0, 0.325, 0], orange)
    }

    private func headphoneStand(_ root: Entity, at p: SIMD3<Float>) {
        let stand = group(root, "headphone-stand", p, yaw: 0.3)
        box(stand, "stand-base", [0.13, 0.02, 0.13], [0, 0.01, 0], trim, radius: 0.02)
        box(stand, "stand-pole", [0.025, 0.3, 0.025], [0, 0.16, 0], steel)
        box(stand, "headphone-band", [0.22, 0.04, 0.05], [0, 0.325, 0], blue, radius: 0.02)
        for x: Float in [-0.11, 0.11] {
            box(stand, "headphone-cup", [0.05, 0.12, 0.1], [x, 0.26, 0], blue, radius: 0.02)
            box(stand, "headphone-pad", [0.02, 0.1, 0.085], [x * 0.8, 0.26, 0], trim, radius: 0.01)
        }
    }

    /// A tiny model of the office robots, perched by the monitor.
    private func figurine(_ root: Entity, at p: SIMD3<Float>) {
        let bot = group(root, "robot-figurine", p, yaw: -0.4)
        box(bot, "figurine-feet", [0.09, 0.03, 0.06], [0, 0.015, 0], trim, radius: 0.01)
        box(bot, "figurine-body", [0.1, 0.09, 0.08], [0, 0.075, 0], paper, radius: 0.03)
        box(bot, "figurine-head", [0.15, 0.11, 0.12], [0, 0.17, 0], paper, radius: 0.04)
        box(bot, "figurine-visor", [0.11, 0.06, 0.01], [0, 0.17, 0.06], signInk, radius: 0.02)
        for x: Float in [-0.026, 0.026] {
            glowBox(bot, "figurine-eye", [0.02, 0.018, 0.005], [x, 0.172, 0.066], NSColor(srgbRed: 0.45, green: 0.93, blue: 1, alpha: 1))
        }
        box(bot, "figurine-antenna", [0.01, 0.05, 0.01], [0, 0.245, 0], steel)
        oval(bot, "figurine-antenna-tip", [0.025, 0.025, 0.025], [0, 0.275, 0], orange)
    }

    private func inboxTray(_ root: Entity, at p: SIMD3<Float>) {
        let tray = group(root, "inbox-tray", p, yaw: 0.08)
        for level in 0..<2 {
            let y = Float(level) * 0.09
            box(tray, "tray-base", [0.34, 0.015, 0.26], [0, y + 0.008, 0], steel)
            for x: Float in [-0.165, 0.165] { box(tray, "tray-rail", [0.012, 0.05, 0.26], [x, y + 0.03, 0], steel) }
            box(tray, "tray-paper", [0.3, 0.012 + Float(level) * 0.01, 0.22], [0, y + 0.024, 0.01], paper)
        }
    }

    private func stickyNotes(_ monitor: Entity) {
        let colors = stickyColors
        for i in 0..<3 {
            let note = box(monitor, "sticky-note", [0.07, 0.07, 0.004], [0.385, 0.56 - Float(i) * 0.085, 0.04], colors[i])
            note.orientation = simd_quatf(angle: Float(i - 1) * 0.12, axis: [0, 0, 1])
        }
    }

    private func calendar(_ root: Entity, at p: SIMD3<Float>) {
        let sheet = group(root, "wall-calendar", p)
        box(sheet, "calendar-page", [0.36, 0.42, 0.008], .zero, paper)
        box(sheet, "calendar-header", [0.36, 0.08, 0.01], [0, 0.17, 0.001], orange)
        for row in 0..<5 { box(sheet, "calendar-rule", [0.32, 0.006, 0.01], [0, 0.1 - Float(row) * 0.065, 0.002], steel) }
        for column in 0..<6 { box(sheet, "calendar-rule", [0.006, 0.26, 0.01], [-0.135 + Float(column) * 0.054, -0.03, 0.002], steel) }
        oval(sheet, "calendar-circled-day", [0.045, 0.045, 0.012], [0.055, 0.001, 0.004], orange)
        oval(sheet, "push-pin", [0.03, 0.03, 0.02], [0, 0.2, 0.01], orange)
    }

    private func pixelPoster(_ root: Entity, at p: SIMD3<Float>) {
        let poster = group(root, "pixel-poster", p)
        box(poster, "poster-sheet", [0.42, 0.44, 0.008], .zero, signInk)
        // A small pixel-art robot head.
        let rows = ["01110", "11111", "10101", "11111", "01010"]
        for (row, pattern) in rows.enumerated() {
            for (column, pixel) in pattern.enumerated() where pixel == "1" {
                box(poster, "poster-pixel", [0.052, 0.052, 0.006], [-0.12 + Float(column) * 0.06, 0.12 - Float(row) * 0.06, 0.006], row == 2 ? green : neon)
            }
        }
        box(poster, "poster-caption", [0.26, 0.03, 0.006], [0, -0.17, 0.006], paper)
    }

    private func botanicalPrint(_ root: Entity, at p: SIMD3<Float>) {
        let print = group(root, "botanical-print", p)
        box(print, "print-frame", [0.36, 0.44, 0.015], .zero, wood)
        box(print, "print-paper", [0.3, 0.38, 0.006], [0, 0, 0.009], paper)
        strut(print, "print-stem", from: [0, -0.16, 0.013], to: [0.02, 0.14, 0.013], width: 0.008, color: green)
        for i in 0..<4 {
            let side: Float = i.isMultiple(of: 2) ? -1 : 1
            let leaf = oval(print, "print-leaf", [0.1, 0.045, 0.006], [side * 0.05, -0.09 + Float(i) * 0.065, 0.014], green)
            leaf.orientation = simd_quatf(angle: side * 0.5, axis: [0, 0, 1])
        }
    }

    private func globe(_ root: Entity, at p: SIMD3<Float>) {
        let globe = group(root, "desk-globe", p)
        oval(globe, "globe-base", [0.15, 0.03, 0.15], [0, 0.015, 0], wood)
        box(globe, "globe-post", [0.02, 0.08, 0.02], [0, 0.06, 0], steel)
        let sphere = group(globe, "globe-sphere", [0, 0.2, 0], yaw: 0.6)
        sphere.orientation *= simd_quatf(angle: 0.4, axis: [0, 0, 1])
        oval(sphere, "globe-ocean", [0.2, 0.2, 0.2], .zero, blue)
        oval(sphere, "globe-land", [0.09, 0.07, 0.03], [0.03, 0.03, 0.088], green)
        oval(sphere, "globe-land", [0.06, 0.08, 0.03], [-0.07, -0.03, 0.066], green)
        oval(sphere, "globe-land", [0.03, 0.08, 0.07], [0.09, -0.02, -0.03], green)
        box(sphere, "globe-meridian", [0.012, 0.23, 0.012], [0, 0, -0.105], steel)
    }

    private func waterBottle(_ root: Entity, at p: SIMD3<Float>) {
        box(root, "water-bottle", [0.08, 0.24, 0.08], p + [0, 0.12, 0], blue, radius: 0.035)
        box(root, "bottle-label", [0.083, 0.06, 0.083], p + [0, 0.11, 0], paper, radius: 0.03)
        box(root, "bottle-cap", [0.06, 0.04, 0.06], p + [0, 0.26, 0], trim, radius: 0.015)
    }

    private func backpack(_ root: Entity, at p: SIMD3<Float>) {
        let bag = group(root, "backpack", p, yaw: -0.35)
        box(bag, "backpack-body", [0.34, 0.42, 0.2], [0, 0.21, 0], orange, radius: 0.08)
        box(bag, "backpack-pocket", [0.26, 0.16, 0.06], [0, 0.14, 0.11], orange, radius: 0.03)
        box(bag, "backpack-zip", [0.22, 0.012, 0.012], [0, 0.22, 0.14], trim)
        box(bag, "backpack-handle", [0.1, 0.035, 0.03], [0, 0.44, 0], trim, radius: 0.012)
        for x: Float in [-0.09, 0.09] { box(bag, "backpack-strap", [0.05, 0.34, 0.03], [x, 0.22, -0.11], trim, radius: 0.012) }
    }

    private func postcards(_ root: Entity, at p: SIMD3<Float>) {
        let board = group(root, "postcard-cluster", p)
        let inserts = [blue, green, orange]
        for i in 0..<3 {
            let card = group(board, "postcard", [-0.13 + Float(i) * 0.13, Float(i % 2) * 0.1 - 0.02, 0], yaw: 0)
            card.orientation = simd_quatf(angle: Float(i - 1) * 0.14, axis: [0, 0, 1])
            box(card, "postcard-card", [0.15, 0.1, 0.005], .zero, paper)
            box(card, "postcard-scene", [0.12, 0.05, 0.004], [0, 0.012, 0.004], inserts[i])
            oval(card, "push-pin", [0.022, 0.022, 0.015], [0, 0.04, 0.008], orange)
        }
        box(board, "boarding-pass", [0.2, 0.07, 0.005], [0.02, -0.16, 0.002], stickyColors[0])
    }

    private func deskFan(_ root: Entity, at p: SIMD3<Float>) {
        let fan = group(root, "desk-fan", p, yaw: -0.5)
        oval(fan, "fan-base", [0.15, 0.03, 0.13], [0, 0.015, 0], trim)
        box(fan, "fan-neck", [0.025, 0.18, 0.025], [0, 0.11, 0], steel)
        oval(fan, "fan-cage", [0.24, 0.24, 0.06], [0, 0.27, 0.01], steel)
        oval(fan, "fan-hub", [0.06, 0.06, 0.08], [0, 0.27, 0.02], trim)
        for i in 0..<3 {
            let blade = box(fan, "fan-blade", [0.08, 0.035, 0.01], [0, 0.27, 0.045], paper, radius: 0.01)
            let angle = Float(i) * 2 * .pi / 3
            blade.position += [cos(angle) * 0.05, sin(angle) * 0.05, 0]
            blade.orientation = simd_quatf(angle: angle, axis: [0, 0, 1])
        }
    }

    private func puzzleCube(_ root: Entity, at p: SIMD3<Float>) {
        let cube = group(root, "puzzle-cube", p, yaw: 0.5)
        let faces = [orange, blue, green, stickyColors[0], paper, stickyColors[1]]
        for i in 0..<8 {
            let x = Float(i & 1) - 0.5, y = Float((i >> 1) & 1), z = Float((i >> 2) & 1) - 0.5
            box(cube, "cube-piece", [0.036, 0.036, 0.036], [x * 0.038, 0.019 + y * 0.038, z * 0.038], faces[i % faces.count], radius: 0.005)
        }
    }

    private func blueprint(_ root: Entity, at p: SIMD3<Float>) {
        let sheet = group(root, "pinned-blueprint", p)
        box(sheet, "blueprint-sheet", [0.44, 0.32, 0.006], .zero, blue)
        box(sheet, "blueprint-outline", [0.3, 0.008, 0.008], [0, 0.08, 0.004], paper)
        box(sheet, "blueprint-outline", [0.3, 0.008, 0.008], [0, -0.08, 0.004], paper)
        box(sheet, "blueprint-outline", [0.008, 0.16, 0.008], [-0.15, 0, 0.004], paper)
        box(sheet, "blueprint-outline", [0.008, 0.16, 0.008], [0.15, 0, 0.004], paper)
        oval(sheet, "blueprint-gear", [0.08, 0.08, 0.006], [0.06, 0, 0.005], paper)
        oval(sheet, "blueprint-gear-hole", [0.035, 0.035, 0.008], [0.06, 0, 0.007], blue)
        for x: Float in [-0.19, 0.19] { oval(sheet, "push-pin", [0.022, 0.022, 0.015], [x, 0.13, 0.008], orange) }
    }

    private func deskLamp(_ root: Entity, at p: SIMD3<Float>) {
        let lamp = group(root, "desk-lamp", p, yaw: -0.6)
        oval(lamp, "lamp-base", [0.15, 0.035, 0.15], [0, 0.018, 0], trim)
        strut(lamp, "lamp-arm", from: [0, 0.03, 0], to: [0, 0.3, -0.06], width: 0.022, color: steel)
        strut(lamp, "lamp-arm", from: [0, 0.3, -0.06], to: [0, 0.34, 0.14], width: 0.022, color: steel)
        oval(lamp, "lamp-joint", [0.035, 0.035, 0.035], [0, 0.3, -0.06], trim)
        let shade = box(lamp, "lamp-shade", [0.12, 0.08, 0.13], [0, 0.32, 0.17], orange, radius: 0.03)
        shade.orientation = simd_quatf(angle: 0.35, axis: [1, 0, 0])
        glowOval(lamp, "lamp-bulb", [0.07, 0.025, 0.07], [0, 0.285, 0.18], glow)
    }

    private func pinnedPhoto(_ root: Entity, at p: SIMD3<Float>) {
        let photo = group(root, "pinned-photo", p)
        photo.orientation = simd_quatf(angle: 0.08, axis: [0, 0, 1])
        box(photo, "photo-print", [0.26, 0.2, 0.005], .zero, paper)
        box(photo, "photo-sky", [0.22, 0.09, 0.004], [0, 0.035, 0.004], blue)
        box(photo, "photo-ground", [0.22, 0.06, 0.004], [0, -0.045, 0.004], green)
        oval(photo, "photo-sun", [0.04, 0.04, 0.004], [0.06, 0.05, 0.007], stickyColors[0])
        oval(photo, "push-pin", [0.022, 0.022, 0.015], [0, 0.09, 0.008], orange)
        box(root, "pinned-note", [0.11, 0.11, 0.004], p + [0.2, -0.1, 0], stickyColors[2])
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
        box(plant, "planter", [0.45, 0.45, 0.45], [0, 0.225, 0], paper, radius: 0.06)
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
        box(root, "monitor-display", [0.66, 0.4, 0.012], [0, 0.42, 0.041], palette.idleScreen)
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
        let length = simd_length(d)
        box(wall, "plaster-wall", [length, height, 0.18], [0, height / 2, 0], plaster)
        glowBox(wall, "wall-cap", [length + 0.05, 0.06, 0.24], [0, height, 0], violet)
        box(wall, "skirting", [length, 0.14, 0.22], [0, 0.07, 0], trim)
        // A chair rail gives full-height walls a lived-in, workshop feel.
        if height > 1 { box(wall, "wall-chair-rail", [length, 0.07, 0.22], [0, 1.0, 0], trim) }
    }

    private func glassWall(_ root: Entity, from a: SIMD2<Float>, to b: SIMD2<Float>) {
        let d = b - a
        let center = (a + b) / 2
        let length = simd_length(d)
        let frame = group(root, "glazed-partition", [center.x, 0, center.y], yaw: -atan2(d.y, d.x))
        // Honey-oak rails and a waist-height handrail, like a studio mezzanine.
        for y: Float in [0.1, 1.05] { box(frame, "frame-rail", [length, y == 1.05 ? 0.09 : 0.07, 0.08], [0, y, 0], oak) }
        glowBox(frame, "frame-rail", [length, 0.06, 0.08], [0, 2.9, 0], violet)
        let panels = Int(ceil(length / 1.5))
        for i in 0...panels {
            let x = -length / 2 + Float(i) * length / Float(panels)
            box(frame, "frame-upright", [0.075, 2.9, 0.08], [x, 1.45, 0], oak)
        }
        let glass = SimpleMaterial(color: palette.glass, roughness: 0.3, isMetallic: false)
        let pane = ModelEntity(mesh: .generateBox(size: [length - 0.1, 2.75, 0.018]), materials: [glass])
        pane.position = [0, 1.45, 0]
        frame.addChild(pane)
    }

    private func window(_ root: Entity, at p: SIMD3<Float>, yaw: Float, blinds: Bool) {
        let window = group(root, "window", p, yaw: yaw)
        box(window, "window-trim", [1.9, 1.35, 0.08], .zero, oak)
        glowBox(window, "sky-view", [1.74, 1.17, 0.02], [0, 0, 0.055], palette.windowView)
        for x: Float in [-0.45, 0, 0.45] { box(window, "mullion", [0.035, 1.2, 0.03], [x, 0, 0.08], paper) }
        box(window, "crossbar", [1.76, 0.04, 0.03], [0, -0.12, 0.08], paper)
        box(window, "sill", [2.04, 0.08, 0.23], [0, -0.7, 0.1], paper)
        let slats = blinds ? 13 : 3
        for row in 0..<slats { box(window, "blind-slat", [1.82, 0.065, 0.06], [0, 0.58 - Float(row) * 0.078, 0.12], paper) }
        box(window, "blind-rail", [2.03, 0.10, 0.15], [0, 0.75, 0.1], oak)
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
        else { mesh = OfficeLowPolyMesh.box(size: size, cornerRadius: radius); meshes[key] = mesh }
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

    /// Unlit geometry for light sources, screens and signage.
    @discardableResult
    private func glowBox(_ root: Entity, _ name: String, _ size: SIMD3<Float>, _ p: SIMD3<Float>, _ color: NSColor, radius: Float = 0) -> ModelEntity {
        let entity = box(root, name, size, p, color, radius: radius)
        entity.model?.materials = [unlit(color)]
        return entity
    }

    private var unlitMaterials: [NSColor: UnlitMaterial] = [:]
    private func unlit(_ color: NSColor) -> UnlitMaterial {
        if let cached = unlitMaterials[color] { return cached }
        let material = UnlitMaterial(color: color)
        unlitMaterials[color] = material
        return material
    }

    @discardableResult
    private func oval(_ root: Entity, _ name: String, _ size: SIMD3<Float>, _ p: SIMD3<Float>, _ color: NSColor) -> ModelEntity {
        let key = "sphere"
        let mesh = meshes[key] ?? OfficeLowPolyMesh.sphere(radius: 0.5)
        meshes[key] = mesh
        let material: SimpleMaterial
        if let cached = materials[color] { material = cached }
        else { material = SimpleMaterial(color: color, roughness: 1, isMetallic: false); materials[color] = material }
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = name
        entity.scale = size
        entity.position = p
        root.addChild(entity)
        return entity
    }

    @discardableResult
    private func glowOval(_ root: Entity, _ name: String, _ size: SIMD3<Float>, _ p: SIMD3<Float>, _ color: NSColor) -> ModelEntity {
        let entity = oval(root, name, size, p, color)
        entity.model?.materials = [unlit(color)]
        return entity
    }

    /// A straight bar between two points, for lattices, arms and frames.
    @discardableResult
    private func strut(_ root: Entity, _ name: String, from a: SIMD3<Float>, to b: SIMD3<Float>, width: Float, color: NSColor) -> ModelEntity {
        let bar = box(root, name, [width, simd_length(b - a), width], (a + b) / 2, color)
        bar.orientation = simd_quatf(from: [0, 1, 0], to: simd_normalize(b - a))
        return bar
    }
}
