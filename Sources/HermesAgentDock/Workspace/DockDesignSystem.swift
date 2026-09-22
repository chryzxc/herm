import SwiftUI

/// Central presentation contract for Dock-owned interfaces. Feature views use
/// these semantic roles rather than introducing near-duplicate font sizes,
/// row heights, and compact control treatments.
enum DockTypography {
    static let pageTitle: Font = .system(size: 16, weight: .semibold)
    static let sectionLabel: Font = .system(size: 10, weight: .semibold, design: .monospaced)
    static let rowTitle: Font = .system(size: 12, weight: .medium)
    static let body: Font = .system(size: 12)
    static let control: Font = .system(size: 12, weight: .medium)
    static let metadata: Font = .system(size: 11)
    static let machineMetadata: Font = .system(size: 11, design: .monospaced)
    static let compactStatus: Font = .system(size: 10, weight: .semibold, design: .monospaced)
}
enum DockSpacing {
    static let micro: CGFloat = 4
    static let tight: CGFloat = 6
    static let control: CGFloat = 8
    static let group: CGFloat = 12
    static let section: CGFloat = 16
    static let page: CGFloat = 20
}

enum DockControlMetrics {
    static let compactHeight: CGFloat = 28
    static let standardHeight: CGFloat = 36
    static let hitTarget: CGFloat = 44
    static let cornerRadius: CGFloat = 8
    static let paneRadius: CGFloat = 10
    static let rowHeight: CGFloat = 44
    static let denseRowHeight: CGFloat = 36
}

/// Shared segmented-control treatment for mutually exclusive local scopes.
/// It intentionally retains native macOS behavior while giving every page the
/// same compact geometry and palette-aware surrounding spacing.
extension View {
    func dockSegmentedControl() -> some View {
        self
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(minHeight: DockControlMetrics.standardHeight)
    }
}
