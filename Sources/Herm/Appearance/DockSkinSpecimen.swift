import SwiftUI

/// A material and typography specimen, never a projection of session activity.
/// Explicit theme inputs let every tile render without changing the global theme.
struct DockSkinSpecimen: View {
    let theme: DockThemeID
    @Environment(\.colorScheme) private var colorScheme

    private var palette: DockThemePalette { DockThemePalette(theme: theme) }
    private var style: DockThemeStyle { theme.style }
    private var panel: DockThemeShape {
        DockThemeShape(cornerRadius: style.paneRadius, role: .pane, geometry: style.geometry)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                selection
                Circle().fill(palette.secondaryText.opacity(0.3)).frame(width: 6, height: 6)
                Circle().fill(palette.secondaryText.opacity(0.3)).frame(width: 6, height: 6)
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .frame(width: 38)
            .frame(maxHeight: .infinity)
            .background(palette.surface2)

            VStack(alignment: .leading, spacing: 12) {
                Text("Herm")
                    .font(.system(size: 16, weight: .semibold, design: style.fontDesign))
                    .foregroundStyle(palette.primaryText)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Aa")
                        .font(.system(size: 16, weight: .semibold, design: style.fontDesign))
                        .foregroundStyle(palette.primaryText)
                    Text("012")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.secondaryText)
                    Spacer(minLength: 0)
                    Circle().fill(palette.accent).frame(width: 7, height: 7)
                }
                .padding(10)
                .background { surface }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 112)
        // Native-material tokens are translucent; the specimen needs a solid base.
        .background(palette.windowBackground.overlay(DockBackdrop(style: style, accent: palette.accent)))
        .background(theme.appearance == .dark || (theme.appearance == .system && colorScheme == .dark) ? Color.black : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var selection: some View {
        let shape = DockThemeShape(cornerRadius: style.controlRadius, geometry: style.geometry)
        return Text("H")
            .font(.system(size: 12, weight: .semibold, design: style.fontDesign))
            .foregroundStyle(style.selection == .invert ? palette.background : palette.accent)
            .frame(width: 26, height: 26)
            .dockSelectionBackground(shape, active: true, fill: palette.selectedFill, theme: theme)
    }

    @ViewBuilder private var surface: some View {
        if style.chrome == .open {
            Color.clear.overlay(alignment: .bottom) { palette.accent.frame(height: 2) }
        } else {
            panel.fill(palette.surface)
                .overlay {
                    if style.material == .glass {
                        panel.stroke(LinearGradient(colors: [palette.primaryText.opacity(0.5), palette.divider.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    } else if style.outlineWidth > 0 {
                        panel.stroke(palette.divider.opacity(style.outlineWidth > 1 ? 1 : 0.6), lineWidth: style.outlineWidth)
                    }
                }
                .dockStickerShadow(panel, theme: theme)
                .dockEmboss(panel, theme: theme)
                .dockFoldCrease(theme: theme)
                .dockBevel(enabled: style.bevel)
                .dockCardMarks(theme: theme)
                .shadow(color: palette.accent.opacity(style.glow > 0 ? 0.12 : 0), radius: style.glow)
                .shadow(color: .black.opacity(style.cardShadow > 0 ? 0.12 : 0), radius: style.cardShadow / 2, y: 2)
        }
    }
}
