import SwiftUI

/// macOS's default disclosure only toggles from its caret; make the header a button.
struct DockDisclosureGroupStyle: DisclosureGroupStyle {
    var alignment: VerticalAlignment = .center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion || !DockThemeStyle.current.animates ? nil : .dockEase(duration: 0.18)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(alignment: alignment, spacing: 6) {
                    DockIcon(.caretRight, size: 10, color: .dockSecondaryText)
                        .frame(height: 14)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

            DockRetainedDisclosureContent(isExpanded: configuration.isExpanded) {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dockPadding(.leading, 16)
            }
        }
    }
}

/// Mount on first use, then keep nested inputs and disclosures alive while closed.
struct DockRetainedDisclosureContent<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isExpanded: Bool
    @ViewBuilder var content: () -> Content
    @State private var hasExpanded = false

    var body: some View {
        Group {
            if isExpanded || hasExpanded {
                content()
                    .offset(
                        y: isExpanded || !DockMotion.isEnabled(reduceMotion: reduceMotion)
                            ? 0 : -DockMotion.revealDistance
                    )
                    .frame(height: isExpanded ? nil : 0, alignment: .top)
                    .clipped()
                    .opacity(isExpanded ? 1 : 0)
                    .disabled(!isExpanded)
                    .allowsHitTesting(isExpanded)
                    .accessibilityHidden(!isExpanded)
                    .transition(.opacity.combined(with: .offset(y: -DockMotion.revealDistance)))
            }
        }
        .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.2), value: isExpanded)
        .onChange(of: isExpanded, initial: true) { _, expanded in
            if expanded { hasExpanded = true }
        }
    }
}
