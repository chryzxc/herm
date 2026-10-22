import SwiftUI

/// Compact visible tabs inside full-height hit targets in the conversation header.
struct SessionModeTabStrip: View {
    let modes: [DockPopover.SessionWorkspaceMode]
    let selectedMode: DockPopover.SessionWorkspaceMode
    let style: DockThemePalette
    let onSelect: (DockPopover.SessionWorkspaceMode) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = DockThemeShape(cornerRadius: DockControlMetrics.cornerRadius)
        let segment = DockThemeShape(cornerRadius: DockControlMetrics.cornerRadius - 2)
        let selection = style.theme.style.selection
        let selectedInk = selection == .invert ? style.background : style.primaryText
        HStack(spacing: 0) {
            ForEach(modes) { mode in
                let isSelected = mode == selectedMode
                Button { onSelect(mode) } label: {
                    Text(mode == .pullRequests ? "PRs" : mode.label)
                        .dockFont(size: 12, weight: isSelected ? .semibold : .medium)
                        .foregroundStyle(isSelected ? selectedInk : style.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(minWidth: DockControlMetrics.hitTarget, minHeight: DockControlMetrics.compactHeight)
                        .dockSelectionBackground(segment, active: isSelected, fill: style.selectedFill, theme: style.theme)
                        .overlay(alignment: .bottom) {
                            if isSelected && selection != .underline {
                                Capsule().fill(selection == .invert ? selectedInk : style.accent)
                                    .frame(width: 16, height: 2)
                                    .padding(.bottom, 2)
                            }
                        }
                        .frame(height: DockControlMetrics.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .help(mode.help)
                .accessibilityLabel(mode.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 2)
        .background {
            shape.fill(style.surface4.opacity(0.5))
                .overlay(shape.stroke(style.divider, lineWidth: DockLayout.hairline))
                .frame(height: DockControlMetrics.compactHeight + 4)
        }
        .fixedSize()
        .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: selectedMode)
    }
}
