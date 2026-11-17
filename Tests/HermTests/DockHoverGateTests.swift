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

    @Test func admitsEachMoveOnceAcrossForwardedDeliveries() {
        let gate = DockHoverGate()
        let event = move(at: 1_000)
        #expect(gate.admit(event, replay: { _ in }))
        // The same move forwarded up from a nested host is not re-dispatched.
        #expect(!gate.admit(event, replay: { _ in }))
        #expect(gate.admit(move(at: 1_000.01, x: 11), replay: { _ in }))
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
