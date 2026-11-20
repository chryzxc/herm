import Observation
import SwiftUI

/// Kept in row state for identity, but observed only by decorative leaves.
@MainActor @Observable
final class ConversationRowHoverPresentation {
    var isHovering = false
}

struct ConversationRowHoverTimestamp: View {
    let text: String
    let hover: ConversationRowHoverPresentation
    var alwaysVisible = false
    #if DEBUG
        @Environment(\.conversationRowEvaluation) private var evaluation
    #endif

    var body: some View {
        let opacity: Double = hover.isHovering || alwaysVisible ? 1 : 0
        #if DEBUG
            let _ = evaluation?("timestamp", opacity)
        #endif
        Text(text).opacity(opacity)
    }
}

struct ConversationRowHoverBackground: View {
    let hover: ConversationRowHoverPresentation
    let isExpanded: Bool
    #if DEBUG
        @Environment(\.conversationRowEvaluation) private var evaluation
    #endif

    var body: some View {
        let opacity = hover.isHovering || isExpanded ? 0.05 : 0
        #if DEBUG
            let _ = evaluation?("background", opacity)
        #endif
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.dockPrimaryText.opacity(opacity))
    }
}

#if DEBUG
    /// Hosted tests record production evaluations without global mutable hooks.
    private struct ConversationRowEvaluationKey: EnvironmentKey {
        static let defaultValue: (@MainActor @Sendable (String, Double) -> Void)? = nil
    }

    extension EnvironmentValues {
        var conversationRowEvaluation: (@MainActor @Sendable (String, Double) -> Void)? {
            get { self[ConversationRowEvaluationKey.self] }
            set { self[ConversationRowEvaluationKey.self] = newValue }
        }
    }
#endif

/// The metadata and action line under a message, shared by user and assistant rows so their
/// order and gaps stay in one place. `anchor` is the side the bubble hugs: always-shown actions
/// sit there, status next to them, and hover-only metadata at the outer edge, so its hidden slot
/// never opens a gap between visible items.
struct ConversationMessageFooter<HoverOnly: View, Status: View, Actions: View>: View {
    enum Anchor { case leading, trailing }

    let anchor: Anchor
    @ViewBuilder let hoverOnly: () -> HoverOnly
    @ViewBuilder let status: () -> Status
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 0) {
            switch anchor {
            case .trailing:
                HStack(spacing: ConversationMessageFooterMetrics.itemSpacing) {
                    hoverOnly()
                    status()
                }
                actions()
            case .leading:
                actions()
                HStack(spacing: ConversationMessageFooterMetrics.itemSpacing) {
                    status()
                    hoverOnly()
                }
            }
        }
    }
}

enum ConversationMessageFooterMetrics {
    /// Gap between footer metadata items. Action buttons sit flush beside them: their 24pt
    /// boxes already inset a 12pt glyph by this much, so every visible gap reads the same.
    static let itemSpacing: CGFloat = 6
}
