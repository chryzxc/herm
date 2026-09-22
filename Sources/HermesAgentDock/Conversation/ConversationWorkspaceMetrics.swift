import CoreGraphics

/// Presentation geometry shared by the fullscreen and compact conversation
/// surfaces. It is intentionally independent from sidebar brand concepts.
struct ConversationWorkspaceMetrics: Equatable {
    let headerHeight: CGFloat
    let contentInset: CGFloat
    let readingWidth: CGFloat
    let userMessageWidthFraction: CGFloat
    let composerInset: CGFloat
    let composerMaxWidth: CGFloat
    let composerTopInset: CGFloat
    let composerBottomInset: CGFloat
    let usesCompactToolbarLabels: Bool

    static func resolve(isFullscreen: Bool) -> Self {
        if isFullscreen {
            return Self(
                headerHeight: 56,
                contentInset: 24,
                readingWidth: 760,
                userMessageWidthFraction: 0.72,
                composerInset: 20,
                composerMaxWidth: 760,
                composerTopInset: 16,
                composerBottomInset: 14,
                usesCompactToolbarLabels: false
            )
        }
        return Self(
            headerHeight: 52,
            contentInset: 12,
            readingWidth: 760,
            userMessageWidthFraction: 0.84,
            composerInset: 12,
            composerMaxWidth: 760,
            composerTopInset: 12,
            composerBottomInset: 10,
            usesCompactToolbarLabels: true
        )
    }
}
