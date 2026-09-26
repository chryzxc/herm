import AppKit
import SwiftUI

/// Central presentation contract for Dock-owned interfaces. Feature views use
/// these semantic roles rather than introducing near-duplicate font sizes,
/// row heights, and compact control treatments.
enum DockTypography {
    static let pageTitle: Font = .system(size: 16, weight: .semibold)
    static let sectionLabel: Font = .system(size: 10, weight: .semibold, design: .monospaced)
    static let rowTitle: Font = .system(size: 12, weight: .medium)
    static let body: Font = .system(size: 12)
    static let control: Font = .system(size: 12, weight: .medium)
    static let metadata: Font = .system(size: 11)
    static let machineMetadata: Font = .system(size: 11, design: .monospaced)
    static let compactStatus: Font = .system(size: 10, weight: .semibold, design: .monospaced)
    /// Measured figures on monitoring surfaces, such as remaining quota.
    static let metric: Font = .system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()
}
enum DockSpacing {
    static let micro: CGFloat = 4
    static let tight: CGFloat = 6
    static let control: CGFloat = 8
    static let group: CGFloat = 12
    static let section: CGFloat = 16
    static let page: CGFloat = 20
}

enum DockControlMetrics {
    static let compactHeight: CGFloat = 28
    static let standardHeight: CGFloat = 36
    static let hitTarget: CGFloat = 44
    static let cornerRadius: CGFloat = 8
    static let paneRadius: CGFloat = 10
    static let rowHeight: CGFloat = 44
    static let denseRowHeight: CGFloat = 36
}

// MARK: - Status vocabulary

/// The single status vocabulary shared by the office scene, its HUD, and the
/// notch. Hue communicates state only; every use pairs it with a text label.
enum DockStatusTone: CaseIterable {
    case attention, working, review, queued, complete, inactive

    /// Pastel hues tuned for dark signage. Office bubbles always draw on dark
    /// sign ink, so the scene uses these regardless of appearance.
    var signageColor: NSColor {
        switch self {
        case .attention: NSColor(srgbRed: 1.0, green: 0.74, blue: 0.36, alpha: 1)
        case .working: NSColor(srgbRed: 0.45, green: 0.93, blue: 1.0, alpha: 1)
        case .review: NSColor(srgbRed: 0.74, green: 0.64, blue: 1.0, alpha: 1)
        case .queued: NSColor(srgbRed: 0.62, green: 0.72, blue: 0.98, alpha: 1)
        case .complete: NSColor(srgbRed: 0.55, green: 0.95, blue: 0.72, alpha: 1)
        case .inactive: NSColor(srgbRed: 0.62, green: 0.64, blue: 0.72, alpha: 1)
        }
    }

    /// Deeper variants that keep dots and borders legible on light surfaces.
    private var paperColor: NSColor {
        switch self {
        case .attention: NSColor(srgbRed: 0.71, green: 0.40, blue: 0.04, alpha: 1)
        case .working: NSColor(srgbRed: 0.05, green: 0.46, blue: 0.56, alpha: 1)
        case .review: NSColor(srgbRed: 0.43, green: 0.24, blue: 0.80, alpha: 1)
        case .queued: NSColor(srgbRed: 0.23, green: 0.36, blue: 0.80, alpha: 1)
        case .complete: NSColor(srgbRed: 0.08, green: 0.50, blue: 0.24, alpha: 1)
        case .inactive: NSColor(srgbRed: 0.42, green: 0.45, blue: 0.50, alpha: 1)
        }
    }

    var nsColor: NSColor {
        let signage = signageColor, paper = paperColor
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? signage : paper
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Live states breathe; attention breathes faster. Settled states hold still.
    var pulseDuration: Double? {
        switch self {
        case .attention: 0.7
        case .working: 1.1
        default: nil
        }
    }
}

/// Status dot with the office's soft glow. Pulsing is opt-in for rows that
/// represent live work and always stops under Reduce Motion.
struct DockStatusDot: View {
    let tone: DockStatusTone
    var size: CGFloat = 7
    var pulses = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: size, height: size)
            .shadow(color: tone.color.opacity(0.6), radius: 3)
            .opacity(dimmed ? 0.3 : 1)
            .onAppear(perform: updatePulse)
            .onChange(of: tone) { updatePulse() }
            .onChange(of: reduceMotion) { updatePulse() }
            .accessibilityHidden(true)
    }

    private func updatePulse() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { dimmed = false }
        guard pulses, !reduceMotion, let duration = tone.pulseDuration else { return }
        withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) { dimmed = true }
    }
}

/// Capsule status label: symbol or dot in the tone hue, text in primary ink.
struct DockStatusPill: View {
    let tone: DockStatusTone
    let text: String
    var symbol: Ph?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                DockIcon(symbol).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tone.color)
            } else {
                DockStatusDot(tone: tone, size: 6)
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(tone.color.opacity(0.16)))
        .overlay(Capsule().stroke(tone.color.opacity(0.45), lineWidth: 0.5))
    }
}

/// Uppercase monospaced section label with an optional live count.
struct DockSectionLabel: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.dockSectionText)
            if let count {
                Text("\(count)")
                    .font(DockTypography.sectionLabel.monospacedDigit())
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Indeterminate progress track drawn along the bottom of a live card. It
/// never implies a measured percentage and holds still under Reduce Motion.
struct DockShimmerTrack: View {
    let tone: DockStatusTone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Capsule().fill(Color.dockPrimaryText.opacity(0.08))
                .overlay(alignment: .leading) {
                    LinearGradient(colors: [tone.color.opacity(0), tone.color, tone.color.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: min(80, width * 0.4))
                        .offset(x: reduceMotion ? width * 0.3 : sweeping ? width : -80)
                }
                .clipShape(Capsule())
        }
        .frame(height: 2)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { sweeping = true }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// The floating panel treatment for anything drawn over a scene or edge:
    /// 92% canvas, hairline border, 12pt radius, and a soft drop shadow.
    func dockHUDPanel() -> some View {
        self
            .background(Color.dockCanvas.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.dockBorder, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
    }

    /// Signage card: the SwiftUI counterpart of an office task bubble. A raised
    /// surface with a hairline border tinted by status; emphasized cards (the
    /// current session) and cards that need attention use a stronger border.
    func dockSignageCard(tone: DockStatusTone, emphasized: Bool = false, highlighted: Bool = false) -> some View {
        let strong = emphasized || tone == .attention
        return self
            .background(
                RoundedRectangle(cornerRadius: DockControlMetrics.paneRadius, style: .continuous)
                    .fill(highlighted ? Color.dockSurface4 : Color.dockSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DockControlMetrics.paneRadius, style: .continuous)
                    .stroke(tone.color.opacity(strong ? 0.9 : highlighted ? 0.6 : 0.35), lineWidth: emphasized ? 1.5 : 1)
            )
    }
}

/// A navigation destination row: icon and label, a hover fill, and the
/// theme's selected fill with an accent bar and icon. Rows share one geometry
/// so the primary, Tools, and footer groups line up.
struct DockNavRow: View {
    let title: String
    let icon: Ph
    let isSelected: Bool
    var showsUpdateBadge = false
    let style: DockThemePalette
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                DockIcon(icon, size: 15, color: isSelected ? style.accent : isHovering ? style.primaryText : style.secondaryText)
                .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected || isHovering ? style.primaryText : style.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if showsUpdateBadge {
                    Text("Update")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(style.warning)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Capsule().fill(style.warning.opacity(0.16)))
                        .accessibilityLabel("Update available")
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                    .fill(isSelected ? style.selectedFill : isHovering ? style.surface4.opacity(0.6) : .clear)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule().fill(style.accent).frame(width: 3, height: 14)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: isHovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Square icon action for sidebar headers: quiet until hovered; prominent
/// actions keep an accent tint so the primary action reads at a glance.
struct DockIconButton: View {
    let icon: Ph
    let label: String
    var isProminent = false
    var isBusy = false
    var size: CGFloat = 28
    let style: DockThemePalette
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    DockIcon(icon, size: size * 0.5, color: isProminent ? style.accent : isHovering ? style.primaryText : style.secondaryText)
                }
            }
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isProminent
                          ? style.accent.opacity(isHovering ? 0.24 : 0.14)
                          : isHovering ? style.surface4.opacity(0.7) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockPress)
        .disabled(isBusy)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// One header for every sidebar group: a quiet uppercase label, a count pill,
/// a rotating disclosure chevron when collapsible, and trailing actions.
struct DockSectionHeader<Actions: View>: View {
    let title: String
    var count: Int?
    var isExpanded: Binding<Bool>?
    let style: DockThemePalette
    @ViewBuilder var actions: () -> Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 2) {
            if let isExpanded {
                Button {
                    withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) { isExpanded.wrappedValue.toggle() }
                } label: {
                    label(isExpanded: isExpanded.wrappedValue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isExpanded.wrappedValue ? "Collapse" : "Expand") \(title)")
            } else {
                label(isExpanded: nil)
            }
            actions()
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(minHeight: 30)
        .onHover { isHovering = $0 }
    }

    private func label(isExpanded: Bool?) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(DockTypography.sectionLabel)
                .tracking(0.6)
                .foregroundStyle(isHovering && isExpanded != nil ? style.secondaryText : style.metadataText)
            if let count {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(style.secondaryText)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 16)
                    .background(Capsule().fill(style.surface4.opacity(0.8)))
            }
            if let isExpanded {
                DockIcon(.caretRight, size: 10, color: style.metadataText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(isHovering || !isExpanded ? 1 : 0.5)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension DockSectionHeader where Actions == EmptyView {
    init(title: String, count: Int? = nil, isExpanded: Binding<Bool>? = nil, style: DockThemePalette) {
        self.init(title: title, count: count, isExpanded: isExpanded, style: style) { EmptyView() }
    }
}
