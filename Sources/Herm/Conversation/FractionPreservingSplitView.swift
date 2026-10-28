import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Window resizes (e.g. entering fullscreen, moving to a larger display, or
/// dragging the window edge) otherwise dump 100% of the size delta into
/// NSSplitView's trailing subview, silently collapsing a fraction-based
/// layout like 30/40/30 back to whatever raw pixel widths were set at
/// launch. Re-derive the leading position from the stored fraction on every
/// resize so proportional splits stay proportional, unless the person has
/// dragged a divider (tracked via delegate resize-subviews callbacks driven
/// by the divider itself rather than the window).
final class FractionPreservingSplitView: NSSplitView {
    // AppKit can paint the divider at the old coordinate after a host/window
    // width change. The hosting view paints the hairline at its real edge;
    // this transparent divider still provides the native drag target.
    override var dividerColor: NSColor { .clear }
    var fraction: CGFloat?
    var minimumLeadingWidth: CGFloat = 220 {
        didSet { if oldValue != minimumLeadingWidth { invalidatePositions() } }
    }
    var maximumLeadingWidth: CGFloat? {
        didSet { if oldValue != maximumLeadingWidth { invalidatePositions() } }
    }
    var minimumTrailingWidth: CGFloat = 360 {
        didSet { if oldValue != minimumTrailingWidth { invalidatePositions() } }
    }
    private var userAdjusted = false
    private var expandedLeadingWidth: CGFloat?
    private var lastAppliedWidth: CGFloat = 0

    /// Collapsed panes stay mounted at zero width so their SwiftUI state survives.
    private(set) var isTrailingCollapsed = false
    private(set) var isLeadingCollapsed = false

    var minimumLeadingPosition: CGFloat {
        if isLeadingCollapsed { return 0 }
        if isTrailingCollapsed { return collapsedLeadingPosition }
        // Preserve readable navigation when the workspace cannot fit both minimums.
        return min(minimumLeadingWidth, max(0, bounds.width - dividerThickness))
    }

    var maximumLeadingPosition: CGFloat {
        if isLeadingCollapsed { return 0 }
        if isTrailingCollapsed { return collapsedLeadingPosition }
        let availableMaximum = max(minimumLeadingPosition, bounds.width - dividerThickness - minimumTrailingWidth)
        return min(maximumLeadingWidth ?? availableMaximum, availableMaximum)
    }

    private var collapsedLeadingPosition: CGFloat { max(0, bounds.width - dividerThickness) }

    func setTrailingCollapsed(_ collapsed: Bool) {
        setCollapsed(leading: false, trailing: collapsed)
    }

    func setCollapsed(leading: Bool, trailing: Bool) {
        guard leading != isLeadingCollapsed || trailing != isTrailingCollapsed else { return }
        if !isLeadingCollapsed, !isTrailingCollapsed {
            expandedLeadingWidth = arrangedSubviews.first?.frame.width
        }
        isLeadingCollapsed = leading
        isTrailingCollapsed = trailing && !leading
        for pane in arrangedSubviews {
            pane.wantsLayer = true
            pane.layer?.masksToBounds = true
        }
        invalidatePositions()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            layoutSubtreeIfNeeded()
            for pane in arrangedSubviews { pane.needsLayout = true }
        }
    }

    private func invalidatePositions() {
        lastAppliedWidth = 0
        needsLayout = true
    }

    /// A collapsed trailing host is zero-width, but its SwiftUI content still
    /// claims clicks past that frame, swallowing the leading pane's edge controls.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if isLeadingCollapsed, let trailing = arrangedSubviews.last {
            return trailing.hitTest(convert(point, from: superview))
        }
        if isTrailingCollapsed, let leading = arrangedSubviews.first {
            return leading.hitTest(convert(point, from: superview))
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isLeadingCollapsed, !isTrailingCollapsed else { return }
        userAdjusted = true
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        // Cache the width we last applied the fraction to so we only call
        // setPosition() when width actually changes, not on every layout pass.
        // This prevents cascading layout invalidations that cause stuttering.
        guard bounds.width > 0, bounds.width != lastAppliedWidth,
            arrangedSubviews.count >= 2
        else { return }
        lastAppliedWidth = bounds.width
        // Passing an out-of-range fraction lets AppKit clamp the subview but
        // leaves its drawn divider at the requested coordinate. This happens
        // when the inspector closes and the window narrows to 720pt.
        let proposed =
            userAdjusted || fraction == nil
            ? (expandedLeadingWidth ?? arrangedSubviews[0].frame.width)
            : bounds.width * (fraction ?? 0.30)
        let position = min(max(proposed, minimumLeadingPosition), maximumLeadingPosition)
        setPosition(position, ofDividerAt: 0)
        if !isLeadingCollapsed, !isTrailingCollapsed { expandedLeadingWidth = nil }
    }
}
