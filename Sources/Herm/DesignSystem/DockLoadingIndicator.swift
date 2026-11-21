import SwiftUI

/// Indeterminate work in a control, a status slot, or a loading state.
struct DockLoadingIndicator: View {
    @Environment(\.controlSize) private var controlSize
    @DockChromeTheme private var theme
    private let title: LocalizedStringKey?
    private let size: CGFloat?
    private let color: Color?
    private let paused: Bool

    init(_ title: LocalizedStringKey? = nil, size: CGFloat? = nil, color: Color? = nil, paused: Bool = false) {
        self.title = title
        self.size = size
        self.color = color
        self.paused = paused
    }

    var body: some View {
        if let title {
            VStack(spacing: 4) {
                mark.accessibilityHidden(true)
                Text(title)
                    .dockFont(.metadata)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
        } else {
            mark.accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading")
        }
    }

    private var mark: some View {
        let side = size ?? defaultSize
        return DockLayerMotion(
            kind: .loading, color: color ?? DockThemePalette(theme: theme).accent,
            paused: paused || !theme.style.animates
        )
        .frame(width: side, height: side)
    }

    private var defaultSize: CGFloat {
        switch controlSize {
        case .mini: 10
        case .small: 16
        default: 32
        }
    }
}
