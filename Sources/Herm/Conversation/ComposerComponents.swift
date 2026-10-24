import SwiftUI

struct ComposerControlLabel: View {
    let icon: Ph

    var body: some View {
        DockIcon(icon, size: 14, color: Color.dockSecondaryText)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .fill(DockSkinPresentation.current.composerControlFill)
            )
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
    }
}

struct ComposerSubmitLabel<Content: View>: View {
    let isEnabled: Bool
    var isFullscreen = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            (DockSkinPresentation.current.composer != .floating
                ? AnyShape(DockThemeShape(cornerRadius: DockLayout.controlRadius))
                : AnyShape(Circle()))
                .fill(isEnabled ? Color.dockAccent : Color.dockSurface6)
                .frame(width: isFullscreen ? 36 : 32, height: isFullscreen ? 36 : 32)
            content()
        }
    }
}

struct ComposerInputSurface: ViewModifier {
    let isFocused: Bool
    var isRecording = false
    var isPulsing = false

    func body(content: Content) -> some View {
        content.background {
            let skin = DockSkinPresentation.current
            let shape = DockThemeShape(cornerRadius: skin.composerRadius, role: .pane)
            if skin.composer == .line {
                Rectangle()
                    .fill(
                        isRecording ? Color.dockDestructiveFill : isFocused ? Color.dockAccent : Color.dockPrimaryText
                    )
                    .frame(height: isFocused ? 2 : 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            } else {
                shape.dockInputFill()
                    .overlay {
                        shape.stroke(
                            isRecording
                                ? Color.dockDestructive.opacity(isPulsing ? 0.65 : 0.28)
                                : (isFocused ? Color.dockAccent.opacity(0.42) : Color.dockBorder),
                            lineWidth: isFocused || isRecording ? max(1, DockLayout.outline) : DockLayout.outline
                        )
                        .opacity(DockLayout.outline > 0 || isFocused || isRecording ? 1 : 0)
                    }
                    .dockStickerShadow(shape)
                    .dockFoldCrease()
                    .dockEmboss(shape)
                    .dockBevel(pressed: true)
                    .dockCardMarks()
                    .shadow(
                        color: Color.black.opacity(0.10), radius: skin.composerShadow,
                        y: skin.composerShadow == 0 ? 0 : 2)
            }
        }
    }
}
