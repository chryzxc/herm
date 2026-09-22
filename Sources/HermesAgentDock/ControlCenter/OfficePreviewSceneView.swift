import AppKit
import Combine
import RealityKit
import SwiftUI
import QuartzCore

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

@MainActor
private final class OfficePreviewScreenLabel: NSView {
    var onSelect: (() -> Void)?
    private let statusIcon = NSImageView()
    private var animationKey = ""
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(Color.dockCanvas).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        statusIcon.imageScaling = .scaleProportionallyDown
        statusIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        addSubview(statusIcon)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Open agent task details")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityPerformPress() -> Bool {
        guard let onSelect else { return false }
        onSelect()
        return true
    }
    override func layout() {
        super.layout()
        statusIcon.frame = bounds.insetBy(dx: 6, dy: 6)
    }

    func update(agent: OfficePreviewAgentPresentation, reduceMotion: Bool, isDataCurrent: Bool) {
        let isDataCurrent = agent.mainSession.map { $0.lane != .unknown } ?? isDataCurrent
        let color: NSColor
        switch agent.activityLane {
        case .running, .review, .triage, .ready: color = NSColor(Color.dockAccent)
        case .blocked, .unknown: color = NSColor(Color.dockWarning)
        case .done: color = NSColor(Color.dockSuccess)
        default: color = NSColor(Color.dockSecondaryText)
        }
        let tint = !isDataCurrent ? NSColor(Color.dockSecondaryText) : agent.hasNoPendingTasks ? NSColor(Color.dockSuccess) : color
        statusIcon.image = NSImage(systemSymbolName: isDataCurrent ? agent.activitySymbol : "questionmark", accessibilityDescription: agent.monitorStatus)
        statusIcon.contentTintColor = tint
        layer?.borderColor = tint.withAlphaComponent(0.65).cgColor
        layer?.borderWidth = agent.mainSession?.isCurrent == true ? 2.5 : 1
        toolTip = "\(agent.name) · \(isDataCurrent ? agent.availabilityLabel : "Kanban status not current")\n\(agent.monitorStatus) · \(agent.monitorTitle)"
        setAccessibilityLabel(toolTip)
        let pulse = isDataCurrent && !reduceMotion && (agent.activityLane == .running || agent.activityLane == .blocked)
        let key = pulse ? agent.monitorStatus : "static"
        if key != animationKey {
            animationKey = key
            layer?.removeAllAnimations()
            if pulse {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1
                animation.toValue = 0.65
                animation.duration = agent.activityLane == .blocked ? 0.85 : 1.4
                animation.autoreverses = true
                animation.repeatCount = .infinity
                layer?.add(animation, forKey: "activity-pulse")
            }
        }
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

    func makeCoordinator() -> Coordinator { Coordinator(onSelectAgent: onSelectAgent) }

    func makeNSView(context: Context) -> OfficePreviewARView {
        let view = OfficePreviewARView(frame: .zero)
        view.environment.background = .color(NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 1))
        view.onCameraDrag = { [weak coordinator = context.coordinator] gesture, x, y in
            coordinator?.applyCameraGesture(gesture, x: x, y: y)
        }
        view.onCameraZoom = { [weak coordinator = context.coordinator] delta in coordinator?.applyCameraZoom(delta: delta) }
        view.onSceneClick = { [weak coordinator = context.coordinator] point in coordinator?.handleClick(at: point) }
        view.onCameraReset = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            coordinator.resetCamera(reduceMotion: coordinator.lastReduceMotion, wholeOffice: coordinator.wholeOfficePreset)
        }
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.layoutLabels() }
        let magnify = NSMagnificationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMagnification(_:)))
        view.addGestureRecognizer(magnify)
        context.coordinator.showsAgents = showsAgents
        context.coordinator.isDataCurrent = isDataCurrent
        context.coordinator.install(in: view, agents: agents)
        return view
    }

    func updateNSView(_ view: OfficePreviewARView, context: Context) {
        context.coordinator.onSelectAgent = onSelectAgent
        context.coordinator.showsAgents = showsAgents
        context.coordinator.isDataCurrent = isDataCurrent
        context.coordinator.onSelectBoard = onSelectBoard
        context.coordinator.updateBoard(boardLanes)
        context.coordinator.wholeOfficePreset = wholeOffice
        if context.coordinator.lastResetToken != resetToken {
            context.coordinator.lastResetToken = resetToken
            context.coordinator.resetCamera(reduceMotion: reduceMotion, wholeOffice: wholeOffice, focusAgentID: focusAgentID)
        }
        context.coordinator.update(agents: agents, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: OfficePreviewARView, coordinator: Coordinator) {
        coordinator.stop()
        view.onLayout = nil
        view.onCameraDrag = nil
        view.onCameraZoom = nil
        view.onSceneClick = nil
        view.onCameraReset = nil
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
        private var lastActionFrame: TimeInterval = 0
        private var lastPresentations: [OfficePreviewAgentPresentation] = []
        private var boxMeshes: [String: MeshResource] = [:]
        private var matteMaterials: [NSColor: SimpleMaterial] = [:]
        private lazy var toonSphere = MeshResource.generateSphere(radius: 0.5)
        private var actionSubscription: (any Cancellable)?
        private weak var view: OfficePreviewARView?
        private var avatarRoots: [String: Entity] = [:]
        private var movementTasks: [String: Task<Void, Never>] = [:]
        private var reservedSteps: [String: SIMD3<Float>] = [:]
        private var characterVisuals: [String: Entity] = [:]
        private var walkedDistances: [String: Float] = [:]
        fileprivate var lastReduceMotion = false
        private var zoomTarget: Float?
        private var labels: [String: OfficePreviewScreenLabel] = [:]
        private var labelsNeedLayout = false
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

        init(onSelectAgent: @escaping (String) -> Void) { self.onSelectAgent = onSelectAgent }

        func install(in view: OfficePreviewARView, agents: [OfficePreviewAgentPresentation]) {
            guard anchor == nil else { update(agents: agents, reduceMotion: true); return }
            self.view = view
            let room = AnchorEntity(world: .zero)
            anchor = room
            roomLayout.reconcile(ids: agents.map(\.id), mainAgentID: mainOfficeOwner(in: agents), reserveMainOffice: true)
            rebuildRoom()
            addCameraAndLight(to: room)
            view.scene.anchors.append(room)
            update(agents: agents, reduceMotion: true)
            actionSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.advanceCamera(delta: event.deltaTime)
                    self?.animateStationary(delta: event.deltaTime)
                    self?.flushLabelLayout()
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
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
            }
        }

        private func mainOfficeOwner(in agents: [OfficePreviewAgentPresentation]) -> String? {
            let main = agents.filter { $0.mainSession != nil }
            return main.first(where: { $0.mainSession?.isCurrent == true })?.id ?? main.map(\.id).sorted().first
        }

        func update(agents: [OfficePreviewAgentPresentation], reduceMotion: Bool) {
            guard let anchor else { return }
            let visibleAgents = showsAgents ? agents : []
            guard visibleAgents != lastPresentations || reduceMotion != lastReduceMotion || isDataCurrent != lastDataCurrent else { return }
            lastDataCurrent = isDataCurrent
            lastPresentations = visibleAgents
            let oldCapacity = roomLayout.capacity
            roomLayout.reconcile(ids: visibleAgents.map(\.id), mainAgentID: mainOfficeOwner(in: visibleAgents), reserveMainOffice: true)
            if oldCapacity != roomLayout.capacity {
                rebuildRoom()
                if wholeOfficePreset && !manuallyMovedCamera { resetCamera(reduceMotion: true, wholeOffice: true) }
            }
            desiredAgents = Dictionary(uniqueKeysWithValues: visibleAgents.map { ($0.id, $0) })
            interactionPlan = isDataCurrent ? .make(agents: visibleAgents) : OfficePreviewInteractionPlan()
            for id in Array(avatarRoots.keys) where desiredAgents[id] == nil {
                movementTasks.removeValue(forKey: id)?.cancel()
                avatarRoots.removeValue(forKey: id)?.removeFromParent()
                labels.removeValue(forKey: id)?.removeFromSuperview()
                characterVisuals.removeValue(forKey: id)
                limbEntities.removeValue(forKey: id)
                currentNodes.removeValue(forKey: id)
                walkedDistances.removeValue(forKey: id)
                reservedSteps.removeValue(forKey: id)
                leisureTargets.removeValue(forKey: id)
                nextLeisureChange.removeValue(forKey: id)
            }
            lastReduceMotion = reduceMotion
            for (index, agent) in visibleAgents.enumerated() {
                guard let slot = roomLayout.slots[agent.id] else { continue }
                if !agent.canWander || reduceMotion { leisureTargets[agent.id] = nil; nextLeisureChange[agent.id] = nil }
                let destination = destination(for: agent, slot: slot)
                let isNew = avatarRoots[agent.id] == nil
                let root = avatarRoots[agent.id] ?? makeAvatar(agent: agent)
                if isNew {
                    avatarRoots[agent.id] = root
                    anchor.addChild(root)
                }
                if isNew || reduceMotion {
                    movementTasks.removeValue(forKey: agent.id)?.cancel()
                    root.stopAllAnimations()
                    currentNodes[agent.id] = destination
                    root.position = roomLayout.position(destination)
                    applyStationaryPose(agent: agent, root: root, time: 0)
                } else if currentNodes[agent.id] != destination && movementTasks[agent.id] == nil {
                    movementTasks[agent.id] = move(root, id: agent.id, delay: Double(index % 6) * 0.12)
                } else if movementTasks[agent.id] == nil {
                    applyStationaryPose(agent: agent, root: root, time: reduceMotion ? 0 : animationTime)
                }
                let label = labels[agent.id] ?? OfficePreviewScreenLabel(frame: .zero)
                label.onSelect = { [weak self] in self?.onSelectAgent(agent.id) }
                if labels[agent.id] == nil { labels[agent.id] = label; view?.addSubview(label) }
                label.update(agent: agent, reduceMotion: reduceMotion, isDataCurrent: isDataCurrent)
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
            return roomLayout.node(slot: slot, location: agent.location)
        }

        private func dataCurrent(for agent: OfficePreviewAgentPresentation) -> Bool {
            agent.mainSession.map { $0.lane != .unknown } ?? isDataCurrent
        }

        private func updateLeisure() {
            guard let authored = roomLayout.authored else { return }
            for agent in desiredAgents.values.sorted(by: { $0.id < $1.id }) where agent.canWander && movementTasks[agent.id] == nil {
                guard let slot = roomLayout.slots[agent.id], let current = currentNodes[agent.id] else { continue }
                if nextLeisureChange[agent.id] == nil { nextLeisureChange[agent.id] = animationTime + 2 + Double(agent.identitySeed % 5) }
                guard animationTime >= nextLeisureChange[agent.id, default: .infinity] else { continue }
                // Reserve destinations and still-occupied seats until their occupant
                // has left. Leisure never changes Hermes tasks or their ordering.
                let reserved = Set(leisureTargets.filter { $0.key != agent.id }.values.compactMap(\.leisureIndex)
                    + currentNodes.filter { $0.key != agent.id }.values.compactMap(\.leisureIndex))
                var target = roomLayout.node(slot: slot, location: .desk)
                do {
                    let count = authored.leisureSpots.count
                    if count > 0 {
                        let start = Int(agent.identitySeed % UInt64(count)) + Int(animationTime / 20)
                        for offset in 0..<count {
                            let index = (start + offset) % count
                            guard index != current.leisureIndex, !reserved.contains(index) else { continue }
                            let candidate = OfficePreviewLayout.Node(slot: slot, index: 0, isStation: true, leisureIndex: index)
                            if !roomLayout.route(from: current, to: candidate).isEmpty { target = candidate; break }
                        }
                    }
                }
                leisureTargets[agent.id] = target
                nextLeisureChange[agent.id] = animationTime + 8 + Double(agent.identitySeed % 7)
                if current != target, let root = avatarRoots[agent.id] { movementTasks[agent.id] = move(root, id: agent.id, delay: 0) }
            }
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
                let color = active.contains(slot) ? NSColor(srgbRed: 0.24, green: 0.62, blue: 0.78, alpha: 1) : NSColor(srgbRed: 0.13, green: 0.17, blue: 0.23, alpha: 1)
                screen.model?.materials = [UnlitMaterial(color: color)]
                if slot == 22, let extended = roomGeometry?.findEntity(named: "main-office-extended-screen") as? ModelEntity {
                    extended.model?.materials = [UnlitMaterial(color: color)]
                }
            }
        }

        func stop() {
            movementTasks.values.forEach { $0.cancel() }
            movementTasks.removeAll()
            actionSubscription?.cancel()
            actionSubscription = nil
            resetTask?.cancel()
            labels.values.forEach { $0.removeFromSuperview() }
            labels.removeAll()
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
                defer { self.reservedSteps[id] = nil }
                var remainingRoute: [OfficePreviewLayout.Node] = []
                var plannedDestination: OfficePreviewLayout.Node?
                // Stations are private; corridors are shared. Reserve the next
                // short segment and yield if another character occupies it.
                while let agent = self.desiredAgents[id], let node = self.currentNodes[id],
                      let slot = self.roomLayout.slots[id] {
                    guard !Task.isCancelled else { return }
                    if (!self.dataCurrent(for: agent) && !agent.canWander) || self.view?.window?.isVisible != true {
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        continue
                    }
                    let destination = self.destination(for: agent, slot: slot)
                    if node == destination {
                        self.applyStationaryPose(agent: agent, root: root, time: 0)
                        self.movementTasks[id] = nil
                        if agent.canWander { self.nextLeisureChange[id] = self.animationTime + 8 + Double(agent.identitySeed % 7) }
                        self.updateComputers()
                        self.layoutLabels()
                        return
                    }
                    let occupied = self.avatarRoots.filter { $0.key != id }.map { $0.value.position }
                        + self.reservedSteps.filter { $0.key != id }.map(\.value)
                    func obstructed(_ point: SIMD3<Float>) -> Bool {
                        occupied.contains { abs($0.x - point.x) < 0.8 && abs($0.z - point.z) < 0.8 }
                    }
                    if plannedDestination != destination || remainingRoute.isEmpty ||
                        remainingRoute.first.map({ obstructed(self.roomLayout.position($0)) }) == true {
                        remainingRoute = Array(self.roomLayout.route(from: node, to: destination, avoiding: occupied).dropFirst())
                        plannedDestination = destination
                    }
                    guard let nextNode = remainingRoute.first, !obstructed(self.roomLayout.position(nextNode)) else {
                        self.resetWalkingPose(agentID: id)
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        continue
                    }
                    remainingRoute.removeFirst()
                    self.reservedSteps[id] = self.roomLayout.position(nextNode)
                    let initialVisualHeight = self.characterVisuals[id]?.position.y ?? 0
                    self.resetWalkingPose(agentID: id)
                    let start = root.position
                    let end = self.roomLayout.position(nextNode)
                    let duration = max(0.25, Double(simd_length(end - start)) / 1.05)
                    let initialRotation = root.orientation
                    let rotation = self.walkingTransform(from: start, to: end).rotation
                    // ContinuousClock makes speed independent of dropped frames.
                    let clock = ContinuousClock()
                    var lastTick = clock.now
                    var seconds: Double = 0
                    var previous = start
                    while !Task.isCancelled {
                        let now = clock.now
                        let elapsed = lastTick.duration(to: now)
                        lastTick = now
                        let visible = (self.dataCurrent(for: agent) || agent.canWander) && self.view?.window?.occlusionState.contains(.visible) == true
                        if !visible {
                            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                            continue
                        }
                        seconds += min(0.05, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                        let t = min(1, Float(seconds / duration))
                        let point = start + (end - start) * t
                        self.walkedDistances[id, default: 0] += simd_length(point - previous)
                        previous = point
                        root.position = point
                        root.orientation = simd_slerp(initialRotation, rotation, min(1, Float(seconds / 0.22)))
                        self.applyWalkingPose(agentID: id, distance: self.walkedDistances[id, default: 0])
                        if initialVisualHeight > 0.1 {
                            self.characterVisuals[id]?.position.y += initialVisualHeight * max(0, 1 - t * 3)
                        }
                        if nextNode == destination && self.isSeated(agent) {
                            let walkingOrientation = root.orientation
                            self.applyStationaryPose(agent: agent, root: root, time: 0)
                            let seatedOrientation = root.orientation
                            root.orientation = simd_slerp(walkingOrientation, seatedOrientation, t)
                            self.characterVisuals[id]?.position.y = 0.30 * t
                        }
                        self.layoutLabels()
                        if t == 1 { break }
                        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                    }
                    if Task.isCancelled { return }
                    self.currentNodes[id] = nextNode
                    self.reservedSteps[id] = nil
                    // Only now read the newest destination: a refresh finishes
                    // this segment and replans from an actual graph node.
                }
                self.movementTasks[id] = nil
            }
        }

        private func animateStationary(delta: TimeInterval) {
            guard !lastReduceMotion, view?.window?.isVisible == true else { return }
            animationTime += min(delta, 0.1)
            guard animationTime - lastActionFrame >= 0.08 else { return }
            lastActionFrame = animationTime
            if animationTime - lastLeisureTick >= 1 {
                lastLeisureTick = animationTime
                updateLeisure()
                updateComputers()
            }
            for (id, agent) in desiredAgents where movementTasks[id] == nil {
                guard dataCurrent(for: agent) || agent.canWander else { continue }
                applyActionLoop(agent: agent, time: animationTime)
            }
        }

        private func applyStationaryPose(agent: OfficePreviewAgentPresentation, root: Entity, time: TimeInterval) {
            resetWalkingPose(agentID: agent.id)
            guard let limbs = limbEntities[agent.id], let visual = characterVisuals[agent.id] else { return }
            let slot = roomLayout.slots[agent.id] ?? 0
            let leisure = currentNodes[agent.id]?.leisureIndex.flatMap { roomLayout.authored?.leisureSpots[$0] }
            root.orientation = simd_quatf(angle: leisure?.station.yaw ?? roomLayout.yaw(slot: currentNodes[agent.id]?.slot ?? slot, location: OfficePreviewLayout.locations[currentNodes[agent.id]?.index ?? 0]), axis: [0, 1, 0])
            if isSeated(agent) {
                visual.position.y = 0.30
                for leg in [limbs.leftLeg, limbs.rightLeg] {
                    leg.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
                    leg.position = [leg.position.x, 0.23, 0.08]
                }
            }
            applyActionLoop(agent: agent, time: time)
        }

        private func isSeated(_ agent: OfficePreviewAgentPresentation) -> Bool {
            guard agent.phase.isSeated else { return false }
            if let index = currentNodes[agent.id]?.leisureIndex { return roomLayout.authored?.leisureSpots[index].station.seated ?? false }
            let slot = roomLayout.slots[agent.id] ?? 0
            return roomLayout.authored?.station(slot: currentNodes[agent.id]?.slot ?? slot, location: OfficePreviewLayout.locations[currentNodes[agent.id]?.index ?? 0]).seated ?? true
        }

        private func applyActionLoop(agent: OfficePreviewAgentPresentation, time: TimeInterval) {
            guard let limbs = limbEntities[agent.id], let visual = characterVisuals[agent.id] else { return }
            let wave = time == 0 ? Float(0) : sin(Float(time) * 2.3 + Float(agent.identitySeed % 10))
            let leisure = agent.canWander ? currentNodes[agent.id]?.leisureIndex.flatMap { roomLayout.authored?.leisureSpots[$0].action } : nil
            visual.findEntity(named: "leisure-cup")?.isEnabled = leisure == .coffee
            visual.findEntity(named: "leisure-book")?.isEnabled = leisure == .reading
            if let leisure {
                switch leisure {
                case .coffee: limbs.rightArm.orientation = simd_quatf(angle: -1.6 + wave * 0.25, axis: [1, 0, 0])
                case .arcade:
                    limbs.leftArm.orientation = simd_quatf(angle: -1.1 + wave * 0.18, axis: [1, 0, 0])
                    limbs.rightArm.orientation = simd_quatf(angle: -1.1 - wave * 0.18, axis: [1, 0, 0])
                case .reading:
                    limbs.leftArm.orientation = simd_quatf(angle: -0.9, axis: [1, 0, 0])
                    limbs.rightArm.orientation = simd_quatf(angle: -1.0 + wave * 0.03, axis: [1, 0, 0])
                case .socializing: limbs.rightArm.orientation = simd_quatf(angle: -0.7 + wave * 0.3, axis: [1, 0, 0])
                case .strolling: visual.orientation = simd_quatf(angle: wave * 0.12, axis: [0, 1, 0])
                }
                return
            }
            // Exchange gestures only once both colleagues have arrived. Work
            // continues to display the original task and reported status.
            if let partnerID = interactionPlan.partners[agent.id],
               movementTasks[partnerID] == nil, let peer = avatarRoots[partnerID],
               let root = avatarRoots[agent.id], simd_distance(root.position, peer.position) < 4 {
                let delta = peer.position - root.position
                root.orientation = simd_quatf(angle: atan2(delta.x, delta.z), axis: [0, 1, 0])
                let speaking = (Int(time / 3) % 2 == 0) == (agent.id < partnerID)
                limbs.rightArm.orientation = simd_quatf(angle: speaking ? -0.7 + wave * 0.22 : -0.3, axis: [1, 0, 0])
                limbs.leftArm.orientation = simd_quatf(angle: -0.4, axis: [1, 0, 0])
                return
            }
            switch agent.phase {
            case .implementing:
                limbs.leftArm.orientation = simd_quatf(angle: -1.05 + wave * 0.13, axis: [1, 0, 0])
                limbs.rightArm.orientation = simd_quatf(angle: -1.05 - wave * 0.13, axis: [1, 0, 0])
            case .testing, .reading, .reviewing:
                limbs.leftArm.orientation = simd_quatf(angle: -0.85, axis: [1, 0, 0])
                limbs.rightArm.orientation = simd_quatf(angle: -0.9 + wave * 0.06, axis: [1, 0, 0])
            case .planning:
                limbs.rightArm.orientation = simd_quatf(angle: -0.5 + wave * 0.10, axis: [1, 0, 0])
            case .resting: visual.position.y = (isSeated(agent) ? 0.30 : 0) + wave * 0.005
            case .waiting:
                // A quiet 24-second routine, offset by identity. These gestures
                // are presentation only; Hermes alone clears the blocker.
                let cycle = time == 0 ? 0 : (time + Double(agent.identitySeed % 24)).truncatingRemainder(dividingBy: 24)
                func gesture(_ start: Double, _ end: Double) -> Float {
                    guard cycle > start, cycle < end else { return 0 }
                    let fade = min(1, min((cycle - start) / 0.8, (end - cycle) / 0.8))
                    return Float(fade * fade * (3 - 2 * fade))
                }
                let check = gesture(1, 6)
                let ponder = gesture(9, 13)
                let ask = gesture(18, 21)
                limbs.leftArm.orientation = simd_quatf(angle: -0.8 * check - 0.45 * ponder, axis: [1, 0, 0])
                limbs.rightArm.orientation = simd_quatf(angle: -0.85 * check - (2.35 + wave * 0.06) * ponder - 2.85 * ask, axis: [1, 0, 0])
                    * simd_quatf(angle: -0.18 * ponder - 0.25 * ask, axis: [0, 0, 1])
                visual.orientation = simd_quatf(angle: 0.035 * ponder, axis: [0, 0, 1])
            }
        }

        private func applyWalkingPose(agentID: String, distance: Float) {
            guard let limbs = limbEntities[agentID], let visual = characterVisuals[agentID] else { return }
            let pose = OfficePreviewWalkPose(distance: distance)
            for (limb, angle, lift) in [
                (limbs.leftLeg, pose.legAngle, pose.leftLift),
                (limbs.rightLeg, -pose.legAngle, pose.rightLift),
                (limbs.leftArm, -pose.legAngle * 0.85, Float(0)),
                (limbs.rightArm, pose.legAngle * 0.85, Float(0))
            ] {
                limb.orientation = simd_quatf(angle: angle, axis: [1, 0, 0])
                limb.position.y = (limb === limbs.leftLeg || limb === limbs.rightLeg ? 0.16 : 0.55) + lift
                if limb === limbs.leftLeg { limb.position.z = pose.footTravel }
                if limb === limbs.rightLeg { limb.position.z = -pose.footTravel }
            }
            // Move only the character, not the route root or activity bubble.
            visual.position.y = pose.bounce
            visual.orientation = simd_quatf(angle: pose.sway, axis: [0, 0, 1])
        }

        private func resetWalkingPose(agentID: String) {
            guard let limbs = limbEntities[agentID] else { return }
            for limb in [limbs.leftLeg, limbs.rightLeg, limbs.leftArm, limbs.rightArm] {
                limb.orientation = simd_quatf()
                limb.position.y = (limb === limbs.leftLeg || limb === limbs.rightLeg) ? 0.16 : 0.55
                limb.position.z = 0
            }
            characterVisuals[agentID]?.transform = Transform()
            characterVisuals[agentID]?.findEntity(named: "leisure-cup")?.isEnabled = false
            characterVisuals[agentID]?.findEntity(named: "leisure-book")?.isEnabled = false
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
            let usesAlternateHair = agent.identitySeed.isMultiple(of: 2)
            let outfit = NSColor(calibratedHue: agent.identityHue, saturation: 0.55, brightness: 0.87, alpha: 1)
            let skin = nsColor(0.96, 0.74, 0.53)
            let hair = usesAlternateHair ? nsColor(0.32, 0.20, 0.13) : nsColor(0.26, 0.18, 0.31)
            let ink = nsColor(0.14, 0.18, 0.22)
            let cream = nsColor(0.98, 0.94, 0.82)

            // Chibi proportions: broad, soft head over a short hoodie body.
            // Limb roots retain the same pivots used by the walking animation.
            addToonPart(to: root, name: "hoodie", size: [0.45, 0.53, 0.35], position: [0, 0.52, 0], color: outfit, radius: 0.14)
            addToonPart(to: root, name: "hood", size: [0.39, 0.19, 0.21], position: [0, 0.74, -0.10], color: outfit, radius: 0.09)
            addToonPart(to: root, name: "head", size: [0.60, 0.55, 0.48], position: [0, 1.04, 0], color: skin, radius: 0.20)
            for side: Float in [-1, 1] {
                addToonOval(to: root, name: "ear", size: [0.10, 0.15, 0.10], position: [side * 0.29, 1.03, 0], color: skin)
            }
            addToonPart(to: root, name: "hair-cap", size: [0.61, 0.24, 0.47], position: [0, 1.26, -0.035], color: hair, radius: 0.115)
            addToonPart(to: root, name: "hair-back", size: [0.55, 0.35, 0.16], position: [0, 1.09, -0.20], color: hair, radius: 0.075)
            for index in 0..<3 {
                let x = Float(index - 1) * 0.16
                addToonOval(to: root, name: "fringe", size: [0.25, 0.19, 0.18], position: [x, 1.23 - Float(index) * 0.015, 0.15], color: hair)
            }
            if !usesAlternateHair {
                addToonOval(to: root, name: "hair-bun", size: [0.26, 0.26, 0.25], position: [0.20, 1.36, -0.13], color: hair)
                addToonPart(to: root, name: "hair-tie", size: [0.14, 0.055, 0.15], position: [0.20, 1.27, -0.13], color: outfit, radius: 0.025)
            }
            for x: Float in [-0.105, 0.105] {
                addToonOval(to: root, name: "eye", size: [0.064, 0.088, 0.025], position: [x, 1.055, 0.237], color: ink)
                addToonOval(to: root, name: "eye-glint", size: [0.019, 0.024, 0.009], position: [x - 0.012, 1.076, 0.253], color: cream)
                addToonOval(to: root, name: "cheek", size: [0.081, 0.038, 0.015], position: [x * 1.7, 0.996, 0.219], color: nsColor(0.96, 0.49, 0.42))
            }
            addToonOval(to: root, name: "nose", size: [0.054, 0.048, 0.048], position: [0, 1.018, 0.247], color: skin)
            addToonPart(to: root, name: "smile", size: [0.058, 0.023, 0.016], position: [0, 0.968, 0.242], color: ink, radius: 0.01)

            let trousers = nsColor(0.23, 0.29, 0.36)
            let leftLeg = addToonPart(to: root, name: "left-leg", size: [0.145, 0.30, 0.16], position: [-0.12, 0.16, 0], color: trousers, radius: 0.065)
            let rightLeg = addToonPart(to: root, name: "right-leg", size: [0.145, 0.30, 0.16], position: [0.12, 0.16, 0], color: trousers, radius: 0.065)
            for leg in [leftLeg, rightLeg] {
                addToonPart(to: leg, name: "sneaker", size: [0.18, 0.12, 0.27], position: [0, -0.10, 0.042], color: cream, radius: 0.055)
                addToonPart(to: leg, name: "sneaker-sole", size: [0.185, 0.035, 0.275], position: [0, -0.143, 0.042], color: outfit, radius: 0.016)
                addToonPart(to: leg, name: "sneaker-tongue", size: [0.095, 0.022, 0.10], position: [0, -0.04, 0.065], color: outfit, radius: 0.01)
            }
            let leftArm = addToonPart(to: root, name: "left-sleeve", size: [0.14, 0.31, 0.15], position: [-0.28, 0.55, 0], color: outfit, radius: 0.065)
            let rightArm = addToonPart(to: root, name: "right-sleeve", size: [0.14, 0.31, 0.15], position: [0.28, 0.55, 0], color: outfit, radius: 0.065)
            for arm in [leftArm, rightArm] {
                addToonOval(to: arm, name: "mitten-hand", size: [0.13, 0.15, 0.13], position: [0, -0.19, 0.014], color: skin)
                addToonPart(to: arm, name: "cuff", size: [0.145, 0.055, 0.155], position: [0, -0.135, 0], color: cream, radius: 0.025)
            }
            addToonPart(to: root, name: "hoodie-pocket", size: [0.22, 0.11, 0.025], position: [0, 0.44, 0.178], color: outfit, radius: 0.012)
            if agent.mainSession != nil {
                addToonOval(to: root, name: "nexus-compass-badge", size: [0.13, 0.13, 0.025], position: [0, 0.61, 0.19], color: cream)
                let needle = addToonPart(to: root, name: "nexus-compass-needle", size: [0.025, 0.09, 0.012], position: [0, 0.61, 0.207], color: ink, radius: 0.008)
                needle.orientation = simd_quatf(angle: -.pi / 5, axis: [0, 0, 1])
            }
            for x: Float in [-0.065, 0.065] {
                addToonPart(to: root, name: "hoodie-cord", size: [0.017, 0.14, 0.018], position: [x, 0.67, 0.177], color: cream, radius: 0.008)
            }
            limbEntities[agent.id] = (leftLeg, rightLeg, leftArm, rightArm)
            let cup = addToonPart(to: rightArm, name: "leisure-cup", size: [0.14, 0.16, 0.14], position: [0, -0.25, 0.03], color: cream, radius: 0.03)
            cup.isEnabled = false
            let book = addToonPart(to: leftArm, name: "leisure-book", size: [0.30, 0.04, 0.23], position: [0.08, -0.24, 0.04], color: nsColor(0.38, 0.28, 0.19), radius: 0.01)
            book.isEnabled = false
            // One selection volume per bot. Limb-by-limb collision hulls make
            // every typing frame update dozens of unnecessary physics shapes.
            avatar.components.set(CollisionComponent(shapes: [
                ShapeResource.generateBox(size: [0.76, 1.7, 0.76]).offsetBy(translation: [0, 0.85, 0])
            ]))
            return avatar
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
            var occupied: [CGRect] = []
            let ordered = desiredAgents.values.sorted {
                let left = $0.taskData?.lane.rank ?? 99
                let right = $1.taskData?.lane.rank ?? 99
                return left == right ? $0.id < $1.id : left < right
            }
            for id in ordered.map(\.id) {
                guard let label = labels[id], let root = avatarRoots[id],
                      let point = view.project(root.position + [0, 1.65, 0]),
                      point.x.isFinite, point.y.isFinite, view.bounds.contains(point) else {
                    labels[id]?.isHidden = true
                    continue
                }
                label.isHidden = false
                let size = CGSize(width: 28, height: 28)
                let y = view.isFlipped ? point.y - size.height - 2 : point.y + 2
                var frame = CGRect(x: point.x - size.width / 2, y: y, width: size.width, height: size.height)
                frame.origin.x = min(view.bounds.maxX - size.width - 8, max(8, frame.origin.x))
                frame.origin.y = min(view.bounds.maxY - size.height - 8, max(8, frame.origin.y))
                if occupied.contains(where: { $0.intersects(frame) }) {
                    // Keep indicators attached to their own bot instead of
                    // displacing them over another character in crowded views.
                    label.isHidden = true
                    continue
                }
                if label.frame != frame { label.frame = frame }
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
            let geometry = Entity()
            roomGeometry = geometry
            anchor?.addChild(geometry)
            buildRoom(in: geometry)
            screens = Dictionary(uniqueKeysWithValues: (0..<(roomLayout.authored?.stations[.desk]?.count ?? 8)).compactMap { slot in
                (geometry.findEntity(named: "work-screen-\(slot)") as? ModelEntity).map { (slot, $0) }
            })
            poweredScreens = []
            updateComputers()
            renderBoardCounts()
        }

        private func buildRoom(in root: Entity) {
            roomLayout.authored = OfficeDesignSceneBuilder().build(in: root, capacity: roomLayout.capacity)
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
            let light = DirectionalLight()
            light.light.intensity = 1300
            light.position = SIMD3<Float>(2, 6, 4)
            light.look(at: SIMD3<Float>(0, 0, 0), from: light.position, relativeTo: nil)
            root.addChild(light)
        }

        private func applyCameraTransform() {
            guard let camera else { return }
            camera.position = cameraState.position
            camera.look(at: cameraState.orbitTarget, from: camera.position, relativeTo: nil)
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
                    mesh: .generateBox(size: [0.43, 0.47, 0.42], cornerRadius: 0.18),
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
            let clock = ModelEntity(mesh: .generateSphere(radius: 0.38), materials: [SimpleMaterial(color: nsColor(0.92, 0.95, 0.97), isMetallic: false)])
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
            let mesh = MeshResource.generateBox(size: size, cornerRadius: radius)
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
