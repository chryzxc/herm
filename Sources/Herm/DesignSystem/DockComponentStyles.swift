import AppKit
import SwiftUI

private func dockAdaptiveColor(light: NSColor, dark: NSColor) -> Color {
    Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
}

extension Color {
    // The notch is an extension of the workspace and follows its global palette.
    static var dockNotchText: Color { dockPrimaryText }
    static var dockNotchSecondaryText: Color { dockSecondaryText }

    // Shared appearance-aware palette for the Dock popover and its supporting
    // panels. These roles intentionally follow the system Light/Dark mode.
    static var dockOnAccentText: Color { DockThemePalette(theme: DockThemeRuntime.current).onAccent }
    // Match the cool navy tint of macOS menu-bar popovers instead of allowing
    // the host window's warm/black material to determine the panel palette.
    static var dockCanvas: Color { DockThemePalette(theme: DockThemeRuntime.current).background }
    /// Navigation rail and window title rows share this, so the chrome reads as one frame.
    static var dockSidebar: Color { DockThemePalette(theme: DockThemeRuntime.current).sidebarBackground }
    static var dockSurface: Color { DockThemePalette(theme: DockThemeRuntime.current).surface }
    static var dockSurface2: Color { DockThemePalette(theme: DockThemeRuntime.current).surface2 }
    static var dockSurface4: Color { DockThemePalette(theme: DockThemeRuntime.current).surface4 }
    static var dockSurface6: Color { DockThemePalette(theme: DockThemeRuntime.current).surface6 }
    static var dockSurface8: Color { DockThemePalette(theme: DockThemeRuntime.current).surface8 }
    static var dockMessageBubble: Color { dockSurface }
    static var dockUserMessageBubble: Color {
        DockThemeStyle.current.neutralUserBubble ? dockSurface4 : dockAccent.opacity(0.12)
    }
    /// Opaque themed canvas for presentations; never inherit AppKit's warm window fill.
    static var dockOpaqueCanvas: Color {
        DockThemePalette(theme: DockThemeRuntime.current).opaqueBackground
    }
    static var dockControlSurface: Color { dockSurface4 }
    static var dockBorderStrong: Color { DockThemePalette(theme: DockThemeRuntime.current).divider.opacity(0.95) }
    static var dockBorder: Color { DockThemePalette(theme: DockThemeRuntime.current).divider.opacity(0.72) }
    static var dockBorderLight: Color { DockThemePalette(theme: DockThemeRuntime.current).divider.opacity(0.48) }
    static var dockAccent: Color { DockThemePalette(theme: DockThemeRuntime.current).accent }
    static var dockAccentMuted: Color { dockAccent.opacity(0.14) }
    // Discord identity tint; separate from interaction and lifecycle colors.
    static let dockDiscord = dockAdaptiveColor(
        light: NSColor(red: 0.29, green: 0.32, blue: 0.78, alpha: 1),
        dark: NSColor(red: 0.65, green: 0.67, blue: 1, alpha: 1)
    )
    static let dockAccentGlow = Color.clear
    /// Highlighter yellow for Notebook's selection swipe and tape; unlike `dockWarning` it never carries text.
    static let dockMarker = Color(red: 1, green: 0.85, blue: 0.2)
    static var dockPrimaryText: Color { DockThemePalette(theme: DockThemeRuntime.current).primaryText }
    // Markdown bodies are long-form reading surfaces; keep them a little softer
    // than primary chrome while preserving each theme's contrast and hue.
    static var dockMarkdownText: Color { dockPrimaryText.opacity(0.86) }
    static var dockSecondaryText: Color { DockThemePalette(theme: DockThemeRuntime.current).secondaryText }
    static var dockMetadataText: Color { DockThemePalette(theme: DockThemeRuntime.current).metadataText }
    static var dockSectionText: Color { dockSecondaryText }
    // Kanban lifecycle accents shared by board and session-kanban surfaces.
    static var dockKanbanRunning: Color { DockStatusTone.working.color }
    static var dockKanbanReview: Color { DockStatusTone.review.color }
    // Solid fill roles are distinct from readable semantic ink.
    static var dockInfoFill: Color { DockAccentColor.blue.fill }
    static var dockReviewFill: Color { DockAccentColor.teal.fill }
    static var dockMergedFill: Color { DockAccentColor.violet.fill }
    static var dockSuccessFill: Color { DockAccentColor.green.fill }
    static var dockWarningFill: Color { DockAccentColor.orange.fill }
    static var dockDestructiveFill: Color { DockAccentColor.coral.fill }
    static var dockInfo: Color { DockThemePalette(theme: DockThemeRuntime.current).info }
    static var dockReview: Color { DockThemePalette(theme: DockThemeRuntime.current).review }
    static var dockMerged: Color { DockThemePalette(theme: DockThemeRuntime.current).merged }
    static var dockSuccess: Color { DockThemePalette(theme: DockThemeRuntime.current).success }
    static var dockWarning: Color { DockThemePalette(theme: DockThemeRuntime.current).warning }
    static var dockFolder: Color { dockSecondaryText }
    static var dockDestructive: Color { DockThemePalette(theme: DockThemeRuntime.current).destructive }
}

/// Layout values shared by the compact popover and its inspectors. Keeping
/// these few measurements together prevents individual surfaces from slowly
/// drifting into almost-the-same gutters and control heights.
enum DockLayout {
    static let hairline: CGFloat = 0.5
    static let tight: CGFloat = 6
    static let controlGap: CGFloat = 8
    static let contentInset: CGFloat = 16
    static let compactInset: CGFloat = 12
    static let controlHeight: CGFloat = 36
    static let iconControlSize: CGFloat = 28
    /// Glyph size for every icon control in a title row or toolbar.
    static let toolbarIconSize: CGFloat = 14
    static var controlRadius: CGFloat { DockThemeStyle.current.controlRadius }
    static var paneRadius: CGFloat { DockThemeStyle.current.paneRadius }
    static var outline: CGFloat { DockThemeStyle.current.outlineWidth }
    /// Matches AppKit's corner radius for a window with a unified toolbar, so
    /// the borderless floating panel reads like Herm's titled window.
    static let windowRadius: CGFloat = {
        if #available(macOS 26, *) { return 26 }
        return 10
    }()
}

enum DockThemeShapeRole {
    case control
    case pane

    var foldSize: CGFloat {
        return self == .control ? 6 : 10
    }
    /// Corner cut for chamfered panels.
    var cut: CGFloat { self == .control ? 5 : 10 }
    /// One stair step of a pixel corner (each corner has two).
    var step: CGFloat { self == .control ? 2 : 3 }
}

/// One shared silhouette for themed controls and surfaces. Rounded themes use
/// the existing continuous rectangle; Origami clips opposing corners so the
/// component geometry changes without special-casing individual screens.
struct DockThemeShape: Shape {
    let cornerRadius: CGFloat
    var role: DockThemeShapeRole = .control
    var geometry: DockThemeGeometry = DockThemeStyle.current.geometry

    func path(in rect: CGRect) -> Path {
        switch geometry {
        case .pixel: return pixelPath(in: rect)
        case .sketch: return sketchPath(in: rect)
        case .chamfered: return chamferPath(in: rect)
        case .rounded, .folded: break
        }
        let fold = geometry == .folded ? min(role.foldSize, min(rect.width, rect.height) * 0.38) : 0
        guard fold > 0 else {
            return RoundedRectangle(cornerRadius: max(0, cornerRadius), style: .continuous).path(in: rect)
        }

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + fold * 0.55, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - fold * 0.55))
        path.addLine(to: CGPoint(x: rect.maxX - fold * 0.55, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + fold, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - fold))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + fold * 0.55))
        path.closeSubpath()
        return path
    }
}

extension DockThemeShape {
    private func pixelPath(in r: CGRect) -> Path {
        let s = min(role.step, min(r.width, r.height) / 5)
        let d = s * 2
        var p = Path()
        p.addLines([
            CGPoint(x: r.minX + d, y: r.minY), CGPoint(x: r.maxX - d, y: r.minY),
            CGPoint(x: r.maxX - d, y: r.minY + s), CGPoint(x: r.maxX - s, y: r.minY + s),
            CGPoint(x: r.maxX - s, y: r.minY + d), CGPoint(x: r.maxX, y: r.minY + d),
            CGPoint(x: r.maxX, y: r.maxY - d), CGPoint(x: r.maxX - s, y: r.maxY - d),
            CGPoint(x: r.maxX - s, y: r.maxY - s), CGPoint(x: r.maxX - d, y: r.maxY - s),
            CGPoint(x: r.maxX - d, y: r.maxY), CGPoint(x: r.minX + d, y: r.maxY),
            CGPoint(x: r.minX + d, y: r.maxY - s), CGPoint(x: r.minX + s, y: r.maxY - s),
            CGPoint(x: r.minX + s, y: r.maxY - d), CGPoint(x: r.minX, y: r.maxY - d),
            CGPoint(x: r.minX, y: r.minY + d), CGPoint(x: r.minX + s, y: r.minY + d),
            CGPoint(x: r.minX + s, y: r.minY + s), CGPoint(x: r.minX + d, y: r.minY + s),
        ])
        p.closeSubpath()
        return p
    }

    /// Top-leading and bottom-trailing corners are cut; the others stay square.
    private func chamferPath(in r: CGRect) -> Path {
        let c = min(role.cut, min(r.width, r.height) * 0.3)
        var p = Path()
        p.addLines([
            CGPoint(x: r.minX + c, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY - c), CGPoint(x: r.maxX - c, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY + c),
        ])
        p.closeSubpath()
        return p
    }

    /// A smoothed closed curve through jittered edge points. The jitter is a
    /// pure function of the rect size, so a shape never shimmers on redraw.
    private func sketchPath(in r: CGRect) -> Path {
        let inset = max(cornerRadius, 6)
        let amp: CGFloat = 1.3
        func jitter(_ i: Int) -> CGFloat {
            let v = sin(Double(i) * 12.9898 + Double(Int(r.width)) * 0.37 + Double(Int(r.height)) * 0.71) * 43758.5453
            return CGFloat(v - v.rounded(.down)) * 2 - 1
        }
        let base = [
            CGPoint(x: r.minX + inset, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX - inset, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY + inset), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY - inset),
            CGPoint(x: r.maxX - inset, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX + inset, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY - inset), CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.minX, y: r.minY + inset),
        ]
        let pts = base.enumerated().map { CGPoint(x: $1.x + jitter($0 * 2) * amp, y: $1.y + jitter($0 * 2 + 1) * amp) }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var p = Path()
        p.move(to: mid(pts[pts.count - 1], pts[0]))
        for i in pts.indices { p.addQuadCurve(to: mid(pts[i], pts[(i + 1) % pts.count]), control: pts[i]) }
        p.closeSubpath()
        return p
    }
}

/// L-shaped brackets in the four corners of a rect (HUD cards).
private struct DockCornerBrackets: Shape {
    var length: CGFloat = 10
    func path(in r: CGRect) -> Path {
        var p = Path()
        for (corner, dx, dy) in [
            (CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
            (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0),
        ] {
            p.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
        }
        return p
    }
}

private struct DockInvertIf: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.colorInvert() } else { content }
    }
}

/// Static material patterns shared by the workspace and skin specimens.
struct DockBackdrop: View {
    var style: DockThemeStyle = .current
    var accent: Color = .dockAccent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let kind = style.backdrop
        if kind == .etching, let art = DockAppBrand.backdrop {
            // Mirrors the Hermes desktop: inverted in light, plain in dark, difference-blended at a whisper.
            GeometryReader { proxy in
                Image(nsImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height * 1.6, alignment: .topLeading)
                    .clipped()
                    .modifier(DockInvertIf(active: colorScheme == .light))
            }
            // Hermes Desktop's Backdrop.tsx value (opacity-[0.025]).
            .opacity(0.025)
            .blendMode(.difference)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else if kind != .none && kind != .etching {
            Canvas { context, size in
                let step: CGFloat =
                    switch kind {
                    case .none, .grid: style.geometry == .pixel ? 16 : 32
                    case .ruled: 28
                    case .dots: 16
                    case .scanlines: 4
                    case .crosshairs: 40
                    case .rain: 24
                    case .etching: 0
                    }
                var path = Path()
                if kind == .rain {
                    // Sparse slanted streaks; a fixed lattice hash keeps them static.
                    for (row, y) in stride(from: 0, to: size.height, by: step).enumerated() {
                        for (column, x) in stride(from: 0, to: size.width, by: step).enumerated()
                        where (row * 7 + column * 3) % 5 == 0 {
                            let x = x + CGFloat((row * 11) % 17)
                            let length = CGFloat(6 + (column * 5 + row) % 9)
                            path.move(to: CGPoint(x: x, y: y))
                            path.addLine(to: CGPoint(x: x - length * 0.3, y: y + length))
                        }
                    }
                } else if kind == .dots || kind == .crosshairs {
                    for y in stride(from: step / 2, to: size.height, by: step) {
                        for x in stride(from: step / 2, to: size.width, by: step) {
                            if kind == .dots {
                                path.addEllipse(in: CGRect(x: x, y: y, width: 1, height: 1))
                            } else {
                                path.move(to: CGPoint(x: x - 3, y: y))
                                path.addLine(to: CGPoint(x: x + 3, y: y))
                                path.move(to: CGPoint(x: x, y: y - 3))
                                path.addLine(to: CGPoint(x: x, y: y + 3))
                            }
                        }
                    }
                } else {
                    for y in stride(from: step, to: size.height, by: step) {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    if kind == .grid {
                        for x in stride(from: step, to: size.width, by: step) {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: size.height))
                        }
                    }
                }
                if kind == .rain {
                    // Night city: horizon haze and a low skyline with a few lit windows.
                    let horizon = size.height * 0.45
                    context.fill(
                        Path(CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon)),
                        with: .linearGradient(
                            Gradient(colors: [accent.opacity(0), accent.opacity(0.07)]),
                            startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: size.height)))
                    var towers = Path()
                    var windows = Path()
                    var x: CGFloat = 0
                    var index = 0
                    // Tall enough that the roofline clears the floating chat composer.
                    let maxHeight = min(380, size.height * 0.5)
                    while x < size.width {
                        // Scattered heights and open lots keep it a skyline, not a wall.
                        let width = CGFloat(22 + (index * 29) % 26)
                        let height = maxHeight * CGFloat(30 + (index * 37) % 71) / 100
                        defer {
                            x += width + CGFloat(8 + (index * 13) % 40)
                            index += 1
                        }
                        if index % 3 == 2 { continue }
                        towers.addRect(CGRect(x: x, y: size.height - height, width: width - 2, height: height))
                        for wy in stride(from: size.height - height + 6, to: size.height - 4, by: 7) {
                            for wx in stride(from: x + 4, to: x + width - 6, by: 6)
                            where (Int(wx) * 3 + Int(wy) * 7 + index) % 9 == 0 {
                                windows.addRect(CGRect(x: wx, y: wy, width: 2, height: 3))
                            }
                        }
                    }
                    context.fill(towers, with: .color(.black.opacity(0.22)))
                    context.fill(windows, with: .color(accent.opacity(0.28)))
                }
                let opacity: Double =
                    kind == .scanlines ? 0.045 : kind == .crosshairs ? 0.18 : kind == .rain ? 0.16 : 0.09
                context.stroke(path, with: .color(accent.opacity(opacity)), lineWidth: kind == .dots ? 1 : 0.5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct DockFoldCrease: Shape {
    let size: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX - size, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - size, y: rect.minY + size))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + size))
        path.closeSubpath()
        return path
    }
}

extension Animation {
    static func dockEase(duration: TimeInterval = 0.3) -> Animation {
        switch DockThemeStyle.current.motion {
        case .glide: .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
        case .snap: .timingCurve(0.16, 1, 0.3, 1, duration: duration * 0.6)
        case .mechanical: .timingCurve(0.4, 0, 0.2, 1, duration: duration * 0.7)
        case .bouncy: .spring(duration: duration * 1.4, bounce: 0.28)
        case .float: .spring(duration: duration * 1.3, bounce: 0)
        }
    }

    /// Hover and press feedback. Snap skins paint the active state in the
    /// current frame and ease only the return, like the Hermes desktop.
    static func dockFeedback(_ active: Bool, duration: TimeInterval = 0.16) -> Animation? {
        guard DockThemeStyle.current.animates else { return nil }
        return DockThemeStyle.current.motion == .snap && active ? nil : .dockEase(duration: duration)
    }
}

extension View {
    /// Keeps compact glass controls visually light while preserving the 44pt
    /// hit area specified by the Dock design system.
    func dockHitTarget() -> some View {
        frame(minWidth: 44, minHeight: 44)
    }

    /// Applies the selected Dock theme at a hosting root. Nested
    /// `NSHostingView`s do not inherit the parent SwiftUI environment, so each
    /// root sets the themed default text and control tint itself; unstyled
    /// `Text`, hierarchical styles, toggles, and links then follow the theme.
    func dockThemedRoot() -> some View {
        foregroundStyle(Color.dockPrimaryText)
            .tint(Color.dockAccent)
            .buttonStyle(.dockCompact)
            .fontDesign(DockThemeStyle.current.fontDesign)
            // Native controls (placeholders, carets, menus) follow the colour
            // scheme, not our tokens; pin it so a light skin under dark macOS
            // (or vice versa) doesn't get invisible placeholder text.
            .modifier(DockPinnedColorScheme())
            .modifier(DockMotionAccessibility())
    }

    /// Marks an active/hovered tab, row, or control per the theme's selection
    /// style: tinted fill, inverted ink, or an accent underline. `allowsInvert`
    /// is false for containers whose children set their own text colors.
    func dockSelectionBackground<S: Shape>(
        _ shape: S, active: Bool, fill: Color, allowsInvert: Bool = true, theme: DockThemeID = DockThemeRuntime.current
    ) -> some View {
        let mode = theme.style.selection
        let palette = DockThemePalette(theme: theme)
        return background {
            switch mode {
            case .underline:
                Color.clear
            case .invert where allowsInvert:
                shape.fill(active ? palette.primaryText : .clear)
            case .highlight:
                // A marker swipe behind the label, set slightly off-level.
                if active {
                    Color.dockMarker.opacity(0.5)
                        .frame(height: 12)
                        .rotationEffect(.degrees(-0.8))
                        .dockPadding(.bottom, 4)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            case .neon where !palette.neonHues.isEmpty:
                if active {
                    shape.fill(
                        LinearGradient(
                            colors: [palette.neonHues[0].opacity(0.24), palette.neonHues[1].opacity(0.06)],
                            startPoint: .leading, endPoint: .trailing)
                    )
                    .overlay(shape.stroke(palette.neonHues[0].opacity(0.22), lineWidth: 0.5))
                }
            default:
                shape.fill(active ? fill : .clear)
            }
        }
        .overlay(alignment: .bottom) {
            if mode == .underline && active { palette.accent.frame(height: 2) }
        }
        .overlay(alignment: .leading) {
            if theme != .glass && active
                && (mode == .bar || mode == .fill || mode == .highlight || (mode == .invert && !allowsInvert))
            {
                palette.primaryText.frame(width: 2).dockPadding(.vertical, 6)
            }
            if mode == .neon && active && !palette.neonHues.isEmpty {
                LinearGradient(colors: Array(palette.neonHues.prefix(2)), startPoint: .top, endPoint: .bottom)
                    .frame(width: 2)
                    .dockPadding(.vertical, 5)
                    .shadow(color: palette.neonHues[0].opacity(0.9), radius: 4)
            }
        }
    }

    /// Clay look: paired light and dark soft shadows behind the shape. Pressing
    /// flattens them so the control reads as pushed in.
    func dockEmboss<S: Shape>(_ shape: S, pressed: Bool = false, theme: DockThemeID = DockThemeRuntime.current)
        -> some View
    {
        let depth = theme.style.emboss * (pressed ? 0.3 : 1)
        return background {
            if depth > 0 {
                shape.fill(DockThemePalette(theme: theme).background)
                    .shadow(color: .white.opacity(0.85), radius: depth, x: -depth / 2, y: -depth / 2)
                    .shadow(color: .black.opacity(0.16), radius: depth, x: depth / 2, y: depth / 2)
            }
        }
    }

    /// Retro look: two-pixel light/dark edges. `pressed` (also used for inset fields) swaps them.
    func dockBevel(pressed: Bool = false, enabled: Bool = DockThemeStyle.current.bevel) -> some View {
        overlay(DockBevel(pressed: pressed, enabled: enabled))
    }

    /// Corner brackets (HUD) or a strip of tape (Notebook) on cards.
    func dockCardMarks(theme: DockThemeID = DockThemeRuntime.current) -> some View {
        let geometry = theme.style.geometry
        let neon = DockThemePalette(theme: theme).neonHues
        return overlay {
            if !neon.isEmpty {
                // Neon rim: a faint gradient outline with a brighter lit top edge.
                let rim = DockThemeShape(cornerRadius: theme.style.paneRadius, role: .pane, geometry: geometry)
                rim.stroke(
                    LinearGradient(
                        colors: neon.map { $0.opacity(0.35) }, startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
                .overlay {
                    rim.stroke(LinearGradient(colors: neon, startPoint: .leading, endPoint: .trailing), lineWidth: 1)
                        .mask(
                            LinearGradient(
                                colors: [.white, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25)))
                }
                .allowsHitTesting(false)
            }
        }
        .overlay {
            if geometry == .chamfered {
                DockCornerBrackets().stroke(DockThemePalette(theme: theme).accent, lineWidth: 1.5).allowsHitTesting(
                    false)
            }
        }
        .overlay(alignment: .top) {
            if geometry == .sketch {
                Color.dockMarker.opacity(0.4)
                    .frame(width: 34, height: 10)
                    .rotationEffect(.degrees(-3))
                    .offset(y: -5)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Cartoon-style hard shadow: an ink copy of `shape` offset behind the
    /// view. Themes without a sticker shadow draw nothing. An opaque canvas
    /// copy sits between the ink and the view so translucent fills don't
    /// blend with the shadow into a muddy tone.
    func dockStickerShadow<S: Shape>(_ shape: S, pressed: Bool = false, theme: DockThemeID = DockThemeRuntime.current)
        -> some View
    {
        let offset = theme.style.stickerShadow * (pressed ? 0.35 : 1)
        return background {
            if offset > 0 {
                ZStack {
                    shape.fill(DockThemePalette(theme: theme).divider).offset(x: offset, y: offset)
                    shape.fill(DockThemePalette(theme: theme).background)
                }
            }
        }
    }

    /// A quiet crease on larger Origami surfaces. It uses existing semantic
    /// colors and does not add content, state, or a new elevation level.
    func dockFoldCrease(theme: DockThemeID = DockThemeRuntime.current) -> some View {
        overlay {
            if theme.style.geometry == .folded {
                let crease = DockFoldCrease(size: DockThemeShapeRole.pane.foldSize)
                crease
                    .fill(DockThemePalette(theme: theme).background.opacity(0.72))
                    .overlay(
                        crease.stroke(
                            DockThemePalette(theme: theme).divider.opacity(0.75), lineWidth: DockLayout.hairline)
                    )
                    .allowsHitTesting(false)
            }
        }
    }
}

/// AppKit's popover material — the same heavy backdrop blur macOS uses for menu-bar extras like
/// Battery and Wi-Fi. Keeping this as a view instead of approximating it with
/// layered SwiftUI colors gives the panel the real appearance-aware blur.
struct NativePopoverBackground: NSViewRepresentable {
    /// Glass uses the lighter window-under material so a bright wallpaper
    /// reads as frosted light/dark glass instead of the popover's gray cast.
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

/// AppKit's own Liquid Glass (macOS 26): frosts what is behind the window the
/// way system panels do, without an extra blur material graying it out.
@available(macOS 26.0, *)
struct NativeLiquidGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {}
}

/// The workspace's base layer. Native macOS uses the real system popover
/// material under the shared palette; authored Herm themes keep their solid
/// canvas so selecting a theme never changes its intended color treatment.
struct DockWindowBackground: View {
    // Observed so the canvas repaints on theme switch; it has no other inputs.
    @ObservedObject private var themeStore = DockThemeStore.shared
    /// Clip the native material to the panel silhouette, including attached notches.
    var shape = AnyShape(Rectangle())

    /// Glass samples the real backdrop with the system Liquid Glass effect
    /// (macOS 26+); older systems and System skin use the blur material.
    @ViewBuilder private var glassOrPopover: some View {
        if DockThemeRuntime.current == .glass, #available(macOS 26.0, *) {
            NativeLiquidGlassBackground()
                // NSGlassEffectView's blur isn't tunable; a blur material beneath it frosts the backdrop further.
                .background(NativePopoverBackground(material: .underWindowBackground))
                // A second full-window glass effect adds a broad specular reflection over the transcript.
                .clipShape(shape)
        } else {
            NativePopoverBackground(material: DockThemeRuntime.current == .glass ? .underWindowBackground : .popover)
        }
    }

    var body: some View {
        if DockThemeRuntime.current.usesNativeMaterial {
            glassOrPopover
                .id(DockThemeRuntime.revision)
                .overlay(DockThemePalette(theme: DockThemeRuntime.current).windowBackground)
        } else {
            Color.dockCanvas.overlay(DockBackdrop())
        }
    }
}

/// Layered sheets and panes need a stable canvas independent of the material beneath them.
struct DockPaneBackground: View {
    var body: some View {
        Color.dockOpaqueCanvas
    }
}

/// Shared interaction and input treatments derived from DESIGN.md's glass
/// button and input specifications. Keeping them here prevents native control
/// styles from leaking into individual Control, chat, or Activity views.
/// Low-level chrome for icons and content rows; text actions use dockPrimary/dockSecondary.
struct DockPressButtonStyle: ButtonStyle {
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius - 1)
        configuration.label
            .dockFont(.control)
            .foregroundStyle(configuration.role == .destructive ? Color.dockDestructive : Color.dockPrimaryText)
            .padding(DockWorkspaceScale.points(3, scale: workspaceScale))
            .background {
                if DockThemeStyle.current.material == .glass {
                    Color.clear.dockLiquidGlass(shape)
                        .overlay(shape.fill(Color.dockPrimaryText.opacity(isHovering && isEnabled ? 0.07 : 0)))
                } else {
                    shape.fill(Color.dockControlSurface.opacity(isHovering && isEnabled ? 0.9 : 0.55))
                        .overlay(shape.stroke(Color.dockBorder, lineWidth: DockLayout.hairline))
                }
            }
            .contentShape(shape)
            .scaleEffect(
                DockMotion.pressScale(
                    isPressed: configuration.isPressed, isEnabled: isEnabled, reduceMotion: reduceMotion)
            )
            .opacity(!isEnabled ? 0.42 : configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : .dockFeedback(configuration.isPressed), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .dockFeedback(isHovering), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// Reusable hover affordance: a faint accent fill while the pointer is over the
/// view and a stronger one while `isPressed`. Use `.dockHoverable()` on any
/// clickable non-Button (tap-gesture rows, icons); buttons get it via `.dockHover`.
struct DockHoverModifier: ViewModifier {
    var cornerRadius: CGFloat = DockLayout.controlRadius - 1
    var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                // Only lit rows draw a shape; long scrolling lists stay free of invisible overlays.
                if isPressed || (isHovering && isEnabled) {
                    DockThemeShape(cornerRadius: cornerRadius)
                        .fill(Color.dockAccent.opacity(isPressed ? 0.16 : 0.09))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .dockFeedback(isHovering, duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// Drop-in for `.plain`/`.borderless`: same layout; hover lifts the label's own
/// pixels (and press dims them) so it never paints outside the visible control
/// when the hit area is larger than the artwork.
struct DockHoverButtonStyle: ButtonStyle {
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dockFont(.control)
            .foregroundStyle(configuration.role == .destructive ? Color.dockDestructive : Color.dockPrimaryText)
            .brightness(configuration.isPressed ? -0.06 : isHovering && isEnabled ? 0.12 : 0)
            .opacity(isEnabled ? 1 : 0.42)
            // Squash on press, spring back on release.
            .scaleEffect(
                DockMotion.pressScale(
                    isPressed: configuration.isPressed, isEnabled: isEnabled, reduceMotion: reduceMotion)
            )
            .animation(
                reduceMotion ? nil : .dockFeedback(configuration.isPressed, duration: 0.2),
                value: configuration.isPressed
            )
            .animation(reduceMotion ? nil : .dockFeedback(isHovering, duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    func dockHoverable(cornerRadius: CGFloat = DockLayout.controlRadius - 1) -> some View {
        modifier(DockHoverModifier(cornerRadius: cornerRadius))
    }
}

/// The single accent-tinted action treatment from DESIGN.md. Use it only for the
/// primary action in a section; secondary actions keep a neutral outline.
struct DockPrimaryButtonStyle: ButtonStyle {
    /// Split actions keep the shared fill readable while their selector is enabled.
    var dimsWhenDisabled = true
    static var foregroundColor: Color {
        DockThemeStyle.current.material == .glass || !DockThemePalette(theme: DockThemeRuntime.current).neonHues.isEmpty
            ? .dockOnAccentText : .dockPrimaryText
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius)
        let tint = configuration.role == .destructive ? Color.dockDestructive : Color.dockAccent
        let highlighted = isHovering && isEnabled
        // Dense actions share shadowless glass in both appearances.
        let isGlass = DockThemeStyle.current.material == .glass
        let neon = DockThemePalette(theme: DockThemeRuntime.current).neonHues
        configuration.label
            .foregroundStyle(Self.foregroundColor)
            .dockButtonMetrics()
            .background {
                if isGlass {
                    Color.clear.dockLiquidGlass(
                        shape, tint: tint.opacity(configuration.isPressed ? 0.86 : highlighted ? 0.94 : 1),
                        interactive: true,
                        elevated: false)
                } else if !neon.isEmpty {
                    // Neon skins: a solid accent-to-magenta fill that glows brighter on hover.
                    shape.fill(
                        LinearGradient(
                            colors: configuration.role == .destructive ? [tint, tint] : [neon[0], neon[1]],
                            startPoint: .leading, endPoint: .trailing)
                    )
                    .brightness(configuration.isPressed ? -0.08 : highlighted ? 0.05 : 0)
                    .shadow(
                        color: (configuration.role == .destructive ? tint : neon[1]).opacity(highlighted ? 0.55 : 0.3),
                        radius: highlighted ? 10 : 6)
                } else {
                    shape.fill(tint.opacity(configuration.isPressed ? 0.30 : highlighted ? 0.24 : 0.14))
                        .background(shape.fill(Color.dockCanvas))
                        .overlay(shape.stroke(tint.opacity(highlighted ? 0.6 : 0.35), lineWidth: DockLayout.outline))
                        // Glossy skins add a top-down sheen.
                        .overlay {
                            if DockThemeStyle.current.accentGradient {
                                shape.fill(
                                    LinearGradient(
                                        colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center))
                            }
                        }
                }
            }
            .dockStickerShadow(shape, pressed: configuration.isPressed)
            .dockEmboss(shape, pressed: configuration.isPressed)
            .dockBevel(pressed: configuration.isPressed)
            .contentShape(shape)
            .opacity(isEnabled || !dimsWhenDisabled ? 1 : 0.42)
            .scaleEffect(
                DockMotion.pressScale(
                    isPressed: configuration.isPressed, isEnabled: isEnabled, reduceMotion: reduceMotion)
            )
            .offset(
                y: DockMotion.hoverOffset(
                    isHovered: isHovering, isPressed: configuration.isPressed,
                    isEnabled: isEnabled, reduceMotion: reduceMotion)
            )
            .animation(reduceMotion ? nil : .dockFeedback(configuration.isPressed), value: configuration.isPressed)
            .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.16), value: highlighted)
            .onHover { isHovering = $0 }
    }
}

/// The outlined companion to the primary action (Cancel, Remove, Copy). A
/// destructive role tints the label instead of filling the control.
struct DockSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius)
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? Color.dockDestructive : Color.dockPrimaryText)
            .dockButtonMetrics()
            .background {
                // Keep actions distinct without stacking native drop shadows.
                if DockThemeStyle.current.material == .glass {
                    Color.clear.dockLiquidGlass(shape, interactive: true)
                        .overlay(
                            shape.fill(
                                Color.dockPrimaryText.opacity(
                                    !isEnabled ? 0 : configuration.isPressed ? 0.12 : isHovering ? 0.07 : 0))
                        )
                } else {
                    shape.fill(
                        configuration.isPressed
                            ? Color.dockSurface6
                            : isHovering && isEnabled ? Color.dockSurface4 : Color.dockControlSurface.opacity(0.6)
                    )
                    .overlay(shape.stroke(Color.dockBorder, lineWidth: max(DockLayout.hairline, DockLayout.outline)))
                }
            }
            .dockStickerShadow(shape, pressed: configuration.isPressed)
            .dockEmboss(shape, pressed: configuration.isPressed)
            .dockBevel(pressed: configuration.isPressed)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(
                DockMotion.pressScale(
                    isPressed: configuration.isPressed, isEnabled: isEnabled, reduceMotion: reduceMotion)
            )
            .offset(
                y: DockMotion.hoverOffset(
                    isHovered: isHovering, isPressed: configuration.isPressed,
                    isEnabled: isEnabled, reduceMotion: reduceMotion)
            )
            .animation(reduceMotion ? nil : .dockFeedback(configuration.isPressed), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .dockFeedback(isHovering), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// Compact toggle treatment for labeled presentation controls. This keeps
/// native macOS switch chrome out of the sci-fi glass system while retaining
/// a clear on/off state through the label, track, and thumb position.
struct DockToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label
                ZStack {
                    Capsule()
                        .fill(configuration.isOn ? Color.dockAccent.opacity(0.24) : Color.dockSurface6)
                        .overlay {
                            Capsule()
                                .stroke(
                                    configuration.isOn ? Color.dockAccent.opacity(0.72) : Color.dockBorderStrong,
                                    lineWidth: max(0.7, DockLayout.outline))
                        }
                    Circle()
                        .fill(configuration.isOn ? Color.dockAccent : Color.dockSecondaryText)
                        .frame(width: 16, height: 16)
                        .shadow(color: configuration.isOn ? Color.dockAccentGlow : .clear, radius: 5)
                        .offset(x: configuration.isOn ? 9 : -9)
                }
                .frame(width: 38, height: 22)
            }
            .foregroundStyle(Color.dockSecondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.16), value: configuration.isOn)
    }
}

struct DockGlassTextFieldStyle: TextFieldStyle {
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    var compact = false
    var trailingInset: CGFloat = 0
    func _body(configuration: TextField<Self._Label>) -> some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius)
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: DockTypography.size(compact ? .control : .navigation, scale: workspaceScale)))
            .foregroundStyle(Color.dockPrimaryText)
            .dockPadding(.horizontal, 10)
            .dockPadding(.trailing, trailingInset)
            .dockPadding(.vertical, compact ? 4 : 8)
            .frame(minHeight: compact ? DockWorkspaceScale.points(28, scale: workspaceScale) : DockLayout.controlHeight)
            // The shared canvas keeps inputs consistent across panes; the
            // plain field style removes the warm native field fill.
            .background(DockFieldBackground(shape: shape))
            .overlay(DockBevel(pressed: true))
    }
}

/// A View so the glass branch runs main-actor isolated (TextFieldStyle bodies are not).
private struct DockFieldBackground: View {
    let shape: DockThemeShape

    var body: some View {
        if DockThemeStyle.current.material == .glass {
            Color.clear.dockLiquidGlass(shape)
        } else {
            shape.fill(Color.dockControlSurface).stroke(Color.dockBorder, lineWidth: DockLayout.outline)
        }
    }
}

/// The consistent title treatment for full workspace destinations. Keeping it
/// shared prevents individual pages from inventing competing title bars.
struct DockPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let onRefresh: (() -> Void)?
    let isRefreshing: Bool
    let horizontalPadding: CGFloat
    /// Pages with a list column pass this to get the sidebar toggle before the title.
    let sidebarCollapsed: Binding<Bool>?
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String,
        onRefresh: (() -> Void)? = nil,
        isRefreshing: Bool = false,
        sidebarCollapsed: Binding<Bool>? = nil,
        horizontalPadding: CGFloat = 16,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onRefresh = onRefresh
        self.isRefreshing = isRefreshing
        self.horizontalPadding = horizontalPadding
        self.sidebarCollapsed = sidebarCollapsed
        self.trailing = trailing
    }

    @ViewBuilder private var sidebarToggle: some View {
        if let sidebarCollapsed { DockSidebarToggle(isCollapsed: sidebarCollapsed) }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .dockFont(.pageTitle)
                .foregroundStyle(Color.dockPrimaryText)
            Text(subtitle)
                .dockFont(.compactStatus, weight: .regular)
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
        }
    }

    private var refreshButton: some View {
        Group {
            if let onRefresh {
                DockIconButton(
                    icon: .arrowsClockwise, label: "Refresh", isBusy: isRefreshing,
                    style: DockThemePalette(theme: DockThemeRuntime.current), action: onRefresh)
            }
        }
    }

    var body: some View {
        if let titleRow {
            windowTitleRow(titleRow)
        } else {
            panelHeader
        }
    }

    @Environment(\.dockTitleRow) private var titleRow

    /// In a window the header is the title row beside the traffic lights: one
    /// line, title then status, actions trailing, like a native toolbar.
    private func windowTitleRow(_ row: DockTitleRow) -> some View {
        HStack(spacing: 8) {
            sidebarToggle
            Text(title)
                .dockFont(.navigation, weight: .semibold, design: DockThemeStyle.current.fontDesign)
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
                .layoutPriority(1)
            Text(subtitle)
                .dockFont(.body)
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
                .frame(maxHeight: .infinity)
                .background { TitlebarDoubleClickArea() }
            refreshButton
            trailing().fixedSize()
        }
        // Titles and sidebar controls share Calendar’s gutter beside the traffic lights.
        .dockPadding(.leading, 16 + row.leadingClearance)
        .dockPadding(.trailing, 12)
        .frame(height: row.height)
        .background(Color.dockSidebar)
        .overlay(alignment: .bottom) { DockWindowChrome.titleRowSeparator }
        // Same gap under the line as the panel header, so every page's content sits alike.
        .dockPadding(.bottom, 10)
    }

    private var panelHeader: some View {
        // One row when it fits; in the minimized panel the trailing controls
        // drop to their own row instead of truncating.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                sidebarToggle
                titleBlock.frame(maxWidth: 360, alignment: .leading)
                Spacer(minLength: 12)
                refreshButton
                trailing().fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    sidebarToggle
                    titleBlock
                    Spacer(minLength: 12)
                    refreshButton
                }
                HStack(spacing: 8) { trailing() }
            }
        }
        .dockPadding(.bottom, 10)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
        .dockPadding(.bottom, 10)
        .dockPadding(.horizontal, horizontalPadding)
        .dockPadding(.top, 16)
    }
}

/// Set by the window shell when a page's header should fill the window's title row.
struct DockTitleRow: Equatable {
    var height: CGFloat
    var leadingClearance: CGFloat
}

extension EnvironmentValues {
    @Entry var dockTitleRow: DockTitleRow? = nil
}

extension DockPageHeader where Trailing == EmptyView {
    init(
        title: String, subtitle: String, onRefresh: (() -> Void)? = nil, isRefreshing: Bool = false,
        sidebarCollapsed: Binding<Bool>? = nil, horizontalPadding: CGFloat = 16
    ) {
        self.init(
            title: title, subtitle: subtitle, onRefresh: onRefresh, isRefreshing: isRefreshing,
            sidebarCollapsed: sidebarCollapsed, horizontalPadding: horizontalPadding
        ) { EmptyView() }
    }
}

/// Every full-window (expanded) presentation: a `DockPageHeader` with Close, then
/// the content. The header owns the window title row, so nothing draws under the
/// traffic lights; content below gets a plain panel context. See docs/expanded-pages.md.
struct DockExpandedPage<Trailing: View, Content: View>: View {
    let title: String
    let subtitle: String
    var help: String? = nil
    var onRefresh: (() -> Void)? = nil
    var isRefreshing = false
    var showsClose = true
    var close: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    // A required closure preserves legacy close/content trailing-closure resolution.
    init(
        title: String, subtitle: String, help: String? = nil, onRefresh: (() -> Void)? = nil,
        isRefreshing: Bool = false, showsClose: Bool = true, close: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing, @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.help = help
        self.onRefresh = onRefresh
        self.isRefreshing = isRefreshing
        self.showsClose = showsClose
        self.close = close
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DockPageHeader(title: title, subtitle: subtitle, onRefresh: onRefresh, isRefreshing: isRefreshing) {
                HStack(spacing: 8) {
                    trailing()
                    if showsClose, let close {
                        Button("Close", action: close).buttonStyle(.dockCompact).keyboardShortcut(.cancelAction)
                    }
                }
            }
            .help(help ?? "")
            content()
                .dockSurfaceReveal()
                .environment(\.dockTitleRow, nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.dockCanvas)
    }
}

extension DockExpandedPage where Trailing == EmptyView {
    init(
        title: String, subtitle: String, help: String? = nil, onRefresh: (() -> Void)? = nil,
        isRefreshing: Bool = false,
        close: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title, subtitle: subtitle, help: help, onRefresh: onRefresh, isRefreshing: isRefreshing,
            close: close, trailing: { EmptyView() }, content: content)
    }

    init(title: String, subtitle: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, close: {}, content: content)
        self.close = nil
    }
}

/// Shows or hides a page's first column (session list, PR list, settings
/// categories). Sits right after the traffic lights, like a native sidebar toggle.
struct DockSidebarToggle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    enum Edge { case leading, trailing }

    let isCollapsed: Bool
    var edge: Edge = .leading
    var panel: String?
    let action: () -> Void

    init(isCollapsed: Binding<Bool>) {
        self.isCollapsed = isCollapsed.wrappedValue
        self.action = { isCollapsed.wrappedValue.toggle() }
    }

    /// Open panels retain a selected glyph and marker even when the pointer leaves.
    init(isCollapsed: Bool, edge: Edge, panel: String? = nil, action: @escaping () -> Void) {
        self.isCollapsed = isCollapsed
        self.edge = edge
        self.panel = panel
        self.action = action
    }

    private var noun: String { panel ?? (edge == .leading ? "sidebar" : "workspace") }

    var body: some View {
        let button = Button {
            withAnimation(DockMotion.animation(reduceMotion: reduceMotion)) { action() }
        } label: {
            // The collapsed glyph shows the hidden panel's rows; trailing panels mirror it.
            DockIcon(
                isCollapsed ? .sidebar : .sidebarSimple, size: DockLayout.toolbarIconSize,
                weight: isCollapsed ? .regular : .fill
            )
            .scaleEffect(x: edge == .trailing ? -1 : 1)
            .foregroundStyle(isCollapsed ? Color.dockSecondaryText : Color.dockPrimaryText)
            .frame(width: DockLayout.iconControlSize, height: DockLayout.iconControlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityLabel(isCollapsed ? "Show \(noun)" : "Hide \(noun)")
        .accessibilityAddTraits(isCollapsed ? [] : .isSelected)
        if edge == .leading, panel == nil {
            button
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help(isCollapsed ? "Show sidebar (⇧⌘S)" : "Hide sidebar (⇧⌘S)")
        } else {
            button.help(isCollapsed ? "Show \(noun)" : "Hide \(noun)")
        }
    }
}

/// A compact in-place pending treatment for actions that call Hermes. The
/// button retains its footprint so the surrounding control surface never jumps.
struct DockActionLabel: View {
    let title: String
    let pendingTitle: String
    let isPending: Bool
    var tint: Color = .dockAccent

    var body: some View {
        HStack(spacing: 6) {
            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
            }
            Text(isPending ? pendingTitle : title)
        }
        .lineLimit(1)
        .contentTransition(.opacity)
    }
}

/// The standard inline notice: errors, warnings, and questions Hermes is
/// waiting on. Keep the header compact and give forms and actions the full width.
struct DockCallout<Content: View>: View {
    enum Tone {
        case info, warning, danger

        var color: Color {
            switch self {
            case .info: .dockAccent
            case .warning: .dockWarning
            case .danger: .dockDestructive
            }
        }
    }

    let tone: Tone
    let icon: Ph
    let title: String
    var message: String?
    var badge: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        let tint = tone.color
        let shape = DockThemeShape(cornerRadius: DockLayout.paneRadius, role: .pane)
        VStack(alignment: .leading, spacing: 0) {
            // Header band: the tone lives here, so every callout reads the same
            // at a glance and the body stays neutral.
            HStack(spacing: DockSpacing.control) {
                DockIcon(icon, size: 14, weight: .fill, color: tint)
                Text(title)
                    .dockFont(.navigation, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DockSpacing.control)
                if let badge { statusPill(badge, tint: tint) }
            }
            .dockPadding(.horizontal, DockSpacing.group)
            .dockPadding(.vertical, DockSpacing.control + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.09))

            let hasMessage = !(message ?? "").isEmpty
            if hasMessage || Content.self != EmptyView.self {
                VStack(alignment: .leading, spacing: DockSpacing.group) {
                    if let message, hasMessage {
                        DockExpandableText(message, lineLimit: 4, prominent: true)
                    }
                    content()
                }
                .dockPadding(DockSpacing.group)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.dockSurfaceFill(Color.dockSurface))
        .clipShape(shape)
        .overlay(shape.stroke(tint.opacity(0.35), lineWidth: DockLayout.hairline))
        .dockFoldCrease()
        .accessibilityElement(children: .contain)
    }

    private func statusPill(_ badge: String, tint: Color) -> some View {
        HStack(spacing: DockSpacing.micro) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(badge).dockFont(.metadata, weight: .semibold)
        }
        .foregroundStyle(tint)
        .dockPadding(.horizontal, 8)
        .dockPadding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .fixedSize()
    }
}

/// A labelled, collapsed-by-default block for supporting detail (scope, limits,
/// stack traces) so the decision and its buttons stay above the fold.
struct DockCalloutDisclosure: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let text: String
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: DockSpacing.tight) {
            Button {
                withAnimation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.18)) { isOpen.toggle() }
            } label: {
                HStack(spacing: DockSpacing.tight) {
                    DockIcon(.caretRight, size: 11, color: .dockMetadataText)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(title)
                        .dockFont(.body, weight: .medium)
                        .foregroundStyle(Color.dockSecondaryText)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            if isOpen {
                ScrollView(.vertical) {
                    Text(text)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dockPadding(.horizontal, 10)
        .dockPadding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DockThemeShape(cornerRadius: DockLayout.controlRadius)
                .dockSurfaceFill(Color.dockSurface2.opacity(0.6), stroke: Color.dockBorderLight)
        )
    }
}

/// Secondary text that collapses to a few lines with a Show more toggle, so a
/// long scope or error never pushes the actions off screen. Short text renders
/// as plain text with no toggle.
struct DockExpandableText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    var lineLimit = 4
    var monospaced = false
    var prominent = false

    @State private var isExpanded = false

    init(_ text: String, lineLimit: Int = 4, monospaced: Bool = false, prominent: Bool = false) {
        self.text = text
        self.lineLimit = lineLimit
        self.monospaced = monospaced
        self.prominent = prominent
    }

    // ponytail: length/newline heuristic instead of measuring rendered lines.
    private var isLong: Bool {
        text.count > lineLimit * 70 || text.split(separator: "\n", omittingEmptySubsequences: false).count > lineLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DockSpacing.tight) {
            Text(text)
                .dockFont(.body, weight: .regular, design: monospaced ? .monospaced : .default)
                .foregroundStyle(prominent ? Color.dockPrimaryText : Color.dockSecondaryText)
                .lineSpacing(2)
                .lineLimit(isExpanded || !isLong ? nil : lineLimit)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if isLong {
                Button(isExpanded ? "Show less" : "Show more") {
                    withAnimation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.18)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.dockLink)
            }
        }
    }
}

/// Keep related decisions together, stacking when the pane cannot fit them.
struct DockCalloutActions<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DockSpacing.group) {
            Rectangle().fill(Color.dockBorderLight).frame(height: DockLayout.hairline)
            actions
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DockSpacing.control, content: content)
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: DockSpacing.control, content: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlSize(.small)
    }
}

extension DockCallout where Content == EmptyView {
    init(tone: Tone, icon: Ph, title: String, message: String? = nil, badge: String? = nil) {
        self.init(tone: tone, icon: icon, title: title, message: message, badge: badge) { EmptyView() }
    }
}

/// Placeholder for a page or panel whose first load is still in flight, so it
/// never renders blank or a false "nothing here" state while Hermes answers.
struct DockLoadingState: View {
    let title: String
    var detail: String? = nil
    var minHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
                .tint(Color.dockAccent)
            Text(title)
                .dockFont(.navigation, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
            if let detail {
                Text(detail)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockSecondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
        }
        .dockPadding(24)
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity)
        .dockSurfaceReveal()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

extension ButtonStyle where Self == DockPressButtonStyle {
    static var dockPress: Self { Self() }
}

extension ButtonStyle where Self == DockHoverButtonStyle {
    static var dockHover: Self { Self() }
}

extension ButtonStyle where Self == DockPrimaryButtonStyle {
    static var dockPrimary: Self { Self() }
}

extension ButtonStyle where Self == DockSecondaryButtonStyle {
    static var dockSecondary: Self { Self() }
    /// Compatibility alias. Size is inherited from the enclosing action group.
    static var dockCompact: Self { Self() }
}

/// Inline navigation and disclosure stay recognizable in monochrome themes too.
struct DockLinkButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let tint = configuration.role == .destructive ? Color.dockDestructive : Color.dockAccent
        configuration.label
            .dockFont(.control)
            .foregroundStyle(tint)
            .underline(true, color: tint)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : isHovering ? 0.85 : 1) : 0.42)
            .animation(reduceMotion ? nil : .dockFeedback(isHovering), value: isHovering)
            .animation(reduceMotion ? nil : .dockFeedback(configuration.isPressed), value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }
}

extension ButtonStyle where Self == DockLinkButtonStyle {
    static var dockLink: Self { Self() }
}

extension TextFieldStyle where Self == DockGlassTextFieldStyle {
    static var dockGlass: Self { Self() }
}

extension ToggleStyle where Self == DockToggleStyle {
    static var dockSwitch: Self { Self() }
}

extension Shape {
    /// Theme-aware box/control fill: Liquid Glass on the glass skin, else `fallback`.
    /// Use it for any card, field, chip or segmented track instead of `fill(Color.dockSurface…)`.
    /// Neutral outlines are dropped on glass (native glass has its own rim);
    /// pass `strokeOnGlass` for strokes that carry state such as focus or tint.
    @MainActor @ViewBuilder
    func dockSurfaceFill(
        _ fallback: Color, interactive: Bool = false, stroke: Color? = nil, lineWidth: CGFloat = DockLayout.hairline,
        strokeOnGlass: Bool = false
    ) -> some View {
        if DockThemeStyle.current.material == .glass {
            Color.clear.dockLiquidGlass(self, interactive: interactive)
                .overlay { if strokeOnGlass, let stroke { self.stroke(stroke, lineWidth: lineWidth) } }
        } else {
            fill(fallback).overlay { if let stroke { self.stroke(stroke, lineWidth: lineWidth) } }
        }
    }

    /// Theme-aware row selection: the selected row becomes interactive glass on
    /// the glass skin (hover keeps `fallback`); other skins always use `fallback`.
    @MainActor @ViewBuilder
    func dockSelectionFill(_ isSelected: Bool, fallback: Color) -> some View {
        if isSelected && DockThemeStyle.current.material == .glass {
            Color.clear.dockLiquidGlass(self, interactive: true)
                .overlay(stroke(Color.dockGlassSelectionEdge, lineWidth: 1))
        } else {
            fill(fallback)
                .overlay(stroke(isSelected ? Color.dockPrimaryText.opacity(0.75) : .clear, lineWidth: 1))
        }
    }

    /// Input/composer background.
    @MainActor
    func dockInputFill() -> some View { dockSurfaceFill(Color.dockSurface2) }
}

extension View {
    /// Theme-aware full-width tint for headers, list columns and footers: clear on
    /// the glass skin (the window glass is the only layer), else `color`.
    @MainActor @ViewBuilder
    func dockPaneTint(_ color: Color) -> some View {
        if DockThemeStyle.current.material == .glass { self } else { background(color) }
    }
}

extension View {
    /// Liquid Glass surface. `elevated` (floating panels, buttons) uses native
    /// `glassEffect` on macOS 26, which casts a drop shadow; inline surfaces and
    /// older systems get a blurred body with a specular rim and top sheen, so
    /// rows of chips and cards never smear their shadows together.
    @ViewBuilder
    func dockLiquidGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false, elevated: Bool = false)
        -> some View
    {
        if elevated, #available(macOS 26.0, *) {
            self.background(shape.fill(Color.dockLightGlassLift)).glassEffect(
                {
                    var g = Glass.regular
                    if let tint { g = g.tint(tint) }
                    return interactive ? g.interactive() : g
                }(), in: shape)
        } else {
            // A single material body with an appearance-aware edge keeps dense surfaces quiet.
            self
                .background(shape.fill(tint ?? .clear))
                .background(shape.fill(Color.dockLightGlassLift))
                .background(shape.fill(.thinMaterial))
                .background(shape.fill(Color.dockSurface))
                .overlay(shape.stroke(Color.dockLightGlassEdge, lineWidth: DockLayout.hairline))
                .overlay(
                    shape.stroke(
                        LinearGradient(
                            colors: [.dockGlassHighlight, .clear, .dockGlassHighlight.opacity(0.3)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: DockLayout.hairline
                    )
                )
                .clipShape(shape)
        }
    }

    /// Floating panels (menus, popovers, navigators): Liquid Glass on the glass
    /// skin; elsewhere an opaque canvas so content beneath never bleeds through.
    @ViewBuilder
    func dockFloatingSurface<S: Shape>(
        _ shape: S, tint: Color = .clear, stroke: Color = .dockBorder, lineWidth: CGFloat = DockLayout.hairline
    ) -> some View {
        if DockThemeStyle.current.material == .glass {
            dockLiquidGlass(shape, elevated: true)
        } else {
            background(shape.fill(tint)).background(shape.fill(Color.dockOpaqueCanvas)).overlay(
                shape.stroke(stroke, lineWidth: lineWidth))
        }
    }

    /// Level 1 glass pane: reserved for a focused, interactive unit of work.
    func dockGlassPane() -> some View {
        self
            .background(Color.clear)
            .overlay(alignment: .bottom) {
                Color.dockBorderLight.frame(height: 0.5)
            }
    }

    /// Divider-led rows keep operational lists dense without turning each item
    /// into a separate card.
    func dockListRow(isHighlighted: Bool = false) -> some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius - 1)
        return
            self
            .frame(maxWidth: .infinity, alignment: .leading)
            .dockPadding(.horizontal, 10)
            .dockPadding(.vertical, 10)
            .dockSelectionBackground(
                shape, active: isHighlighted, fill: Color.dockAccent.opacity(0.10), allowsInvert: false
            )
            .overlay(alignment: .bottom) {
                Color.dockBorderLight
                    .opacity(isHighlighted ? 0 : 1)
                    .frame(height: DockLayout.hairline)
            }
            .contentShape(Rectangle())
    }

    /// Shared compact surface for secondary inspectors and detail groups.
    /// It uses the same low-contrast treatment as the main Control panel.
    @ViewBuilder
    func dockCard(padding: CGFloat = 12, isQuiet: Bool = false) -> some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.paneRadius, role: .pane)
        let style = DockThemeStyle.current
        if style.chrome == .open {
            // Typographic skins: spacing and type group content, not boxes.
            self.dockPadding(padding)
        } else if style.material == .glass {
            self
                .dockPadding(padding)
                .dockLiquidGlass(shape)
        } else if isQuiet {
            self
                .dockPadding(padding)
                .background(shape.fill(Color.dockSurface))
                .overlay(shape.stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline))
        } else {
            self
                .dockPadding(padding)
                .background(shape.fill(Color.dockSurface.opacity(style.cardFill)))
                // A 0-width stroke still draws a hairline, so outline-free skins skip it.
                .overlay(
                    shape.stroke(
                        DockLayout.outline > 1 ? Color.dockBorderStrong : Color.dockBorderLight.opacity(0.72),
                        lineWidth: DockLayout.outline
                    ).opacity(DockLayout.outline > 0 ? 1 : 0)
                )
                .dockStickerShadow(shape)
                .dockFoldCrease()
                .dockEmboss(shape)
                .dockBevel()
                .dockCardMarks()
                .dockCardDepth()
        }
    }

    /// Soft drop shadow and accent halo for themes that opt in; both are 0 by default.
    func dockCardDepth() -> some View {
        let style = DockThemeStyle.current
        return shadow(
            color: Color.black.opacity(style.cardShadow > 0 ? 0.14 : 0), radius: style.cardShadow,
            y: style.cardShadow / 3
        )
        .shadow(color: Color.dockAccent.opacity(style.glow > 0 ? 0.22 : 0), radius: style.glow)
    }
}

/// The standard tab control for mutually exclusive scopes on every page.
struct DockTabButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let isSelected: Bool
    var showsSelectionMark = false
    let action: () -> Void

    var body: some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius - 1)
        Button(action: action) {
            HStack(spacing: 4) {
                if showsSelectionMark && isSelected {
                    DockIcon(
                        .check, size: 11,
                        color: DockThemeStyle.current.selection == .invert ? Color.dockCanvas : Color.dockPrimaryText)
                }
                Text(title)
            }
            .dockFont(.metadata, weight: isSelected ? .medium : .regular)
            .foregroundStyle(
                isSelected
                    ? (DockThemeStyle.current.selection == .invert ? Color.dockCanvas : Color.dockPrimaryText)
                    : Color.dockSecondaryText
            )
            .dockPadding(.horizontal, showsSelectionMark ? 6 : 10)
            .frame(height: 30)
            .dockSelectionBackground(
                shape, active: isSelected,
                fill: DockThemeStyle.current.material == .glass ? .clear : Color.dockSurface4
            )
            .background {
                if isSelected && DockThemeStyle.current.material == .glass {
                    Color.clear.dockLiquidGlass(
                        shape, tint: colorScheme == .light ? Color.dockAccentMuted : nil, interactive: true)
                }
            }
            .overlay(
                shape.stroke(
                    isSelected && (showsSelectionMark || DockLayout.outline > 1) ? Color.dockBorderStrong : .clear,
                    lineWidth: DockLayout.outline))
        }
        .buttonStyle(.dockHover)
        .contentShape(shape)
        .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.18), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A row of `DockTabButton`s bound to a selection, replacing segmented pickers.
struct DockTabBar<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                DockTabButton(title: title(option), isSelected: selection == option) { selection = option }
            }
        }
        .dockTabTrack()
    }
}

extension View {
    /// Seats a row of `DockTabButton`s in the shared segmented track.
    func dockTabTrack() -> some View {
        dockPadding(2)
            .background(
                DockThemeShape(cornerRadius: DockLayout.controlRadius + 1)
                    .dockSurfaceFill(Color.dockSurface4.opacity(0.5))
            )
    }
}

/// A native floating tip stays above sibling views and outside scroll clipping.
struct DockHoverTip: ViewModifier {
    let text: String
    let edge: Edge
    var gap: CGFloat = 6
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .background(DockHoverTipAnchor(text: text, edge: edge, gap: gap, hovering: hovering))
    }
}

extension View {
    func dockHoverTip(_ text: String, edge: Edge = .bottom, gap: CGFloat = 6) -> some View {
        modifier(DockHoverTip(text: text, edge: edge, gap: gap))
    }

    /// Shadows SwiftUI's `.help`: native tooltips only show in the key window, so
    /// they fail in Herm's non-activating panels. Every `.help("…")` uses our floating tip.
    func help(_ text: String) -> some View { dockHoverTip(text) }
}

/// Pins the SwiftUI colour scheme for fixed light/dark skins; system skins follow macOS.
private struct DockPinnedColorScheme: ViewModifier {
    @Environment(\.colorScheme) private var systemColorScheme

    func body(content: Content) -> some View {
        let colorScheme: ColorScheme =
            switch DockThemeRuntime.current.appearance {
            case .light: .light
            case .dark: .dark
            case .system: systemColorScheme
            }
        // Keep content identity stable so skin changes preserve navigation and drafts.
        return content.environment(\.colorScheme, colorScheme)
    }
}

struct DockBevel: View {
    let pressed: Bool
    var enabled: Bool = DockThemeStyle.current.bevel

    var body: some View {
        if enabled {
            Canvas { context, size in
                let w = size.width
                let h = size.height
                let light = Color.white
                let dark = Color.black.opacity(0.55)
                func edge(_ points: [CGPoint], _ color: Color) {
                    var path = Path()
                    path.addLines(points)
                    context.stroke(path, with: .color(color), lineWidth: 2)
                }
                edge([CGPoint(x: 1, y: h - 1), CGPoint(x: 1, y: 1), CGPoint(x: w - 1, y: 1)], pressed ? dark : light)
                edge(
                    [CGPoint(x: w - 1, y: 1), CGPoint(x: w - 1, y: h - 1), CGPoint(x: 1, y: h - 1)],
                    pressed ? light : dark)
            }
            .allowsHitTesting(false)
        }
    }
}

/// A text field whose placeholder follows the theme. The system placeholder
/// color ignores theme tokens and can vanish on themed surfaces.
struct DockTextField: View {
    let placeholder: String
    @Binding var text: String
    var axis: Axis = .horizontal

    init(_ placeholder: String, text: Binding<String>, axis: Axis = .horizontal) {
        self.placeholder = placeholder
        self._text = text
        self.axis = axis
    }

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Color.dockMetadataText), axis: axis)
    }
}
