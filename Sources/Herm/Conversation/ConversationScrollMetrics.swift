import AppKit
import Combine
import SwiftUI
import Foundation
import UniformTypeIdentifiers

enum ConversationScrollMetrics {
    // Streaming rows grow while the viewport is parked at the bottom; the
    // sticky-bottom check must tolerate that transient growth so auto-scroll
    // is not suppressed before the settle re-assertion runs.
    static let atBottomTolerance: CGFloat = 96
    static let pastEndTolerance: CGFloat = 1

    static func isAtBottom(
        bottomMaxY: CGFloat,
        viewportHeight: CGFloat,
        tolerance: CGFloat = atBottomTolerance
    ) -> Bool {
        bottomMaxY >= viewportHeight - pastEndTolerance
            && bottomMaxY <= viewportHeight + tolerance
    }

    static func isAtBottom(
        topMinY: CGFloat,
        bottomMaxY: CGFloat,
        viewportHeight: CGFloat,
        tolerance: CGFloat = atBottomTolerance
    ) -> Bool {
        // A transcript that fits without scrolling has one legal origin: zero.
        // It is therefore both at the top and at the bottom; treating it as
        // browsing produces a false unread badge on the next append.
        if topMinY >= -pastEndTolerance,
           bottomMaxY <= viewportHeight + pastEndTolerance {
            return true
        }
        return isAtBottom(bottomMaxY: bottomMaxY, viewportHeight: viewportHeight, tolerance: tolerance)
    }

    /// The content is visibly above the viewport bottom despite having already
    /// been scrolled upward. Unlike a short transcript at origin zero, this is
    /// an invalid trailing scroll position and must be clamped to the footer.
    static func isPastEnd(
        topMinY: CGFloat,
        bottomMaxY: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        topMinY < -pastEndTolerance
            && bottomMaxY < viewportHeight - pastEndTolerance
    }
}
