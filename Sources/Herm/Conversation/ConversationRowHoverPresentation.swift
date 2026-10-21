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
