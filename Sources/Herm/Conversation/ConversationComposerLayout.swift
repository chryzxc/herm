import SwiftUI

/// Keeps the same composer mounted as an empty chat becomes a conversation.
struct ConversationComposerLayout<Transcript: View, Composer: View>: View {
    let showsWelcome: Bool
    let hermFaceID: String?
    var trailingContentInset: CGFloat = 0
    @ViewBuilder var transcript: Transcript
    @ViewBuilder var composer: Composer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if showsWelcome {
                    Spacer(minLength: 0)
                        .frame(maxHeight: .infinity)
                    StartupAssistantView(hermFaceID: hermFaceID)
                        .fixedSize(horizontal: false, vertical: true)
                        .dockPadding(.trailing, trailingContentInset)
                        .dockPadding(.bottom, 12)
                        .transition(.opacity)
                } else {
                    transcript
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
            }
            composer
            Spacer(minLength: 0)
                .frame(maxHeight: showsWelcome ? .infinity : 0)
        }
        .animation(
            reduceMotion || !DockThemeStyle.current.animates
                ? nil : .spring(response: 0.45, dampingFraction: 0.9),
            value: showsWelcome
        )
    }
}
