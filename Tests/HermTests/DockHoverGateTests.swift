import AppKit
import Testing

@testable import Herm

@MainActor
struct DockHoverGateTests {
    private func move(at timestamp: TimeInterval, x: CGFloat = 10) -> NSEvent {
        NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: x, y: 10), modifierFlags: [], timestamp: timestamp,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    }

    @Test func deliversOnlyTheLatestMoveThroughTheDeepestHost() async {
        let gate = DockHoverGate()
        var deliveries: [String] = []
        let first = move(at: 1_000)
        let latest = move(at: 1_000.01, x: 11)
        #expect(!gate.admit(first, depth: 2) { _ in deliveries.append("old") })
        #expect(!gate.admit(latest, depth: 1) { _ in deliveries.append("root") })
        let admitted = gate.admit(latest, depth: 2) { event in
            deliveries.append("pane")
            #expect(gate.admit(event, depth: 1) { _ in })
        }
        #expect(!admitted)
        await gate.deferred?.value
        #expect(deliveries == ["pane"])
        #expect(!gate.admit(latest, depth: 1) { _ in })
    }

    @Test func deliversMovesImmediatelyToEachHostOutsideAScroll() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [], backing: .buffered,
            defer: true)
        let root = NSView(frame: window.contentLayoutRect)
        let pane = NSView(frame: root.bounds)
        window.contentView = root
        root.addSubview(pane)
        let event = move(at: ProcessInfo.processInfo.systemUptime)
        // Hover must land in the same event as AppKit's own cursor update, in every host.
        #expect(DockHoverGate.admit(event, in: pane) { _ in })
        #expect(DockHoverGate.admit(event, in: root) { _ in })
        // A move forwarded up the responder chain reaches a host only once.
        #expect(!DockHoverGate.admit(event, in: pane) { _ in })
    }

    private func scroll(at seconds: TimeInterval, phase: Int64) -> NSEvent {
        let cg = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 4, wheel2: 0, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.timestamp = UInt64(seconds * 1_000_000_000)
        return NSEvent(cgEvent: cg)!
    }

    @Test func reusesScrollTargetOnlyWithinOneGesture() {
        // CGScrollPhase: 1 began, 2 changed.
        #expect(DockScrollHitCache.canReuse(during: scroll(at: 10, phase: 2)))
        #expect(DockScrollHitCache.canReuse(during: nil))
        #expect(!DockScrollHitCache.canReuse(during: scroll(at: 10, phase: 1)))
        let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 10,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        #expect(!DockScrollHitCache.canReuse(during: click))
    }
}
