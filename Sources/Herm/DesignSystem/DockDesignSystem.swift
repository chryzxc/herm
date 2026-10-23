import AppKit
import SwiftUI

/// Central presentation contract for Dock-owned interfaces. Feature views use
/// these semantic roles rather than introducing near-duplicate font sizes,
/// row heights, and compact control treatments.
enum DockTypography {
    enum Role {
        case pageTitle, sectionLabel, rowTitle, body, control, metadata, machineMetadata, compactStatus, metric,
            navigation, conversation, code
    }

    /// Compact point sizes. Window sizing is applied once by the caller's environment.
    nonisolated static func size(_ role: Role, scale: CGFloat = 1) -> CGFloat {
        let points: CGFloat =
            switch role {
            case .pageTitle: 16
            case .sectionLabel, .compactStatus: 10
            case .rowTitle, .body, .control: 12
            case .metadata, .machineMetadata: 11
            case .metric: 20
            case .navigation: 13
            case .conversation: 14
            case .code: 12.5
            }
        return DockWorkspaceScale.points(points, scale: scale)
    }

    nonisolated static func markdownHeadingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 18
        case 2: size(.pageTitle)
        case 3: 14.5
        default: size(.conversation)
        }
    }

    static func font(
        _ role: Role, scale: CGFloat = 1, weight: Font.Weight? = nil, design overrideDesign: Font.Design? = nil
    ) -> Font {
        let defaultWeight: Font.Weight =
            switch role {
            case .pageTitle, .sectionLabel, .compactStatus: .semibold
            case .rowTitle, .control: .medium
            default: .regular
            }
        let design: Font.Design =
            switch role {
            case .sectionLabel, .machineMetadata, .compactStatus, .code: .monospaced
            case .metric: .rounded
            default: DockThemeStyle.current.fontDesign
            }
        let font = Font.system(
            size: size(role, scale: scale), weight: weight ?? defaultWeight, design: overrideDesign ?? design)
        return role == .metric ? font.monospacedDigit() : font
    }

    static var pageTitle: Font { font(.pageTitle) }
    static var sectionLabel: Font { font(.sectionLabel) }
    static var rowTitle: Font { font(.rowTitle) }
    static var body: Font { font(.body) }
    static var control: Font { font(.control) }
    static var metadata: Font { font(.metadata) }
    static var machineMetadata: Font { font(.machineMetadata) }
    static var compactStatus: Font { font(.compactStatus) }
    static var metric: Font { font(.metric) }
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
    static var cornerRadius: CGFloat { DockThemeStyle.current.controlRadius }
    static var paneRadius: CGFloat { DockThemeStyle.current.paneRadius }
    static let rowHeight: CGFloat = 44
    static let denseRowHeight: CGFloat = 36
}

// MARK: - Status vocabulary

/// The single status vocabulary shared by the office scene, its HUD, and the
/// notch. Hue communicates state only; every use pairs it with a text label.
enum DockStatusTone: CaseIterable, Hashable {
    case attention, working, review, queued, complete, inactive

    private var accent: DockAccentColor? {
        switch self {
        case .attention: .orange
        case .working: .blue
        case .review: .violet
        case .queued: .indigo
        case .complete: .green
        case .inactive: nil
        }
    }

    /// Office signage always has a dark backing, independent of the window theme.
    var signageColor: NSColor {
        accent?.signageColor ?? NSColor(white: 0.60, alpha: 1)
    }

    var nsColor: NSColor { NSColor(color) }
    var color: Color { accent?.color ?? .dockMetadataText }
    var fill: Color { accent?.fill ?? .dockMetadataText }

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
    /// Theme ink without the glow, for chrome that should read as plain UI.
    var muted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fill: Color {
        guard muted else { return tone.fill }
        return tone == .attention ? .dockWarning : .dockSecondaryText
    }

    var body: some View {
        let duration = pulses && !reduceMotion ? tone.pulseDuration : nil
        TimelineView(.dockMotion(paused: duration == nil)) { context in
            let dim = duration.map { DockMotionSchedule.breath(context.date, period: $0 * 2) } ?? 0
            Circle()
                .fill(fill)
                .frame(width: size, height: size)
                .shadow(color: muted ? .clear : tone.color.opacity(0.6), radius: 3)
                .opacity(1 - 0.7 * dim)
        }
        .accessibilityHidden(true)
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
                DockIcon(symbol).dockFont(size: 10, weight: .semibold)
                    .foregroundStyle(tone.color)
            } else {
                DockStatusDot(tone: tone, size: 6)
            }
            Text(text)
                .dockFont(size: 11, weight: .semibold)
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
                .dockFont(size: 12, weight: .semibold)
                .foregroundStyle(Color.dockSectionText)
            if let count {
                Text("\(count)")
                    .dockFont(.sectionLabel).monospacedDigit()
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
    /// A plain theme-ink segment instead of the glowing tone gradient.
    var muted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.dockMotion(paused: reduceMotion)) { context in
            GeometryReader { geometry in
                let width = geometry.size.width
                let sweep = DockMotionSchedule.loop(context.date, period: 1.6)
                Capsule().fill(Color.dockPrimaryText.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Group {
                            if muted {
                                Capsule().fill(Color.dockSecondaryText.opacity(0.55))
                            } else {
                                LinearGradient(
                                    colors: [tone.color.opacity(0), tone.color, tone.color.opacity(0)],
                                    startPoint: .leading, endPoint: .trailing)
                            }
                        }
                        .frame(width: min(80, width * 0.4))
                        .offset(x: reduceMotion ? width * 0.3 : -80 + (width + 80) * sweep)
                    }
                    .clipShape(Capsule())
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

extension View {
    /// The floating panel treatment for anything drawn over a scene or edge:
    /// 92% canvas, hairline border, 12pt radius, and a soft drop shadow.
    @ViewBuilder
    func dockHUDPanel() -> some View {
        let shape = DockThemeShape(cornerRadius: DockControlMetrics.paneRadius + 2, role: .pane)
        if DockThemeStyle.current.material == .glass {
            dockLiquidGlass(shape, elevated: true)
        } else {
            self
                .background(Color.dockOpaqueCanvas)  // dockCanvas is translucent in native themes
                .background(Color.dockCanvas.opacity(0.92))
                .clipShape(shape)
                .overlay(shape.stroke(Color.dockBorder, lineWidth: DockLayout.outline))
                .dockFoldCrease()
                .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        }
    }

    /// Signage card: the SwiftUI counterpart of an office task bubble. A raised
    /// surface with a hairline border tinted by status; emphasized cards (the
    /// current session) and cards that need attention use a stronger border.
    func dockSignageCard(tone: DockStatusTone, emphasized: Bool = false, highlighted: Bool = false) -> some View {
        let strong = emphasized || tone == .attention
        let shape = DockThemeShape(cornerRadius: DockControlMetrics.paneRadius, role: .pane)
        return
            self
            .background(shape.fill(highlighted ? Color.dockSurface4 : Color.dockSurface))
            .overlay(
                shape.stroke(
                    tone.color.opacity(strong ? 0.9 : highlighted ? 0.6 : 0.35),
                    lineWidth: max(emphasized ? 1.5 : 1, DockLayout.outline))
            )
            .dockStickerShadow(shape)
            .dockFoldCrease()
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
        let shape = DockThemeShape(cornerRadius: DockControlMetrics.cornerRadius)
        let inverted = isSelected && style.theme.style.selection == .invert
        Button(action: action) {
            HStack(spacing: 10) {
                DockIcon(
                    icon, size: 15,
                    color: inverted
                        ? style.background
                        : isSelected ? style.accent : isHovering ? style.primaryText : style.secondaryText
                )
                .frame(width: 18)
                Text(title)
                    .dockFont(
                        size: 13, weight: isSelected ? .semibold : .regular, design: DockThemeStyle.current.fontDesign
                    )
                    .foregroundStyle(
                        inverted ? style.background : isSelected || isHovering ? style.primaryText : style.secondaryText
                    )
                    .lineLimit(1)
                Spacer(minLength: 0)
                if showsUpdateBadge {
                    Text("Update")
                        .dockFont(size: 10, weight: .semibold)
                        .foregroundStyle(inverted ? style.background : style.warning)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Capsule().fill(style.warning.opacity(0.16)))
                        .accessibilityLabel("Update available")
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .dockSelectionBackground(shape, active: isSelected, fill: style.selectedFill, theme: style.theme)
            .background(shape.fill(!isSelected && isHovering ? style.surface4.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .dockFeedback(isHovering), value: isHovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Icon-only destination for the narrow primary rail. The label lives in the
/// tooltip and accessibility name; selection uses the same fill as DockNavRow.
struct DockRailButton: View {
    let title: String
    let icon: Ph
    let isSelected: Bool
    var showsUpdateBadge = false
    let style: DockThemePalette
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = DockThemeShape(cornerRadius: DockControlMetrics.cornerRadius)
        let inverted = isSelected && style.theme.style.selection == .invert
        Button(action: action) {
            DockIcon(
                icon, size: 17,
                color: inverted
                    ? style.background
                    : isSelected ? style.accent : isHovering ? style.primaryText : style.secondaryText
            )
            .frame(width: 38, height: 38)
            .dockSelectionBackground(shape, active: isSelected, fill: style.selectedFill, theme: style.theme)
            .background(shape.fill(!isSelected && isHovering ? style.accent.opacity(0.14) : .clear))
            .overlay(alignment: .topTrailing) {
                if showsUpdateBadge {
                    Circle().fill(style.warning).frame(width: 7, height: 7).padding(7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(showsUpdateBadge ? "\(title), update available" : title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Square icon action for sidebar headers: quiet until hovered; prominent
/// actions keep an accent tint so the primary action reads at a glance.
struct DockIconButton: View {
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    let icon: Ph
    let label: String
    var isProminent = false
    var isBusy = false
    var size: CGFloat = 28
    let style: DockThemePalette
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = DockThemeShape(cornerRadius: DockLayout.controlRadius - 1)
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    DockIcon(
                        icon, size: size * 0.5,
                        color: isProminent ? style.accent : isHovering ? style.primaryText : style.secondaryText)
                }
            }
            .frame(
                width: DockWorkspaceScale.points(size, scale: workspaceScale),
                height: DockWorkspaceScale.points(size, scale: workspaceScale)
            )
            .background(
                shape.fill(
                    isProminent
                        ? style.accent.opacity(isHovering ? 0.24 : 0.14)
                        : style.surface4.opacity(isHovering ? 0.9 : 0.6))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .disabled(isBusy)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A copy action with consistent, in-place success feedback. Both states stay
/// in the layout so changing from Copy to Copied never shifts nearby controls.
/// Callers can apply the button style that belongs to their surface.
struct DockCopyButton: View {
    enum Presentation {
        case icon
        case text
        case iconAndText
    }

    let label: String
    let accessibilityLabel: String
    var presentation: Presentation = .iconAndText
    var iconSize: CGFloat = 14
    var color: Color = .dockSecondaryText
    var confirmationColor: Color = .dockSuccess
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    init(
        _ value: String,
        label: String = "Copy",
        accessibilityLabel: String,
        presentation: Presentation = .iconAndText,
        iconSize: CGFloat = 14,
        color: Color = .dockSecondaryText,
        confirmationColor: Color = .dockSuccess
    ) {
        self.label = label
        self.accessibilityLabel = accessibilityLabel
        self.presentation = presentation
        self.iconSize = iconSize
        self.color = color
        self.confirmationColor = confirmationColor
        self.action = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }

    init(
        label: String = "Copy",
        accessibilityLabel: String,
        presentation: Presentation = .iconAndText,
        iconSize: CGFloat = 14,
        color: Color = .dockSecondaryText,
        confirmationColor: Color = .dockSuccess,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.accessibilityLabel = accessibilityLabel
        self.presentation = presentation
        self.iconSize = iconSize
        self.color = color
        self.confirmationColor = confirmationColor
        self.action = action
    }

    var body: some View {
        Button(action: copy) {
            ZStack {
                buttonLabel(isConfirmation: false)
                    .opacity(didCopy ? 0 : 1)
                    .scaleEffect(didCopy ? 0.8 : 1)
                    .offset(x: didCopy ? 3 : 0, y: didCopy ? -3 : 0)
                buttonLabel(isConfirmation: true)
                    .opacity(didCopy ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .help(didCopy ? "Copied" : accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(didCopy ? "Copied" : "")
        .onDisappear { resetTask?.cancel() }
    }

    @ViewBuilder
    private func buttonLabel(isConfirmation: Bool) -> some View {
        let icon: Ph = isConfirmation ? .check : .copy
        let title = isConfirmation ? "Copied" : label
        let foreground = isConfirmation ? confirmationColor : color

        switch presentation {
        case .icon:
            confirmationAwareIcon(icon, isConfirmation: isConfirmation, color: foreground)
        case .text:
            HStack(spacing: 5) {
                if isConfirmation { DockIcon(icon, size: iconSize, color: foreground) }
                Text(title)
            }
            .foregroundStyle(foreground)
        case .iconAndText:
            HStack(spacing: 6) {
                confirmationAwareIcon(icon, isConfirmation: isConfirmation, color: foreground)
                Text(title)
            }
            .foregroundStyle(foreground)
        }
    }

    @ViewBuilder
    private func confirmationAwareIcon(_ icon: Ph, isConfirmation: Bool, color: Color) -> some View {
        if isConfirmation {
            DockDrawOnIcon(icon: icon, size: iconSize, color: color, isDrawn: didCopy)
        } else {
            DockIcon(icon, size: iconSize, color: color)
        }
    }

    private func copy() {
        action()
        resetTask?.cancel()
        setCopied(true)
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            setCopied(false)
        }
    }

    private func setCopied(_ copied: Bool) {
        if reduceMotion {
            didCopy = copied
        } else {
            withAnimation(.dockEase(duration: 0.18)) { didCopy = copied }
        }
    }
}

/// One header for every sidebar group: a quiet uppercase label, a count pill,
/// a rotating disclosure chevron when collapsible, and trailing actions.
struct DockSectionHeader<Actions: View>: View {
    let title: String
    var count: Int?
    var isExpanded: Binding<Bool>?
    let style: DockThemePalette
    var isContentHeader = false
    var titleRole: DockTypography.Role = .body
    /// A tinted lead icon marks a prominent, scannable group title.
    var icon: Ph? = nil
    var tint: Color = .dockAccent
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
        .padding(.leading, isContentHeader ? 0 : 8)
        .padding(.trailing, isContentHeader ? 0 : 2)
        .frame(minHeight: 30)
        .onHover { isHovering = $0 }
    }

    private func label(isExpanded: Bool?) -> some View {
        HStack(spacing: 6) {
            if let icon {
                DockIcon(icon, size: 12, color: tint)
            }
            // Sentence case, quiet weight: a label, not a banner.
            Text(title)
                .dockFont(titleRole, weight: isContentHeader || icon != nil ? .semibold : .medium)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .foregroundStyle(
                    isContentHeader || icon != nil
                        ? style.primaryText
                        : (isHovering && isExpanded != nil ? style.secondaryText : style.metadataText))
            if let count, icon != nil {
                Text(count > 99 ? "99+" : "\(count)")
                    .dockFont(size: 11, weight: .semibold).monospacedDigit()
                    .foregroundStyle(style.secondaryText)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 16)
                    .background(Capsule().fill(tint.opacity(0.14)))
            } else if let count {
                Text(count > 99 ? "99+" : "\(count)")
                    .dockFont(size: 12).monospacedDigit()
                    .foregroundStyle(style.metadataText)
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
    init(
        title: String, count: Int? = nil, isExpanded: Binding<Bool>? = nil, style: DockThemePalette,
        isContentHeader: Bool = false, icon: Ph? = nil, tint: Color = .dockAccent
    ) {
        self.init(
            title: title, count: count, isExpanded: isExpanded, style: style, isContentHeader: isContentHeader,
            icon: icon, tint: tint
        ) { EmptyView() }
    }
}

/// The one clock behind every decorative animation. Ticks land on shared
/// 30fps instants, so any number of animated views cost one window render per
/// tick: separate `.animation` timelines each kept their own phase, and
/// `repeatForever` ran at the display's full 120Hz, so a working turn rendered
/// the whole window several times per frame. Occluded windows drop to 1Hz.
struct DockMotionSchedule: TimelineSchedule {
    static let step = 1.0 / 30
    var paused = false

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        if paused { return AnyIterator([startDate].makeIterator()) }
        let step = mode == .lowFrequency ? 1 : Self.step
        // Count whole ticks so every view computes bit-identical instants.
        var tick = (startDate.timeIntervalSinceReferenceDate / step).rounded(.down)
        return AnyIterator {
            defer { tick += 1 }
            return Date(timeIntervalSinceReferenceDate: tick * step)
        }
    }

    /// 0...1 progress through a loop of `period` seconds.
    static func loop(_ date: Date, period: Double) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
    }

    /// 0...1...0, eased, over `period` seconds: an autoreversing easeInOut.
    static func breath(_ date: Date, period: Double) -> Double {
        (1 - cos(2 * .pi * loop(date, period: period))) / 2
    }
}

extension TimelineSchedule where Self == DockMotionSchedule {
    static func dockMotion(paused: Bool = false) -> DockMotionSchedule { DockMotionSchedule(paused: paused) }
}
