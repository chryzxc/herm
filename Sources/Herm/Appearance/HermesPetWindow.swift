import AppKit
import Combine
import SwiftUI

/// Local movement only. Hermes still owns the pet, sprites and selected profile.
@MainActor
final class HermesPetWindow {
    static let attachedKey = "hermes.pet.attached"
    static let snapRadius: CGFloat = 64
    private let panel = PetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let pet: HermesPetModel
    private let defaults: UserDefaults
    private let motion = PetRoamPresentation()
    private var timer: AnyCancellable?
    private var tickInterval: TimeInterval = 0
    private var home = NSPoint.zero
    private var homeAnchor = NSPoint.zero
    private var side: EdgeDockSide = .right
    private var screen = NSRect.zero
    private var destination: NSPoint?
    private var nextTrip = Date.now.addingTimeInterval(25)
    private var hovering = false
    private var dragOrigin: NSPoint?
    private var dragPointer: NSPoint?
    private var allowed = false
    private var petIdentity: String?
    private var snapping = false
    private var holding = false
    /// Attached (the default) pins the pet to the notch; dragging it away frees it to roam.
    private(set) var attached: Bool {
        get { defaults.object(forKey: Self.attachedKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.attachedKey); motion.attached = newValue; onAttachChange?(newValue) }
    }
    /// The notch wraps the pet while attached and previews that while a drag is in range.
    var onAttachChange: ((Bool) -> Void)?
    /// (dragging, pull 0...1): how strongly the notch should reach for the pet.
    var onDragProgress: ((Bool, Double) -> Void)?

    init(pet: HermesPetModel, defaults: UserDefaults) {
        self.pet = pet; self.defaults = defaults
        panel.backgroundColor = .clear; panel.isOpaque = false
        panel.hasShadow = false; panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) // above the notch shell it sits in
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PetWindowContent(pet: pet, motion: motion,
            hover: { [weak self] in self?.hovering = $0 },
            recall: { [weak self] in self?.recall() }))
        motion.attached = attached
        // AppKit-level drag: the SwiftUI Button swallows the mouse-down before a DragGesture sees it.
        panel.onDrag = { [weak self] in self?.drag() }
        panel.onDragEnd = { [weak self] in self?.endDrag() }
        panel.onHold = { [weak self] in self?.holding = $0; self?.motion.held = $0 }
        panel.onClick = { [weak self] in self?.pet.pet() }
        scheduleTicks()
    }

    /// 20Hz only while walking somewhere; parked, attached or hidden pets
    /// still notice profile, visibility and trip changes once a second.
    private func scheduleTicks() {
        let interval: TimeInterval = allowed && destination != nil ? 0.05 : 1
        guard interval != tickInterval else { return }
        tickInterval = interval
        timer = Timer.publish(every: interval, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    static func clamped(_ origin: NSPoint, to screen: NSRect, size: CGSize = CGSize(width: 44, height: 44)) -> NSPoint {
        NSPoint(x: min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - size.width)),
                y: min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - size.height)))
    }

    static func spriteSize(info: HermesPetInfo, screen: NSRect) -> CGSize {
        let scale = min(3, max(0.1, info.scale ?? 0.33))
        let width = CGFloat(info.frameW ?? 192) * scale
        let height = CGFloat(info.frameH ?? 208) * scale
        let fit = min(1, max(1, screen.width) / width, max(1, screen.height) / height)
        return CGSize(width: width * fit, height: height * fit)
    }

    /// Desktop's stroll rule: favor the roomier side and cover at least 45%
    /// of the available span, rather than pacing close to the home coordinate.
    static func strollTarget(from origin: NSPoint, screen: NSRect, fraction: CGFloat, size: CGSize = CGSize(width: 44, height: 44)) -> NSPoint {
        let left = screen.minX, right = max(left, screen.maxX - size.width)
        let x = min(max(origin.x, left), right)
        let goRight = right - x >= x - left
        let room = goRight ? right - x : x - left
        let minimum = min(room, max((right - left) * 0.45, 110))
        let distance = minimum + min(1, max(0, fraction)) * (room - minimum)
        return clamped(NSPoint(x: x + (goRight ? distance : -distance), y: screen.minY + 8), to: screen, size: size)
    }

    func update(home: NSPoint, screen: NSRect, visible: Bool, side: EdgeDockSide = .right) {
        let moved = self.homeAnchor != home || self.screen != screen || self.side != side
        self.screen = screen; self.homeAnchor = home; self.side = side; allowed = visible
        updateSize()
        if moved { if attached { recall() } else { panel.setFrameOrigin(Self.clamped(panel.frame.origin, to: screen, size: windowSize)) } }
        tick()
    }

    func hide() { allowed = false; panel.orderOut(nil) }

    /// Reattaches the pet to the notch (also the "Call pet home" action).
    func recall() {
        motion.direction = 0
        destination = nil; dragOrigin = nil; dragPointer = nil
        nextTrip = .now.addingTimeInterval(30)
        let wasFree = !attached
        attached = true; motion.nearNotch = false
        let frame = NSRect(origin: home, size: windowSize)
        guard wasFree, panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true); return
        }
        snapping = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in self?.snapping = false })
    }

    private func endDrag() {
        dragOrigin = nil; dragPointer = nil; destination = nil
        motion.nearNotch = false; onDragProgress?(false, 0)
        if distanceToHome <= snapDistance {
            recall(); pet.react(.greeting); motion.pulse += 1
        } else {
            attached = false
            nextTrip = .now.addingTimeInterval(4)
        }
    }

    /// Hysteresis: leaving an attached notch takes a short pull, joining one takes a closer approach.
    private var snapDistance: CGFloat { attached ? 24 : Self.snapRadius }
    private var distanceToHome: CGFloat { hypot(panel.frame.origin.x - home.x, panel.frame.origin.y - home.y) }

    private func drag() {
        let pointer = NSEvent.mouseLocation
        if dragOrigin == nil { dragOrigin = panel.frame.origin; dragPointer = pointer; destination = nil; snapping = false }
        guard let origin = dragOrigin, let start = dragPointer else { return }
        // Use screen coordinates: the view itself moves during the drag.
        panel.setFrameOrigin(Self.clamped(NSPoint(x: origin.x + pointer.x - start.x, y: origin.y + pointer.y - start.y), to: screen, size: windowSize))
        let near = distanceToHome <= snapDistance
        if motion.nearNotch != near { motion.nearNotch = near }
        onDragProgress?(true, min(1, max(0, (snapDistance + 110 - distanceToHome) / 110)))
    }

    private var windowSize: CGSize { CGSize(width: max(44, motion.size.width), height: max(44, motion.size.height)) }

    private func updateSize() {
        let size = Self.spriteSize(info: pet.info, screen: screen)
        let atHome = panel.frame.origin == home
        if motion.size != size { motion.size = size }
        home = Self.clamped(NSPoint(x: side == .right ? homeAnchor.x + 44 - windowSize.width : homeAnchor.x,
                                   y: homeAnchor.y + 44 - windowSize.height), to: screen, size: windowSize)
        if panel.frame.size != windowSize {
            destination = nil
            panel.setFrame(NSRect(origin: atHome ? home : Self.clamped(panel.frame.origin, to: screen, size: windowSize), size: windowSize), display: true)
        }
    }

    private func tick() {
        step()
        scheduleTicks()
    }

    private func step() {
        defer { if !allowed, motion.direction != 0 { motion.direction = 0 } }
        guard allowed, pet.visible, screen.width > 0 else { panel.orderOut(nil); return }
        updateSize()
        let identity = "\(pet.profile ?? "")/\(pet.info.slug ?? "")"
        if petIdentity != identity { petIdentity = identity; if attached { recall() } }
        if !panel.isVisible { panel.orderFrontRegardless() }
        let roaming = !attached && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && pet.online && !pet.stale
        if !roaming {
            if motion.direction != 0 { motion.direction = 0 }
            if attached, !snapping, dragOrigin == nil, panel.frame.origin != home { panel.setFrameOrigin(home) }
            return
        }
        // Like Desktop, live activity and direct interactions pause wandering.
        guard !hovering, !holding, dragOrigin == nil, pet.pose == "idle" else {
            if motion.direction != 0 { motion.direction = 0 }
            return
        }
        if destination == nil {
            guard Date.now >= nextTrip else { return }
            destination = Self.strollTarget(from: panel.frame.origin, screen: screen, fraction: .random(in: 0...1), size: windowSize)
        }
        guard let target = destination else { return }
        let origin = panel.frame.origin
        let dx = target.x - origin.x, dy = target.y - origin.y
        let distance = hypot(dx, dy)
        if distance <= 2 {
            motion.direction = 0
            panel.setFrameOrigin(target); destination = nil
            nextTrip = .now.addingTimeInterval(Double.random(in: 3...13))
        } else {
            let direction = dx < 0 ? -1 : 1
            if motion.direction != direction { motion.direction = direction }
            panel.setFrameOrigin(NSPoint(x: origin.x + dx / distance * 2, y: origin.y + dy / distance * 2))
        }
    }
}

@MainActor
private final class PetRoamPresentation: ObservableObject {
    @Published var direction = 0
    @Published var size = CGSize(width: 36, height: 40)
    @Published var attached = true
    @Published var nearNotch = false
    @Published var pulse = 0
    @Published var held = false // pointer is down on the pet, before or during a drag
}

private final class PetPanel: NSPanel {
    var onDrag: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onClick: (() -> Void)?
    var onHold: ((Bool) -> Void)?
    private var downAt: NSPoint?
    private var dragging = false
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        // The mouse-down is swallowed too: a SwiftUI Button would otherwise run its own tracking loop
        // and starve the drag. A press without movement is forwarded as a click instead.
        case .leftMouseDown: downAt = NSEvent.mouseLocation; dragging = false; onHold?(true); return
        case .leftMouseDragged:
            if !dragging, let start = downAt, hypot(NSEvent.mouseLocation.x - start.x, NSEvent.mouseLocation.y - start.y) > 4 { dragging = true }
            if dragging { onDrag?(); return }
        case .leftMouseUp:
            downAt = nil; onHold?(false)
            if dragging { dragging = false; onDragEnd?() } else { onClick?() }
            return
        default: break
        }
        super.sendEvent(event)
    }
}

private struct PetWindowContent: View {
    @ObservedObject var pet: HermesPetModel
    @ObservedObject var motion: PetRoamPresentation
    let hover: (Bool) -> Void
    let recall: () -> Void
    @State private var wobble = false
    @State private var ring = 0.0 // 0 idle, then animates to 1 after an attach
    private var walkingRow: String? {
        if motion.held { return HermesPetReaction.petting.pose } // lifted: the jump row while held or dragged
        guard motion.direction != 0, pet.pose == "idle" else { return nil }
        let row = motion.direction < 0 ? "running-left" : "running-right"
        return pet.sheet?.info.stateRows?.contains(row) == true ? row : "run"
    }
    var body: some View {
        HermesNotchPetButton(pet: pet, mirrored: walkingRow == "run" && motion.direction < 0, poseOverride: walkingRow, spriteSize: motion.size)
            .scaleEffect(motion.held ? 1.1 : motion.nearNotch ? 1.12 : 1)
            .rotationEffect(.degrees(motion.held ? (wobble ? 5 : -5) : 0))
            .shadow(color: .black.opacity(motion.held ? 0.35 : 0), radius: 8, y: 6)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: motion.held)
            .onChange(of: motion.held) { _, held in
                guard held else { wobble = false; return }
                withAnimation(.easeInOut(duration: 0.18).repeatForever(autoreverses: true)) { wobble = true }
            }
            .overlay { if motion.nearNotch { Circle().strokeBorder(DockThemePalette(theme: DockThemeRuntime.current).accent, style: StrokeStyle(lineWidth: 2, dash: [4, 3])).padding(2) } }
            .overlay { Circle().stroke(DockThemePalette(theme: DockThemeRuntime.current).accent, lineWidth: 2).scaleEffect(0.8 + ring * 0.7).opacity(ring == 0 ? 0 : 0.8 * (1 - ring)).padding(4).allowsHitTesting(false) }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: motion.nearNotch)
            .onChange(of: motion.pulse) {
                ring = 0.001
                withAnimation(.easeOut(duration: 0.6)) { ring = 1 }
            }
            .onHover(perform: hover)
            .contextMenu { Button("Attach to notch", action: recall).disabled(motion.attached) }
    }
}
