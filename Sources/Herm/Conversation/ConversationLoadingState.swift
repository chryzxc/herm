import SwiftUI

struct ConversationLoadingState: View {
    var minHeight: CGFloat = 120
    var compact = false

    var body: some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 8))
        layout {
            DockLayerMotion(kind: .openingConversation, color: .dockPrimaryText)
                .frame(width: compact ? 28 : 64, height: compact ? 21 : 48)
                .accessibilityHidden(true)
            Text("Loading conversation…")
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
