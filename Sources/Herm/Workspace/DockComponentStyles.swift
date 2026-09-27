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
    static let controlRadius: CGFloat = 8
    static let paneRadius: CGFloat = 10
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
        configuration.label
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? Color.dockAccent.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isHovering ? Color.dockAccent.opacity(0.28) : Color.clear, lineWidth: 0.5)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
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
        configuration.label
            .font(isCompact ? .system(size: 12, weight: .semibold) : .body.weight(.semibold))
            .foregroundStyle(Color.dockOnAccentText)
            .padding(.horizontal, isCompact ? 10 : 12)
            .frame(minHeight: isCompact ? 26 : DockLayout.controlHeight)
            .background(Color.dockAccent.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            .shadow(color: Color.dockAccent.opacity(configuration.isPressed || !isEnabled ? 0 : 0.14), radius: 6)
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
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
        configuration.label
            .font(isCompact ? .system(size: 12, weight: .medium) : .body.weight(.medium))
            .foregroundStyle(configuration.role == .destructive ? Color.dockDestructive : Color.dockPrimaryText)
            .padding(.horizontal, isCompact ? 10 : 12)
            .frame(minHeight: isCompact ? 26 : DockLayout.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .fill(configuration.isPressed ? Color.dockSurface6 : isHovering ? Color.dockSurface4 : Color.dockControlSurface.opacity(0.6))
                    .stroke(Color.dockBorder, lineWidth: DockLayout.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
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
                                .stroke(configuration.isOn ? Color.dockAccent.opacity(0.72) : Color.dockBorderStrong, lineWidth: 0.7)
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
        configuration
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundStyle(Color.dockPrimaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: DockLayout.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    // The shared canvas keeps inputs consistent across panes;
                    // the plain field style removes the warm native field fill.
                    .fill(Color.dockControlSurface)
                    .stroke(Color.dockBorder, lineWidth: 0.5)
            )
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
        let shape = RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            DockIcon(icon, size: 15, weight: .fill, color: tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.14)))
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
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHighlighted ? Color.dockAccent.opacity(0.10) : Color.clear)
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
    func dockCard(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous)
                    .fill(Color.dockSurface.opacity(0.26))
            )
            .overlay {
                RoundedRectangle(cornerRadius: DockLayout.paneRadius, style: .continuous)
                    .stroke(Color.dockBorderLight.opacity(0.72), lineWidth: DockLayout.hairline)
            }
    }
}

/// The standard tab control for mutually exclusive scopes on every page.
struct DockTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? Color.dockSurface4 : Color.clear))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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
