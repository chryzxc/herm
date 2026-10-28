import Foundation

/// Distance-driven gait: slowing down travel also slows the steps. No second timer.
/// `amount` (0...1) follows walking speed so starts and stops blend into the idle pose.
struct OfficePreviewWalkPose {
    static let strideLength: Float = 0.95
    let legAngle: Float
    let leftLift: Float
    let rightLift: Float
    let bounce: Float
    let sway: Float
    let footTravel: Float
    let armAngle: Float
    let lean: Float
    let twist: Float
    let headBob: Float

    init(distance: Float, amount: Float = 1) {
        let amount = min(1, max(0, amount))
        let phase = max(0, distance).truncatingRemainder(dividingBy: Self.strideLength) / Self.strideLength * 2 * .pi
        let swing = sin(phase)
        // A slightly sharpened swing keeps feet planted longer at each extreme.
        let planted = swing * (1.25 - 0.25 * swing * swing)
        legAngle = planted * 0.50 * amount
        leftLift = max(0, swing) * 0.085 * amount
        rightLift = max(0, -swing) * 0.085 * amount
        bounce = (1 - cos(phase * 2)) * 0.020 * amount
        sway = swing * 0.045 * amount
        footTravel = swing * 0.075 * amount
        armAngle = -planted * 0.62 * amount
        lean = 0.07 * amount
        twist = swing * 0.07 * amount
        headBob = -cos(phase * 2) * 0.035 * amount
    }
}

struct OfficePreviewCameraInput: Equatable, Sendable {
    var right: Float = 0
    var forward: Float = 0
    var orbit: Float = 0
    var tilt: Float = 0
    var zoom: Float = 0
    var fast = false
    var isActive: Bool { right != 0 || forward != 0 || orbit != 0 || tilt != 0 || zoom != 0 }
}

struct OfficePreviewCameraState: Equatable, Sendable {
    static let target = SIMD3<Float>(0, 0.55, 0)
    static let defaultAzimuth: Float = .pi * 8 / 180
    static let defaultElevation: Float = .pi * 57 / 180
    static let defaultDistance: Float = 17
    static let elevationRange = (min: Float.pi * 12 / 180, max: Float.pi * 82 / 180)
    static let distanceRange = (min: Float(3), max: Float(48))
    static let panXRange: ClosedRange<Float> = -5.5...11.5
    static let panZRange: ClosedRange<Float> = -4...9

    var azimuth: Float = Self.defaultAzimuth
    var elevation: Float = Self.defaultElevation
    var distance: Float = Self.defaultDistance
    var orbitTarget = Self.target

    var position: SIMD3<Float> {
        let horizontal = cos(elevation) * distance
        return orbitTarget
            + SIMD3<Float>(sin(azimuth) * horizontal, sin(elevation) * distance, cos(azimuth) * horizontal)
    }

    mutating func applyDrag(deltaX: CGFloat, deltaY: CGFloat) {
        // Horizontal orbit is deliberately unbounded: a management-sim camera
        // must let people inspect the whole room, not just its front 180°.
        azimuth = wrappedAngle(azimuth + Float(deltaX) * 0.008)
        elevation = clamped(elevation - Float(deltaY) * 0.008, to: Self.elevationRange)
    }

    mutating func applyGroundPan(
        deltaX: CGFloat, deltaY: CGFloat, xRange: ClosedRange<Float> = Self.panXRange,
        zRange: ClosedRange<Float> = Self.panZRange
    ) {
        let speed = max(0.012, distance * 0.00115)
        let right = SIMD3<Float>(cos(azimuth), 0, -sin(azimuth))
        let forward = SIMD3<Float>(-sin(azimuth), 0, -cos(azimuth))
        // Grab-and-drag follows the pointer in either AppKit vertical convention
        // after the view supplies a positive-up delta. Compensate for foreshortening.
        orbitTarget += right * -Float(deltaX) * speed - forward * Float(deltaY) * speed / max(0.3, sin(elevation))
        orbitTarget.x = clamped(orbitTarget.x, to: (xRange.lowerBound, xRange.upperBound))
        orbitTarget.z = clamped(orbitTarget.z, to: (zRange.lowerBound, zRange.upperBound))
    }

    mutating func applyZoom(delta: CGFloat, maximumDistance: Float = Self.distanceRange.max) {
        let exponent = max(-20, min(20, -Float(delta) * 0.008))
        distance = min(maximumDistance, max(Self.distanceRange.min, distance * exp(exponent)))
    }

    /// Frame-time based controls preserve speed across refresh rates. Diagonal
    /// movement is normalized and always relative to the current camera heading.
    mutating func advance(
        input: OfficePreviewCameraInput, delta: TimeInterval,
        xRange: ClosedRange<Float> = Self.panXRange,
        zRange: ClosedRange<Float> = Self.panZRange,
        maximumDistance: Float = Self.distanceRange.max
    ) {
        let dt = Float(min(0.05, max(0, delta)))
        let boost: Float = input.fast ? 2.5 : 1
        azimuth = wrappedAngle(azimuth + input.orbit * dt * 1.3)
        elevation = clamped(elevation + input.tilt * dt * 0.8, to: Self.elevationRange)
        let length = max(1, sqrt(input.right * input.right + input.forward * input.forward))
        let right = SIMD3<Float>(cos(azimuth), 0, -sin(azimuth))
        let forward = SIMD3<Float>(-sin(azimuth), 0, -cos(azimuth))
        let speed = max(2, distance * 0.4) * boost
        orbitTarget += (right * input.right + forward * input.forward) / length * speed * dt
        orbitTarget.x = clamped(orbitTarget.x, to: (xRange.lowerBound, xRange.upperBound))
        orbitTarget.z = clamped(orbitTarget.z, to: (zRange.lowerBound, zRange.upperBound))
        if input.zoom != 0 {
            applyZoom(delta: CGFloat(input.zoom * dt * 100 * boost), maximumDistance: maximumDistance)
        }
    }

    mutating func easeZoom(toward target: Float, delta: TimeInterval) {
        let amount = 1 - exp(-Float(max(0, min(0.05, delta))) * 18)
        distance += (target - distance) * amount
    }

    mutating func reset() {
        orbitTarget = Self.target
        azimuth = Self.defaultAzimuth
        elevation = Self.defaultElevation
        distance = Self.defaultDistance
    }

    private func clamped(_ value: Float, to range: (min: Float, max: Float)) -> Float {
        min(range.max, max(range.min, value))
    }

    private func wrappedAngle(_ value: Float) -> Float {
        let fullTurn = 2 * Float.pi
        let remainder = value.truncatingRemainder(dividingBy: fullTurn)
        return remainder < 0 ? remainder + fullTurn : remainder
    }
}

enum OfficePreviewLocation: String, CaseIterable, Sendable {
    case kanbanBoard = "Kanban board"
    case desk = "Assigned desk"
    case reviewTable = "Review table"
    case waitingArea = "Help point"
    case lounge = "Garden patio"
    case library = "Library"
    case qaLab = "QA Lab"
    case securityOps = "Security Ops"
    case serverRoom = "Server Room"
    case designStudio = "Design Studio"
    case assemblyBay = "Assembly Bay"
    case missionWall = "Mission Control wall"

    /// Rooms entered only for a running task's work kind. They exist only in
    /// the authored office; a full or missing room falls back to the desk.
    static let workZones: [OfficePreviewLocation] = [
        .library, .qaLab, .securityOps, .serverRoom, .designStudio, .assemblyBay, .missionWall,
    ]
    var isWorkZone: Bool { Self.workZones.contains(self) }
}

enum OfficePreviewPhase: String, Sendable {
    case planning = "Reading task cards"
    case implementing = "Typing"
    case testing = "Checking results"
    case reading = "Reading at desk"
    case reviewing = "Reviewing"
    case waiting = "Waiting for help"
    case resting = "Taking a break outside"

    var isSeated: Bool {
        switch self {
        case .implementing, .testing, .reading, .reviewing, .resting, .waiting: true
        default: false
        }
    }
}

enum OfficePreviewLane: String, CaseIterable, Sendable {
    case triage, todo, ready, running, review, scheduled, blocked, done, unknown

    init(_ raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "triage": self = .triage
        case "todo": self = .todo
        case "ready": self = .ready
        case "running", "active", "working", "in_progress", "in-progress", "inprogress": self = .running
        case "review", "waiting", "pending": self = .review
        case "scheduled": self = .scheduled
        case "blocked", "failed", "error": self = .blocked
        case "done", "completed", "complete", "archived": self = .done
        default: self = .unknown
        }
    }

    var rank: Int {
        switch self {
        case .running: 0
        case .review: 1
        case .blocked: 2
        case .ready: 3
        case .triage: 4
        case .todo, .scheduled: 5
        case .unknown: 6
        case .done: 7
        }
    }

    var location: OfficePreviewLocation {
        switch self {
        case .running: .desk
        case .review: .reviewTable
        case .blocked: .desk
        case .triage, .ready: .kanbanBoard
        default: .lounge
        }
    }
}

struct OfficePreviewTaskData: Identifiable, Equatable, Sendable {
    let id: String
    let boardSlug: String?
    let title: String
    let status: String
    let detail: String?
    let priority: String?
    let assignee: String?
    let currentStepKey: String?
    let latestEventKind: String?
    let latestEventNote: String?
    let latestEventAt: Date?
    let startedAt: Date?
    let skills: [String]
    let workflowTemplateID: String?
    var lane: OfficePreviewLane { OfficePreviewLane(status) }
    var work: OfficeWorkClassification { OfficeWorkClassifier.classify(self) }

    init(_ task: KanbanTaskSummary) {
        id = task.id
        boardSlug = task.boardSlug
        title = task.title
        status = task.status
        detail = task.detail
        priority = task.priority
        assignee = task.assignee
        currentStepKey = task.currentStepKey
        latestEventKind = task.latestEventKind
        latestEventNote = task.latestEventNote
        latestEventAt = task.latestEventAt
        startedAt = task.startedAt
        skills = task.skills
        workflowTemplateID = task.workflowTemplateID
    }

    var phase: OfficePreviewPhase {
        switch lane {
        case .running: return work.kind.phase
        case .review: return .reviewing
        case .blocked: return .waiting
        case .triage, .ready: return .planning
        default: return .resting
        }
    }
}

struct OfficeMainSession: Equatable, Sendable, Identifiable {
    struct Activity: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let timestamp: Date
    }
    let id: String
    let title: String
    let state: String
    let isCurrent: Bool
    let activities: [Activity]
    var lane: OfficePreviewLane {
        switch state.lowercased() {
        case "idle", "completed", "done": .done
        case "working", "running", "active", "busy", "streaming": .running
        case "needs_approval", "needs_clarification", "blocked", "failed", "error", "waiting_for_approval",
            "waiting_for_input":
            .blocked
        default: .unknown
        }
    }
}

struct OfficePreviewAgentPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let tasks: [OfficePreviewTaskData]
    var mainSession: OfficeMainSession? = nil
    var avatarID: String? = nil
    var faceID: String { avatarID ?? id }
    /// Settled work kind from `OfficePreviewSimulation`; nil means unsmoothed.
    var settledWork: OfficeWorkClassification? = nil
    var activityLane: OfficePreviewLane? { mainSession?.lane ?? taskData?.lane }
    var taskData: OfficePreviewTaskData? { tasks.first }
    var phase: OfficePreviewPhase {
        if let mainSession {
            return mainSession.lane == .running ? .implementing : mainSession.lane == .done ? .resting : .waiting
        }
        guard let taskData else { return .resting }
        return taskData.lane == .running ? (work?.kind.phase ?? .implementing) : taskData.phase
    }
    /// The running work kind and its evidence; nil when no work is in progress.
    var work: OfficeWorkClassification? {
        if let mainSession { return mainSession.lane == .running ? OfficeWorkClassifier.classify(mainSession) : nil }
        guard let taskData, taskData.lane == .running else { return nil }
        return settledWork ?? taskData.work
    }
    var location: OfficePreviewLocation {
        if let mainSession { return mainSession.lane == .done ? .lounge : .desk }
        guard let taskData else { return .lounge }
        return taskData.lane == .running ? (work?.kind.location ?? .desk) : taskData.lane.location
    }
    /// Availability here describes the loaded Kanban queue, not runtime capacity.
    var hasNoPendingTasks: Bool { mainSession == nil && tasks.allSatisfy { $0.lane == .done } }
    var canWander: Bool {
        mainSession.map { $0.lane == .done } ?? tasks.allSatisfy { [.todo, .scheduled, .done].contains($0.lane) }
    }
    var availabilityLabel: String {
        if let mainSession { return "Orchestrator · \(mainSession.state.replacingOccurrences(of: "_", with: " "))" }
        if hasNoPendingTasks { return "No pending Kanban tasks" }
        if tasks.contains(where: { $0.lane == .running }) { return "Working" }
        if tasks.contains(where: { $0.lane == .blocked || $0.lane == .unknown }) { return "Needs attention" }
        return "Assigned work · \(tasks.filter { $0.lane != .done }.count) pending"
    }
    var activitySymbol: Ph {
        if let mainSession {
            switch mainSession.lane {
            case .running: return .desktop
            case .blocked: return .warningCircle
            case .done: return .chat
            default: return .question
            }
        }
        if hasNoPendingTasks { return .diamond }
        switch taskData?.lane {
        case .running: return work?.kind.symbol ?? .desktop
        case .review: return .eye
        case .blocked: return .warningCircle
        case .scheduled: return .clock
        case .triage, .unknown: return .question
        case .ready: return .play
        default: return .listBullets
        }
    }
    var monitorTitle: String { mainSession?.title ?? taskData?.title ?? "No assigned Kanban task" }
    var monitorStatus: String {
        if let mainSession { return mainSession.state.replacingOccurrences(of: "_", with: " ").capitalized }
        guard let taskData else { return "No assigned task" }
        return taskData.lane == .unknown ? "Unknown status" : taskData.lane.rawValue.capitalized
    }
    var bubbleText: String {
        guard let taskData else { return "No assigned task" }
        if taskData.lane == .blocked { return "Blocked" }
        if taskData.lane == .unknown { return "Unknown status" }
        return "\(monitorStatus) · \(String(taskData.title.prefix(42)))"
    }
    // FNV-1a is deterministic across launches; Swift Hasher deliberately is not.
    var identitySeed: UInt64 {
        id.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
    var identityHue: Double { mainSession == nil ? Double(identitySeed % 360) / 360 : 0.56 }
}

enum OfficePreviewResolver {
    static func ordered(_ tasks: [OfficePreviewTaskData]) -> [OfficePreviewTaskData] {
        tasks.sorted {
            if $0.lane.rank != $1.lane.rank { return $0.lane.rank < $1.lane.rank }
            if $0.latestEventAt != $1.latestEventAt {
                return ($0.latestEventAt ?? .distantPast) > ($1.latestEventAt ?? .distantPast)
            }
            if $0.startedAt != $1.startedAt { return ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id < $1.id
        }
    }

    static func agents(bots: [BotSummary], tasks: [KanbanTaskSummary], includeDefault: Bool = false)
        -> [OfficePreviewAgentPresentation]
    {
        let byAssignee = Dictionary(grouping: tasks.map(OfficePreviewTaskData.init), by: { $0.assignee ?? "" })
        var seen = Set<String>()
        // The office is a roster view: hidden profiles remain intentionally
        // absent from selectors but keep their physical desk here.
        return bots.filter { (includeDefault || !$0.isDefault) && seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
            .map {
                OfficePreviewAgentPresentation(id: $0.id, name: $0.name, tasks: ordered(byAssignee[$0.id] ?? []))
            }
    }

    static func board(tasks: [KanbanTaskSummary]) -> [OfficePreviewBoardLane] {
        let grouped = Dictionary(grouping: tasks.map(OfficePreviewTaskData.init), by: \.lane)
        return OfficePreviewLane.allCases.filter { $0 != .unknown || grouped[$0] != nil }.map {
            OfficePreviewBoardLane(lane: $0, tasks: ordered(grouped[$0] ?? []))
        }
    }
}

struct OfficePreviewBoardLane: Identifiable, Equatable {
    let lane: OfficePreviewLane
    let tasks: [OfficePreviewTaskData]
    var id: String { lane.rawValue }
}

/// Presentation only. Incoming canonical snapshots are the sole semantic clock.
@MainActor
final class OfficePreviewSimulation: ObservableObject {
    @Published private(set) var agents: [OfficePreviewAgentPresentation] = []
    @Published private(set) var board: [OfficePreviewBoardLane] = []
    private var stabilizer = OfficeWorkStabilizer()

    init(bots: [BotSummary] = [], tasks: [KanbanTaskSummary] = [], sessions: [OfficeMainSession] = []) {
        update(bots: bots, tasks: tasks, sessions: sessions)
    }

    func update(bots: [BotSummary], tasks: [KanbanTaskSummary], sessions: [OfficeMainSession] = [], now: Date = Date())
    {
        var seen = Set<String>()
        // The default bot's current name; users can rename it in Hermes.
        let defaultBot = bots.first(where: \.isDefault)
        let orchestrator = defaultBot?.name ?? "Herm"
        let main = sessions.filter {
            seen.insert($0.id).inserted && ($0.isCurrent || [.running, .blocked].contains($0.lane))
        }
        .sorted { $0.id < $1.id }.map {
            OfficePreviewAgentPresentation(
                id: "main-session:\($0.id)", name: "\(orchestrator) · \($0.title)", tasks: [], mainSession: $0,
                avatarID: defaultBot?.id ?? "nexus")
        }
        var next = main + OfficePreviewResolver.agents(bots: bots, tasks: tasks, includeDefault: main.isEmpty)
        var keys = Set<String>()
        for index in next.indices {
            guard let task = next[index].taskData else { continue }
            let key = "\(next[index].id)|\(task.boardSlug ?? "")|\(task.id)"
            keys.insert(key)
            next[index].settledWork = stabilizer.stabilize(key: key, lane: task.lane, proposed: task.work, now: now)
        }
        stabilizer.retain(keys: keys)
        if next != agents { agents = next }
        let lanes = OfficePreviewResolver.board(tasks: tasks)
        if lanes != board { board = lanes }
    }
}

/// Visual conversations only: a shared board and reported planning/review phase
/// connect colleagues. This never assigns work or fabricates a task handoff.
struct OfficePreviewInteractionPlan {
    var partners: [String: String] = [:]
    var stations: [String: Int] = [:]

    /// `zoneCapacity` is the authored seat count per work room. Bots beyond it
    /// have no seat and work at their own desk; a seat is never shared.
    static func make(agents: [OfficePreviewAgentPresentation], zoneCapacity: [OfficePreviewLocation: Int] = [:]) -> Self
    {
        var plan = Self()
        for zone in OfficePreviewLocation.workZones {
            let capacity = zoneCapacity[zone] ?? 0
            guard capacity > 0 else { continue }
            var taken = Set<Int>()
            // Each bot prefers a seat derived from its identity, so a refresh
            // or a colleague leaving does not reshuffle the room.
            for agent in agents.filter({ $0.mainSession == nil && $0.location == zone }).sorted(by: { $0.id < $1.id }) {
                guard taken.count < capacity else { break }
                var seat = Int(agent.identitySeed % UInt64(capacity))
                while taken.contains(seat) { seat = (seat + 1) % capacity }
                taken.insert(seat)
                plan.stations[agent.id] = seat
            }
        }
        for phase in [OfficePreviewPhase.planning, .reviewing] {
            let participants = agents.filter { $0.mainSession == nil && $0.phase == phase }
                .sorted {
                    let left = $0.taskData?.boardSlug ?? ""
                    let right = $1.taskData?.boardSlug ?? ""
                    return left == right ? $0.id < $1.id : left < right
                }
            var seat = 0
            var remaining = participants
            while !remaining.isEmpty {
                let first = remaining.removeFirst()
                plan.stations[first.id] = seat
                seat += 1
                guard let board = first.taskData?.boardSlug, !board.isEmpty,
                    let index = remaining.firstIndex(where: { $0.taskData?.boardSlug == board })
                else { continue }
                let second = remaining.remove(at: index)
                plan.stations[second.id] = seat
                seat += 1
                plan.partners[first.id] = second.id
                plan.partners[second.id] = first.id
            }
        }
        return plan
    }
}
