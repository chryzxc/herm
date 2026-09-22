import CoreGraphics

enum ComposerLayout {
    static let minHeight: CGFloat = 34
    static let maxHeight: CGFloat = 120
    static let toolbarHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 6
    static let verticalPadding: CGFloat = 8

    static var idleHeight: CGFloat {
        minHeight + toolbarHeight + rowSpacing + (verticalPadding * 2)
    }

    static func height(for measuredContentHeight: CGFloat) -> CGFloat {
        min(max(measuredContentHeight, minHeight), maxHeight)
    }
}

enum ComposerToolbarPresentation {
    static func showsReasoningLabel(for metrics: ConversationWorkspaceMetrics) -> Bool {
        !metrics.usesCompactToolbarLabels
    }
}
