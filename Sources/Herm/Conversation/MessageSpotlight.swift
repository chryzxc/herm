import SwiftUI

/// Focus effect for the message a jump lands on: a light sweeps across its bubble
/// while a ring ripples outward, and the rest of the transcript dims (see the row
/// modifiers in `ConversationTranscriptView`).
struct MessageSpotlightEffect: View {
    let shape: AnyShape
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rippled = false
    @State private var swept = false

    var body: some View {
        ZStack {
            shape.fill(Color.dockAccent.opacity(0.08))
            if !reduceMotion {
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [.clear, Color.dockAccent.opacity(0.28), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 0.35)
                    .offset(x: swept ? geometry.size.width : -geometry.size.width * 0.35)
                }
                .clipShape(shape)
                shape
                    .stroke(Color.dockAccent.opacity(rippled ? 0 : 0.7), lineWidth: 2)
                    .scaleEffect(rippled ? 1.06 : 1)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9)) { swept = true }
            withAnimation(.easeOut(duration: 1.2)) { rippled = true }
        }
    }
}

extension View {
    /// Highlights (and, for compact bubbles, lifts) this view while `active`; the effect follows `shape`.
    func messageSpotlight(_ active: Bool, shape: AnyShape, lifts: Bool = true, reduceMotion: Bool) -> some View {
        scaleEffect(active && lifts && !reduceMotion ? 1.03 : 1)
            .overlay {
                if active { MessageSpotlightEffect(shape: shape).transition(.opacity) }
            }
    }
}
