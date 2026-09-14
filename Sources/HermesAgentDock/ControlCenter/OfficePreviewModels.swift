import Foundation

/// Distance-driven gait: slowing down travel also slows the steps. No second timer.
struct OfficePreviewWalkPose {
    static let strideLength: Float = 0.95
    let legAngle: Float
    let leftLift: Float
    let rightLift: Float
    let bounce: Float
    let sway: Float
    let footTravel: Float

    init(distance: Float) {
        let phase = max(0, distance).truncatingRemainder(dividingBy: Self.strideLength) / Self.strideLength * 2 * .pi
        let swing = sin(phase)
        legAngle = swing * 0.50
        leftLift = max(0, swing) * 0.085
        rightLift = max(0, -swing) * 0.085
        bounce = (1 - cos(phase * 2)) * 0.020
        sway = swing * 0.045
        footTravel = swing * 0.075
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
        return orbitTarget + SIMD3<Float>(sin(azimuth) * horizontal, sin(elevation) * distance, cos(azimuth) * horizontal)
    }

    mutating func applyDrag(deltaX: CGFloat, deltaY: CGFloat) {
        // Horizontal orbit is deliberately unbounded: a management-sim camera
        // must let people inspect the whole room, not just its front 180°.
        azimuth = wrappedAngle(azimuth + Float(deltaX) * 0.008)
        elevation = clamped(elevation - Float(deltaY) * 0.008, to: Self.elevationRange)
    }

    mutating func applyGroundPan(deltaX: CGFloat, deltaY: CGFloat, xRange: ClosedRange<Float> = Self.panXRange, zRange: ClosedRange<Float> = Self.panZRange) {
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
    mutating func advance(input: OfficePreviewCameraInput, delta: TimeInterval,
                          xRange: ClosedRange<Float> = Self.panXRange,
                          zRange: ClosedRange<Float> = Self.panZRange,
                          maximumDistance: Float = Self.distanceRange.max) {
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
        if input.zoom != 0 { applyZoom(delta: CGFloat(input.zoom * dt * 100 * boost), maximumDistance: maximumDistance) }
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
    var lane: OfficePreviewLane { OfficePreviewLane(status) }

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
    }

    var phase: OfficePreviewPhase {
        switch lane {
        case .running:
            // Explicit reported step takes precedence over the older event.
            let report = (currentStepKey ?? latestEventNote ?? latestEventKind ?? "").lowercased()
            let words = Set(report.split(whereSeparator: { !$0.isLetter }).map(String.init))
            if !words.isDisjoint(with: ["test", "testing", "tests", "verify", "verification", "validate"]) { return .testing }
            if !words.isDisjoint(with: ["read", "reading", "inspect", "research", "analyze"]) { return .reading }
            return .implementing
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
        case "needs_approval", "needs_clarification", "blocked", "failed", "error", "waiting_for_approval", "waiting_for_input": .blocked
        default: .unknown
        }
    }
}

struct OfficePreviewAgentPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let tasks: [OfficePreviewTaskData]
    var mainSession: OfficeMainSession? = nil
    var activityLane: OfficePreviewLane? { mainSession?.lane ?? taskData?.lane }
    var taskData: OfficePreviewTaskData? { tasks.first }
    var phase: OfficePreviewPhase {
        if let mainSession { return mainSession.lane == .running ? .implementing : mainSession.lane == .done ? .resting : .waiting }
        return taskData?.phase ?? .resting
    }
    var location: OfficePreviewLocation { mainSession.map { $0.lane == .done ? .lounge : .desk } ?? taskData?.lane.location ?? .lounge }
    /// Availability here describes the loaded Kanban queue, not runtime capacity.
    var hasNoPendingTasks: Bool { mainSession == nil && tasks.allSatisfy { $0.lane == .done } }
    var canWander: Bool { mainSession.map { $0.lane == .done } ?? tasks.allSatisfy { [.todo, .scheduled, .done].contains($0.lane) } }
    var availabilityLabel: String {
        if let mainSession { return "Nexus orchestrator · \(mainSession.state.replacingOccurrences(of: "_", with: " "))" }
        if hasNoPendingTasks { return "No pending Kanban tasks" }
        if tasks.contains(where: { $0.lane == .running }) { return "Working" }
        if tasks.contains(where: { $0.lane == .blocked || $0.lane == .unknown }) { return "Needs attention" }
        return "Assigned work · \(tasks.filter { $0.lane != .done }.count) pending"
    }
    var activitySymbol: String {
        if let mainSession {
            switch mainSession.lane {
            case .running: return "desktopcomputer"
            case .blocked: return "exclamationmark"
            case .done: return "bubble.left.fill"
            default: return "questionmark"
            }
        }
        if hasNoPendingTasks { return "diamond.fill" }
        switch taskData?.lane {
        case .running:
            switch phase {
            case .testing: return "testtube.2"
            case .reading: return "book.fill"
            default: return "desktopcomputer"
            }
        case .review: return "eye.fill"
        case .blocked: return "exclamationmark"
        case .scheduled: return "clock.fill"
        case .triage, .unknown: return "questionmark"
        case .ready: return "play.fill"
        default: return "list.bullet"
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
        id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
    var identityHue: Double { mainSession == nil ? Double(identitySeed % 360) / 360 : 0.56 }
}

enum OfficePreviewResolver {
    static func ordered(_ tasks: [OfficePreviewTaskData]) -> [OfficePreviewTaskData] {
        tasks.sorted {
            if $0.lane.rank != $1.lane.rank { return $0.lane.rank < $1.lane.rank }
            if $0.latestEventAt != $1.latestEventAt { return ($0.latestEventAt ?? .distantPast) > ($1.latestEventAt ?? .distantPast) }
            if $0.startedAt != $1.startedAt { return ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id < $1.id
        }
    }

    static func agents(bots: [BotSummary], tasks: [KanbanTaskSummary]) -> [OfficePreviewAgentPresentation] {
        let byAssignee = Dictionary(grouping: tasks.map(OfficePreviewTaskData.init), by: { $0.assignee ?? "" })
        var seen = Set<String>()
        return bots.filter { !$0.isHidden && !$0.isDefault && seen.insert($0.id).inserted }.sorted { $0.id < $1.id }.map {
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

    init(bots: [BotSummary] = [], tasks: [KanbanTaskSummary] = [], sessions: [OfficeMainSession] = []) {
        update(bots: bots, tasks: tasks, sessions: sessions)
    }

    func update(bots: [BotSummary], tasks: [KanbanTaskSummary], sessions: [OfficeMainSession] = []) {
        var seen = Set<String>()
        let main = sessions.filter { seen.insert($0.id).inserted && ($0.isCurrent || [.running, .blocked].contains($0.lane)) }
            .sorted { $0.id < $1.id }.map {
                OfficePreviewAgentPresentation(id: "main-session:\($0.id)", name: "Nexus · \($0.title)", tasks: [], mainSession: $0)
            }
        let next = main + OfficePreviewResolver.agents(bots: bots, tasks: tasks)
        if next != agents { agents = next }
        let lanes = OfficePreviewResolver.board(tasks: tasks)
        if lanes != board { board = lanes }
    }
}
