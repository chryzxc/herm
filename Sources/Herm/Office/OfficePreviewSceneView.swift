import AppKit
import Combine
import RealityKit
import SwiftUI
import QuartzCore

/// One status vocabulary shared by robot eyes, task bubbles and the office
/// HUD. Every case is derived from reported Kanban or session state.
enum OfficeAgentStatus: Int, CaseIterable, Identifiable {
    case blocked, working, reviewing, queued, idle, stale
    var id: Int { rawValue }

    init(agent: OfficePreviewAgentPresentation, isDataCurrent: Bool) {
        let current = agent.mainSession.map { $0.lane != .unknown } ?? isDataCurrent
        if !current { self = .stale; return }
        if agent.hasNoPendingTasks { self = .idle; return }
        switch agent.activityLane ?? .todo {
        case .running: self = .working
        case .review: self = .reviewing
        case .blocked, .unknown: self = .blocked
        case .done: self = .idle
        case .triage, .todo, .ready, .scheduled: self = .queued
        }
    }

    var label: String {
        switch self {
        case .blocked: "Blocked"
        case .working: "Working"
        case .reviewing: "Review"
        case .queued: "Queued"
        case .idle: "Idle"
        case .stale: "Not current"
        }
    }

    var symbol: Ph {
        switch self {
        case .blocked: .warning
        case .working: .lightning
        case .reviewing: .eye
        case .queued: .tray
        case .idle: .coffee
        case .stale: .wifiSlash
        }
    }

    /// Office statuses map onto the shared Dock status vocabulary.
    var tone: DockStatusTone {
        switch self {
        case .blocked: .attention
        case .working: .working
        case .reviewing: .review
        case .queued: .queued
        case .idle: .complete
        case .stale: .inactive
        }
    }

    /// Bubbles and eyes draw on dark sign ink, so the scene always uses the
    /// signage hues.
    var nsColor: NSColor { tone.signageColor }

    var color: Color { Color(nsColor: nsColor) }
}

/// Scene materials are deliberately lighter than the app chrome. Identity and
/// status colors stay separate so the characters remain the visual focus.
private enum OfficePreviewPalette {
    static let floor = color(0x857571)
    static let floorAlternate = color(0x716E80)
    static let loungeFloor = color(0x716E80)
    static let wall = color(0xC6CBD8)
    static let sideWall = color(0xB3BDCE)
    static let frame = color(0x38343F)
    static let wood = color(0xAE9180)
    static let teal = color(0x529BA7)
    static let lavender = color(0x687D9A)
    static let sage = color(0x729780)
    static let paper = color(0xDBE1ED)

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

/// A speech bubble above each bot. It shows only reported state: the bot,
/// its lane, the task title, the reported step and time since the task
/// started. Running work uses an indeterminate shimmer, never a percentage.
@MainActor
final class OfficePreviewTaskBubble: NSView {
    enum Tier: Int, Comparable {
        case dot, compact, full
        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Content: Equatable {
        var name: String
        var status: String
        var title: String
        var detail: String?
        var startedAt: Date?
        var tint: NSColor
        var isWorking: Bool
        var needsAttention: Bool
        var isEmphasized: Bool
    }

    static let tailHeight: CGFloat = 6
    var onSelect: (() -> Void)?
    private(set) var tier: Tier = .full
    private(set) var content: Content?
    private var reduceMotion = false
    private var wasHidden = true
    private let card = CALayer()
    private let tail = CAShapeLayer()
    private let dot = CALayer()
    private let shimmerTrack = CALayer()
    private let shimmer = CAGradientLayer()
    private let nameLabel = OfficePreviewTaskBubble.makeLabel(.systemFont(ofSize: 11, weight: .semibold), alpha: 1)
    private let statusLabel = OfficePreviewTaskBubble.makeLabel(.monospacedDigitSystemFont(ofSize: 11, weight: .medium), alpha: 0.62)
    private let titleLabel = OfficePreviewTaskBubble.makeLabel(.systemFont(ofSize: 11, weight: .regular), alpha: 0.9)
    private let detailLabel = OfficePreviewTaskBubble.makeLabel(.systemFont(ofSize: 11, weight: .regular), alpha: 0.6)
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        applyInk(NSColor(srgbRed: 0.11, green: 0.13, blue: 0.22, alpha: 1))
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = 0.18
        card.shadowRadius = 6
        card.shadowOffset = CGSize(width: 0, height: -2)
        dot.cornerRadius = 3.5
        shimmerTrack.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        shimmerTrack.cornerRadius = 1
        shimmerTrack.masksToBounds = true
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmerTrack.addSublayer(shimmer)
        layer?.addSublayer(tail)
        layer?.addSublayer(card)
        card.addSublayer(dot)
        card.addSublayer(shimmerTrack)
        for label in [nameLabel, statusLabel, titleLabel, detailLabel] { addSubview(label) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Open agent task details")
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Bubbles share the theme's sign color so they read as office signage.
    func applyInk(_ color: NSColor) {
        let ink = color.withAlphaComponent(0.94).cgColor
        guard card.backgroundColor != ink else { return }
        card.backgroundColor = ink
        tail.fillColor = ink
    }
    override func accessibilityPerformPress() -> Bool {
        guard let onSelect else { return false }
        onSelect()
        return true
    }

    private static func makeLabel(_ font: NSFont, alpha: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = NSColor.white.withAlphaComponent(alpha)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        return label
    }

    func update(agent: OfficePreviewAgentPresentation, reduceMotion: Bool, isDataCurrent: Bool) {
        let isDataCurrent = agent.mainSession.map { $0.lane != .unknown } ?? isDataCurrent
        let lane = agent.activityLane ?? .todo
        let status = OfficeAgentStatus(agent: agent, isDataCurrent: isDataCurrent)
        let tint = status.nsColor
        let running = lane == .running
        let detail: String? = {
            if let session = agent.mainSession { return session.activities.max(by: { $0.timestamp < $1.timestamp })?.name }
            guard running, let task = agent.taskData else { return nil }
            return [task.currentStepKey, task.latestEventNote].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }?.replacingOccurrences(of: "_", with: " ")
        }()
        let next = Content(
            name: agent.name,
            status: isDataCurrent ? agent.monitorStatus : "Status not current",
            title: agent.monitorTitle,
            detail: isDataCurrent ? detail : nil,
            startedAt: isDataCurrent && running ? agent.taskData?.startedAt : nil,
            tint: tint,
            isWorking: isDataCurrent && running,
            needsAttention: isDataCurrent && (lane == .blocked || lane == .unknown),
            isEmphasized: agent.mainSession?.isCurrent == true
        )
        self.reduceMotion = reduceMotion
        toolTip = "\(agent.name) · \(isDataCurrent ? agent.availabilityLabel : "Kanban status not current")\n\(agent.monitorStatus) · \(agent.monitorTitle)"
        setAccessibilityLabel(toolTip)
        guard next != content else { return }
        let changedState = content.map { $0.status != next.status || $0.title != next.title } ?? false
        content = next
        apply()
        if changedState && !isHidden { pop() }
    }

    /// Elapsed time is refreshed by the coordinator about once per second.
    @discardableResult
    func refreshClock(now: Date = Date()) -> Bool {
        guard content?.startedAt != nil else { return false }
        let text = statusText(now: now)
        guard statusLabel.stringValue != text else { return false }
        statusLabel.stringValue = text
        return tier == .full
    }

    private func statusText(now: Date) -> String {
        guard let content else { return "" }
        guard let start = content.startedAt else { return content.status }
        let minutes = max(0, Int(now.timeIntervalSince(start))) / 60
        let elapsed = minutes < 1 ? "<1m" : minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
        return "\(content.status) · \(elapsed)"
    }

    func size(for tier: Tier) -> CGSize {
        guard let content else { return .zero }
        func width(_ label: NSTextField, _ text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: label.font as Any]).width)
        }
        switch tier {
        case .dot: return CGSize(width: 14, height: 14)
        case .compact:
            let text = width(nameLabel, content.name)
            return CGSize(width: min(170, max(56, 23 + text)), height: 22 + Self.tailHeight)
        case .full:
            let rows = [width(nameLabel, content.name) + 15, width(statusLabel, statusText(now: Date())),
                        width(titleLabel, content.title), content.detail.map { width(detailLabel, $0) } ?? 0]
            let height: CGFloat = 8 + 15 + 14 + 14 + (content.detail == nil ? 0 : 14) + (content.isWorking ? 6 : 0) + 7
            return CGSize(width: min(220, max(128, (rows.max() ?? 0) + 20)), height: height + Self.tailHeight)
        }
    }

    func setTier(_ next: Tier) {
        guard next != tier else { return }
        let grew = next > tier
        tier = next
        apply()
        if grew && !isHidden && !reduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            layer?.add(fade, forKey: "tier")
        }
    }

    /// Unhiding plays a short rise-and-fade so bubbles do not blink in.
    func setVisible(_ visible: Bool) {
        guard visible == wasHidden else { isHidden = !visible; return }
        wasHidden = !visible
        isHidden = !visible
        guard visible, !reduceMotion, let layer else { return }
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -6
        rise.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [rise, fade]
        group.duration = 0.24
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "appear")
    }

    /// A status or task change gives the bubble a brief spring from its tail.
    private func pop() {
        guard !reduceMotion, let layer else { return }
        let pivot = CGPoint(x: bounds.midX, y: bounds.maxY)
        func scaled(_ factor: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
            t = CATransform3DScale(t, factor, factor, 1)
            return CATransform3DTranslate(t, -pivot.x, -pivot.y, 0)
        }
        let spring = CAKeyframeAnimation(keyPath: "transform")
        spring.values = [scaled(0.82), scaled(1.07), scaled(0.98), scaled(1)].map { NSValue(caTransform3D: $0) }
        spring.keyTimes = [0, 0.45, 0.75, 1]
        spring.duration = 0.42
        layer.add(spring, forKey: "pop")
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        layer.add(fade, forKey: "content")
    }

    private func apply() {
        guard let content else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        nameLabel.stringValue = content.name
        statusLabel.stringValue = statusText(now: Date())
        titleLabel.stringValue = content.title
        detailLabel.stringValue = content.detail ?? ""
        dot.backgroundColor = content.tint.cgColor
        card.borderColor = content.tint.withAlphaComponent(content.needsAttention || content.isEmphasized ? 0.9 : 0.35).cgColor
        card.borderWidth = content.isEmphasized ? 1.5 : 1
        let showsText = tier != .dot
        nameLabel.isHidden = !showsText
        statusLabel.isHidden = tier != .full
        titleLabel.isHidden = tier != .full
        detailLabel.isHidden = tier != .full || content.detail == nil
        shimmerTrack.isHidden = tier != .full || !content.isWorking
        tail.isHidden = tier == .dot
        shimmer.colors = [content.tint.withAlphaComponent(0).cgColor, content.tint.cgColor, content.tint.withAlphaComponent(0).cgColor]
        CATransaction.commit()
        updateLoops()
        needsLayout = true
    }

    /// Running bots breathe and shimmer; blocked bots pulse faster.
    private func updateLoops() {
        dot.removeAllAnimations()
        shimmer.removeAllAnimations()
        guard let content, !reduceMotion else { return }
        if content.isWorking || content.needsAttention {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = content.needsAttention ? 0.7 : 1.1
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            dot.add(pulse, forKey: "pulse")
        }
        if content.isWorking {
            let sweep = CABasicAnimation(keyPath: "position.x")
            sweep.byValue = 0
            sweep.fromValue = -40
            sweep.toValue = 260
            sweep.duration = 1.6
            sweep.repeatCount = .infinity
            shimmer.add(sweep, forKey: "sweep")
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if tier == .dot {
            card.frame = bounds
            card.cornerRadius = bounds.height / 2
            dot.frame = bounds.insetBy(dx: 3.5, dy: 3.5)
            dot.cornerRadius = dot.bounds.height / 2
            return
        }
        let body = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.tailHeight)
        card.frame = body
        card.cornerRadius = tier == .compact ? body.height / 2 : 10
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.midX - 6, y: body.maxY - 1))
        path.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.midX + 6, y: body.maxY - 1))
        path.closeSubpath()
        tail.path = path
        dot.cornerRadius = 3.5
        if tier == .compact {
            dot.frame = CGRect(x: 9, y: (body.height - 7) / 2, width: 7, height: 7)
            nameLabel.frame = CGRect(x: 21, y: (body.height - 15) / 2, width: body.width - 30, height: 15)
            return
        }
        dot.frame = CGRect(x: 10, y: 12, width: 7, height: 7)
        nameLabel.frame = CGRect(x: 23, y: 8, width: body.width - 33, height: 15)
        statusLabel.frame = CGRect(x: 10, y: 23, width: body.width - 20, height: 14)
        titleLabel.frame = CGRect(x: 10, y: 37, width: body.width - 20, height: 14)
        var y: CGFloat = 51
        if !detailLabel.isHidden { detailLabel.frame = CGRect(x: 10, y: y, width: body.width - 20, height: 14); y += 14 }
        shimmerTrack.frame = CGRect(x: 10, y: y + 3, width: body.width - 20, height: 2)
        shimmer.frame = CGRect(x: -40, y: 0, width: 60, height: 2)
        shimmer.position.x = -40
    }
}

@MainActor
enum OfficePreviewCameraGesture {
    case orbit
    case pan
}

@MainActor
final class OfficePreviewARView: ARView {
    var onCameraDrag: ((OfficePreviewCameraGesture, CGFloat, CGFloat) -> Void)?
    var onCameraZoom: ((CGFloat) -> Void)?
    var onSceneClick: ((NSPoint) -> Void)?
    var onSceneHover: ((NSPoint?) -> Void)?
    var onLayout: (() -> Void)?
    var onCameraReset: (() -> Void)?
    private var heldKeys: Set<UInt16> = []
    private var fastMovement = false
    private let cameraKeys: Set<UInt16> = [0, 1, 2, 13, 12, 14, 3, 15, 24, 27, 123, 124, 125, 126]

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        heldKeys.removeAll()
        fastMovement = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 115 { heldKeys.removeAll(); onCameraReset?(); return }
        guard cameraKeys.contains(event.keyCode) else { super.keyDown(with: event); return }
        heldKeys.insert(event.keyCode)
        fastMovement = event.modifierFlags.contains(.shift)
    }

    override func keyUp(with event: NSEvent) {
        guard cameraKeys.contains(event.keyCode) else { super.keyUp(with: event); return }
        heldKeys.remove(event.keyCode)
    }

    override func flagsChanged(with event: NSEvent) {
        fastMovement = event.modifierFlags.contains(.shift)
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { heldKeys.removeAll() }
        super.flagsChanged(with: event)
    }

    func cameraInput() -> OfficePreviewCameraInput {
        guard NSApp.isActive, window?.isKeyWindow == true, window?.firstResponder === self else {
            heldKeys.removeAll()
            return OfficePreviewCameraInput()
        }
        func pressed(_ keys: UInt16...) -> Float { keys.contains(where: heldKeys.contains) ? 1 : 0 }
        return OfficePreviewCameraInput(
            right: pressed(2, 124) - pressed(0, 123),
            forward: pressed(13, 126) - pressed(1, 125),
            orbit: pressed(14) - pressed(12),
            tilt: pressed(15) - pressed(3),
            zoom: pressed(24) - pressed(27), fast: fastMovement
        )
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { onSceneHover?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onSceneHover?(nil) }

    private var mouseDownPoint: NSPoint = .zero
    private var lastDragPoint: NSPoint = .zero
    private var didDrag = false
    private var cameraGesture: OfficePreviewCameraGesture = .orbit

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        lastDragPoint = mouseDownPoint
        didDrag = false
        cameraGesture = event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control) ? .orbit : .pan
    }

    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event); cameraGesture = .orbit }
    override func rightMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func rightMouseUp(with event: NSEvent) { didDrag = false }
    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event); cameraGesture = .pan }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { didDrag = false }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let total = hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y)
        if total >= 4 { didDrag = true }
        guard didDrag else { return }
        let deltaY = (point.y - lastDragPoint.y) * (isFlipped ? -1 : 1)
        onCameraDrag?(cameraGesture, point.x - lastDragPoint.x, deltaY)
        lastDragPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !didDrag && cameraGesture == .pan { onSceneClick?(point) }
        didDrag = false
    }

    override func scrollWheel(with event: NSEvent) {
        onCameraZoom?(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10))
    }
}

@MainActor
struct OfficePreviewSceneView: NSViewRepresentable {
    let agents: [OfficePreviewAgentPresentation]
    let reduceMotion: Bool
    let resetToken: Int
    var wholeOffice = false
    var focusAgentID: String? = nil
    let onSelectAgent: (String) -> Void
    var onSelectBoard: () -> Void = {}
    var boardLanes: [OfficePreviewBoardLane] = []
    var showsAgents = false
    var isDataCurrent = true
    var selectedAgentID: String? = nil
    var palette: OfficeScenePalette = .current()
    var music: OfficeMusicService? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onSelectAgent: onSelectAgent) }

    func makeNSView(context: Context) -> OfficePreviewARView {
        let view = OfficePreviewARView(frame: .zero)
        view.environment.background = .color(palette.background)
        context.coordinator.palette = palette
        view.onCameraDrag = { [weak coordinator = context.coordinator] gesture, x, y in
            coordinator?.applyCameraGesture(gesture, x: x, y: y)
        }
        view.onCameraZoom = { [weak coordinator = context.coordinator] delta in coordinator?.applyCameraZoom(delta: delta) }
        view.onSceneClick = { [weak coordinator = context.coordinator] point in coordinator?.handleClick(at: point) }
        view.onSceneHover = { [weak coordinator = context.coordinator] point in coordinator?.handleHover(at: point) }
        context.coordinator.music = music
        view.onCameraReset = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            coordinator.resetCamera(reduceMotion: coordinator.lastReduceMotion, wholeOffice: coordinator.wholeOfficePreset)
        }
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.layoutLabels() }
        let magnify = NSMagnificationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMagnification(_:)))
        view.addGestureRecognizer(magnify)
        context.coordinator.showsAgents = showsAgents
        context.coordinator.isDataCurrent = isDataCurrent
        context.coordinator.install(in: view, agents: agents, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ view: OfficePreviewARView, context: Context) {
        context.coordinator.onSelectAgent = onSelectAgent
        context.coordinator.showsAgents = showsAgents
        context.coordinator.isDataCurrent = isDataCurrent
        context.coordinator.onSelectBoard = onSelectBoard
        context.coordinator.apply(palette: palette)
        context.coordinator.updateBoard(boardLanes)
        context.coordinator.wholeOfficePreset = wholeOffice
        if context.coordinator.lastResetToken != resetToken {
            context.coordinator.lastResetToken = resetToken
            context.coordinator.resetCamera(reduceMotion: reduceMotion, wholeOffice: wholeOffice, focusAgentID: focusAgentID)
        }
        context.coordinator.update(agents: agents, reduceMotion: reduceMotion)
        context.coordinator.select(selectedAgentID)
    }

    static func dismantleNSView(_ view: OfficePreviewARView, coordinator: Coordinator) {
        coordinator.stop()
        view.onLayout = nil
        view.onCameraDrag = nil
        view.onCameraZoom = nil
        view.onSceneClick = nil
        view.onSceneHover = nil
        view.onCameraReset = nil
        view.renderCallbacks.postProcess = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var showsAgents = false
        var isDataCurrent = true
        private var lastDataCurrent = true
        var onSelectAgent: (String) -> Void
        var onSelectBoard: () -> Void = {}
        private var roomLayout = OfficePreviewLayout()
        private var roomGeometry: Entity?
        private var desiredAgents: [String: OfficePreviewAgentPresentation] = [:]
        private var currentNodes: [String: OfficePreviewLayout.Node] = [:]
        private var boardSummary: [OfficePreviewBoardLane] = []
        private var animationTime: TimeInterval = 0
        private var lastPresentations: [OfficePreviewAgentPresentation] = []
        private var boxMeshes: [String: MeshResource] = [:]
        private var matteMaterials: [NSColor: SimpleMaterial] = [:]
        private lazy var toonSphere = OfficeLowPolyMesh.sphere(radius: 0.5)
        private var actionSubscription: (any Cancellable)?
        private weak var view: OfficePreviewARView?
        private var avatarRoots: [String: Entity] = [:]
        private var movementTasks: [String: Task<Void, Never>] = [:]
        private var reservedSteps: [String: SIMD3<Float>] = [:]
        private var characterVisuals: [String: Entity] = [:]
        private var walkedDistances: [String: Float] = [:]
        fileprivate var lastReduceMotion = false
        private var zoomTarget: Float?
        private var labels: [String: OfficePreviewTaskBubble] = [:]
        private var robotFaces: [String: (head: Entity, eyes: [ModelEntity])] = [:]
        private var eyeColors: [String: NSColor] = [:]
        private var unlitMaterials: [NSColor: UnlitMaterial] = [:]
        private var lastClockTick = Date.distantPast
        private var selectedAgentID: String?
        var palette = OfficeScenePalette.current()
        private var lighting: OfficeSceneLighting?
        private var sky: OfficeSky?
        /// The local clock drives the sun; the render snapshot overrides it.
        var clock: () -> Date = Date.init
        private lazy var daylight = OfficeDaylight(date: clock())
        private var lastDaylightCheck = Date.distantPast
        private let postProcess = OfficePostProcess()
        private var labelsNeedLayout = false
        private var labelOrder: [String] = []
        private var limbEntities: [String: (leftLeg: Entity, rightLeg: Entity, leftArm: Entity, rightArm: Entity)] = [:]
        private var anchor: AnchorEntity?
        private var camera: PerspectiveCamera?
        private var cameraState = OfficePreviewCameraState()
        fileprivate var lastResetToken = 0
        private var resetTask: Task<Void, Never>?
        var wholeOfficePreset = true
        private var manuallyMovedCamera = false
        private var leisureTargets: [String: OfficePreviewLayout.Node] = [:]
        private var nextLeisureChange: [String: TimeInterval] = [:]
        private var lastLeisureTick: TimeInterval = 0
        private var screens: [Int: ModelEntity] = [:]
        private var poweredScreens: Set<Int> = []
        private var interactionPlan = OfficePreviewInteractionPlan()
        private var lastShowsAgents = true
        private var walkSpeeds: [String: Float] = [:]
        private var walkingNow: Set<String> = []
        private var upperBodies: [String: Entity] = [:]
        private var chatBubbles: [String: Entity] = [:]
        private var handProps: [String: (cup: Entity, book: Entity)] = [:]
        private var socialPartners: [String: String] = [:]
        private var conversationStarts: [String: TimeInterval] = [:]
        private var conversationInvites: [String: TimeInterval] = [:]
        private var lastLeisureAction: [String: OfficeDesignNavigation.LeisureAction] = [:]
        /// Where each bot last stood, kept across view rebuilds so reopening
        /// the office resumes the simulation instead of resetting to desks.
        private let placementStore: OfficePlacementStore
        private var placements: [String: OfficePreviewLayout.Node] = [:]
        private var lastPlacementSave = Date.distantPast
        /// The furnished room is static between visits. Keep the flattened
        /// geometry after closing Office so reopening does not build and batch
        /// thousands of props again on the main thread.
        private struct CachedRoom {
            let geometry: Entity
            let navigation: OfficeDesignNavigation
            let palette: OfficeScenePalette
            let capacity: Int
        }
        private static var cachedRoom: CachedRoom?
        private static let hipHeight: Float = 0.30
        var music: OfficeMusicService?
        private var musicParts: (player: Entity, marker: Entity, platter: Entity, speakers: [Entity], woofers: [Entity], tweeters: [Entity], notes: [Entity], waves: [ModelEntity], ping: ModelEntity?)?
        private var musicControl: NSHostingView<OfficeMusicControl>?
        private var musicHovered = false
        private var musicHideTask: Task<Void, Never>?
        private var musicTime: Float = 0
        private var musicLevel: Float = 0

        init(placementStore: OfficePlacementStore = OfficePlacementStore(), onSelectAgent: @escaping (String) -> Void) {
            self.placementStore = placementStore
            self.onSelectAgent = onSelectAgent
        }

        func install(in view: OfficePreviewARView, agents: [OfficePreviewAgentPresentation], reduceMotion: Bool = false) {
            guard anchor == nil else { update(agents: agents, reduceMotion: reduceMotion); return }
            self.view = view
            placements = placementStore.load()
            let room = AnchorEntity(world: .zero)
            anchor = room
            roomLayout.reconcile(ids: agents.map(\.id), mainAgentID: mainOfficeOwner(in: agents), reserveMainOffice: true)
            rebuildRoom()
            addCameraAndLight(to: room)
            view.scene.anchors.append(room)
            update(agents: agents, reduceMotion: reduceMotion)
            savePlacements()
            actionSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.advanceCamera(delta: event.deltaTime)
                    self?.advanceSky(delta: event.deltaTime)
                    self?.animateStationary(delta: event.deltaTime)
                    self?.animateMusic(delta: event.deltaTime)
                    self?.refreshBubbleClocks()
                    self?.flushLabelLayout()
                    self?.resumeFrameWaiters()
                }
            }
            resetCamera(reduceMotion: true, wholeOffice: true)
        }

        func applyCameraGesture(_ gesture: OfficePreviewCameraGesture, x: CGFloat, y: CGFloat) {
            manuallyMovedCamera = true
            resetTask?.cancel()
            switch gesture {
            case .orbit: cameraState.applyDrag(deltaX: x, deltaY: y)
            case .pan:
                cameraState.applyGroundPan(deltaX: x, deltaY: y, xRange: (roomLayout.minX - 5)...(roomLayout.maxX + 5), zRange: (roomLayout.back - 5)...(roomLayout.front + 5))
            }
            applyCameraTransform()
        }

        func applyCameraZoom(delta: CGFloat) {
            manuallyMovedCamera = true
            resetTask?.cancel()
            var destination = cameraState
            destination.distance = zoomTarget ?? cameraState.distance
            destination.applyZoom(delta: delta, maximumDistance: maximumCameraDistance)
            zoomTarget = destination.distance
            if lastReduceMotion { cameraState.distance = destination.distance; zoomTarget = nil; applyCameraTransform() }
        }

        private var maximumCameraDistance: Float { max(48, max(roomLayout.width, roomLayout.depth) * 1.6) }

        private func advanceCamera(delta: TimeInterval) {
            guard let view, view.window?.isVisible == true else { return }
            let input = view.cameraInput()
            let old = cameraState
            if input.isActive {
                manuallyMovedCamera = true
                resetTask?.cancel()
                if input.zoom != 0 { zoomTarget = nil }
                cameraState.advance(input: input, delta: delta,
                    xRange: (roomLayout.minX - 5)...(roomLayout.maxX + 5),
                    zRange: (roomLayout.back - 5)...(roomLayout.front + 5), maximumDistance: maximumCameraDistance)
            }
            if let target = zoomTarget {
                cameraState.easeZoom(toward: target, delta: delta)
                if abs(cameraState.distance - target) < 0.005 { cameraState.distance = target; zoomTarget = nil }
            }
            if old != cameraState { applyCameraTransform() }
        }

        func resetCamera(reduceMotion: Bool, wholeOffice: Bool = false, focusAgentID: String? = nil) {
            manuallyMovedCamera = false
            resetTask?.cancel()
            zoomTarget = nil
            let old = cameraState
            cameraState.reset()
            if wholeOffice {
                cameraState.orbitTarget = roomLayout.center
                cameraState.distance = max(30, max(roomLayout.width, roomLayout.depth) * 1.3)
            } else if let id = focusAgentID, let root = avatarRoots[id] {
                cameraState.orbitTarget = root.position + [0, 0.55, 0]
                cameraState.distance = 11
            } else if roomLayout.authored != nil {
                cameraState.orbitTarget = [-10.5, 0.55, -5]
                cameraState.distance = 26
            }
            let destination = cameraState
            guard !reduceMotion else { applyCameraTransform(); return }
            resetTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for frame in 1...14 {
                    if Task.isCancelled { return }
                    let t = Float(frame) / 14
                    let eased = t * t * (3 - 2 * t)
                    self.cameraState.azimuth = old.azimuth + (destination.azimuth - old.azimuth) * eased
                    self.cameraState.elevation = old.elevation + (destination.elevation - old.elevation) * eased
                    self.cameraState.distance = old.distance + (destination.distance - old.distance) * eased
                    self.cameraState.orbitTarget = old.orbitTarget + (destination.orbitTarget - old.orbitTarget) * eased
                    self.applyCameraTransform()
                    await self.nextFrame()
                }
            }
        }

        private func mainOfficeOwner(in agents: [OfficePreviewAgentPresentation]) -> String? {
            let main = agents.filter { $0.mainSession != nil }
            return main.first(where: { $0.mainSession?.isCurrent == true })?.id ?? main.map(\.id).sorted().first
        }

        func update(agents: [OfficePreviewAgentPresentation], reduceMotion: Bool) {
            guard let anchor else { return }
            // Hiding bots only hides them. They keep simulating in place so
            // showing them again never teleports anyone back to a desk.
            if showsAgents != lastShowsAgents {
                lastShowsAgents = showsAgents
                for root in avatarRoots.values { root.isEnabled = showsAgents }
                if !showsAgents { labels.values.forEach { $0.setVisible(false) } }
                layoutLabels()
            }
            guard agents != lastPresentations || reduceMotion != lastReduceMotion || isDataCurrent != lastDataCurrent else { return }
            lastDataCurrent = isDataCurrent
            lastPresentations = agents
            labelOrder = agents.sorted {
                let left = $0.taskData?.lane.rank ?? 99
                let right = $1.taskData?.lane.rank ?? 99
                return left == right ? $0.id < $1.id : left < right
            }.map(\.id)
            let oldCapacity = roomLayout.capacity
            roomLayout.reconcile(ids: agents.map(\.id), mainAgentID: mainOfficeOwner(in: agents), reserveMainOffice: true)
            if oldCapacity != roomLayout.capacity {
                rebuildRoom()
                if wholeOfficePreset && !manuallyMovedCamera { resetCamera(reduceMotion: true, wholeOffice: true) }
            }
            desiredAgents = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
            let zoneCapacity = Dictionary(uniqueKeysWithValues: OfficePreviewLocation.workZones.map {
                ($0, roomLayout.authored?.stations[$0]?.count ?? 0)
            })
            interactionPlan = isDataCurrent ? .make(agents: agents, zoneCapacity: zoneCapacity) : OfficePreviewInteractionPlan()
            for id in Array(avatarRoots.keys) where desiredAgents[id] == nil {
                if let node = currentNodes[id] { placements[id] = node }
                endConversation(id)
                movementTasks.removeValue(forKey: id)?.cancel()
                avatarRoots.removeValue(forKey: id)?.removeFromParent()
                labels.removeValue(forKey: id)?.removeFromSuperview()
                characterVisuals.removeValue(forKey: id)
                upperBodies.removeValue(forKey: id)
                chatBubbles.removeValue(forKey: id)
                limbEntities.removeValue(forKey: id)
                handProps.removeValue(forKey: id)
                robotFaces.removeValue(forKey: id)
                eyeColors.removeValue(forKey: id)
                currentNodes.removeValue(forKey: id)
                walkedDistances.removeValue(forKey: id)
                walkSpeeds.removeValue(forKey: id)
                walkingNow.remove(id)
                reservedSteps.removeValue(forKey: id)
                leisureTargets.removeValue(forKey: id)
                nextLeisureChange.removeValue(forKey: id)
            }
            // Working bots leave any chat; their reported task comes first.
            for id in Array(socialPartners.keys) where desiredAgents[id]?.canWander != true || reduceMotion { endConversation(id) }
            lastReduceMotion = reduceMotion
            for (index, agent) in agents.enumerated() {
                guard let slot = roomLayout.slots[agent.id] else { continue }
                if !agent.canWander || reduceMotion { leisureTargets[agent.id] = nil; nextLeisureChange[agent.id] = nil }
                let isNew = avatarRoots[agent.id] == nil
                let root = avatarRoots[agent.id] ?? makeAvatar(agent: agent)
                if isNew {
                    avatarRoots[agent.id] = root
                    root.isEnabled = showsAgents
                    anchor.addChild(root)
                    // Resume where the bot was last seen. New idle bots start
                    // at a free activity across the office instead of a desk.
                    var start = restoredNode(for: agent, slot: slot)
                    if start == nil, agent.canWander, !reduceMotion, let spot = leisureCandidates(for: agent, slot: slot, current: nil).prefix(8).randomElement() {
                        leisureTargets[agent.id] = spot
                        start = spot
                    }
                    if let index = start?.leisureIndex, agent.canWander, !reduceMotion {
                        leisureTargets[agent.id] = start
                        lastLeisureAction[agent.id] = roomLayout.authored?.leisureSpots[index].action
                        nextLeisureChange[agent.id] = animationTime + dwell(for: start, seed: agent.identitySeed) * 0.5
                    }
                    let node = reduceMotion ? destination(for: agent, slot: slot) : start ?? destination(for: agent, slot: slot)
                    currentNodes[agent.id] = node
                    root.position = roomLayout.position(node)
                    applyStationaryPose(agent: agent, root: root, time: 0)
                    // Anyone restored away from their destination walks there
                    // on the next activity tick.
                } else if reduceMotion {
                    movementTasks.removeValue(forKey: agent.id)?.cancel()
                    walkingNow.remove(agent.id)
                    let destination = destination(for: agent, slot: slot)
                    currentNodes[agent.id] = destination
                    root.position = roomLayout.position(destination)
                    applyStationaryPose(agent: agent, root: root, time: 0)
                } else if currentNodes[agent.id] != destination(for: agent, slot: slot) && movementTasks[agent.id] == nil {
                    movementTasks[agent.id] = move(root, id: agent.id, delay: Double(index % 6) * 0.12)
                }
                let label = labels[agent.id] ?? OfficePreviewTaskBubble(frame: .zero)
                label.onSelect = { [weak self] in self?.onSelectAgent(agent.id) }
                if labels[agent.id] == nil { labels[agent.id] = label; label.applyInk(palette.signInk); view?.addSubview(label) }
                label.update(agent: agent, reduceMotion: reduceMotion, isDataCurrent: isDataCurrent)
                tintEyes(agent: agent)
            }
            updateComputers()
            layoutLabels()
        }

        private func destination(for agent: OfficePreviewAgentPresentation, slot: Int) -> OfficePreviewLayout.Node {
            if let seat = interactionPlan.stations[agent.id] {
                return roomLayout.node(slot: seat, location: agent.location)
            }
            if agent.canWander, let target = leisureTargets[agent.id] { return target }
            // Every bot owns a unique home. Shared leisure seats are claimed
            // only when walking there, never used as overlapping spawn points.
            if agent.canWander { return roomLayout.node(slot: slot, location: .desk) }
            // A full work room, or stale data, keeps the bot at its own desk.
            if agent.location.isWorkZone { return roomLayout.node(slot: slot, location: .desk) }
            return roomLayout.node(slot: slot, location: agent.location)
        }

        private func dataCurrent(for agent: OfficePreviewAgentPresentation) -> Bool {
            agent.mainSession.map { $0.lane != .unknown } ?? isDataCurrent
        }

        /// The last place a bot stood, if it is still a valid spot in this layout.
        private func restoredNode(for agent: OfficePreviewAgentPresentation, slot: Int) -> OfficePreviewLayout.Node? {
            guard let saved = placements[agent.id],
                  OfficePreviewLayout.locations.indices.contains(saved.index) else { return nil }
            let taken = Set(currentNodes.values.compactMap(\.leisureIndex))
            if let index = saved.leisureIndex {
                guard agent.canWander, roomLayout.authored?.leisureSpots.indices.contains(index) == true, !taken.contains(index) else { return nil }
                return OfficePreviewLayout.Node(slot: slot, index: 0, isStation: true, leisureIndex: index)
            }
            if saved.isStation {
                guard saved.slot == slot, saved.slot >= 0 else { return nil }
                let point = roomLayout.position(saved)
                guard !currentNodes.values.contains(where: { simd_distance(roomLayout.position($0), point) < 0.8 }) else { return nil }
                return saved
            }
            let point = roomLayout.position(saved)
            guard roomLayout.isWalkable(point), !avatarRoots.contains(where: { $0.key != agent.id && simd_distance($0.value.position, point) < 0.8 }) else { return nil }
            return OfficePreviewLayout.Node(slot: -1, index: 0, isStation: false, connectorPosition: point)
        }

        /// Solo activities ranked so idle bots fill the whole office: crowded
        /// rooms and a repeat of the last activity score worse. Chat spots are
        /// reserved for pairs.
        private func leisureCandidates(for agent: OfficePreviewAgentPresentation, slot: Int, current: OfficePreviewLayout.Node?) -> [OfficePreviewLayout.Node] {
            guard let authored = roomLayout.authored else { return [] }
            let chatSpots = Set(socialPairs.flatMap { [$0.0, $0.1] })
            let reserved = Set(leisureTargets.filter { $0.key != agent.id }.values.compactMap(\.leisureIndex)
                + currentNodes.filter { $0.key != agent.id }.values.compactMap(\.leisureIndex))
            let others = avatarRoots.filter { $0.key != agent.id }.map(\.value.position)
                + leisureTargets.filter { $0.key != agent.id }.values.map { roomLayout.position($0) }
            let epoch = UInt64(max(0, animationTime) / 30)
            let scored = authored.leisureSpots.indices.compactMap { index -> (Int, Float)? in
                guard index != current?.leisureIndex, !reserved.contains(index), !chatSpots.contains(index) else { return nil }
                let spot = authored.leisureSpots[index]
                let crowd = Float(others.filter { simd_distance($0, spot.station.position) < 5 }.count)
                let repeatPenalty: Float = lastLeisureAction[agent.id] == spot.action ? 2.5 : 0
                let jitter = Float((agent.identitySeed &+ UInt64(index) &* 2_654_435_761 &+ epoch &* 40_503) % 1000) / 250
                return (index, crowd * 3 + repeatPenalty + jitter)
            }
            return scored.sorted { $0.1 < $1.1 }.map { OfficePreviewLayout.Node(slot: slot, index: 0, isStation: true, leisureIndex: $0.0) }
        }

        /// Adjacent chat spots that face each other.
        private var socialPairs: [(Int, Int)] {
            guard let spots = roomLayout.authored?.leisureSpots else { return [] }
            var pairs: [(Int, Int)] = []
            var index = 0
            while index + 1 < spots.count {
                if spots[index].action == .socializing, spots[index + 1].action == .socializing,
                   simd_distance(spots[index].station.position, spots[index + 1].station.position) < 2 {
                    pairs.append((index, index + 1))
                    index += 2
                } else { index += 1 }
            }
            return pairs
        }

        private func dwell(for node: OfficePreviewLayout.Node?, seed: UInt64) -> TimeInterval {
            let action = node?.leisureIndex.flatMap { index in
                roomLayout.authored?.leisureSpots.indices.contains(index) == true ? roomLayout.authored?.leisureSpots[index].action : nil
            }
            let base: TimeInterval
            switch action {
            case .charging: base = 24
            case .reading: base = 20
            case .tinkering: base = 16
            case .arcade: base = 14
            case .coffee: base = 12
            case .browsing: base = 10
            case .strolling: base = 7
            case .socializing: base = 15
            case nil: base = 10
            }
            return base + Double(seed % 6)
        }

        private func updateLeisure() {
            guard let authored = roomLayout.authored else { return }
            updateConversations()
            for agent in desiredAgents.values.sorted(by: { $0.id < $1.id })
            where agent.canWander && movementTasks[agent.id] == nil && socialPartners[agent.id] == nil {
                guard let slot = roomLayout.slots[agent.id], let current = currentNodes[agent.id] else { continue }
                if nextLeisureChange[agent.id] == nil { nextLeisureChange[agent.id] = animationTime + 2 + Double(agent.identitySeed % 5) }
                guard animationTime >= nextLeisureChange[agent.id, default: .infinity] else { continue }
                if startConversation(agent, slot: slot, current: current) { continue }
                // Leisure never changes Hermes tasks or their ordering.
                var target = roomLayout.node(slot: slot, location: .desk)
                for candidate in leisureCandidates(for: agent, slot: slot, current: current).prefix(6)
                where !roomLayout.route(from: current, to: candidate).isEmpty {
                    target = candidate
                    break
                }
                leisureTargets[agent.id] = target
                if let index = target.leisureIndex { lastLeisureAction[agent.id] = authored.leisureSpots[index].action }
                nextLeisureChange[agent.id] = animationTime + dwell(for: target, seed: agent.identitySeed)
                if current != target, let root = avatarRoots[agent.id] { movementTasks[agent.id] = move(root, id: agent.id, delay: 0) }
            }
            // Settle anyone standing away from their destination, such as a
            // bot restored mid-route or whose task changed while it was idle.
            for agent in desiredAgents.values where movementTasks[agent.id] == nil && (dataCurrent(for: agent) || agent.canWander) {
                guard let slot = roomLayout.slots[agent.id], let current = currentNodes[agent.id], let root = avatarRoots[agent.id],
                      current != destination(for: agent, slot: slot) else { continue }
                movementTasks[agent.id] = move(root, id: agent.id, delay: 0)
            }
        }

        /// Invites the nearest free idle colleague to a pair of chat spots.
        private func startConversation(_ agent: OfficePreviewAgentPresentation, slot: Int, current: OfficePreviewLayout.Node) -> Bool {
            let roll = (agent.identitySeed &+ UInt64(max(0, animationTime) / 7) &* 7_919) % 100
            guard roll < 45, let authored = roomLayout.authored, let position = avatarRoots[agent.id]?.position else { return false }
            let partner = desiredAgents.values.filter {
                $0.id != agent.id && $0.canWander && movementTasks[$0.id] == nil && socialPartners[$0.id] == nil
                    && currentNodes[$0.id] != nil && roomLayout.slots[$0.id] != nil && avatarRoots[$0.id] != nil
            }.min { simd_distance(avatarRoots[$0.id]!.position, position) < simd_distance(avatarRoots[$1.id]!.position, position) }
            guard let partner, let partnerSlot = roomLayout.slots[partner.id], let partnerNode = currentNodes[partner.id],
                  let partnerPosition = avatarRoots[partner.id]?.position, simd_distance(partnerPosition, position) < 16 else { return false }
            let reserved = Set(leisureTargets.filter { $0.key != agent.id && $0.key != partner.id }.values.compactMap(\.leisureIndex)
                + currentNodes.filter { $0.key != agent.id && $0.key != partner.id }.values.compactMap(\.leisureIndex))
            let middle = (position + partnerPosition) / 2
            let pairs = socialPairs.filter { !reserved.contains($0.0) && !reserved.contains($0.1) }.sorted {
                simd_distance(authored.leisureSpots[$0.0].station.position, middle) < simd_distance(authored.leisureSpots[$1.0].station.position, middle)
            }
            for pair in pairs.prefix(3) {
                let near = simd_distance(authored.leisureSpots[pair.0].station.position, position)
                    <= simd_distance(authored.leisureSpots[pair.1].station.position, position)
                let mine = OfficePreviewLayout.Node(slot: slot, index: 0, isStation: true, leisureIndex: near ? pair.0 : pair.1)
                let theirs = OfficePreviewLayout.Node(slot: partnerSlot, index: 0, isStation: true, leisureIndex: near ? pair.1 : pair.0)
                guard !roomLayout.route(from: current, to: mine).isEmpty, !roomLayout.route(from: partnerNode, to: theirs).isEmpty else { continue }
                leisureTargets[agent.id] = mine
                leisureTargets[partner.id] = theirs
                socialPartners[agent.id] = partner.id
                socialPartners[partner.id] = agent.id
                conversationInvites[conversationKey(agent.id, partner.id)] = animationTime
                lastLeisureAction[agent.id] = .socializing
                lastLeisureAction[partner.id] = .socializing
                for (id, delay) in [(agent.id, 0.0), (partner.id, 0.5)] where currentNodes[id] != leisureTargets[id] {
                    if let root = avatarRoots[id] { movementTasks[id] = move(root, id: id, delay: delay) }
                }
                return true
            }
            return false
        }

        private func conversationKey(_ a: String, _ b: String) -> String { a < b ? "\(a)|\(b)" : "\(b)|\(a)" }

        /// Seconds since both colleagues arrived, or nil while either is walking.
        private func conversationTime(_ id: String) -> TimeInterval? {
            guard let partner = socialPartners[id], let start = conversationStarts[conversationKey(id, partner)] else { return nil }
            return animationTime - start
        }

        private func updateConversations() {
            for (id, partner) in socialPartners where id < partner {
                let key = conversationKey(id, partner)
                let arrived = [id, partner].allSatisfy { movementTasks[$0] == nil && currentNodes[$0] != nil && currentNodes[$0] == leisureTargets[$0] }
                if arrived, conversationStarts[key] == nil { conversationStarts[key] = animationTime }
                let invited = conversationInvites[key] ?? animationTime
                let finished = conversationStarts[key].map { animationTime - $0 > Self.conversationLength } ?? (animationTime - invited > 40)
                guard finished else { continue }
                endConversation(id)
                nextLeisureChange[id] = animationTime
                nextLeisureChange[partner] = animationTime + 1.2
            }
        }

        private func endConversation(_ id: String) {
            guard let partner = socialPartners.removeValue(forKey: id) else { return }
            socialPartners.removeValue(forKey: partner)
            conversationStarts.removeValue(forKey: conversationKey(id, partner))
            conversationInvites.removeValue(forKey: conversationKey(id, partner))
            for bot in [id, partner] { chatBubbles[bot]?.isEnabled = false }
        }


        private func updateComputers() {
            let active = Set(desiredAgents.values.compactMap { agent -> Int? in
                guard dataCurrent(for: agent), agent.activityLane == .running, let slot = roomLayout.slots[agent.id],
                      currentNodes[agent.id] == roomLayout.node(slot: slot, location: .desk),
                      movementTasks[agent.id] == nil else { return nil }
                return slot
            })
            guard active != poweredScreens else { return }
            poweredScreens = active
            for (slot, screen) in screens {
                let color = active.contains(slot) ? palette.activeScreen : palette.idleScreen
                screen.model?.materials = [unlitMaterial(color)]
                if slot == 22, let extended = roomGeometry?.findEntity(named: "main-office-extended-screen") as? ModelEntity {
                    extended.model?.materials = [UnlitMaterial(color: color)]
                }
            }
        }

        private func savePlacements() {
            for (id, node) in currentNodes {
                if walkingNow.contains(id), let root = avatarRoots[id] {
                    placements[id] = .init(slot: -1, index: 0, isStation: false, connectorPosition: root.position)
                } else {
                    placements[id] = node
                }
            }
            placementStore.save(placements)
            lastPlacementSave = Date()
        }

        func stop() {
            savePlacements()
            movementTasks.values.forEach { $0.cancel() }
            movementTasks.removeAll()
            actionSubscription?.cancel()
            actionSubscription = nil
            resetTask?.cancel()
            resumeFrameWaiters()
            labels.values.forEach { $0.removeFromSuperview() }
            labels.removeAll()
            if let roomGeometry, let navigation = roomLayout.authored {
                roomGeometry.removeFromParent()
                Self.cachedRoom = CachedRoom(geometry: roomGeometry, navigation: navigation,
                                             palette: palette, capacity: roomLayout.capacity)
                self.roomGeometry = nil
            }
            view?.scene.anchors.removeAll()
        }

        deinit {
            movementTasks.values.forEach { $0.cancel() }
            resetTask?.cancel()
        }

        private func move(_ root: Entity, id: String, delay: Double) -> Task<Void, Never> {
            Task { @MainActor [weak self, weak root] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, let root else { return }
                defer {
                    self.reservedSteps[id] = nil
                    self.walkingNow.remove(id)
                }
                var remainingRoute: [OfficePreviewLayout.Node] = []
                var plannedDestination: OfficePreviewLayout.Node?
                // Speed carries across route corners: bots ease in, cruise
                // and ease out instead of restarting at every waypoint.
                var speed: Float = 0
                let cruise: Float = 1.15 + Float(self.desiredAgents[id].map { $0.identitySeed % 5 } ?? 0) * 0.04
                while let agent = self.desiredAgents[id], let node = self.currentNodes[id],
                      let slot = self.roomLayout.slots[id] {
                    guard !Task.isCancelled else { return }
                    if (!self.dataCurrent(for: agent) && !agent.canWander) || self.view?.window?.occlusionState.contains(.visible) != true {
                        self.walkingNow.remove(id)
                        speed = 0
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        continue
                    }
                    let destination = self.destination(for: agent, slot: slot)
                    if node == destination {
                        self.walkingNow.remove(id)
                        self.walkSpeeds[id] = 0
                        self.movementTasks[id] = nil
                        if agent.canWander && self.socialPartners[id] == nil {
                            self.nextLeisureChange[id] = self.animationTime + self.dwell(for: node, seed: agent.identitySeed)
                        }
                        if self.lastReduceMotion { self.applyStationaryPose(agent: agent, root: root, time: 0) }
                        self.updateComputers()
                        self.layoutLabels()
                        return
                    }
                    // Stations are private; corridors are shared. Reserve the
                    // next waypoint and yield if another character occupies it.
                    let occupied = self.avatarRoots.filter { $0.key != id }.map { $0.value.position }
                        + self.reservedSteps.filter { $0.key != id }.map(\.value)
                    func obstructed(_ point: SIMD3<Float>) -> Bool {
                        occupied.contains { abs($0.x - point.x) < 0.8 && abs($0.z - point.z) < 0.8 }
                    }
                    if plannedDestination != destination || remainingRoute.isEmpty ||
                        remainingRoute.first.map({ obstructed(self.roomLayout.position($0)) }) == true {
                        let route = self.roomLayout.route(from: node, to: destination, avoiding: occupied)
                        remainingRoute = Array(self.roomLayout.smoothed(route, from: self.roomLayout.position(node), avoiding: occupied).dropFirst())
                        plannedDestination = destination
                    }
                    guard let nextNode = remainingRoute.first, !obstructed(self.roomLayout.position(nextNode)) else {
                        self.walkingNow.remove(id)
                        speed = 0
                        do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                        continue
                    }
                    remainingRoute.removeFirst()
                    self.reservedSteps[id] = self.roomLayout.position(nextNode)
                    self.walkingNow.insert(id)
                    let start = root.position
                    let end = self.roomLayout.position(nextNode)
                    let length = simd_length(end - start)
                    let direction = length > 0.001 ? (end - start) / length : SIMD3<Float>(0, 0, 1)
                    let isFinalStep = nextNode == destination
                    // Step into a seat already facing the way the seat faces.
                    let heading = simd_quatf(angle: isFinalStep ? (self.stationYaw(nextNode) ?? atan2(direction.x, direction.z)) : atan2(direction.x, direction.z), axis: [0, 1, 0])
                    let clock = ContinuousClock()
                    var lastTick = clock.now
                    var traveled: Float = 0
                    var held: Float = 0
                    var interrupted = false
                    var remainingDistance: Float = 0
                    var cursor = end
                    for waypoint in remainingRoute {
                        let point = self.roomLayout.position(waypoint)
                        remainingDistance += simd_length(point - cursor)
                        cursor = point
                    }
                    while !Task.isCancelled && traveled < length {
                        let now = clock.now
                        let elapsed = lastTick.duration(to: now)
                        lastTick = now
                        let visible = (self.dataCurrent(for: agent) || agent.canWander) && self.view?.window?.occlusionState.contains(.visible) == true
                        if !visible {
                            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                            continue
                        }
                        let dt = Float(min(0.05, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
                        let ahead = length - traveled + remainingDistance
                        var targetSpeed = min(isFinalStep ? 0.6 : cruise, sqrt(2 * 1.5 * max(0, ahead)) + 0.12)
                        // Personal space: slow and wait for a bot just ahead.
                        let here = start + direction * traveled
                        let blocked = self.avatarRoots.contains { key, other in
                            guard key != id else { return false }
                            let offset = SIMD2<Float>(other.position.x - here.x, other.position.z - here.z)
                            let forward = offset.x * direction.x + offset.y * direction.z
                            let lateral = abs(offset.x * direction.z - offset.y * direction.x)
                            return forward > 0.1 && forward < 0.95 && lateral < 0.55
                        }
                        if blocked { targetSpeed = 0; held += dt } else { held = 0 }
                        speed += max(-3.2 * dt, min(2.2 * dt, targetSpeed - speed))
                        traveled = min(length, traveled + speed * dt)
                        self.walkedDistances[id, default: 0] += speed * dt
                        self.walkSpeeds[id] = speed / cruise
                        root.position = start + direction * traveled
                        root.orientation = simd_slerp(root.orientation, heading, 1 - exp(-dt * 10))
                        self.layoutLabels()
                        if held > 1.5 && self.roomLayout.isWalkable(root.position) { interrupted = true; break }
                        await self.nextFrame()
                    }
                    if Task.isCancelled { return }
                    self.reservedSteps[id] = nil
                    if interrupted {
                        // Replan around the colleague from exactly where we stopped.
                        self.currentNodes[id] = OfficePreviewLayout.Node(slot: -1, index: 0, isStation: false, connectorPosition: root.position)
                        remainingRoute = []
                        speed = 0
                        self.walkingNow.remove(id)
                        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                        continue
                    }
                    // Only now read the newest destination: a refresh finishes
                    // this segment and replans from an actual graph node.
                    self.currentNodes[id] = nextNode
                }
                self.movementTasks[id] = nil
            }
        }

        /// Walks and camera tweens step once per rendered frame, so motion
        /// never beats against the display the way a fixed 16 ms sleep does.
        private var frameWaiters: [CheckedContinuation<Void, Never>] = []

        private func nextFrame() async {
            guard !Task.isCancelled else { return }
            guard actionSubscription != nil else { try? await Task.sleep(for: .milliseconds(16)); return }
            await withCheckedContinuation { frameWaiters.append($0) }
        }

        private func resumeFrameWaiters() {
            guard !frameWaiters.isEmpty else { return }
            let waiters = frameWaiters
            frameWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        private func stationYaw(_ node: OfficePreviewLayout.Node) -> Float? {
            guard node.isStation else { return nil }
            if let index = node.leisureIndex {
                guard let spots = roomLayout.authored?.leisureSpots, spots.indices.contains(index) else { return nil }
                return spots[index].station.yaw
            }
            return roomLayout.yaw(slot: node.slot, location: OfficePreviewLayout.locations[node.index])
        }

        /// One per-frame driver for every pose. Targets blend with a critically
        /// damped follow, so sitting, standing, walking and gesturing never pop.
        private func animateStationary(delta: TimeInterval) {
            guard !lastReduceMotion, view?.window?.occlusionState.contains(.visible) == true else { return }
            let dt = Float(min(delta, 0.1))
            animationTime += Double(dt)
            if animationTime - lastLeisureTick >= 1 {
                lastLeisureTick = animationTime
                updateLeisure()
                updateComputers()
            }
            guard showsAgents else { return }
            for (id, agent) in desiredAgents {
                guard dataCurrent(for: agent) || agent.canWander || walkingNow.contains(id), let root = avatarRoots[id] else { continue }
                let target = targetPose(for: agent, time: animationTime)
                applyPose(target.pose, agentID: id, amount: 1 - exp(-dt * (walkingNow.contains(id) ? 16 : 7)))
                if let yaw = target.yaw { root.orientation = simd_slerp(root.orientation, simd_quatf(angle: yaw, axis: [0, 1, 0]), 1 - exp(-dt * 6)) }
            }
            for (id, agent) in desiredAgents { blink(agentID: id, seed: agent.identitySeed) }
        }


        /// Visor eyes report the same lane colors as the task bubble.
        private func tintEyes(agent: OfficePreviewAgentPresentation) {
            guard let face = robotFaces[agent.id] else { return }
            let color = OfficeAgentStatus(agent: agent, isDataCurrent: isDataCurrent).nsColor
            guard eyeColors[agent.id] != color else { return }
            eyeColors[agent.id] = color
            for eye in face.eyes { eye.model?.materials = [unlitMaterial(color)] }
        }

        /// Clouds drift every frame; the sun is re-read from the clock twice a
        /// minute, which keeps dawn and dusk gradual without per-frame work.
        private func advanceSky(delta: TimeInterval) {
            guard let view, view.window?.isVisible == true else { return }
            if !lastReduceMotion { sky?.drift(delta: delta) }
            let now = Date()
            guard now.timeIntervalSince(lastDaylightCheck) >= 30 else { return }
            lastDaylightCheck = now
            let next = OfficeDaylight(date: clock())
            guard next != daylight else { return }
            daylight = next
            lighting?.apply(next)
            sky?.apply(next)
            OfficeSceneLighting.applyEnvironment(to: view, daylight: next)
            postProcess.update(cameraDistance: cameraState.distance, isDark: next.isDark)
        }

        /// Theme changes rebuild static scenery once; agents keep their places.
        func apply(palette next: OfficeScenePalette) {
            guard next != palette else { return }
            palette = next
            guard anchor != nil else { return }
            rebuildRoom()
            labels.values.forEach { $0.applyInk(next.signInk) }
        }

        /// A glowing floor ring marks the bot whose details are open.
        func select(_ id: String?) {
            guard id != selectedAgentID else { return }
            if let old = selectedAgentID { avatarRoots[old]?.findEntity(named: "selection-ring")?.isEnabled = false }
            selectedAgentID = id
            if let id, let ring = avatarRoots[id]?.findEntity(named: "selection-ring") { ring.isEnabled = true }
            if let id, let label = labels[id] { label.superview?.addSubview(label) }
        }

        /// A brief, identity-offset blink every few seconds.
        private func blink(agentID: String, seed: UInt64) {
            guard let face = robotFaces[agentID] else { return }
            let cycle = (animationTime + Double(seed % 7) * 0.61).truncatingRemainder(dividingBy: 4.3)
            let height: Float = cycle < 0.14 ? 0.15 : 1
            for eye in face.eyes where eye.scale.y != height { eye.scale.y = height }
        }

        private func refreshBubbleClocks() {
            let now = Date()
            guard now.timeIntervalSince(lastClockTick) >= 1 else { return }
            lastClockTick = now
            if now.timeIntervalSince(lastPlacementSave) >= 10 { savePlacements() }
            var changed = false
            for label in labels.values where !label.isHidden { changed = label.refreshClock(now: now) || changed }
            if changed { layoutLabels() }
        }

        /// Snaps to the current target pose (arrival under Reduce Motion, spawn).
        private func applyStationaryPose(agent: OfficePreviewAgentPresentation, root: Entity, time: TimeInterval) {
            let target = targetPose(for: agent, time: time)
            applyPose(target.pose, agentID: agent.id, amount: 1)
            if let yaw = target.yaw { root.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) }
        }

        private func isSeated(_ agent: OfficePreviewAgentPresentation) -> Bool {
            guard agent.phase.isSeated else { return false }
            if let index = currentNodes[agent.id]?.leisureIndex { return roomLayout.authored?.leisureSpots[index].station.seated ?? false }
            let slot = roomLayout.slots[agent.id] ?? 0
            return roomLayout.authored?.station(slot: currentNodes[agent.id]?.slot ?? slot, location: OfficePreviewLayout.locations[currentNodes[agent.id]?.index ?? 0]).seated ?? true
        }

        /// Joint targets for one frame. Angles are about each joint's own pivot
        /// (hips, shoulders, neck and waist), so limbs swing instead of spinning.
        private struct RigPose {
            static let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            var leftArm = identity, rightArm = identity, leftLeg = identity, rightLeg = identity
            var head = identity, upper = identity
            var height: Float = 0
            var leftLift: Float = 0, rightLift: Float = 0
            var chatting = false
        }

        private func pitch(_ angle: Float) -> simd_quatf { simd_quatf(angle: angle, axis: [1, 0, 0]) }
        private func turn(_ angle: Float) -> simd_quatf { simd_quatf(angle: angle, axis: [0, 1, 0]) }
        private func roll(_ angle: Float) -> simd_quatf { simd_quatf(angle: angle, axis: [0, 0, 1]) }

        /// 0→1→0 envelope for a gesture between `start` and `end` seconds.
        private func gesture(_ t: Double, _ start: Double, _ end: Double, fade: Double = 0.45) -> Float {
            guard t > start, t < end else { return 0 }
            let f = min(1, min((t - start) / fade, (end - t) / fade))
            return Float(f * f * (3 - 2 * f))
        }

        private func targetPose(for agent: OfficePreviewAgentPresentation, time: TimeInterval) -> (pose: RigPose, yaw: Float?) {
            let id = agent.id
            let seed = agent.identitySeed
            let t = time + Double(seed % 97) * 0.37
            let wave = time == 0 ? Float(0) : sin(Float(t) * 2.3)
            let slow = time == 0 ? Float(0) : sin(Float(t) * 0.45)
            let breath = time == 0 ? Float(0) : sin(Float(t) * 1.7)
            var pose = RigPose()
            // Relaxed standing baseline: breathing, arms slightly out.
            pose.upper = pitch(breath * 0.012)
            pose.leftArm = pitch(0.06 + breath * 0.02) * roll(-0.07)
            pose.rightArm = pitch(0.06 - breath * 0.02) * roll(0.07)
            pose.head = turn(slow * 0.35) * pitch(0.02)

            if walkingNow.contains(id) {
                let walk = OfficePreviewWalkPose(distance: walkedDistances[id, default: 0], amount: walkSpeeds[id, default: 0])
                pose.leftLeg = pitch(walk.legAngle)
                pose.rightLeg = pitch(-walk.legAngle)
                pose.leftLift = walk.leftLift
                pose.rightLift = walk.rightLift
                pose.leftArm = pitch(walk.armAngle) * roll(-0.08)
                pose.rightArm = pitch(-walk.armAngle) * roll(0.08)
                pose.upper = pitch(walk.lean) * turn(walk.twist) * roll(walk.sway)
                pose.head = pitch(-walk.lean * 0.7 + walk.headBob) * turn(-walk.twist * 0.6)
                pose.height = walk.bounce
                return (pose, nil)
            }
            guard let slot = roomLayout.slots[id], let node = currentNodes[id], movementTasks[id] == nil,
                  node == destination(for: agent, slot: slot) else {
                // Waiting for a clear path: glance around, shift weight.
                pose.upper = pose.upper * roll(slow * 0.03)
                pose.head = turn(sin(Float(t) * 0.9) * 0.5)
                return (pose, nil)
            }
            var yaw = stationYaw(node)
            let seated = isSeated(agent)
            if seated {
                pose.height = 0.30
                pose.leftLeg = pitch(-.pi / 2)
                pose.rightLeg = pitch(-.pi / 2)
            }

            // Sims-style chat once both colleagues arrive.
            if let partner = socialPartners[id], let peer = avatarRoots[partner], let root = avatarRoots[id] {
                let delta = peer.position - root.position
                yaw = atan2(delta.x, delta.z)
                if let e = conversationTime(id) { conversation(&pose, elapsed: e, initiator: id < partner) }
                return (pose, yaw)
            }
            let leisure = agent.canWander ? node.leisureIndex.flatMap { roomLayout.authored?.leisureSpots[$0].action } : nil
            if let leisure {
                switch leisure {
                case .coffee:
                    let sip = gesture(t.truncatingRemainder(dividingBy: 6), 3.4, 5.0)
                    pose.rightArm = pitch(-1.25 - 0.95 * sip) * roll(0.25 * sip)
                    pose.head = pitch(-0.03 - 0.16 * sip) * turn(slow * 0.3 * (1 - sip))
                case .reading:
                    let page = gesture(t.truncatingRemainder(dividingBy: 7), 5.6, 6.6, fade: 0.3)
                    pose.leftArm = pitch(-0.95)
                    pose.rightArm = pitch(-1.0 - 0.2 * page) * roll(0.5 * page)
                    pose.head = pitch(0.3) * turn(0.04 * wave)
                case .arcade:
                    pose.leftArm = pitch(-1.1 + wave * 0.18)
                    pose.rightArm = pitch(-1.1 - sin(Float(t) * 7) * 0.12)
                    pose.head = pitch(0.12 + wave * 0.03)
                case .strolling, .socializing:
                    let stretch = gesture(t.truncatingRemainder(dividingBy: 14), 9, 11.2)
                    pose.leftArm = pose.leftArm * pitch(-2.9 * stretch)
                    pose.rightArm = pose.rightArm * pitch(-2.9 * stretch)
                    pose.upper = pose.upper * pitch(-0.08 * stretch) * roll(slow * 0.04)
                    pose.head = turn(slow * 0.6 * (1 - stretch)) * pitch(-0.15 * stretch)
                case .charging:
                    // Powered down on the dock: head bowed, slow breathing.
                    let doze = time == 0 ? Float(0) : sin(Float(t) * 0.8)
                    pose.head = pitch(0.3 + doze * 0.03)
                    pose.upper = pitch(0.05 + doze * 0.01)
                    pose.leftArm = pitch(0.12) * roll(-0.03)
                    pose.rightArm = pitch(0.12) * roll(0.03)
                case .tinkering:
                    let work = time == 0 ? Float(0) : sin(Float(t) * 5)
                    let inspect = gesture(t.truncatingRemainder(dividingBy: 9), 6, 8)
                    pose.upper = pitch(0.14 - 0.1 * inspect)
                    pose.leftArm = pitch(-0.8 + work * 0.15 * (1 - inspect))
                    pose.rightArm = pitch(-0.85 - work * 0.22 * (1 - inspect) - 0.9 * inspect)
                    pose.head = pitch(0.32 - 0.25 * inspect) * turn(0.2 * inspect)
                case .browsing:
                    let cycle = t.truncatingRemainder(dividingBy: 10)
                    let reachLeft = gesture(cycle, 2, 3.6), reachRight = gesture(cycle, 6.5, 8.1)
                    pose.leftArm = pose.leftArm * pitch(-2.3 * reachLeft)
                    pose.rightArm = pose.rightArm * pitch(-2.3 * reachRight)
                    pose.head = turn(sin(Float(t) * 0.8) * 0.35) * pitch(-0.12 - 0.12 * (reachLeft + reachRight))
                }
                return (pose, yaw)
            }
            // Reported planning/review colleagues discuss without ending.
            if let partnerID = interactionPlan.partners[id], movementTasks[partnerID] == nil,
               let peer = avatarRoots[partnerID], let root = avatarRoots[id], simd_distance(root.position, peer.position) < 4 {
                let delta = peer.position - root.position
                yaw = atan2(delta.x, delta.z)
                let speaking = (Int(time / 3) % 2 == 0) == (id < partnerID)
                talk(&pose, t: t, speaking: speaking)
                return (pose, yaw)
            }
            switch agent.phase {
            case .implementing:
                // Alternating key taps with a short look-back every few seconds.
                let pause = gesture(t.truncatingRemainder(dividingBy: 8), 6, 7.6)
                let left = time == 0 ? Float(0) : max(0, sin(Float(t) * 13)) * 0.09
                let right = time == 0 ? Float(0) : max(0, sin(Float(t) * 13 + 1.9)) * 0.09
                pose.leftArm = pitch(-1.08 + left + 0.3 * pause)
                pose.rightArm = pitch(-1.08 + right + 0.3 * pause)
                pose.upper = pitch(0.07 - 0.1 * pause)
                pose.head = pitch(0.14 + (time == 0 ? 0 : max(0, wave) * 0.05) - 0.12 * pause)
            case .testing, .reading, .reviewing:
                let scroll = time == 0 ? Float(0) : sin(Float(t) * 3.1) * 0.05
                let chin = gesture(t.truncatingRemainder(dividingBy: 11), 7, 9.2)
                pose.leftArm = pitch(-0.8)
                pose.rightArm = pitch(-1.0 + scroll - 1.3 * chin) * roll(-0.3 * chin)
                pose.head = pitch(0.1 - 0.05 * chin) * turn(slow * 0.18)
            case .planning:
                let point = gesture(t.truncatingRemainder(dividingBy: 7), 3, 5)
                pose.rightArm = pitch(-0.5 + wave * 0.1 - 1.5 * point)
                pose.leftArm = pitch(-0.25) * roll(-0.35)
                pose.head = pitch(-0.1 - 0.08 * point) * roll(slow * 0.08)
            case .resting:
                pose.upper = pitch(seated ? -0.08 : 0) * roll(slow * 0.03)
                pose.head = turn(slow * 0.45) * pitch(-0.03)
            case .waiting:
                // A quiet 24-second routine, offset by identity. These gestures
                // are presentation only; Hermes alone clears the blocker.
                let cycle = time == 0 ? 0 : (time + Double(seed % 24)).truncatingRemainder(dividingBy: 24)
                let check = gesture(cycle, 1, 6, fade: 0.8)
                let ponder = gesture(cycle, 9, 13, fade: 0.8)
                let ask = gesture(cycle, 18, 21, fade: 0.8)
                pose.leftArm = pitch(-0.8 * check - 0.45 * ponder)
                pose.rightArm = pitch(-0.85 * check - (2.35 + wave * 0.06) * ponder - 2.85 * ask) * roll(-0.18 * ponder - 0.25 * ask)
                pose.upper = roll(0.035 * ponder)
                pose.head = turn(slow * 0.3) * roll(0.1 + slow * 0.05)
            }
            return (pose, yaw)
        }

        /// Talking: open-hand gestures and nods; listening: slow nods and tilts.
        private func talk(_ pose: inout RigPose, t: Double, speaking: Bool) {
            let u = Float(t)
            if speaking {
                pose.rightArm = pitch(-0.85 + sin(u * 5.5) * 0.35) * roll(0.2 + sin(u * 3.1) * 0.1)
                pose.leftArm = pitch(-0.45 + sin(u * 4.3 + 1) * 0.2) * roll(-0.15)
                pose.head = pitch(sin(u * 4.8) * 0.05) * roll(sin(u * 1.7) * 0.06)
                pose.upper = pose.upper * turn(sin(u * 1.3) * 0.06)
                pose.chatting = true
            } else {
                pose.head = pitch(max(0, sin(u * 2.8)) * 0.14) * roll(0.07)
                pose.leftArm = pitch(-0.1) * roll(-0.05)
                pose.rightArm = pitch(-0.1) * roll(0.05)
            }
        }

        /// A 15-second chat: wave hello, take turns talking, share a laugh,
        /// high-five, then wave goodbye.
        private static let conversationLength: TimeInterval = 15

        private func conversation(_ pose: inout RigPose, elapsed e: TimeInterval, initiator: Bool) {
            let u = Float(e)
            if e < 1.6 {
                let hello = gesture(e, 0, 1.6, fade: 0.35)
                pose.rightArm = pitch(-2.7 * hello) * roll((0.3 + sin(u * 12) * 0.35) * hello)
                pose.head = roll(0.12 * hello)
            } else if e < 6.4 || (e >= 7.8 && e < 11.6) {
                let turnIndex = Int((e - 1.6) / 2.4)
                talk(&pose, t: e, speaking: (turnIndex % 2 == 0) == initiator)
            } else if e < 7.8 {
                // Shared laugh: quick bounce, heads tipped back, hands to belly.
                let laugh = gesture(e, 6.4, 7.8, fade: 0.25)
                pose.height += abs(sin(u * 17)) * 0.035 * laugh
                pose.head = pitch(-0.22 * laugh) * roll(sin(u * 9) * 0.08 * laugh)
                pose.upper = pitch(-0.08 * laugh)
                pose.leftArm = pitch(-0.7 * laugh) * roll(0.3 * laugh)
                pose.rightArm = pitch(-0.7 * laugh) * roll(-0.3 * laugh)
            } else if e < 13.4 {
                let reach = gesture(e, 11.6, 13.4, fade: 0.5)
                let slap = gesture(e, 12.3, 12.7, fade: 0.2)
                pose.rightArm = pitch(-2.35 * reach) * roll(-0.25 * reach)
                pose.upper = pitch(0.1 * reach)
                pose.height += 0.05 * slap
                pose.head = pitch(-0.12 * reach)
            } else {
                let bye = gesture(e, 13.4, Self.conversationLength, fade: 0.3)
                pose.leftArm = pitch(-2.6 * bye) * roll((-0.3 - sin(u * 11) * 0.3) * bye)
            }
        }

        private func applyPose(_ pose: RigPose, agentID: String, amount: Float) {
            guard let limbs = limbEntities[agentID], let visual = characterVisuals[agentID] else { return }
            func blend(_ entity: Entity, _ target: simd_quatf) {
                entity.orientation = amount >= 1 ? target : simd_slerp(entity.orientation, target, amount)
            }
            func mix(_ current: Float, _ target: Float) -> Float { amount >= 1 ? target : current + (target - current) * amount }
            blend(limbs.leftArm, pose.leftArm)
            blend(limbs.rightArm, pose.rightArm)
            blend(limbs.leftLeg, pose.leftLeg)
            blend(limbs.rightLeg, pose.rightLeg)
            limbs.leftLeg.position.y = mix(limbs.leftLeg.position.y, Self.hipHeight + pose.leftLift)
            limbs.rightLeg.position.y = mix(limbs.rightLeg.position.y, Self.hipHeight + pose.rightLift)
            if let upper = upperBodies[agentID] { blend(upper, pose.upper) }
            if let head = robotFaces[agentID]?.head { blend(head, pose.head) }
            let height = mix(visual.position.y, pose.height)
            if abs(height - visual.position.y) > 0.004 { layoutLabels() }
            visual.position.y = height
            visual.orientation = RigPose.identity
            let action = currentNodes[agentID]?.leisureIndex.flatMap { roomLayout.authored?.leisureSpots[$0].action }
            let arrived = movementTasks[agentID] == nil && desiredAgents[agentID]?.canWander == true
            if let props = handProps[agentID] {
                if props.cup.isEnabled != (arrived && action == .coffee) { props.cup.isEnabled = arrived && action == .coffee }
                if props.book.isEnabled != (arrived && action == .reading) { props.book.isEnabled = arrived && action == .reading }
            }
            if let bubble = chatBubbles[agentID] {
                if bubble.isEnabled != pose.chatting { bubble.isEnabled = pose.chatting }
                if pose.chatting {
                    for (index, dot) in bubble.children.filter({ $0.name == "chat-dot" }).enumerated() {
                        dot.position.y = max(0, sin(Float(animationTime) * 7 - Float(index % 3) * 0.9)) * 0.035
                    }
                }
            }
        }

        @objc func handleMagnification(_ recognizer: NSMagnificationGestureRecognizer) {
            applyCameraZoom(delta: recognizer.magnification * 180)
            recognizer.magnification = 0
        }

        func handleClick(at point: NSPoint) {
            guard let view else { return }
            // Keep labels transparent to camera gestures, but give their
            // compact icons a 44-point click target for task inspection.
            if let id = labels.filter({ !$0.value.isHidden && $0.value.frame.insetBy(dx: -8, dy: -8).contains(point) })
                .min(by: { lhs, rhs in
                    hypot(lhs.value.frame.midX - point.x, lhs.value.frame.midY - point.y)
                        < hypot(rhs.value.frame.midX - point.x, rhs.value.frame.midY - point.y)
                })?.key {
                onSelectAgent(id)
                return
            }
            let entity = view.entity(at: point)
            var cursor = entity
            while let current = cursor {
                if current.name == "office-kanban-board" { onSelectBoard(); return }
                if let id = avatarRoots.first(where: { $0.value === current })?.key {
                    onSelectAgent(id)
                    return
                }
                cursor = current.parent
            }
        }
        private func makeAvatar(agent: OfficePreviewAgentPresentation) -> Entity {
            let avatar = Entity()
            avatar.name = "office-agent-\(agent.id)"
            let root = Entity()
            root.name = "character-visual"
            avatar.addChild(root)
            characterVisuals[agent.id] = root
            let accents = [nsColor(0.98, 0.62, 0.72), nsColor(0.58, 0.72, 0.98), nsColor(0.62, 0.86, 0.74),
                           nsColor(0.99, 0.78, 0.52), nsColor(0.78, 0.66, 0.96), nsColor(0.52, 0.84, 0.90)]
            let accent = agent.mainSession != nil ? nsColor(0.98, 0.80, 0.38) : accents[Int(agent.identitySeed % UInt64(accents.count))]
            let shell = nsColor(0.97, 0.96, 0.98)
            let joint = nsColor(0.80, 0.80, 0.87)
            let visor = nsColor(0.10, 0.12, 0.22)

            // A soft contact shadow grounds the bot without real-time shadows.
            let shadow = ModelEntity(mesh: toonSphere, materials: [contactShadow])
            shadow.name = "contact-shadow"
            shadow.scale = [0.78, 0.01, 0.66]
            shadow.position = [0, 0.025, 0]
            avatar.addChild(shadow)
            let ring = ModelEntity(mesh: toonSphere, materials: [selectionGlow])
            ring.name = "selection-ring"
            ring.scale = [1.25, 0.012, 1.25]
            ring.position = [0, 0.02, 0]
            ring.isEnabled = agent.id == selectedAgentID
            avatar.addChild(ring)

            // Hip, waist, shoulder and neck pivots sit at the joints, so every
            // limb swings from where it attaches instead of spinning mid-shell.
            var legs: [Entity] = []
            for side: Float in [-1, 1] {
                let hip = Entity()
                hip.name = side < 0 ? "left-leg" : "right-leg"
                hip.position = [side * 0.12, Self.hipHeight, 0]
                root.addChild(hip)
                addToonPart(to: hip, name: "robot-leg", size: [0.15, 0.28, 0.16], position: [0, -0.14, 0], color: joint, radius: 0.07)
                addToonPart(to: hip, name: "robot-foot", size: [0.19, 0.11, 0.26], position: [0, -0.24, 0.04], color: shell, radius: 0.05)
                addToonPart(to: hip, name: "robot-sole", size: [0.195, 0.03, 0.265], position: [0, -0.285, 0.04], color: accent, radius: 0.014)
                legs.append(hip)
            }
            let upper = Entity()
            upper.name = "upper-body"
            upper.position = [0, Self.hipHeight, 0]
            root.addChild(upper)
            upperBodies[agent.id] = upper
            addToonPart(to: upper, name: "robot-body", size: [0.52, 0.46, 0.40], position: [0, 0.22, 0], color: shell, radius: 0.17)
            addToonPart(to: upper, name: "robot-belt", size: [0.50, 0.06, 0.39], position: [0, 0.06, 0], color: joint, radius: 0.03)
            addToonOval(to: upper, name: "robot-chest-light", size: [0.10, 0.10, 0.03], position: [0.12, 0.30, 0.20], color: accent)
            if agent.mainSession != nil {
                addToonOval(to: upper, name: "nexus-compass-badge", size: [0.13, 0.13, 0.025], position: [-0.08, 0.28, 0.20], color: accent)
                let needle = addToonPart(to: upper, name: "nexus-compass-needle", size: [0.025, 0.09, 0.012], position: [-0.08, 0.28, 0.217], color: visor, radius: 0.008)
                needle.orientation = simd_quatf(angle: -.pi / 5, axis: [0, 0, 1])
            }
            addToonPart(to: upper, name: "robot-neck", size: [0.18, 0.08, 0.16], position: [0, 0.48, 0], color: joint, radius: 0.04)

            let head = Entity()
            head.name = "robot-head"
            head.position = [0, 0.78, 0]
            upper.addChild(head)
            addToonPart(to: head, name: "robot-head-shell", size: [0.74, 0.58, 0.60], position: .zero, color: shell, radius: 0.24)
            addToonPart(to: head, name: "robot-visor", size: [0.58, 0.34, 0.04], position: [0, -0.01, 0.29], color: visor, radius: 0.12)
            var eyes: [ModelEntity] = []
            for x: Float in [-0.13, 0.13] {
                let eye = ModelEntity(mesh: boxMesh(size: [0.13, 0.11, 0.02], radius: 0.05), materials: [unlitMaterial(nsColor(0.45, 0.93, 1.0))])
                eye.name = "robot-eye"
                eye.position = [x, 0.01, 0.315]
                head.addChild(eye)
                eyes.append(eye)
            }
            addToonPart(to: head, name: "headphone-band", size: [0.80, 0.07, 0.12], position: [0, 0.29, 0], color: accent, radius: 0.035)
            for side: Float in [-1, 1] {
                addToonPart(to: head, name: "headphone-cup", size: [0.09, 0.26, 0.24], position: [side * 0.39, 0.02, 0], color: accent, radius: 0.045)
                addToonPart(to: head, name: "headphone-strap", size: [0.05, 0.24, 0.07], position: [side * 0.39, 0.19, 0], color: accent, radius: 0.02)
            }
            robotFaces[agent.id] = (head, eyes)

            var arms: [Entity] = []
            for side: Float in [-1, 1] {
                let shoulder = Entity()
                shoulder.name = side < 0 ? "left-arm" : "right-arm"
                shoulder.position = [side * 0.33, 0.40, 0]
                upper.addChild(shoulder)
                addToonPart(to: shoulder, name: "robot-arm", size: [0.12, 0.30, 0.13], position: [0, -0.15, 0], color: shell, radius: 0.06)
                addToonPart(to: shoulder, name: "robot-shoulder", size: [0.13, 0.07, 0.14], position: [0, -0.03, 0], color: accent, radius: 0.03)
                addToonOval(to: shoulder, name: "robot-hand", size: [0.13, 0.13, 0.13], position: [0, -0.34, 0.01], color: joint)
                arms.append(shoulder)
            }
            limbEntities[agent.id] = (legs[0], legs[1], arms[0], arms[1])
            let cup = addToonPart(to: arms[1], name: "leisure-cup", size: [0.14, 0.16, 0.14], position: [0, -0.40, 0.03], color: nsColor(0.99, 0.95, 0.90), radius: 0.03)
            cup.isEnabled = false
            let book = addToonPart(to: arms[0], name: "leisure-book", size: [0.30, 0.04, 0.23], position: [0.08, -0.39, 0.04], color: accent, radius: 0.01)
            book.isEnabled = false
            handProps[agent.id] = (cup, book)

            // Speech bubble shown only while this bot has the floor in a chat.
            let bubble = Entity()
            bubble.name = "chat-bubble"
            bubble.position = [0.46, 1.66, 0.05]
            bubble.isEnabled = false
            avatar.addChild(bubble)
            let bubbleColor = nsColor(0.99, 0.99, 1.0)
            addToonPart(to: bubble, name: "chat-bubble-body", size: [0.46, 0.28, 0.14], position: .zero, color: bubbleColor, radius: 0.1)
            let tail = addToonPart(to: bubble, name: "chat-bubble-tail", size: [0.1, 0.1, 0.1], position: [-0.14, -0.15, 0], color: bubbleColor, radius: 0.02)
            tail.orientation = simd_quatf(angle: .pi / 4, axis: [0, 0, 1])
            for face: Float in [-1, 1] {
                for index in 0..<3 {
                    let dot = Entity()
                    dot.name = "chat-dot"
                    bubble.addChild(dot)
                    addToonOval(to: dot, name: "chat-dot-shape", size: [0.065, 0.065, 0.02], position: [Float(index - 1) * 0.11, 0, face * 0.072], color: accent)
                }
            }
            chatBubbles[agent.id] = bubble
            // One selection volume per bot. Limb-by-limb collision hulls make
            // every typing frame update dozens of unnecessary physics shapes.
            avatar.components.set(CollisionComponent(shapes: [
                ShapeResource.generateBox(size: [0.84, 1.45, 0.76]).offsetBy(translation: [0, 0.72, 0])
            ]))
            return avatar
        }

        private lazy var contactShadow: UnlitMaterial = {
            var material = UnlitMaterial(color: NSColor(srgbRed: 0.02, green: 0.02, blue: 0.06, alpha: 1))
            material.blending = .transparent(opacity: .init(floatLiteral: 0.45))
            return material
        }()

        private lazy var selectionGlow: UnlitMaterial = {
            var material = UnlitMaterial(color: OfficeAgentStatus.working.nsColor)
            material.blending = .transparent(opacity: .init(floatLiteral: 0.35))
            return material
        }()

        private func unlitMaterial(_ color: NSColor) -> UnlitMaterial {
            if let material = unlitMaterials[color] { return material }
            let material = UnlitMaterial(color: color)
            unlitMaterials[color] = material
            return material
        }

        @discardableResult
        private func addToonPart(to parent: Entity, name: String, size: SIMD3<Float>, position: SIMD3<Float>, color: NSColor, radius: Float) -> ModelEntity {
            let part = ModelEntity(mesh: boxMesh(size: size, radius: radius), materials: [matteMaterial(color)])
            part.name = name
            part.position = position
            parent.addChild(part)
            return part
        }

        private func addToonOval(to parent: Entity, name: String, size: SIMD3<Float>, position: SIMD3<Float>, color: NSColor) {
            let part = ModelEntity(mesh: toonSphere, materials: [matteMaterial(color)])
            part.name = name
            part.scale = size
            part.position = position
            parent.addChild(part)
        }

        /// Labels are ordinary AppKit views: fixed point size, never depth-occluded.
        /// Reproject only on movement, direct camera input, reset, and resize.
        func layoutLabels() {
            labelsNeedLayout = true
        }

        private func flushLabelLayout() {
            guard labelsNeedLayout else { return }
            guard let view, view.bounds.width > 32, view.bounds.height > 80 else { return }
            labelsNeedLayout = false
            positionMusicControl()
            guard showsAgents else { labels.values.forEach { $0.setVisible(false) }; return }
            var occupied: [CGRect] = []
            // Close views show full task bubbles; wider views show name pills.
            // Crowded bubbles step down to smaller tiers instead of overlapping.
            let preferred: OfficePreviewTaskBubble.Tier = cameraState.distance <= 24 ? .full : .compact
            for id in labelOrder {
                let lift = (characterVisuals[id]?.position.y ?? 0) + 1.5
                guard let label = labels[id], let root = avatarRoots[id],
                      let point = view.project(root.position + [0, lift, 0]),
                      point.x.isFinite, point.y.isFinite, view.bounds.contains(point) else {
                    labels[id]?.setVisible(false)
                    continue
                }
                var placed: CGRect?
                for tier in [OfficePreviewTaskBubble.Tier.full, .compact, .dot] where tier <= preferred {
                    let size = label.size(for: tier)
                    let y = view.isFlipped ? point.y - size.height - 2 : point.y + 2
                    var frame = CGRect(x: point.x - size.width / 2, y: y, width: size.width, height: size.height).integral
                    frame.origin.x = min(view.bounds.maxX - size.width - 8, max(8, frame.origin.x))
                    frame.origin.y = min(view.bounds.maxY - size.height - 8, max(8, frame.origin.y))
                    if !occupied.contains(where: { $0.intersects(frame) }) {
                        label.setTier(tier)
                        placed = frame
                        break
                    }
                }
                guard let frame = placed else { label.setVisible(false); continue }
                if label.frame != frame { label.frame = frame }
                label.setVisible(true)
                occupied.append(frame)
            }
        }

        private func walkingTransform(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Transform {
            let direction = end - start
            let yaw = atan2(direction.x, direction.z)
            return Transform(rotation: simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)), translation: end)
        }

        private func rebuildRoom() {
            roomGeometry?.removeFromParent()
            let geometry: Entity
            if let cached = Self.cachedRoom, cached.palette == palette, cached.capacity == roomLayout.capacity {
                geometry = cached.geometry
                roomLayout.authored = cached.navigation
                Self.cachedRoom = nil
            } else {
                Self.cachedRoom = nil
                geometry = Entity()
                buildRoom(in: geometry)
                OfficeStaticMeshBatcher.flatten(geometry)
            }
            roomGeometry = geometry
            anchor?.addChild(geometry)
            screens = Dictionary(uniqueKeysWithValues: (0..<(roomLayout.authored?.stations[.desk]?.count ?? 8)).compactMap { slot in
                (geometry.findEntity(named: "work-screen-\(slot)") as? ModelEntity).map { (slot, $0) }
            })
            poweredScreens = []
            updateComputers()
            renderBoardCounts()
            musicParts = geometry.findEntity(named: "music-player").flatMap { player in
                guard let marker = player.findEntity(named: "interaction-indicator"),
                      let platter = player.findEntity(named: "music-platter") else { return nil }
                func all(_ name: String) -> [Entity] {
                    var found: [Entity] = []
                    func visit(_ entity: Entity) { if entity.name == name { found.append(entity) }; entity.children.forEach(visit) }
                    visit(player)
                    return found
                }
                return (player, marker, platter, all("music-speaker"), all("speaker-woofer"), all("speaker-tweeter"), all("music-note"), all("bass-wave").compactMap { $0 as? ModelEntity }, player.findEntity(named: "indicator-ping") as? ModelEntity)
            }
        }

        /// The lounge jukebox: a bobbing marker always, and pumping speakers,
        /// a spinning record and rising notes while Spotify is playing.
        private func animateMusic(delta: TimeInterval) {
            guard let parts = musicParts, view?.window?.isVisible == true else { return }
            let playing = music?.state.isPlaying == true
            let dt = Float(min(delta, 0.1))
            parts.marker.scale = .init(repeating: musicHovered ? 1.35 : 1)
            guard !lastReduceMotion else {
                parts.notes.forEach { $0.isEnabled = false }
                parts.waves.forEach { $0.isEnabled = false }
                return
            }
            musicTime += dt
            let t = musicTime
            musicLevel += ((playing ? 1 : 0) - musicLevel) * (1 - exp(-dt * 4))
            let level = musicLevel
            parts.marker.position.y = 1.55 + sin(t * 2.4) * 0.06
            parts.marker.orientation = simd_quatf(angle: t * 1.2, axis: [0, 1, 0])
            // ponytail: a fixed 120 BPM pulse; Spotify's audio-analysis API is deprecated, so no real beat data.
            let beat = pow(max(0, sin(t * .pi * 4)), 6)
            for woofer in parts.woofers { woofer.scale = [1 + 0.1 * beat * level, 1 + 0.1 * beat * level, 1 + 1.2 * beat * level] }
            for tweeter in parts.tweeters { tweeter.scale = .init(repeating: 1 + 0.18 * abs(sin(t * 17)) * level) }
            for speaker in parts.speakers { speaker.scale = [1 - 0.015 * beat * level, 1 + 0.03 * beat * level, 1 - 0.015 * beat * level] }
            parts.platter.orientation *= simd_quatf(angle: -3.5 * dt * level, axis: [0, 1, 0])
            // Two rings per woofer, one leaving on each beat, growing and fading as they travel out.
            for (index, wave) in parts.waves.enumerated() {
                wave.isEnabled = level > 0.05
                guard wave.isEnabled else { continue }
                let p = (t + 0.875 + Float(index % 2) * 0.5).truncatingRemainder(dividingBy: 1)
                wave.position.z = 0.2 + p * 0.5
                wave.scale = .init(repeating: 0.25 + p * 0.9)
                wave.model?.materials = [fade(pow(1 - p, 1.5) * 0.9 * level)]
            }
            if let ping = parts.ping {
                let p = (t / 1.8).truncatingRemainder(dividingBy: 1)
                ping.scale = .init(repeating: 0.9 + p * 1.8)
                ping.model?.materials = [fade((1 - p) * (musicHovered ? 1 : 0.75), OfficeScenePalette.interactionBeacon)]
            }
            for (index, note) in parts.notes.enumerated() {
                note.isEnabled = level > 0.05
                guard note.isEnabled else { continue }
                let phase = (t * 0.45 + Float(index) / Float(parts.notes.count)).truncatingRemainder(dividingBy: 1)
                note.position = [(Float(index) - 1) * 0.6 + sin(phase * 6 + Float(index)) * 0.12, 1.0 + phase * 0.9, 0.1]
                note.orientation = simd_quatf(angle: sin(phase * 5) * 0.4, axis: [0, 0, 1])
                note.scale = .init(repeating: level * sin(phase * .pi))
            }
        }

        /// Opacity is stepped and cached so pulsing rings reuse materials
        /// instead of allocating new ones every frame.
        private func fade(_ opacity: Float, _ color: NSColor? = nil) -> UnlitMaterial {
            let color = color ?? palette.neon
            let step = Int((max(0, min(1, opacity)) * 32).rounded())
            let key = FadeKey(color: color, step: step)
            if let cached = fadeMaterials[key] { return cached }
            var material = UnlitMaterial(color: color)
            material.blending = .transparent(opacity: .init(floatLiteral: Float(step) / 32))
            fadeMaterials[key] = material
            return material
        }

        private struct FadeKey: Hashable { let color: NSColor; let step: Int }
        private var fadeMaterials: [FadeKey: UnlitMaterial] = [:]

        func handleHover(at point: NSPoint?) {
            guard let view, let parts = musicParts, music != nil else { return }
            var hovering = false
            if let point {
                if let control = musicControl, !control.isHidden, control.frame.insetBy(dx: -16, dy: -16).contains(point) {
                    hovering = true
                } else {
                    var cursor = view.entity(at: point)
                    while let current = cursor, !hovering { hovering = current === parts.player; cursor = current.parent }
                }
            }
            if hovering {
                musicHideTask?.cancel()
                musicHideTask = nil
                if !musicHovered { showMusicControl() }
            } else if musicHovered, musicHideTask == nil {
                // A short grace lets the pointer cross from the model to the card.
                musicHideTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard let self, !Task.isCancelled else { return }
                    self.musicHideTask = nil
                    self.musicHovered = false
                    self.musicControl?.isHidden = true
                    NSCursor.arrow.set()
                }
            }
        }

        private func showMusicControl() {
            guard let view, let music else { return }
            musicHovered = true
            NSCursor.pointingHand.set()
            if musicControl == nil {
                let control = NSHostingView(rootView: OfficeMusicControl(music: music))
                view.addSubview(control)
                musicControl = control
            }
            musicControl.map { view.addSubview($0) }  // above the bot labels
            musicControl?.isHidden = false
            music.refresh()
            positionMusicControl()
        }

        private func positionMusicControl() {
            guard let view, let control = musicControl, !control.isHidden, let marker = musicParts?.marker,
                  let point = view.project(marker.position(relativeTo: nil) + [0, 0.3, 0]) else { return }
            let size = control.fittingSize
            let y = view.isFlipped ? point.y - size.height - 4 : point.y + 4
            control.frame = CGRect(x: min(view.bounds.maxX - size.width - 8, max(8, point.x - size.width / 2)),
                                   y: min(view.bounds.maxY - size.height - 8, max(8, y)),
                                   width: size.width, height: size.height).integral
        }

        private func buildRoom(in root: Entity) {
            roomLayout.authored = OfficeDesignSceneBuilder(palette: palette).build(in: root, capacity: roomLayout.capacity)
        }

        private func addLaptop(to root: Entity, position: SIMD3<Float>, scale: Float) {
            let laptop = Entity()
            laptop.position = position
            laptop.scale = [scale, scale, scale]
            root.addChild(laptop)
            addBox(to: laptop, name: "laptop-base", size: [0.46, 0.025, 0.32], position: [0, 0.0125, 0], color: OfficePreviewPalette.paper)
            addBox(to: laptop, name: "laptop-keys", size: [0.38, 0.008, 0.15], position: [0, 0.03, -0.035], color: OfficePreviewPalette.frame)
            addBox(to: laptop, name: "laptop-trackpad", size: [0.13, 0.006, 0.07], position: [0, 0.03, 0.10], color: OfficePreviewPalette.sideWall)
            let screen = Entity()
            screen.position = [0, 0.19, -0.15]
            screen.orientation = simd_quatf(angle: -0.15, axis: [1, 0, 0])
            laptop.addChild(screen)
            addBox(to: screen, name: "laptop-lid", size: [0.46, 0.30, 0.025], position: .zero, color: OfficePreviewPalette.frame)
            addBox(to: screen, name: "laptop-display", size: [0.40, 0.24, 0.008], position: [0, 0, 0.018], color: OfficePreviewPalette.teal)
        }

        func updateBoard(_ lanes: [OfficePreviewBoardLane]) {
            guard lanes != boardSummary else { return }
            boardSummary = lanes
            renderBoardCounts()
        }

        private func renderBoardCounts() {
            guard let geometry = roomGeometry else { return }
            for board in geometry.children where board.name == "office-kanban-board" {
                board.findEntity(named: "board-counts")?.removeFromParent()
                let counts = Entity()
                counts.name = "board-counts"
                board.addChild(counts)
                for (index, lane) in boardSummary.enumerated() {
                    let text = "\(lane.lane.rawValue.uppercased())  \(lane.tasks.count)"
                    let mesh = MeshResource.generateText(text, extrusionDepth: 0.001, font: .systemFont(ofSize: 0.10, weight: .semibold))
                    let label = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: OfficePreviewPalette.paper)])
                    label.position = [-0.85, 0.39 - Float(index) * 0.105, 0.075]
                    counts.addChild(label)
                }
            }
        }

        private func addRoomSign(to root: Entity, title: String, position: SIMD3<Float>) {
            let sign = ModelEntity(
                mesh: .generateText(title, extrusionDepth: 0.001, font: .systemFont(ofSize: 0.18, weight: .semibold)),
                materials: [UnlitMaterial(color: OfficePreviewPalette.paper)]
            )
            sign.name = "room-sign-\(title)"
            sign.position = position
            sign.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            root.addChild(sign)
        }

        private func addFramedPartition(to root: Entity, width: Float) {
            let trim = OfficePreviewPalette.frame
            // Open upper frames suggest glazed office partitions without
            // reflective glass obscuring the room contents.
            addBox(to: root, name: "partition-base", size: [width, 0.55, 0.10], position: [0, 0.275, 0], color: OfficePreviewPalette.sideWall)
            for x in [-width / 2, Float(0), width / 2] {
                addBox(to: root, name: "partition-post", size: [0.06, 0.65, 0.06], position: [x, 0.325, 0], color: trim)
            }
            for y: Float in [0.58] {
                addBox(to: root, name: "partition-rail", size: [width, 0.06, 0.06], position: [0, y, 0], color: trim)
            }
        }

        private func addSofa(to root: Entity, position: SIMD3<Float>) {
            let fabric = OfficePreviewPalette.lavender
            addBox(to: root, name: "sofa-base", size: [2.4, 0.30, 0.85], position: position + [0, 0.28, 0], color: OfficePreviewPalette.frame)
            addBox(to: root, name: "sofa-back", size: [2.4, 0.65, 0.18], position: position + [0, 0.65, -0.36], color: fabric)
            for x: Float in [-0.55, 0.55] {
                addToonPart(to: root, name: "sofa-cushion", size: [1.02, 0.22, 0.65], position: position + [x, 0.51, 0.05], color: fabric, radius: 0.10)
                addToonPart(to: root, name: "sofa-back-cushion", size: [1.02, 0.46, 0.24], position: position + [x, 0.76, -0.23], color: fabric, radius: 0.11)
            }
            addToonPart(to: root, name: "sofa-pillow", size: [0.37, 0.33, 0.20], position: position + [-0.76, 0.76, -0.03], color: OfficePreviewPalette.paper, radius: 0.095)
            for x: Float in [-1.13, 1.13] {
                addBox(to: root, name: "sofa-arm", size: [0.18, 0.40, 0.85], position: position + [x, 0.52, 0], color: fabric)
            }
        }

        /// Wall-mounted details do not add obstacles to the authored aisles.

        private func addWindow(to root: Entity) {
            let trim = OfficePreviewPalette.frame
            // Stylized opaque panes suggest exterior greenery without assets.
            addBox(to: root, name: "window-frame", size: [1.66, 1.18, 0.08], position: .zero, color: trim)
            addBox(to: root, name: "window-pane", size: [1.48, 1.0, 0.025], position: [0, 0, 0.055], color: OfficePreviewPalette.sage)
            addBox(to: root, name: "mullion", size: [0.045, 1.04, 0.04], position: [0, 0, 0.08], color: trim)
            addBox(to: root, name: "crossbar", size: [1.5, 0.045, 0.04], position: [0, -0.10, 0.08], color: trim)
            addBox(to: root, name: "sill", size: [1.8, 0.075, 0.24], position: [0, -0.62, 0.05], color: nsColor(0.76, 0.76, 0.79))
            addBox(to: root, name: "blind-rail", size: [1.76, 0.085, 0.12], position: [0, 0.65, 0.06], color: trim)
            for row in 0..<6 {
                addBox(to: root, name: "blind-slat", size: [1.57, 0.058, 0.07], position: [0, 0.54 - Float(row) * 0.073, 0.12], color: nsColor(0.85, 0.84, 0.85))
            }
        }

        private func addCameraAndLight(to root: Entity) {
            let camera = PerspectiveCamera()
            self.camera = camera
            applyCameraTransform()
            root.addChild(camera)
            daylight = OfficeDaylight(date: clock())
            lastDaylightCheck = Date()
            lighting = OfficeSceneLighting(root: root, daylight: daylight)
            lighting?.updateShadow(cameraDistance: cameraState.distance)
            let sky = OfficeSky()
            sky.apply(daylight)
            root.addChild(sky.root)
            self.sky = sky
            if let view {
                OfficeSceneLighting.applyEnvironment(to: view, daylight: daylight)
                let post = postProcess
                view.renderCallbacks.postProcess = { post.process($0) }
            }
        }

        /// Test hook for the opt-in render snapshot.
        func setCamera(_ state: OfficePreviewCameraState) {
            resetTask?.cancel()
            cameraState = state
            applyCameraTransform()
        }

        private func applyCameraTransform() {
            guard let camera else { return }
            camera.position = cameraState.position
            camera.look(at: cameraState.orbitTarget, from: camera.position, relativeTo: nil)
            lighting?.updateShadow(cameraDistance: cameraState.distance)
            postProcess.update(cameraDistance: cameraState.distance, isDark: daylight.isDark)
            layoutLabels()
        }

        private func addDesk(to root: Entity, position: SIMD3<Float>, label: String) {
            addBox(to: root, name: label, size: [1.55, 0.12, 0.82], position: position + [0, 1.05, 0], color: OfficePreviewPalette.wood)
            for x in [-0.62, 0.62] { addBox(to: root, name: "\(label)-leg", size: [0.1, 1.0, 0.1], position: position + [Float(x), 0.5, 0], color: nsColor(0.28, 0.31, 0.34)) }
            addChair(to: root, position: position + [0, 0, 0.72], label: "\(label)-chair")
            addBox(to: root, name: "\(label)-pedestal", size: [0.40, 0.80, 0.60], position: position + [-0.48, 0.44, 0], color: OfficePreviewPalette.teal)
            for row in 0..<3 {
                let y = Float(row) * 0.23 + 0.22
                addBox(to: root, name: "\(label)-drawer", size: [0.36, 0.205, 0.025], position: position + [-0.48, y, 0.31], color: OfficePreviewPalette.wall)
                addBox(to: root, name: "\(label)-handle", size: [0.12, 0.025, 0.035], position: position + [-0.48, y + 0.06, 0.33], color: nsColor(0.25, 0.25, 0.28))
            }
        }

        private func addTable(to root: Entity, position: SIMD3<Float>, label: String) {
            addBox(to: root, name: label, size: [2.0, 0.14, 1.05], position: position + [0, 0.82, 0], color: OfficePreviewPalette.wood)
            addBox(to: root, name: "\(label)-base", size: [0.16, 0.78, 0.16], position: position + [0, 0.4, 0], color: nsColor(0.28, 0.31, 0.34))
            addChair(to: root, position: position + [0, 0, 0.98], label: "\(label)-chair-front")
            addChair(to: root, position: position + [0, 0, -0.98], label: "\(label)-chair-back")
        }

        private func addLoungeSeat(to root: Entity, position: SIMD3<Float>, label: String) {
            let seat = Entity()
            seat.name = label
            seat.position = position
            root.addChild(seat)
            let fabric = nsColor(0.68, 0.34, 0.23)
            addToonPart(to: seat, name: "lounge-cushion", size: [0.66, 0.22, 0.64], position: [0, 0.43, 0], color: fabric, radius: 0.07)
            addToonPart(to: seat, name: "lounge-back", size: [0.72, 0.62, 0.18], position: [0, 0.64, -0.30], color: fabric, radius: 0.06)
            for x: Float in [-0.36, 0.36] {
                addToonPart(to: seat, name: "lounge-arm", size: [0.13, 0.40, 0.72], position: [x, 0.48, 0], color: fabric, radius: 0.04)
                addBox(to: seat, name: "lounge-foot", size: [0.08, 0.20, 0.5], position: [x, 0.10, 0], color: OfficePreviewPalette.wood)
            }
        }

        private func addChair(to root: Entity, position: SIMD3<Float>, label: String) {
            let color = chairColor(for: label)
            let chair = Entity()
            chair.name = label
            chair.position = position
            root.addChild(chair)
            let frame = OfficePreviewPalette.frame
            addBox(to: chair, name: "seat", size: [0.56, 0.11, 0.54], position: [0, 0.51, 0], color: color)
            addBox(to: chair, name: "back-shell", size: [0.52, 0.48, 0.10], position: [0, 0.85, -0.24], color: frame)
            addBox(to: chair, name: "back-cushion", size: [0.46, 0.40, 0.07], position: [0, 0.85, -0.18], color: color)
            addBox(to: chair, name: "gas-lift", size: [0.075, 0.38, 0.075], position: [0, 0.27, 0], color: frame)
            // Open-sided task chairs permit a clear side approach and seating.
            for index in 0..<5 {
                let angle = Float(index) * 2 * .pi / 5
                let spoke = Entity()
                spoke.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
                chair.addChild(spoke)
                addBox(to: spoke, name: "spoke", size: [0.055, 0.045, 0.32], position: [0, 0.10, 0.16], color: frame)
                addBox(to: spoke, name: "caster", size: [0.10, 0.085, 0.075], position: [0, 0.045, 0.30], color: frame)
            }
        }

        private func chairColor(for label: String) -> NSColor {
            if label.contains("desk-b") || label.contains("back-workstation-b") { return OfficePreviewPalette.lavender }
            if label.contains("desk-a") || label.contains("back-workstation-a") { return OfficePreviewPalette.teal }
            return OfficePreviewPalette.lavender
        }




        private func addPlant(to root: Entity, position: SIMD3<Float>) {
            addBox(to: root, name: "plant-pot", size: [0.42, 0.38, 0.42], position: position + [0, 0.2, 0], color: OfficePreviewPalette.paper)
            addBox(to: root, name: "plant-trunk", size: [0.13, 0.55, 0.13], position: position + [0, 0.58, 0], color: nsColor(0.53, 0.34, 0.19))
            // Clustered rounded crowns give the reference's toy-tree silhouette,
            // contained within the existing decoration footprint.
            for index in 0..<4 {
                let angle = Float(index) * 2.1
                let crown = ModelEntity(
                    mesh: OfficeLowPolyMesh.box(size: [0.43, 0.47, 0.42], cornerRadius: 0.18),
                    materials: [SimpleMaterial(color: OfficePreviewPalette.sage, roughness: 1, isMetallic: false)]
                )
                crown.name = "plant-crown"
                crown.position = position + [cos(angle) * 0.15, 0.88 + Float(index % 2) * 0.22, sin(angle) * 0.13]
                root.addChild(crown)
            }
        }

        private func addWorkstationDetails(to root: Entity, deskPosition: SIMD3<Float>, label: String) {
            // A monitor and stand sit toward the back edge of each desk, leaving
            // the front edge clear for the seated avatar.
            addBox(to: root, name: "\(label)-monitor", size: [0.72, 0.42, 0.06], position: deskPosition + [0, 1.34, -0.17], color: nsColor(0.16, 0.24, 0.32))
            addBox(to: root, name: "\(label)-monitor-stand", size: [0.08, 0.25, 0.08], position: deskPosition + [0, 1.17, -0.17], color: nsColor(0.35, 0.42, 0.48))
            addBox(to: root, name: "\(label)-keyboard", size: [0.42, 0.025, 0.18], position: deskPosition + [0, 1.12, 0.16], color: nsColor(0.68, 0.73, 0.77))
            addBox(to: root, name: "\(label)-lamp-stem", size: [0.035, 0.28, 0.035], position: deskPosition + [0.58, 1.22, -0.05], color: nsColor(0.32, 0.39, 0.45))
            addBox(to: root, name: "\(label)-lamp-shade", size: [0.2, 0.08, 0.2], position: deskPosition + [0.58, 1.38, -0.05], color: OfficePreviewPalette.paper)
            addBox(to: root, name: "\(label)-paper-stack", size: [0.25, 0.04, 0.18], position: deskPosition + [-0.48, 1.13, 0.18], color: nsColor(0.93, 0.92, 0.85))
            addBox(to: root, name: "\(label)-file-binder", size: [0.16, 0.22, 0.2], position: deskPosition + [0.35, 1.24, -0.18], color: nsColor(0.15, 0.39, 0.60))
            addBox(to: root, name: "\(label)-screen-bezel", size: [0.66, 0.36, 0.015], position: deskPosition + [0, 1.34, -0.133], color: nsColor(0.59, 0.60, 0.62))
            addBox(to: root, name: "\(label)-screen", size: [0.61, 0.31, 0.012], position: deskPosition + [0, 1.34, -0.12], color: nsColor(0.12, 0.14, 0.17))
            for row in 0..<4 {
                for column in 0..<10 {
                    addBox(to: root, name: "\(label)-key", size: [0.031, 0.008, 0.025], position: deskPosition + [-0.177 + Float(column) * 0.039, 1.14, 0.10 + Float(row) * 0.039], color: nsColor(0.86, 0.85, 0.83))
                }
            }
            addBox(to: root, name: "\(label)-mousepad", size: [0.19, 0.01, 0.20], position: deskPosition + [0.36, 1.117, 0.16], color: nsColor(0.26, 0.26, 0.30))
            addBox(to: root, name: "\(label)-mouse", size: [0.065, 0.035, 0.095], position: deskPosition + [0.36, 1.14, 0.16], color: nsColor(0.67, 0.68, 0.70))
        }



        private func addReviewTableDetails(to root: Entity, position: SIMD3<Float>) {
            addBox(to: root, name: "review-table-screen", size: [0.65, 0.36, 0.05], position: position + [0, 1.02, -0.18], color: nsColor(0.16, 0.24, 0.32))
            addBox(to: root, name: "review-table-screen-stand", size: [0.07, 0.2, 0.07], position: position + [0, 0.94, -0.18], color: nsColor(0.35, 0.42, 0.48))
            addBox(to: root, name: "review-table-notebook", size: [0.38, 0.025, 0.28], position: position + [0.62, 0.91, 0.2], color: nsColor(0.92, 0.95, 0.94))
        }

        private func addStorageShelf(to root: Entity, position: SIMD3<Float>) {
            let shelf = OfficePreviewPalette.wood
            let metal = nsColor(0.38, 0.41, 0.43)
            addBox(to: root, name: "storage-shelf-top", size: [1.25, 0.1, 0.42], position: position + [0, 2.05, 0], color: shelf)
            addBox(to: root, name: "storage-shelf-middle", size: [1.25, 0.1, 0.42], position: position + [0, 1.42, 0], color: shelf)
            addBox(to: root, name: "storage-shelf-bottom", size: [1.25, 0.1, 0.42], position: position + [0, 0.78, 0], color: shelf)
            for x in [-0.54, 0.54] {
                addBox(to: root, name: "storage-shelf-post", size: [0.08, 2.1, 0.08], position: position + [Float(x), 1.05, 0], color: metal)
            }
            addBox(to: root, name: "storage-box-blue", size: [0.36, 0.28, 0.3], position: position + [-0.3, 1.61, 0], color: OfficePreviewPalette.teal)
            addBox(to: root, name: "storage-box-coral", size: [0.36, 0.28, 0.3], position: position + [0.28, 0.97, 0], color: OfficePreviewPalette.lavender)
            for index in 0..<5 {
                let x = -0.43 + Float(index) * 0.13
                addBox(to: root, name: "shelf-binder", size: [0.10, 0.32, 0.25], position: position + [x, 2.26, 0], color: index.isMultiple(of: 2) ? nsColor(0.26, 0.39, 0.35) : nsColor(0.31, 0.35, 0.49))
                addBox(to: root, name: "binder-spine-label", size: [0.06, 0.12, 0.012], position: position + [x, 2.26, 0.132], color: nsColor(0.88, 0.86, 0.79))
            }
            addBox(to: root, name: "archive-carton", size: [0.42, 0.30, 0.32], position: position + [0.24, 1.62, 0], color: OfficePreviewPalette.wood)
            addBox(to: root, name: "archive-label", size: [0.19, 0.09, 0.012], position: position + [0.24, 1.62, 0.166], color: nsColor(0.88, 0.85, 0.75))
        }

        private func addCoffeeStation(to root: Entity, position: SIMD3<Float>) {
            addBox(to: root, name: "coffee-counter", size: [1.15, 0.12, 0.52], position: position + [0, 0.72, 0], color: OfficePreviewPalette.wood)
            addBox(to: root, name: "coffee-machine", size: [0.4, 0.48, 0.34], position: position + [-0.18, 1.02, 0], color: nsColor(0.28, 0.36, 0.42))
            addBox(to: root, name: "coffee-machine-top", size: [0.25, 0.06, 0.22], position: position + [-0.18, 1.3, 0], color: nsColor(0.18, 0.25, 0.3))
            addBox(to: root, name: "coffee-cup", size: [0.14, 0.16, 0.14], position: position + [0.28, 0.86, 0], color: nsColor(0.95, 0.94, 0.87))
        }

        private func addWallClock(to root: Entity, position: SIMD3<Float>) {
            // A flattened sphere keeps the clock compatible with macOS 14,
            // where RealityKit's procedural cylinder mesh is unavailable.
            let clock = ModelEntity(mesh: OfficeLowPolyMesh.sphere(radius: 0.38), materials: [SimpleMaterial(color: nsColor(0.92, 0.95, 0.97), isMetallic: false)])
            clock.name = "wall-clock"
            clock.position = position
            clock.scale = [1, 1, 0.08]
            root.addChild(clock)
            addBox(to: root, name: "wall-clock-hand-hour", size: [0.035, 0.2, 0.025], position: position + [0, 0.04, 0], color: nsColor(0.16, 0.24, 0.32))
            addBox(to: root, name: "wall-clock-hand-minute", size: [0.025, 0.28, 0.025], position: position + [0.1, 0.04, 0], color: nsColor(0.16, 0.24, 0.32))
        }


        private func addBox(to root: Entity, name: String, size: SIMD3<Float>, position: SIMD3<Float>, color: NSColor) {
            // Soften furniture and character details without changing their bounds.
            // Architecture and thin floor tiles retain flush, gap-free joins.
            let isArchitectural = name.contains("wall") || name.contains("floor") || name.contains("tile") || name.contains("partition")
            let radius: Float = isArchitectural ? 0 : min(0.10, min(size.x, min(size.y, size.z)) * 0.35)
            let entity = ModelEntity(mesh: boxMesh(size: size, radius: radius), materials: [matteMaterial(color)])
            entity.name = name
            entity.position = position
            root.addChild(entity)
        }

        private func boxMesh(size: SIMD3<Float>, radius: Float) -> MeshResource {
            let key = "\(size)-\(radius)"
            if let mesh = boxMeshes[key] { return mesh }
            let mesh = OfficeLowPolyMesh.box(size: size, cornerRadius: radius)
            boxMeshes[key] = mesh
            return mesh
        }

        private func matteMaterial(_ color: NSColor) -> SimpleMaterial {
            if let material = matteMaterials[color] { return material }
            let material = SimpleMaterial(color: color, roughness: 1, isMetallic: false)
            matteMaterials[color] = material
            return material
        }

        private func statusColor(_ lane: OfficePreviewLane?) -> NSColor {
            switch lane {
            case .blocked, .unknown: return NSColor(Color.dockWarning)
            case .done: return NSColor(Color.dockSuccess)
            case .running, .review, .ready, .triage: return NSColor(Color.dockAccent)
            default: return NSColor(Color.dockMetadataText)
            }
        }

        private func nsColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor { NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha) }
    }
}
