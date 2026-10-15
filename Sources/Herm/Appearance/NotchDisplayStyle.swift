import SwiftUI

enum NotchDisplayStyle: String, CaseIterable, Identifiable {
    case dots, line, ring, icons, count

    static let defaultsKey = "hermes.notch.display-style"
    var id: String { rawValue }
    /// Icons and Count would look identical to a bare working state, so preview what sets them apart.
    var previewActivity: EdgeNotchActivity {
        switch self {
        case .icons: .init(status: .idle, unread: true)
        case .count: .init(status: .working, workingCount: 3)
        default: .init(status: .working)
        }
    }

    var title: String {
        switch self {
        case .dots: "Dots"
        case .line: "Vertical line"
        case .ring: "Ring"
        case .icons: "Icons"
        case .count: "Count"
        }
    }
}

struct NotchDisplaySettings: View {
    @AppStorage(NotchDisplayStyle.defaultsKey) private var style: NotchDisplayStyle = .dots

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsPreferenceRow(title: "Notch status display", detail: "Choose how activity appears on the screen edge.") { EmptyView() }
            HStack(spacing: 12) {
                ForEach(NotchDisplayStyle.allCases) { option in
                    Button { style = option } label: {
                        HStack(spacing: 8) {
                            EdgeNotchStatusIndicator(activity: option.previewActivity, style: option)
                                .frame(width: 28, height: 44)
                            Text(option.title)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(style == option ? Color.dockAccent : Color.dockSecondaryText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(style == option ? Color.dockAccentMuted : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(style == option ? .isSelected : [])
                }
            }
            .accessibilityLabel("Working animation previews")
            .padding(.bottom, 8)
        }
    }
}

/// Every state is one mark in a fixed 24pt slot, so all styles stack at the same size.
/// Priority: working > finished > blocked > offline > idle. While working, finished and
/// blocked ride along as extra marks; otherwise blocked trails a finished primary.
struct EdgeNotchStatusIndicator: View {
    let activity: EdgeNotchActivity
    var style: NotchDisplayStyle = .dots
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Mark { case working, done, blocked, offline, idle }
    private static let slot: CGFloat = 20

    private var animates: Bool { !reduceMotion && (activity.working || activity.attention) }

    private var primary: Mark {
        activity.working ? .working : activity.hasUpdate ? .done
            : activity.attention ? .blocked : activity.status == .offline ? .offline : .idle
    }

    private var badges: [Mark] {
        if activity.working {
            return (activity.hasUpdate ? [.done] : []) + (activity.attention ? [.blocked] : [])
        }
        return activity.hasUpdate && activity.attention ? [.blocked] : []
    }

    var body: some View {
        TimelineView(.animation(paused: !animates)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            VStack(spacing: 10) {
                mark(primary, t)
                ForEach(Array(badges.enumerated()), id: \.offset) { mark($0.element, t) }
            }
        }
        .accessibilityHidden(true)
    }

    /// 0...1 sine wave; resting at full when motion is off.
    private func wave(_ t: Double, period: Double) -> Double {
        animates ? (1 - cos(t / period * 2 * .pi)) / 2 : 1
    }

    /// 0...1 sawtooth; parked at 0 when motion is off.
    private func phase(_ t: Double, period: Double) -> Double {
        animates ? t.truncatingRemainder(dividingBy: period) / period : 0
    }

    private func color(_ m: Mark) -> Color {
        switch m {
        case .working: .dockAccent
        case .done: .dockSuccess
        case .blocked: .dockWarning
        case .offline, .idle: .dockSecondaryText
        }
    }

    private func mark(_ m: Mark, _ t: Double) -> some View {
        let c = color(m)
        let level = m == .blocked ? 0.45 + 0.55 * wave(t, period: 2) : m == .idle ? 0.35 : 1
        return Group {
            switch style {
            case .dots: dot(m, c, level, t)
            case .line: bar(m, c, level, t)
            case .ring: ring(m, c, level, t)
            case .icons: chip(m, c, level, t)
            case .count: chip(m, c, level, t, number: activity.workingCount)
            }
        }
        .frame(width: Self.slot, height: Self.slot)
    }

    @ViewBuilder
    private func dot(_ m: Mark, _ c: Color, _ level: Double, _ t: Double) -> some View {
        switch m {
        case .working:
            let p = phase(t, period: 1.6)
            Circle().fill(c.opacity(0.35 * (1 - p))).scaleEffect(1 + 1.2 * p).frame(width: 8, height: 8)
                .overlay { Circle().fill(c).frame(width: 8, height: 8) }
        case .offline: Circle().strokeBorder(c, lineWidth: 1.5).frame(width: 8, height: 8)
        case .idle: Circle().fill(c.opacity(level)).frame(width: 5, height: 5)
        default: Circle().fill(c.opacity(level)).frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private func bar(_ m: Mark, _ c: Color, _ level: Double, _ t: Double) -> some View {
        switch m {
        case .working:
            Capsule().fill(c.opacity(0.2)).frame(width: 4, height: Self.slot)
                .overlay(alignment: .top) {
                    Capsule().fill(c).frame(width: 4, height: 8).offset(y: 12 * wave(t, period: 1.6))
                }
        case .offline: Capsule().strokeBorder(c, lineWidth: 1).frame(width: 4, height: Self.slot)
        default: Capsule().fill(c.opacity(level)).frame(width: 4, height: Self.slot)
        }
    }

    @ViewBuilder
    private func ring(_ m: Mark, _ c: Color, _ level: Double, _ t: Double) -> some View {
        switch m {
        case .working:
            Circle().stroke(c.opacity(0.2), lineWidth: 2)
                .overlay {
                    Circle().trim(from: 0, to: 0.7).stroke(c, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(animates ? phase(t, period: 1.6) * 360 : -90))
                }
                .frame(width: 16, height: 16)
        case .done, .blocked:
            Circle().stroke(c.opacity(level), lineWidth: 2).frame(width: 16, height: 16)
                .overlay { Circle().fill(c.opacity(level)).frame(width: 8, height: 8) }
        default:
            Circle().stroke(c.opacity(level), lineWidth: 2).frame(width: 16, height: 16)
        }
    }

    /// Tinted disc with a glyph; working swaps the glyph for a rotating arc.
    private func chip(_ m: Mark, _ c: Color, _ level: Double, _ t: Double, number: Int = 0) -> some View {
        let symbol: String? = switch m {
        case .done: "checkmark"
        case .blocked: activity.status == .needsClarification ? "questionmark" : "exclamationmark"
        case .offline: "moon.zzz.fill"
        default: nil
        }
        return ZStack {
            Circle().fill(c.opacity(0.16 * level))
            Circle().strokeBorder(c.opacity(0.35 * level), lineWidth: 1)
            if m == .working, number > 0 {
                Text(number > 9 ? "9+" : "\(number)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundStyle(c)
            } else if m == .working {
                Circle().trim(from: 0, to: 0.3)
                    .stroke(c, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(2)
                    .rotationEffect(.degrees(animates ? phase(t, period: 1.2) * 360 : -90))
                Circle().fill(c).frame(width: 4, height: 4)
            } else if m == .done, !activity.backgroundCompleted {
                Circle().fill(c.opacity(level)).frame(width: 6, height: 6)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(c.opacity(level))
            }
        }
    }
}
