import SwiftUI

/// A material, typography and Herm Faces specimen, never a projection of
/// session activity. Explicit theme inputs let every tile render without
/// changing the global theme.
struct DockSkinSpecimen: View {
    let theme: DockThemeID
    /// Sample Bots in states that show each skin's face tone, ring and badges.
    static let faces: [(id: String, mood: BotMood)] = [
        ("nexus", .idle), ("forge", .tool), ("comms", .approval), ("atlas", .done),
    ]
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
                    .dockFont(.pageTitle, weight: .semibold, design: style.fontDesign)
                    .foregroundStyle(palette.primaryText)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Aa")
                        .dockFont(.pageTitle, weight: .semibold, design: style.fontDesign)
                        .foregroundStyle(palette.primaryText)
                    Text("012")
                        .dockFont(.metadata, weight: .regular, design: .monospaced)
                        .foregroundStyle(palette.secondaryText)
                    Spacer(minLength: 0)
                    Circle().fill(palette.accent).frame(width: 7, height: 7)
                }
                .padding(10)
                .background { surface }
                HStack(spacing: 0) {
                    ForEach(Self.faces, id: \.id) { face in
                        if face.id != Self.faces.first?.id {
                            Spacer(minLength: 0)
                        }
                        BotFaceMark(id: face.id, size: 24, mood: face.mood, theme: theme)
                    }
                }
                .padding(.leading, 2)
                .frame(maxWidth: 128)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 148)
        // Native-material tokens are translucent; the specimen needs a solid base.
        .background(palette.windowBackground.overlay(DockBackdrop(style: style, accent: palette.accent)))
        .background(
            theme.appearance == .dark || (theme.appearance == .system && colorScheme == .dark)
                ? Color.black : Color.white
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var selection: some View {
        let shape = DockThemeShape(cornerRadius: style.controlRadius, geometry: style.geometry)
        return Text("H")
            .dockFont(.body, weight: .semibold, design: style.fontDesign)
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
                        panel.stroke(
                            LinearGradient(
                                colors: [palette.primaryText.opacity(0.5), palette.divider.opacity(0.2)],
                                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    } else if style.outlineWidth > 0 {
                        panel.stroke(
                            palette.divider.opacity(style.outlineWidth > 1 ? 1 : 0.6), lineWidth: style.outlineWidth)
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
