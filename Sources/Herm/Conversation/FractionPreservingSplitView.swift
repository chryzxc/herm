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
    private var lastAppliedWidth: CGFloat = 0

    /// The trailing pane stays in the hierarchy (so its SwiftUI state lives on)
    /// but is squeezed to zero width instead of being hidden, which AppKit
    /// does not reliably hand back to the leading pane.
    private(set) var isTrailingCollapsed = false

    var minimumLeadingPosition: CGFloat {
        if isTrailingCollapsed { return collapsedLeadingPosition }
        // Preserve readable navigation when the workspace cannot fit both minimums.
        return min(minimumLeadingWidth, max(0, bounds.width - dividerThickness))
    }

    var maximumLeadingPosition: CGFloat {
        if isTrailingCollapsed { return collapsedLeadingPosition }
        let availableMaximum = max(minimumLeadingPosition, bounds.width - dividerThickness - minimumTrailingWidth)
        return min(maximumLeadingWidth ?? availableMaximum, availableMaximum)
    }

    private var collapsedLeadingPosition: CGFloat { max(0, bounds.width - dividerThickness) }

    func setTrailingCollapsed(_ collapsed: Bool) {
        guard collapsed != isTrailingCollapsed, let trailing = arrangedSubviews.last else { return }
        isTrailingCollapsed = collapsed
        trailing.wantsLayer = true
        trailing.layer?.masksToBounds = true
        // Re-derive the divider from the stored fraction when the pane returns.
        lastAppliedWidth = 0
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            self?.layoutSubtreeIfNeeded()
            self?.arrangedSubviews.last?.needsLayout = true
        }
    }

    private func invalidatePositions() {
        lastAppliedWidth = 0
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
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
            ? arrangedSubviews[0].frame.width
            : bounds.width * (fraction ?? 0.30)
        let position = min(max(proposed, minimumLeadingPosition), maximumLeadingPosition)
        setPosition(position, ofDividerAt: 0)
    }
}
