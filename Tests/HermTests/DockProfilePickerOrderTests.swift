import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct DockProfilePickerOrderTests {
    /// A held pointer at the top of an overflow list walks the last profile to slot zero
    /// inside one drag, using the real clip's travel rather than repeated pointer events.
    @Test func heldTopEdgeScrollsLastProfileToFirst() throws {
        let scroll = try overflowClip(documentHeight: 852)
        let clip = scroll.contentView
        let startOrigin = clip.bounds.minY
        #expect(DockEdgeAutoscroll.direction(pointerY: 2, viewport: viewport) == .towardStart)
        var target = DockProfilePickerReorder.target(start: 19, translation: 0, pitch: 40, count: 20)
        var steps = 0
        while steps < 200 {
            let direction = try #require(DockEdgeAutoscroll.direction(pointerY: 2, viewport: viewport))
            let next = DockEdgeAutoscroll.origin(
                from: clip.bounds.minY, direction: direction, clip: clip.bounds,
                documentHeight: 852, isFlipped: clip.isFlipped)
            guard next != clip.bounds.minY else { break }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: next))
            scroll.reflectScrolledClipView(clip)
            target = DockProfilePickerReorder.target(
                start: 19,
                translation: DockEdgeAutoscroll.displacement(
                    translation: 0, startOrigin: startOrigin, origin: clip.bounds.minY,
                    isFlipped: clip.isFlipped),
                pitch: 40, count: 20)
            steps += 1
        }
        #expect(steps > 40, "~800pt of hidden rows must take many held-pointer steps")
        #expect(
            DockEdgeAutoscroll.origin(
                from: clip.bounds.minY, direction: .towardStart, clip: clip.bounds,
                documentHeight: 852, isFlipped: clip.isFlipped) == clip.bounds.minY,
            "The clip must stop at its first row, not scroll past it")
        #expect(target == 0, "The dragged profile must land first after All")
    }

    /// Reversing to the bottom edge scrolls the same drag back to the last slot, then stops.
    @Test func reversedEdgeScrollReachesTheLastProfileAndStops() throws {
        let scroll = try overflowClip(documentHeight: 852)
        let clip = scroll.contentView
        let startOrigin = clip.bounds.minY
        scrollToStart(scroll)
        var target = 0
        var steps = 0
        while steps < 200 {
            let next = DockEdgeAutoscroll.origin(
                from: clip.bounds.minY, direction: .towardEnd, clip: clip.bounds,
                documentHeight: 852, isFlipped: clip.isFlipped)
            guard next != clip.bounds.minY else { break }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: next))
            scroll.reflectScrolledClipView(clip)
            target = DockProfilePickerReorder.target(
                start: 19,
                translation: DockEdgeAutoscroll.displacement(
                    translation: 0, startOrigin: startOrigin, origin: clip.bounds.minY,
                    isFlipped: clip.isFlipped),
                pitch: 40, count: 20)
            steps += 1
        }
        #expect(steps > 40)
        #expect(target == 19)
        #expect(
            DockEdgeAutoscroll.origin(
                from: clip.bounds.minY, direction: .towardEnd, clip: clip.bounds,
                documentHeight: 852, isFlipped: clip.isFlipped) == clip.bounds.minY)
    }

    /// Between the bands nothing moves, and a neighbour's clip keeps its own offset.
    @Test func edgesOnlyMoveTheirOwnClipBetweenTheBands() throws {
        let list = try overflowClip(documentHeight: 852)
        let neighbour = try overflowClip(documentHeight: 852)
        let neighbourOrigin = neighbour.contentView.bounds.minY
        #expect(DockEdgeAutoscroll.direction(pointerY: viewport.midY, viewport: viewport) == nil)
        #expect(
            DockEdgeAutoscroll.direction(
                pointerY: viewport.maxY - 2, viewport: viewport) == .towardEnd)
        scrollToStart(list)
        #expect(list.contentView.bounds.minY != neighbourOrigin)
        #expect(neighbour.contentView.bounds.minY == neighbourOrigin)
    }

    /// Drag translation alone still picks the slot when the list does not move.
    @Test func travelIsZeroWithoutScrolling() {
        let origin: CGFloat = 120
        #expect(DockEdgeAutoscroll.travel(from: origin, to: origin, isFlipped: true) == 0)
        #expect(
            DockEdgeAutoscroll.displacement(
                translation: -44, startOrigin: origin, origin: origin, isFlipped: true) == -44)
    }

    /// A clip that draws its document upward scrolls the other way and clamps at both ends.
    @Test func unflippedClipMovesItsOriginTheOtherWay() {
        let clip = CGRect(x: 0, y: -300, width: 300, height: 360)
        #expect(
            DockEdgeAutoscroll.origin(
                from: -100, direction: .towardStart, clip: clip, documentHeight: 852, isFlipped: false) == -90)
        #expect(
            DockEdgeAutoscroll.origin(
                from: 0, direction: .towardStart, clip: clip, documentHeight: 852, isFlipped: false) == 0)
        #expect(
            DockEdgeAutoscroll.origin(
                from: -492, direction: .towardEnd, clip: clip, documentHeight: 852, isFlipped: false) == -492)
    }

    private var viewport: CGRect { CGRect(x: 0, y: 0, width: 300, height: 360) }

    /// Runs the top-edge steps a held pointer would run until the clip reaches its first row.
    private func scrollToStart(_ scroll: NSScrollView) {
        let clip = scroll.contentView
        while let direction = DockEdgeAutoscroll.direction(pointerY: 2, viewport: viewport) {
            let next = DockEdgeAutoscroll.origin(
                from: clip.bounds.minY, direction: direction, clip: clip.bounds,
                documentHeight: 852, isFlipped: clip.isFlipped)
            guard next != clip.bounds.minY else { break }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: next))
            scroll.reflectScrolledClipView(clip)
        }
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
        let bots = ["a", "b", "c"].map { id in
            BotSummary(
                id: id, name: id, title: nil, description: nil, model: nil,
                isActive: false, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
                isHidden: false, hasAvatar: false, isDefault: false)
        }
        let order = DockProfilePickerOrder(defaults: defaults)
        order.move("a", relativeTo: "c", after: true, in: bots)
        #expect(order.ordered(bots).map(\.id) == ["b", "c", "a"])
        order.move("a", relativeTo: "b", after: false, in: bots)
        #expect(DockProfilePickerOrder(defaults: defaults).ordered(bots).map(\.id) == ["a", "b", "c"])
        order.move("a", relativeTo: "missing", after: false, in: bots)
        order.move("a", relativeTo: "a", after: true, in: bots)
        #expect(order.ordered(bots).map(\.id) == ["a", "b", "c"])
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
