import SwiftUI

struct ComposerControlLabel: View {
    let icon: Ph

    var body: some View {
        DockIcon(icon, size: 14, color: Color.dockSecondaryText)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .dockControlFace(DockSkinPresentation.current.composerControlFill)
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

/// Keeps the model, readings and actions mounted while the toolbar reflows.
struct ComposerToolbarLayout: Layout {
    private let spacing = DockSpacing.control

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrangement(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width proposedWidth: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        guard subviews.count == 3 else { return (.zero, []) }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let readingsGap: CGFloat = ideal[1].width > 0 ? spacing : 0
        let trailingWidth = ideal[1].width + readingsGap + ideal[2].width
        let inlineWidth = ideal[0].width + spacing + trailingWidth
        let width = proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? inlineWidth
        let leading = subviews[0].sizeThatFits(ProposedViewSize(width: min(width, ideal[0].width), height: nil))
        let readings = ideal[1]
        let actions = ideal[2]
        let trailingHeight = max(readings.height, actions.height)
        let actionsX = max(0, width - actions.width)
        let leadingY: CGFloat
        let readingsY: CGFloat
        let actionsY: CGFloat
        let readingsX: CGFloat
        if inlineWidth <= width {
            let rowHeight = max(leading.height, trailingHeight)
            leadingY = (rowHeight - leading.height) / 2
            readingsY = (rowHeight - readings.height) / 2
            actionsY = (rowHeight - actions.height) / 2
            readingsX = width - trailingWidth
        } else {
            leadingY = 0
            readingsX = 0
            let nextRow = leading.height + spacing
            if trailingWidth <= width {
                readingsY = nextRow + (trailingHeight - readings.height) / 2
                actionsY = nextRow + (trailingHeight - actions.height) / 2
            } else {
                readingsY = nextRow
                actionsY = nextRow + readings.height + readingsGap
            }
        }
        let frames = [
            CGRect(origin: CGPoint(x: 0, y: leadingY), size: leading),
            CGRect(origin: CGPoint(x: readingsX, y: readingsY), size: readings),
            CGRect(origin: CGPoint(x: actionsX, y: actionsY), size: actions),
        ]
        return (CGSize(width: width, height: frames.map(\.maxY).max() ?? 0), frames)
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
                let style = DockThemeStyle.current
                let isGlass = style.material == .glass
                let showsNeutralOutline = DockLayout.outline > 0 && !isGlass
                let focusInk = Color.dockAccent.opacity(isGlass ? 0.2 : style.emphasizesOutlines ? 0.72 : 0.42)
                let activeWidth = max(DockLayout.outline, isFocused && style.emphasizesOutlines ? 1.5 : 1)
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
                                    : (isFocused ? focusInk : Color.dockBorder),
                                lineWidth: isFocused || isRecording ? activeWidth : DockLayout.outline
                            )
                            .opacity(showsNeutralOutline || isFocused || isRecording ? 1 : 0)
                        }
                    }
                    .overlay {
                        if DockThemeStyle.current.finish == .machined {
                            shape.stroke(Color.dockBorderStrong, lineWidth: 1).padding(2)
                        } else if isFocused && DockThemeStyle.current.strongFocus {
                            shape.stroke(isRecording ? Color.dockDestructive : Color.dockAccent, lineWidth: 3)
                                .padding(-2)
                        }
                    }
                    .dockStickerShadow(shape)
                    .dockFoldCrease()
                    .dockEmboss(shape)
                    .dockBevel(pressed: true)
                    .dockCardMarks()
                    .shadow(
                        color: Color.black.opacity(style.emphasizesOutlines ? 0.05 : 0.10), radius: skin.composerShadow,
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
        Color.clear.frame(height: 28).dockPadding(.vertical, 2).accessibilityHidden(true)
    }
}

/// Whether the composer holds the empty folder-bar slot. Split columns and group chats keep it
/// so inputs line up side by side; a lone pop-out window has nothing to line up with.
private struct ComposerReservesFolderBarKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var composerReservesFolderBar: Bool {
        get { self[ComposerReservesFolderBarKey.self] }
        set { self[ComposerReservesFolderBarKey.self] = newValue }
    }
}
