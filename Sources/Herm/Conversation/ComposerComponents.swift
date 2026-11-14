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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isFocused: Bool
    var isRecording = false

    init(isFocused: Bool, isRecording: Bool = false) {
        self.isFocused = isFocused
        self.isRecording = isRecording
    }

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
                // Glass already draws its own rim, so only state strokes (focus, recording) go on top.
                let isGlass = DockThemeStyle.current.material == .glass
                let showsNeutralOutline = DockLayout.outline > 0 && !isGlass
                shape.dockInputFill()
                    .overlay {
                        if isRecording && !reduceMotion && DockThemeStyle.current.animates {
                            TimelineView(.dockMotion()) { timeline in
                                shape.stroke(
                                    Color.dockDestructive.opacity(
                                        ComposerRecordingPulse.opacity(at: timeline.date, animates: true)),
                                    lineWidth: max(1, DockLayout.outline))
                            }
                        } else {
                            shape.stroke(
                                isRecording
                                    ? Color.dockDestructive.opacity(
                                        ComposerRecordingPulse.opacity(at: .now, animates: false))
                                    : (isFocused ? Color.dockAccent.opacity(isGlass ? 0.2 : 0.42) : Color.dockBorder),
                                lineWidth: isFocused || isRecording ? max(1, DockLayout.outline) : DockLayout.outline
                            )
                            .opacity(showsNeutralOutline || isFocused || isRecording ? 1 : 0)
                        }
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

enum ComposerRecordingPulse {
    static func opacity(at date: Date, animates: Bool) -> Double {
        animates ? 0.28 + 0.37 * DockMotionSchedule.breath(date, period: 1.6) : 0.65
    }
}

/// Composer chrome shared by the main chat and group chats so both inputs sit
/// in the same spot with the same card, tray and column insets.
extension View {
    /// The input card: its insets and themed surface.
    func composerCard(isFocused: Bool, isRecording: Bool = false) -> some View {
        dockPadding(.leading, 6)
            .dockPadding(.trailing, 8)
            .dockPadding(.top, 6)
            .dockPadding(.bottom, 6)
            .modifier(ComposerInputSurface(isFocused: isFocused, isRecording: isRecording))
    }

    /// The sunken tray that joins strips (plan, queue, quote, folder bar) to the card.
    func composerTray() -> some View {
        background {
            let skin = DockSkinPresentation.current
            if skin.composer != .line {
                Color.clear.dockWell(.sunken, radius: skin.composerRadius, role: .pane, stroke: .dockBorderLight)
            }
        }
    }

    /// The composer's place in the conversation column.
    func composerColumn(_ metrics: ConversationWorkspaceMetrics) -> some View {
        dockPadding(.horizontal, metrics.composerInset)
            .dockPadding(.top, metrics.composerTopInset)
            .dockPadding(.bottom, metrics.composerBottomInset)
            .frame(maxWidth: metrics.composerMaxWidth)
            .frame(maxWidth: .infinity)
    }
}

/// Holds the folder bar's 32pt (28 + 2×2) when there is none, so the input sits
/// at the same height everywhere, e.g. across split columns and group chats.
struct ComposerFolderBarSlot: View {
    var body: some View {
        Color.clear.frame(height: 22).dockPadding(.vertical, 2).accessibilityHidden(true)
    }
}
