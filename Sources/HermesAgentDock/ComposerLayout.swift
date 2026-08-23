import CoreGraphics

enum ComposerLayout {
    static let minHeight: CGFloat = 40
    static let maxHeight: CGFloat = 140

    static func height(for measuredContentHeight: CGFloat) -> CGFloat {
        min(max(measuredContentHeight, minHeight), maxHeight)
    }
}
