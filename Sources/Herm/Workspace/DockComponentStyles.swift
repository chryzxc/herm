import AppKit
import SwiftUI

private func dockAdaptiveColor(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
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
    static var dockSurface: Color { DockThemePalette(theme: DockThemeRuntime.current).surface }
    static var dockSurface2: Color { DockThemePalette(theme: DockThemeRuntime.current).surface2 }
    static var dockSurface4: Color { DockThemePalette(theme: DockThemeRuntime.current).surface4 }
    static var dockSurface6: Color { DockThemePalette(theme: DockThemeRuntime.current).surface6 }
    static var dockSurface8: Color { DockThemePalette(theme: DockThemeRuntime.current).surface8 }
    static var dockMessageBubble: Color { dockSurface }
    static var dockUserMessageBubble: Color { dockAccent.opacity(0.12) }
    /// Opaque panel fill for popovers/overlays: system window colour for the translucent native skins, the skin canvas otherwise.
    static var dockOpaqueCanvas: Color { DockThemeRuntime.current.usesNativeMaterial ? Color(nsColor: .windowBackgroundColor) : dockCanvas }
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
    static var dockKanbanRunning: Color { dockAccent }
    static var dockKanbanReview: Color { dockSecondaryText }
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
    static var controlRadius: CGFloat { DockThemeStyle.current.controlRadius }
    static var paneRadius: CGFloat { DockThemeStyle.current.paneRadius }
    static var outline: CGFloat { DockThemeStyle.current.outlineWidth }
}

enum DockThemeShapeRole {
    case control
    case pane

    var foldSize: CGFloat {
        guard DockThemeStyle.current.geometry == .folded else { return 0 }
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

    func path(in rect: CGRect) -> Path {
        switch DockThemeStyle.current.geometry {
        case .pixel: return pixelPath(in: rect)
        case .sketch: return sketchPath(in: rect)
        case .chamfered: return chamferPath(in: rect)
        case .rounded, .folded: break
        }
        let fold = min(role.foldSize, min(rect.width, rect.height) * 0.38)
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
        let s = min(role.step, min(r.width, r.height) / 5), d = s * 2
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
            CGPoint(x: r.minX + s, y: r.minY + s), CGPoint(x: r.minX + d, y: r.minY + s)
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
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY + c)
        ])
        p.closeSubpath()
        return p
    }

    /// A smoothed closed curve through jittered edge points. The jitter is a
    /// pure function of the rect size, so a shape never shimmers on redraw.
    private func sketchPath(in r: CGRect) -> Path {
        let inset = max(cornerRadius, 6), amp: CGFloat = 1.3
        func jitter(_ i: Int) -> CGFloat {
            let v = sin(Double(i) * 12.9898 + Double(Int(r.width)) * 0.37 + Double(Int(r.height)) * 0.71) * 43758.5453
            return CGFloat(v - v.rounded(.down)) * 2 - 1
        }
        let base = [
            CGPoint(x: r.minX + inset, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX - inset, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY + inset), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY - inset),
            CGPoint(x: r.maxX - inset, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX + inset, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY - inset), CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.minX, y: r.minY + inset)
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
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                 (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
        }
        return p
    }
}

/// Faint ruled lines or grid on the window canvas.
private struct DockBackdrop: View {
    var body: some View {
        let kind = DockThemeStyle.current.backdrop
        if kind != .none {
            Canvas { context, size in
                let step: CGFloat = kind == .ruled ? 28 : 32
                var path = Path()
                var y = step
                while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                if kind == .grid {
                    var x = step
                    while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                }
                context.stroke(path, with: .color(Color.dockAccent.opacity(kind == .ruled ? 0.12 : 0.07)), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
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
        .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
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
            .fontDesign(DockThemeStyle.current.fontDesign)
            // Native controls (placeholders, carets, menus) follow the colour
            // scheme, not our tokens; pin it so a light skin under dark macOS
            // (or vice versa) doesn't get invisible placeholder text.
            .modifier(DockPinnedColorScheme())
            .transaction { transaction in
                // E-Ink: state changes land instantly, like a screen refresh.
                if !DockThemeStyle.current.animates {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }

    /// Marks an active/hovered tab, row, or control per the theme's selection
    /// style: tinted fill, inverted ink, or an accent underline. `allowsInvert`
    /// is false for containers whose children set their own text colors.
    func dockSelectionBackground<S: Shape>(_ shape: S, active: Bool, fill: Color, allowsInvert: Bool = true) -> some View {
        let mode = DockThemeStyle.current.selection
        return background {
            switch mode {
            case .underline:
                Color.clear
            case .invert where allowsInvert:
                shape.fill(active ? Color.dockPrimaryText : .clear)
            case .highlight:
                // A marker swipe behind the label, set slightly off-level.
                if active {
                    Color.dockMarker.opacity(0.5)
                        .frame(height: 12)
                        .rotationEffect(.degrees(-0.8))
                        .padding(.bottom, 4)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            default:
                shape.fill(active ? fill : .clear)
            }
        }
        .overlay(alignment: .bottom) {
            if mode == .underline && active { Color.dockAccent.frame(height: 2) }
        }
        .overlay(alignment: .leading) {
            if mode == .bar && active { Color.dockAccent.frame(width: 2) }
        }
    }

    /// Clay look: paired light and dark soft shadows behind the shape. Pressing
    /// flattens them so the control reads as pushed in.
    func dockEmboss<S: Shape>(_ shape: S, pressed: Bool = false) -> some View {
        let depth = DockThemeStyle.current.emboss * (pressed ? 0.3 : 1)
        return background {
            if depth > 0 {
                shape.fill(Color.dockCanvas)
                    .shadow(color: .white.opacity(0.85), radius: depth, x: -depth / 2, y: -depth / 2)
                    .shadow(color: .black.opacity(0.16), radius: depth, x: depth / 2, y: depth / 2)
            }
        }
    }

    /// Retro look: two-pixel light/dark edges. `pressed` (also used for inset fields) swaps them.
    func dockBevel(pressed: Bool = false) -> some View { overlay(DockBevel(pressed: pressed)) }

    /// Corner brackets (HUD) or a strip of tape (Notebook) on cards.
    func dockCardMarks() -> some View {
        let geometry = DockThemeStyle.current.geometry
        return overlay {
            if geometry == .chamfered {
                DockCornerBrackets().stroke(Color.dockAccent, lineWidth: 1.5).allowsHitTesting(false)
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
    func dockStickerShadow<S: Shape>(_ shape: S, pressed: Bool = false) -> some View {
        let offset = DockThemeStyle.current.stickerShadow * (pressed ? 0.35 : 1)
        return background {
            if offset > 0 {
                ZStack {
                    shape.fill(Color.dockBorderStrong).offset(x: offset, y: offset)
                    shape.fill(Color.dockCanvas)
                }
            }
        }
    }

    /// A quiet crease on larger Origami surfaces. It uses existing semantic
    /// colors and does not add content, state, or a new elevation level.
    func dockFoldCrease() -> some View {
        overlay {
            if DockThemeStyle.current.geometry == .folded {
                let crease = DockFoldCrease(size: DockThemeShapeRole.pane.foldSize)
                crease
                    .fill(Color.dockCanvas.opacity(0.72))
                    .overlay(crease.stroke(Color.dockBorder.opacity(0.75), lineWidth: DockLayout.hairline))
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

/// The workspace's base layer. Native macOS uses the real system popover
/// material under the shared palette; authored Herm themes keep their solid
/// canvas so selecting a theme never changes its intended color treatment.
struct DockWindowBackground: View {
    // Observed so the canvas repaints on theme switch; it has no other inputs.
    @ObservedObject private var themeStore = DockThemeStore.shared

    /// Glass samples the real backdrop with the system Liquid Glass effect
    /// (macOS 26+); older systems and System skin use the blur material.
    @ViewBuilder private var glassOrPopover: some View {
        if DockThemeRuntime.current == .glass, #available(macOS 26.0, *) {
            // glassEffect alone barely blurs; blur the backdrop first so text
            // from windows behind Herm cannot be read through it.
            NativePopoverBackground(material: .hudWindow)
                .overlay(Color.clear.glassEffect(.regular, in: Rectangle()))
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

/// Shared interaction and input treatments derived from DESIGN.md's glass
/// button and input specifications. Keeping them here prevents native control
/// styles from leaking into individual Control, chat, or Activity views.
struct DockPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius - 1)
        configuration.label
            .padding(3)
            .dockSelectionBackground(shape, active: isHovering, fill: Color.dockAccent.opacity(0.12), allowsInvert: false)
            .overlay(shape.stroke(isHovering ? Color.dockAccent.opacity(0.28) : Color.clear, lineWidth: DockLayout.outline))
            .scaleEffect(configuration.isPressed ? DockThemeStyle.current.pressScale : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: isHovering)
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
            .animation(reduceMotion ? nil : .dockEase(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// Drop-in for `.plain`/`.borderless`: same layout; hover lifts the label's own
/// pixels (and press dims them) so it never paints outside the visible control
/// when the hit area is larger than the artwork.
struct DockHoverButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.06 : isHovering && isEnabled ? 0.12 : 0)
            .animation(reduceMotion ? nil : .dockEase(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    func dockHoverable(cornerRadius: CGFloat = DockLayout.controlRadius - 1) -> some View {
        modifier(DockHoverModifier(cornerRadius: cornerRadius))
    }
}

/// The single filled action treatment from DESIGN.md. Use it only for the
/// primary action in a section; secondary actions stay text-on-glass.
struct DockPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isCompact = controlSize == .small || controlSize == .mini
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius)
        configuration.label
            .font(isCompact ? .system(size: 12, weight: .semibold) : .body.weight(.semibold))
            .foregroundStyle(Color.dockOnAccentText)
            .padding(.horizontal, isCompact ? 10 : 12)
            .frame(minHeight: isCompact ? 26 : DockLayout.controlHeight)
            .background {
                if DockThemeStyle.current.material == .glass {
                    Color.clear.dockLiquidGlass(shape, tint: Color.dockAccent, interactive: true)
                } else {
                    shape.fill(Color.dockAccent.opacity(configuration.isPressed ? 0.82 : 1)).stroke(DockLayout.outline > 1 ? Color.dockBorderStrong : .clear, lineWidth: DockLayout.outline)
                }
                if DockThemeStyle.current.accentGradient && DockThemeStyle.current.material != .glass {
                    shape.fill(LinearGradient(colors: [Color.white.opacity(0.20), .clear], startPoint: .top, endPoint: .bottom))
                }
            }
            .dockStickerShadow(shape, pressed: configuration.isPressed)
            .dockEmboss(shape, pressed: configuration.isPressed)
            .dockBevel(pressed: configuration.isPressed)
            .shadow(color: Color.dockAccent.opacity(configuration.isPressed || !isEnabled ? 0 : 0.14 + (DockThemeStyle.current.glow > 0 ? 0.4 : 0)), radius: 6 + DockThemeStyle.current.glow)
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? DockThemeStyle.current.pressScale : 1)
            .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: configuration.isPressed)
    }
}

/// The outlined companion to the primary action (Cancel, Remove, Copy). A
/// destructive role tints the label instead of filling the control.
struct DockSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let isCompact = controlSize == .small || controlSize == .mini
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius)
        configuration.label
            .font(isCompact ? .system(size: 12, weight: .medium) : .body.weight(.medium))
            .foregroundStyle(configuration.role == .destructive ? Color.dockDestructive : Color.dockPrimaryText)
            .padding(.horizontal, isCompact ? 10 : 12)
            .frame(minHeight: isCompact ? 26 : DockLayout.controlHeight)
            .background {
                if DockThemeStyle.current.material == .glass {
                    Color.clear.dockLiquidGlass(shape, interactive: true)
                } else if DockThemeStyle.current.chrome == .boxed {
                    shape.fill(configuration.isPressed ? Color.dockSurface6 : isHovering ? Color.dockSurface4 : Color.dockControlSurface.opacity(0.6)).stroke(Color.dockBorder, lineWidth: DockLayout.outline)
                }
            }
            .overlay(alignment: .bottom) {
                // Open chrome: text-only control that underlines on hover.
                if DockThemeStyle.current.chrome == .open && (isHovering || configuration.isPressed) {
                    Color.dockAccent.frame(height: 2)
                }
            }
            .dockStickerShadow(shape, pressed: configuration.isPressed)
            .dockEmboss(shape, pressed: configuration.isPressed)
            .dockBevel(pressed: configuration.isPressed)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? DockThemeStyle.current.pressScale : 1)
            .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: configuration.isPressed)
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
                                .stroke(configuration.isOn ? Color.dockAccent.opacity(0.72) : Color.dockBorderStrong, lineWidth: max(0.7, DockLayout.outline))
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
        .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: configuration.isOn)
    }
}

struct DockGlassTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius)
        configuration
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundStyle(Color.dockPrimaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: DockLayout.controlHeight)
            // The shared canvas keeps inputs consistent across panes; the
            // plain field style removes the warm native field fill.
            .background(shape.fill(Color.dockControlSurface).stroke(Color.dockBorder, lineWidth: DockLayout.outline))
            .overlay(DockBevel(pressed: true))
    }
}

/// The consistent title treatment for full workspace destinations. Keeping it
/// shared prevents individual pages from inventing competing title bars.
struct DockPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let onRefresh: (() -> Void)?
    let isRefreshing: Bool
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String,
        onRefresh: (() -> Void)? = nil,
        isRefreshing: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onRefresh = onRefresh
        self.isRefreshing = isRefreshing
        self.trailing = trailing
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DockTypography.pageTitle)
                .foregroundStyle(Color.dockPrimaryText)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
        }
    }

    private var refreshButton: some View {
        Group {
            if let onRefresh {
                Button(action: onRefresh) {
                    Group {
                        if isRefreshing {
                            ProgressView().controlSize(.small).tint(Color.dockSecondaryText)
                        } else {
                            DockIcon(.arrowsClockwise)
                                .font(.system(size: 14, weight: .medium))
                        }
                    }
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.dockHover)
                .disabled(isRefreshing)
                .help("Refresh")
            }
        }
    }

    var body: some View {
        // One row when it fits; in the minimized panel the trailing controls
        // drop to their own row instead of truncating.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                titleBlock.frame(maxWidth: 360, alignment: .leading)
                Spacer(minLength: 12)
                refreshButton
                trailing().fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    titleBlock
                    Spacer(minLength: 12)
                    refreshButton
                }
                HStack(spacing: 8) { trailing() }
            }
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
        .padding(.bottom, 10)
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }
}

extension DockPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String, onRefresh: (() -> Void)? = nil, isRefreshing: Bool = false) {
        self.init(title: title, subtitle: subtitle, onRefresh: onRefresh, isRefreshing: isRefreshing) { EmptyView() }
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DockSpacing.control)
                if let badge { statusPill(badge, tint: tint) }
            }
            .padding(.horizontal, DockSpacing.group)
            .padding(.vertical, DockSpacing.control + 2)
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
                .padding(DockSpacing.group)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dockSurface)
        .clipShape(shape)
        .overlay(shape.stroke(tint.opacity(0.35), lineWidth: DockLayout.hairline))
        .dockFoldCrease()
        .accessibilityElement(children: .contain)
    }

    private func statusPill(_ badge: String, tint: Color) -> some View {
        HStack(spacing: DockSpacing.micro) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(badge).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .fixedSize()
    }
}

/// A labelled, collapsed-by-default block for supporting detail (scope, limits,
/// stack traces) so the decision and its buttons stay above the fold.
struct DockCalloutDisclosure: View {
    let title: String
    let text: String
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: DockSpacing.tight) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: DockSpacing.tight) {
                    DockIcon(isOpen ? .caretDown : .caretRight, size: 11, color: .dockMetadataText)
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
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
                        .font(.system(size: 12))
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DockThemeShape(cornerRadius: DockLayout.controlRadius)
                .fill(Color.dockSurface2.opacity(0.6))
                .stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline)
        )
    }
}

/// Secondary text that collapses to a few lines with a Show more toggle, so a
/// long scope or error never pushes the actions off screen. Short text renders
/// as plain text with no toggle.
struct DockExpandableText: View {
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
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .foregroundStyle(prominent ? Color.dockPrimaryText : Color.dockSecondaryText)
                .lineSpacing(2)
                .lineLimit(isExpanded || !isLong ? nil : lineLimit)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if isLong {
                Button(isExpanded ? "Show less" : "Show more") {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockAccent)
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

    @State private var isVisible = false

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
                .tint(Color.dockAccent)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockSecondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity)
        .opacity(isVisible ? 1 : 0)
        .onAppear { withAnimation(.dockEase(duration: 0.2)) { isVisible = true } }
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
}

extension TextFieldStyle where Self == DockGlassTextFieldStyle {
    static var dockGlass: Self { Self() }
}

extension ToggleStyle where Self == DockToggleStyle {
    static var dockSwitch: Self { Self() }
}

extension Shape {
    /// Input/composer background: Liquid Glass on the glass skin, else the solid surface.
    @MainActor @ViewBuilder
    func dockInputFill() -> some View {
        if DockThemeStyle.current.material == .glass {
            Color.clear.dockLiquidGlass(self)
        } else {
            fill(Color.dockSurface2)
        }
    }
}

extension View {
    /// Liquid Glass surface: native `glassEffect` on macOS 26, otherwise a
    /// blurred body with a specular rim and a soft top sheen approximating it.
    @ViewBuilder
    func dockLiquidGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect({ var g = Glass.regular; if let tint { g = g.tint(tint) }; return interactive ? g.interactive() : g }(), in: shape)
        } else {
            self
                .background(shape.fill(.ultraThinMaterial))
                .background(shape.fill((tint ?? .clear).opacity(0.55)))
                .background(shape.fill(LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .center)))
                .overlay(shape.stroke(
                    LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.08), .white.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                ))
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
        return self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .dockSelectionBackground(shape, active: isHighlighted, fill: Color.dockAccent.opacity(0.10), allowsInvert: false)
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
    func dockCard(padding: CGFloat = 12) -> some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.paneRadius, role: .pane)
        let style = DockThemeStyle.current
        if style.chrome == .open {
            // Typographic skins: spacing and type group content, not boxes.
            self.padding(padding)
        } else if style.material == .glass {
            self
                .padding(padding)
                .dockLiquidGlass(shape)
                .dockCardDepth()
        } else {
            self
                .padding(padding)
                .background(shape.fill(Color.dockSurface.opacity(0.26)))
                .overlay(shape.stroke(DockLayout.outline > 1 ? Color.dockBorderStrong : Color.dockBorderLight.opacity(0.72), lineWidth: DockLayout.outline))
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
        return shadow(color: Color.black.opacity(style.cardShadow > 0 ? 0.14 : 0), radius: style.cardShadow, y: style.cardShadow / 3)
            .shadow(color: Color.dockAccent.opacity(style.glow > 0 ? 0.22 : 0), radius: style.glow)
    }
}

/// The standard tab control for mutually exclusive scopes on every page.
struct DockTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius - 1)
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? (DockThemeStyle.current.selection == .invert ? Color.dockCanvas : Color.dockPrimaryText) : Color.dockSecondaryText)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .dockSelectionBackground(shape, active: isSelected, fill: DockThemeStyle.current.material == .glass ? .clear : Color.dockSurface4)
                .background { if isSelected && DockThemeStyle.current.material == .glass { Color.clear.dockLiquidGlass(shape, interactive: true) } }
                .overlay(shape.stroke(isSelected && DockLayout.outline > 1 ? Color.dockBorderStrong : .clear, lineWidth: DockLayout.outline))
        }
        .buttonStyle(.dockHover)
        .contentShape(shape)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A row of `DockTabButton`s bound to a selection, replacing segmented pickers.
struct DockTabBar<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                DockTabButton(title: title(option), isSelected: selection == option) { selection = option }
            }
        }
    }
}

/// `.help` tooltips never appear in Herm's non-activating panels, so hover
/// draws its own label beside the control after a short delay.
struct DockHoverTip: ViewModifier {
    let text: String
    let edge: Edge
    var gap: CGFloat = 6
    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                pending?.cancel()
                guard hovering else { shown = false; return }
                pending = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    if !Task.isCancelled { shown = true }
                }
            }
            .onDisappear { pending?.cancel(); shown = false }
            .overlay(alignment: alignment) {
                if shown {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.dockSurface4))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.dockBorderStrong, lineWidth: 1))
                        .alignmentGuide(.leading) { $0[.trailing] + gap }
                        .alignmentGuide(.trailing) { $0[.leading] - gap }
                        .alignmentGuide(.top) { $0[.bottom] + gap }
                        .alignmentGuide(.bottom) { $0[.top] - gap }
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .zIndex(shown ? 10 : 0)
            .animation(.dockEase(duration: 0.12), value: shown)
    }

    private var alignment: Alignment {
        switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }
}

extension View {
    func dockHoverTip(_ text: String, edge: Edge = .bottom, gap: CGFloat = 6) -> some View {
        modifier(DockHoverTip(text: text, edge: edge, gap: gap))
    }

    /// Shadows SwiftUI's `.help`: native tooltips only show in the key window, so
    /// they fail in Herm's non-activating panels. Every `.help("…")` draws our tip.
    func help(_ text: String) -> some View { dockHoverTip(text) }
}

/// Pins the SwiftUI colour scheme for fixed light/dark skins; system skins follow macOS.
private struct DockPinnedColorScheme: ViewModifier {
    func body(content: Content) -> some View {
        switch DockThemeRuntime.current.appearance {
        case .light: content.environment(\.colorScheme, .light)
        case .dark: content.environment(\.colorScheme, .dark)
        case .system: content
        }
    }
}

struct DockBevel: View {
    let pressed: Bool

    var body: some View {
        if DockThemeStyle.current.bevel {
            Canvas { context, size in
                let w = size.width, h = size.height
                let light = Color.white, dark = Color.black.opacity(0.55)
                func edge(_ points: [CGPoint], _ color: Color) {
                    var path = Path(); path.addLines(points)
                    context.stroke(path, with: .color(color), lineWidth: 2)
                }
                edge([CGPoint(x: 1, y: h - 1), CGPoint(x: 1, y: 1), CGPoint(x: w - 1, y: 1)], pressed ? dark : light)
                edge([CGPoint(x: w - 1, y: 1), CGPoint(x: w - 1, y: h - 1), CGPoint(x: 1, y: h - 1)], pressed ? light : dark)
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
