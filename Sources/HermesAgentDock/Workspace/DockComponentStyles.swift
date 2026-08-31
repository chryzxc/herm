import AppKit
import SwiftUI

private func dockAdaptiveColor(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    })
}

extension Color {
    // Shared appearance-aware palette for the Dock popover and its supporting
    // panels. These roles intentionally follow the system Light/Dark mode.
    static let dockOnAccentText = dockAdaptiveColor(
        light: NSColor.white,
        dark: NSColor(red: 0.90, green: 0.91, blue: 0.94, alpha: 1)
    )
    // Match the cool navy tint of macOS menu-bar popovers instead of allowing
    // the host window's warm/black material to determine the panel palette.
    static let dockCanvas = dockAdaptiveColor(
        light: NSColor(white: 0.98, alpha: 1),
        dark: NSColor(red: 0.055, green: 0.07, blue: 0.12, alpha: 1)
    )
    static let dockSurface = dockAdaptiveColor(
        light: NSColor(white: 0.96, alpha: 1),
        dark: NSColor(red: 0.075, green: 0.09, blue: 0.15, alpha: 1)
    )
    static let dockSurface2 = dockAdaptiveColor(
        light: NSColor(white: 0.985, alpha: 1),
        dark: NSColor(red: 0.06, green: 0.075, blue: 0.125, alpha: 1)
    )
    static let dockSurface4 = dockAdaptiveColor(
        light: NSColor(white: 0.94, alpha: 1),
        dark: NSColor(red: 0.09, green: 0.105, blue: 0.17, alpha: 1)
    )
    static let dockSurface6 = dockAdaptiveColor(
        light: NSColor(white: 0.92, alpha: 1),
        dark: NSColor(red: 0.105, green: 0.12, blue: 0.19, alpha: 1)
    )
    static let dockSurface8 = dockAdaptiveColor(
        light: NSColor(white: 0.90, alpha: 1),
        dark: NSColor(red: 0.12, green: 0.14, blue: 0.22, alpha: 1)
    )
    static let dockMessageBubble = dockSurface
    static let dockUserMessageBubble = dockAdaptiveColor(
        light: NSColor.systemBlue.withAlphaComponent(0.10),
        dark: NSColor.systemBlue.withAlphaComponent(0.20)
    )
    static let dockControlSurface = dockSurface4
    static let dockBorderStrong = dockAdaptiveColor(
        light: NSColor.separatorColor.withAlphaComponent(0.72),
        dark: NSColor(white: 1, alpha: 0.16)
    )
    static let dockBorder = dockAdaptiveColor(
        light: NSColor.separatorColor.withAlphaComponent(0.52),
        dark: NSColor(white: 1, alpha: 0.11)
    )
    static let dockBorderLight = dockAdaptiveColor(
        light: NSColor.separatorColor.withAlphaComponent(0.38),
        dark: NSColor(white: 1, alpha: 0.075)
    )
    static let dockAccent = dockAdaptiveColor(
        light: NSColor(red: 0.02, green: 0.36, blue: 0.82, alpha: 1),
        dark: NSColor(red: 0.22, green: 0.54, blue: 0.96, alpha: 1)
    )
    static let dockAccentMuted = dockAccent.opacity(0.14)
    static let dockAccentGlow = Color.clear
    static let dockPrimaryText = dockAdaptiveColor(
        light: NSColor(white: 0.12, alpha: 1),
        // Keep primary text readable without using an eye-straining near-white.
        dark: NSColor(red: 0.82, green: 0.83, blue: 0.87, alpha: 1)
    )
    static let dockSecondaryText = dockAdaptiveColor(
        light: NSColor(white: 0.35, alpha: 1),
        dark: NSColor(red: 0.64, green: 0.66, blue: 0.71, alpha: 1)
    )
    static let dockMetadataText = dockAdaptiveColor(
        light: NSColor(white: 0.46, alpha: 1),
        dark: NSColor(red: 0.56, green: 0.58, blue: 0.64, alpha: 1)
    )
    static let dockSectionText = dockSecondaryText
    // Kanban lifecycle accents shared by board and session-kanban surfaces.
    static let dockKanbanRunning = dockAccent
    static let dockKanbanReview = Color(nsColor: .secondaryLabelColor)
    static let dockSuccess = dockAdaptiveColor(
        light: NSColor(red: 0.13, green: 0.55, blue: 0.25, alpha: 1),
        dark: NSColor(red: 0.20, green: 0.76, blue: 0.42, alpha: 1)
    )
    static let dockWarning = dockAdaptiveColor(
        light: NSColor(red: 0.78, green: 0.43, blue: 0.05, alpha: 1),
        dark: NSColor(red: 0.94, green: 0.60, blue: 0.16, alpha: 1)
    )
    static let dockFolder = Color(nsColor: .secondaryLabelColor)
    static let dockDestructive = dockAdaptiveColor(
        light: NSColor(red: 0.78, green: 0.16, blue: 0.20, alpha: 1),
        dark: NSColor(red: 0.92, green: 0.30, blue: 0.34, alpha: 1)
    )
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
}

/// AppKit's actual menu-bar popover material. Keeping this as a view instead
/// of approximating it with layered SwiftUI colors gives the panel the same
/// appearance-aware blur used by macOS system menus.
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.dockOnAccentText)
            .padding(.horizontal, 12)
            .frame(minHeight: DockLayout.controlHeight)
            .background(Color.dockAccent.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
            .shadow(color: Color.dockAccent.opacity(configuration.isPressed ? 0 : 0.14), radius: 6)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: configuration.isPressed)
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

extension ButtonStyle where Self == DockPressButtonStyle {
    static var dockPress: Self { Self() }
}

extension ButtonStyle where Self == DockPrimaryButtonStyle {
    static var dockPrimary: Self { Self() }
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
