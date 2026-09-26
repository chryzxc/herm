import CoreGraphics

/// Presentation sizing for the dedicated Explorer workspace. These values are
/// intentionally independent from the sidebar concept and conversation layout.
struct ExplorerWorkspaceMetrics: Equatable {
    static let initialNavigatorWidth: CGFloat = 280
    static let minimumNavigatorWidth: CGFloat = 220
    static let maximumNavigatorWidth: CGFloat = 360
    static let minimumEditorWidth: CGFloat = 480
    static let treeRowHeight: CGFloat = 30
    static let headerHeight: CGFloat = 44
}
