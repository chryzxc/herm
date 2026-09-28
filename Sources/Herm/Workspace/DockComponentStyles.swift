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
    static let dockOnAccentText = dockAdaptiveColor(
        light: NSColor.white,
        dark: NSColor(red: 0.90, green: 0.91, blue: 0.94, alpha: 1)
    )
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
    static var dockControlSurface: Color { dockSurface4 }
    static var dockBorderStrong: Color { DockThemePalette(theme: DockThemeRuntime.current).divider.opacity(0.95) }
    static var dockBorder: Color { DockThemePalette(theme: DockThemeRuntime.current).divider.opacity(0.72) }
    static var dockBorderLight: Color { DockThemePalette(theme: DockThemeRuntime.current).divider.opacity(0.48) }
    static var dockAccent: Color { DockThemePalette(theme: DockThemeRuntime.current).accent }
    static var dockAccentMuted: Color { dockAccent.opacity(0.14) }
    static let dockAccentGlow = Color.clear
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
}

/// One shared silhouette for themed controls and surfaces. Rounded themes use
/// the existing continuous rectangle; Origami clips opposing corners so the
/// component geometry changes without special-casing individual screens.
struct DockThemeShape: Shape {
    let cornerRadius: CGFloat
    var role: DockThemeShapeRole = .control

    func path(in rect: CGRect) -> Path {
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
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .popover
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

    var body: some View {
        if DockThemeRuntime.current.usesNativeMaterial {
            NativePopoverBackground()
                .overlay(DockThemePalette(theme: .nativeMacOS).windowBackground)
        } else {
            Color.dockCanvas
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
            .background(shape.fill(isHovering ? Color.dockAccent.opacity(0.12) : Color.clear))
            .overlay(shape.stroke(isHovering ? Color.dockAccent.opacity(0.28) : Color.clear, lineWidth: DockLayout.outline))
            .scaleEffect(configuration.isPressed ? DockThemeStyle.current.pressScale : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: isHovering)
            .onHover { isHovering = $0 }
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
            .background(shape.fill(Color.dockAccent.opacity(configuration.isPressed ? 0.82 : 1)).stroke(DockLayout.outline > 1 ? Color.dockBorderStrong : .clear, lineWidth: DockLayout.outline))
            .dockStickerShadow(shape, pressed: configuration.isPressed)
            .shadow(color: Color.dockAccent.opacity(configuration.isPressed || !isEnabled ? 0 : 0.14), radius: 6)
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
            .background(shape.fill(configuration.isPressed ? Color.dockSurface6 : isHovering ? Color.dockSurface4 : Color.dockControlSurface.opacity(0.6)).stroke(Color.dockBorder, lineWidth: DockLayout.outline))
            .dockStickerShadow(shape, pressed: configuration.isPressed)
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
        .buttonStyle(.borderless)
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

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if let onRefresh {
                Button(action: onRefresh) {
                    Group {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            DockIcon(.arrowsClockwise)
                                .font(.system(size: 14, weight: .medium))
                        }
                    }
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help("Refresh")
            }
            trailing()
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
/// waiting on. One shape — tinted icon tile, title, message, optional badge,
/// then any body or actions — so every alert in a list reads the same.
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
        HStack(alignment: .top, spacing: 10) {
            DockIcon(icon, size: 15, weight: .fill, color: tint)
                .frame(width: 28, height: 28)
                .background(DockThemeShape(cornerRadius: DockLayout.controlRadius - 1).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.dockPrimaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(tint)
                                .padding(.horizontal, 7)
                                .frame(height: 18)
                                .background(Capsule().fill(tint.opacity(0.12)))
                        }
                    }
                    if let message, !message.isEmpty {
                        Text(message)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content()
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color.dockSurface).overlay(shape.fill(tint.opacity(0.05))))
        .overlay(alignment: .leading) { tint.frame(width: 3) }
        .clipShape(shape)
        .overlay(shape.stroke(tint.opacity(0.3), lineWidth: DockLayout.hairline))
        .dockFoldCrease()
        .accessibilityElement(children: .contain)
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

extension View {
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
            .background(shape.fill(isHighlighted ? Color.dockAccent.opacity(0.10) : Color.clear))
            .overlay(alignment: .bottom) {
                Color.dockBorderLight
                    .opacity(isHighlighted ? 0 : 1)
                    .frame(height: DockLayout.hairline)
            }
            .contentShape(Rectangle())
    }

    /// Shared compact surface for secondary inspectors and detail groups.
    /// It uses the same low-contrast treatment as the main Control panel.
    func dockCard(padding: CGFloat = 12) -> some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.paneRadius, role: .pane)
        return self
            .padding(padding)
            .background(shape.fill(Color.dockSurface.opacity(0.26)))
            .overlay(shape.stroke(DockLayout.outline > 1 ? Color.dockBorderStrong : Color.dockBorderLight.opacity(0.72), lineWidth: DockLayout.outline))
            .dockStickerShadow(shape)
            .dockFoldCrease()
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
                .foregroundStyle(isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(shape.fill(isSelected ? Color.dockSurface4 : Color.clear))
                .overlay(shape.stroke(isSelected && DockLayout.outline > 1 ? Color.dockBorderStrong : .clear, lineWidth: DockLayout.outline))
        }
        .buttonStyle(.plain)
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
