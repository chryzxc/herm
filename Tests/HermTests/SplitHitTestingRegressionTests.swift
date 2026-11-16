import AppKit
import Testing

@testable import Herm

@MainActor
@Suite(.serialized)
struct SplitHitTestingRegressionTests {
    private enum Pane: Sendable, CaseIterable {
        case leading
        case trailing
    }

    private enum Edge: Sendable, CaseIterable {
        case leading
        case trailing
    }

    @Test(arguments: Pane.allCases, Edge.allCases)
    func expandedSplitDoesNotVisitUnrelatedPane(pane: Pane, edge: Edge) {
        let fixture = SplitFixture()
        defer { fixture.close() }
        let target = fixture.pane(pane)
        let sibling = fixture.pane(pane == .leading ? .trailing : .leading)
        #expect(target.bounds.width > 2, "fixture must give the pane a real frame")
        let point = target.convert(target.probePoint(at: edge), to: fixture.parent)
        let hit = fixture.split.hitTest(point)
        #expect(hit === target)
        #expect(target.calls == 1)
        #expect(sibling.calls == 0)
    }

    @Test(arguments: Pane.allCases)
    func collapsedSplitRoutesInputToTheVisiblePane(collapsedPane: Pane) {
        let fixture = SplitFixture()
        defer { fixture.close() }
        switch collapsedPane {
        case .leading:
            fixture.split.setCollapsed(leading: true, trailing: false)
        case .trailing:
            fixture.split.setCollapsed(leading: false, trailing: true)
        }
        fixture.relayout()
        let visible = fixture.pane(collapsedPane == .leading ? .trailing : .leading)
        let hidden = fixture.pane(collapsedPane)
        #expect(visible.bounds.width > 500, "visible pane must fill the collapsed split")
        let point = visible.convert(
            NSPoint(x: visible.bounds.midX, y: visible.bounds.midY), to: fixture.parent)
        let hit = fixture.split.hitTest(point)
        #expect(hit === visible)
        #expect(visible.calls == 1)
        #expect(hidden.calls == 0)
    }

    @Test func pointOutsideSplitBoundsAsksNoPane() {
        let fixture = SplitFixture()
        defer { fixture.close() }
        let point = NSPoint(x: fixture.split.frame.maxX + 20, y: fixture.split.frame.midY)
        let hit = fixture.split.hitTest(point)
        #expect(hit == nil)
        #expect(fixture.leading.calls == 0)
        #expect(fixture.trailing.calls == 0)
    }

    @Test func nestedExpandedSplitVisitsOnlyThePaneUnderThePoint() {
        _ = NSApplication.shared
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))
        let outer = FractionPreservingSplitView(frame: NSRect(x: 40, y: 30, width: 1000, height: 600))
        outer.isVertical = true
        outer.dividerStyle = .thin
        parent.addSubview(outer)
        let window = NSWindow(
            contentRect: parent.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = parent
        defer { window.orderOut(nil) }

        let inner = FractionPreservingSplitView(frame: .zero)
        inner.isVertical = true
        inner.dividerStyle = .thin
        let innerLeading = CountingPane()
        let innerTrailing = CountingPane()
        inner.addArrangedSubview(innerLeading)
        inner.addArrangedSubview(innerTrailing)
        let outerTrailing = CountingPane()
        outer.addArrangedSubview(inner)
        outer.addArrangedSubview(outerTrailing)
        outer.adjustSubviews()
        outer.setPosition(500, ofDividerAt: 0)
        outer.layoutSubtreeIfNeeded()
        inner.layout()
        inner.setPosition(200, ofDividerAt: 0)
        inner.layoutSubtreeIfNeeded()
        #expect(innerLeading.bounds.width > 2, "nested fixture must give the pane a real frame")
        #expect(innerTrailing.frame.minX > innerLeading.frame.maxX)

        let point = innerLeading.convert(
            NSPoint(x: innerLeading.bounds.midX, y: innerLeading.bounds.midY), to: parent)
        let hit = outer.hitTest(point)
        #expect(hit === innerLeading)
        #expect(innerLeading.calls == 1)
        #expect(innerTrailing.calls == 0)
        #expect(outerTrailing.calls == 0)
    }

    @Test func dividerGapMatchesPlainSplitView() {
        let fixture = SplitFixture()
        defer { fixture.close() }
        #expect(fixture.trailing.frame.minX > fixture.leading.frame.maxX)

        let plain = NSSplitView(frame: fixture.split.frame)
        plain.isVertical = true
        plain.dividerStyle = .thin
        plain.addArrangedSubview(NSView())
        plain.addArrangedSubview(NSView())
        fixture.parent.addSubview(plain)
        plain.adjustSubviews()
        plain.setPosition(400, ofDividerAt: 0)
        plain.layoutSubtreeIfNeeded()

        let gap = NSPoint(
            x: (fixture.leading.frame.maxX + fixture.trailing.frame.minX) / 2,
            y: fixture.split.bounds.midY)
        let point = fixture.split.convert(gap, to: fixture.parent)
        let fractionHit = fixture.split.hitTest(point)
        let plainHit = plain.hitTest(point)
        #expect((fractionHit == nil) == (plainHit == nil))
        #expect((fractionHit === fixture.split) == (plainHit === plain))
        #expect(fractionHit !== fixture.leading)
        #expect(fractionHit !== fixture.trailing)
    }

    private final class SplitFixture {
        let window: NSWindow
        let parent: NSView
        let split: FractionPreservingSplitView
        let leading: CountingPane
        let trailing: CountingPane

        init() {
            _ = NSApplication.shared
            parent = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))
            split = FractionPreservingSplitView(
                frame: NSRect(x: 40, y: 30, width: 1000, height: 600))
            split.isVertical = true
            split.dividerStyle = .thin
            window = NSWindow(
                contentRect: parent.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            leading = CountingPane()
            trailing = CountingPane()
            window.contentView = parent
            parent.addSubview(split)
            split.addArrangedSubview(leading)
            split.addArrangedSubview(trailing)
            split.adjustSubviews()
            split.setPosition(400, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
            leading.calls = 0
            trailing.calls = 0
        }

        func pane(_ pane: Pane) -> CountingPane {
            pane == .leading ? leading : trailing
        }

        func relayout() {
            split.layout()
            split.layoutSubtreeIfNeeded()
            leading.calls = 0
            trailing.calls = 0
        }

        func close() {
            window.orderOut(nil)
        }
    }

    private final class CountingPane: NSView {
        var calls = 0

        override func hitTest(_ point: NSPoint) -> NSView? {
            calls += 1
            return super.hitTest(point)
        }

        func probePoint(at edge: Edge) -> NSPoint {
            let inset: CGFloat = 1
            let x = edge == .leading ? inset : bounds.width - inset
            return NSPoint(x: x, y: bounds.midY)
        }
    }
}
