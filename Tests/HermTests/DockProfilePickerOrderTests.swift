import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct DockProfilePickerOrderTests {
    /// A held pointer at the top of an overflow list walks the last profile to slot zero
    /// inside one drag, using the real clip's travel rather than repeated pointer events.
    @Test func heldTopEdgeScrollsLastProfileToFirst() throws {
        let suite = "profile-edge-drag-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ids = (0..<19).map { "profile-\($0)" } + ["last"]
        let bots = profiles(ids)
        let order = DockProfilePickerOrder(defaults: defaults)
        let target = DockScrollTarget()
        let token = UUID()
        var drag = DockProfilePickerDrag(token: token, id: "last", start: 19)
        #expect(target.scrollView == nil)
        #expect(!drag.isCurrent(token: token, attachment: target.attachment))
        drag.translation = -44
        drag.updateOrder(order, in: bots, pitch: 40)
        #expect(order.ordered(bots)[18].id == "last", "Pointer-only reorder works before the probe attaches")

        let scroll = try overflowClip(documentHeight: 852)
        let clip = scroll.contentView
        let probe = NSView()
        target.attach(scroll, from: probe)
        let liftBeforeAttach = drag.liftOffset(at: 18, pitch: 40)
        drag.bindClip(origin: clip.bounds.minY, attachment: target.attachment)
        drag.trackClip(origin: clip.bounds.minY, isFlipped: clip.isFlipped)
        #expect(drag.isCurrent(token: token, attachment: target.attachment))
        #expect(drag.target(pitch: 40, count: bots.count) == 18)
        #expect(drag.liftOffset(at: 18, pitch: 40) == liftBeforeAttach)

        drag.translation = -330
        let direction = try #require(DockEdgeAutoscroll.direction(pointer: topPointer, viewport: viewport))
        #expect(direction == .towardStart)
        drag.updateOrder(order, in: bots, pitch: 40)
        #expect(drag.slot > 0, "The first slot must initially be unreachable")
        var steps = 0
        while steps < 200, DockEdgeAutoscroll.scrollStep(in: scroll, toward: direction) != 0 {
            drag.trackClip(origin: clip.bounds.minY, isFlipped: clip.isFlipped)
            drag.updateOrder(order, in: bots, pitch: 40)
            steps += 1
        }
        #expect(steps > 40 && steps < 200)
        #expect(clip.bounds.minY == clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: -852)).minY)
        #expect(DockEdgeAutoscroll.scrollStep(in: scroll, toward: .towardStart) == 0)
        #expect(drag.slot == 0, "The dragged profile must land first after All")
        let restored = DockProfilePickerOrder(defaults: defaults)
        #expect(restored.ordered(bots).map(\.id) == ["last"] + Array(ids.dropLast()))
    }

    /// Reversing to the bottom edge scrolls the same drag back to the last slot, then stops.
    @Test func reversedEdgeScrollReachesTheLastProfileAndStops() throws {
        let scroll = try overflowClip(documentHeight: 852)
        let clip = scroll.contentView
        var drag = makeDrag(in: clip, translation: -330)
        let end = clip.bounds.minY
        scrollToStart(scroll)
        drag.trackClip(origin: clip.bounds.minY, isFlipped: clip.isFlipped)
        #expect(drag.target(pitch: 40, count: 20) == 0)
        drag.translation = 0
        var steps = 0
        while steps < 200, DockEdgeAutoscroll.scrollStep(in: scroll, toward: .towardEnd) != 0 {
            drag.trackClip(origin: clip.bounds.minY, isFlipped: clip.isFlipped)
            steps += 1
        }
        #expect(steps > 40 && steps < 200)
        #expect(clip.bounds.minY == end)
        #expect(DockEdgeAutoscroll.scrollStep(in: scroll, toward: .towardEnd) == 0)
        #expect(drag.target(pitch: 40, count: 20) == 19)
    }

    /// Between the bands nothing moves, and a neighbour's clip keeps its own offset.
    @Test func edgesOnlyMoveTheirOwnClipBetweenTheBands() throws {
        let list = try overflowClip(documentHeight: 852)
        let neighbour = try overflowClip(documentHeight: 852)
        let neighbourOrigin = neighbour.contentView.bounds.minY
        let center = CGPoint(x: viewport.midX, y: viewport.midY)
        #expect(DockEdgeAutoscroll.direction(pointer: center, viewport: viewport) == nil)
        #expect(
            DockEdgeAutoscroll.direction(
                pointer: CGPoint(x: viewport.midX, y: viewport.maxY - 2), viewport: viewport) == .towardEnd)
        scrollToStart(list)
        #expect(list.contentView.bounds.minY != neighbourOrigin)
        #expect(neighbour.contentView.bounds.minY == neighbourOrigin)
    }

    @Test func passingAnyViewportEdgeStopsAutoscroll() {
        let outside = [
            CGPoint(x: viewport.midX, y: viewport.minY - 1),
            CGPoint(x: viewport.midX, y: viewport.maxY + 1),
            CGPoint(x: viewport.minX - 1, y: topPointer.y),
            CGPoint(x: viewport.maxX + 1, y: topPointer.y),
        ]
        for pointer in outside {
            #expect(DockEdgeAutoscroll.direction(pointer: pointer, viewport: viewport) == nil)
        }
    }

    @Test func stationaryTickUpdatesLiftBeforeCrossingSlot() throws {
        let scroll = try overflowClip(documentHeight: 852)
        let clip = scroll.contentView
        var drag = makeDrag(in: clip)
        #expect(drag.liftOffset(at: 19, pitch: 40) == 0)
        let delta = DockEdgeAutoscroll.scrollStep(in: scroll, toward: .towardStart)
        drag.trackClip(origin: clip.bounds.minY, isFlipped: clip.isFlipped)
        #expect(delta < 0)
        #expect(drag.target(pitch: 40, count: 20) == 19)
        #expect(drag.liftOffset(at: 19, pitch: 40) == delta)
    }

    @Test func travelIsZeroWithoutScrolling() throws {
        let scroll = try overflowClip(documentHeight: 852)
        let clip = scroll.contentView
        var drag = makeDrag(in: clip, translation: -44)
        drag.trackClip(origin: clip.bounds.minY, isFlipped: clip.isFlipped)
        #expect(drag.liftOffset(at: 19, pitch: 40) == -44)
        #expect(drag.target(pitch: 40, count: 20) == 18)
    }

    /// An unflipped document scrolls the other way, still clamping at AppKit's endpoints.
    @Test func unflippedClipStopsAtBothEnds() {
        let scroll = NSScrollView(frame: viewport)
        scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 852))
        scroll.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        #expect(!clip.isFlipped)
        let end = clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: -852)).origin
        let start = clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: 852)).origin
        clip.scroll(to: end)
        #expect(DockEdgeAutoscroll.scrollStep(in: scroll, toward: .towardEnd) == 0)
        #expect(DockEdgeAutoscroll.scrollStep(in: scroll, toward: .towardStart) > 0)
        clip.scroll(to: start)
        #expect(DockEdgeAutoscroll.scrollStep(in: scroll, toward: .towardStart) == 0)
        #expect(DockEdgeAutoscroll.scrollStep(in: scroll, toward: .towardEnd) < 0)
    }

    @Test func scrollStepReportsZeroWhenClipDoesNotMove() {
        let scroll = NSScrollView(frame: viewport)
        let clip = StationaryClipView(frame: scroll.contentView.frame)
        scroll.contentView = clip
        scroll.documentView = FlippedDocumentView(frame: CGRect(x: 0, y: 0, width: 300, height: 852))
        scroll.layoutSubtreeIfNeeded()
        let origin = clip.bounds.origin
        let requested = clip.bounds.offsetBy(dx: 0, dy: DockEdgeAutoscroll.step)
        #expect(clip.constrainBoundsRect(requested).origin != origin)
        #expect(DockEdgeAutoscroll.scrollStep(in: scroll, toward: .towardEnd) == 0)
        #expect(clip.bounds.origin == origin)
    }

    @Test func replacedProbeAndOldGestureCannotAffectNewDrag() throws {
        let scroll = try overflowClip(documentHeight: 852)
        let target = DockScrollTarget()
        let oldProbe = NSView()
        let newProbe = NSView()
        target.attach(scroll, from: oldProbe)
        let oldDrag = makeDrag(in: scroll.contentView, attachment: target.attachment)
        target.attach(scroll, from: newProbe)
        #expect(!target.detach(from: oldProbe))
        #expect(oldDrag.isCurrent(token: oldDrag.token, attachment: target.attachment))
        #expect(target.detach(from: newProbe))
        #expect(target.scrollView == nil)
        target.attach(scroll, from: newProbe)
        let newDrag = makeDrag(in: scroll.contentView, attachment: target.attachment)
        #expect(!oldDrag.isCurrent(token: oldDrag.token, attachment: target.attachment))
        #expect(!newDrag.isCurrent(token: oldDrag.token, attachment: target.attachment))
        #expect(newDrag.isCurrent(token: newDrag.token, attachment: target.attachment))
    }

    private var viewport: CGRect { CGRect(x: 0, y: 0, width: 300, height: 360) }
    private var topPointer: CGPoint { CGPoint(x: viewport.midX, y: viewport.minY + 2) }

    private func makeDrag(
        in clip: NSClipView, translation: CGFloat = 0, attachment: UUID = UUID()
    ) -> DockProfilePickerDrag {
        var drag = DockProfilePickerDrag(token: UUID(), id: "last", start: 19)
        drag.translation = translation
        drag.bindClip(origin: clip.bounds.minY, attachment: attachment)
        return drag
    }

    /// Runs the top-edge steps a held pointer would run until the clip reaches its first row.
    private func scrollToStart(_ scroll: NSScrollView) {
        for _ in 0..<200 {
            if DockEdgeAutoscroll.scrollStep(in: scroll, toward: .towardStart) == 0 { return }
        }
        Issue.record("The clip did not stop at its start")
    }

    /// A picker-sized overflow list, scrolled to its last row.
    private func overflowClip(documentHeight: CGFloat) throws -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 360))
        scroll.hasVerticalScroller = false
        let document = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 300, height: documentHeight))
        scroll.documentView = document
        scroll.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let end = clip.isFlipped ? document.frame.maxY : document.frame.minY
        clip.scroll(
            to: clip.constrainBoundsRect(
                NSRect(origin: NSPoint(x: clip.bounds.minX, y: end), size: clip.bounds.size)
            ).origin)
        scroll.reflectScrolledClipView(clip)
        #expect(clip.isFlipped, "The picker's clip draws its document downward")
        #expect(clip.bounds.minY != 0, "The fixture must start scrolled away from its first row")
        return scroll
    }

    /// The picker's SwiftUI scroll view draws its rows from the top, like this document.
    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class StationaryClipView: NSClipView {
        override var isFlipped: Bool { true }
        override func scroll(to newOrigin: NSPoint) {}
    }

    @Test func dragTranslationPicksTheNearestSlotWithinBounds() {
        #expect(DockProfilePickerReorder.target(start: 2, translation: 0, pitch: 40, count: 5) == 2)
        #expect(DockProfilePickerReorder.target(start: 2, translation: 19, pitch: 40, count: 5) == 2)
        #expect(DockProfilePickerReorder.target(start: 2, translation: 21, pitch: 40, count: 5) == 3)
        #expect(DockProfilePickerReorder.target(start: 2, translation: -61, pitch: 40, count: 5) == 0)
        #expect(DockProfilePickerReorder.target(start: 2, translation: -500, pitch: 40, count: 5) == 0)
        #expect(DockProfilePickerReorder.target(start: 2, translation: 500, pitch: 40, count: 5) == 4)
        #expect(DockProfilePickerReorder.target(start: 0, translation: 80, pitch: 40, count: 0) == 0)
    }

    @Test func draggingMovesBeforeOrAfterAndPersists() {
        let suite = "profile-drag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bots = profiles(["a", "b", "c"])
        let order = DockProfilePickerOrder(defaults: defaults)
        order.move("a", relativeTo: "c", after: true, in: bots)
        #expect(order.ordered(bots).map(\.id) == ["b", "c", "a"])
        order.move("a", relativeTo: "b", after: false, in: bots)
        #expect(DockProfilePickerOrder(defaults: defaults).ordered(bots).map(\.id) == ["a", "b", "c"])
        order.move("a", relativeTo: "missing", after: false, in: bots)
        order.move("a", relativeTo: "a", after: true, in: bots)
        #expect(order.ordered(bots).map(\.id) == ["a", "b", "c"])
    }

    private func profiles(_ ids: [String]) -> [BotSummary] {
        ids.map { id in
            BotSummary(
                id: id, name: id, title: nil, description: nil, model: nil,
                isActive: false, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
                isHidden: false, hasAvatar: false, isDefault: false)
        }
    }

    @Test func movesAndPersistsWithoutChangingProfiles() {
        let suite = "profile-order-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bots = ["a", "b", "c"].map { id in
            BotSummary(
                id: id, name: id, title: nil, description: nil, model: nil,
                isActive: false, chat: BotChatReference(sessionID: "chat-\(id)", profileID: id),
                worker: BotWorkerReference(sessionID: "worker-\(id)", source: nil, title: nil, lastActive: nil),
                avatarURL: nil, preview: nil, lastActive: nil,
                isHidden: false, hasAvatar: false, isDefault: id == "a")
        }
        let order = DockProfilePickerOrder(defaults: defaults)
        order.move("b", by: -1, in: bots)
        #expect(order.ordered(bots).map(\.id) == ["b", "a", "c"])
        #expect(DockProfilePickerOrder(defaults: defaults).ordered(bots) == [bots[1], bots[0], bots[2]])
        order.move("b", by: -1, in: bots)
        #expect(order.ordered([]).isEmpty)
        #expect(order.ordered(bots).map(\.id) == ["b", "a", "c"])
        order.move("b", by: 1, in: bots)
        #expect(order.ordered(bots) == bots)
        order.move("a", by: -1, in: bots)
        order.move("c", by: 1, in: bots)
        order.move("missing", by: 1, in: bots)
        order.move("a", by: 2, in: bots)
        #expect(order.ordered(bots) == bots)
        defaults.set(["c", "c", "missing", ""], forKey: "herm.sidebar.profilePickerOrder")
        let restored = DockProfilePickerOrder(defaults: defaults)
        #expect(restored.ordered(bots).map(\.id) == ["c", "a", "b"])
        #expect(restored.ordered([bots[0], bots[2]]).map(\.id) == ["c", "a"])
        #expect(restored.ordered([]).isEmpty)
        #expect(restored.ordered(bots).map(\.id) == ["c", "a", "b"])
        restored.move("a", by: 1, in: [bots[0]])
        #expect(restored.ordered([bots[0]]) == [bots[0]])
        let hidden = BotSummary(
            id: "hidden", name: "hidden", title: nil, description: nil, model: nil,
            isActive: false, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
            isHidden: true, hasAvatar: false, isDefault: false)
        #expect(restored.ordered([hidden] + bots) == [bots[2], bots[0], bots[1]])
        defaults.set("not an array", forKey: "herm.sidebar.profilePickerOrder")
        #expect(DockProfilePickerOrder(defaults: defaults).ordered(bots) == bots)
        defaults.set(["c", 42] as [Any], forKey: "herm.sidebar.profilePickerOrder")
        #expect(DockProfilePickerOrder(defaults: defaults).ordered(bots) == bots)
    }
}
