import SwiftUI

enum NotchDisplayStyle: String, CaseIterable, Identifiable {
    case dots, line, ring

    static let defaultsKey = "hermes.notch.display-style"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dots: "Dots"
        case .line: "Vertical line"
        case .ring: "Ring"
        }
    }
}

struct NotchDisplaySettings: View {
    @AppStorage(NotchDisplayStyle.defaultsKey) private var style: NotchDisplayStyle = .dots

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsPreferenceRow(title: "Notch status display", detail: "Choose how activity appears on the screen edge.") {
                Picker("Notch status display", selection: $style) {
                    ForEach(NotchDisplayStyle.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            HStack(spacing: 12) {
                ForEach(NotchDisplayStyle.allCases) { option in
                    Button { style = option } label: {
                        HStack(spacing: 8) {
                            EdgeNotchStatusIndicator(activity: .init(status: .working), style: option)
                                .frame(width: 22, height: 44)
                            Text(option.title)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(style == option ? Color.dockAccent : Color.dockSecondaryText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(style == option ? Color.dockAccentMuted : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(style == option ? .isSelected : [])
                }
            }
            .accessibilityLabel("Working animation previews")
            .padding(.bottom, 8)
        }
    }
}

struct EdgeNotchStatusIndicator: View {
    let activity: EdgeNotchActivity
    var style: NotchDisplayStyle = .dots
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { !reduceMotion && (activity.working || activity.attention) }

    var body: some View {
        TimelineView(.animation(paused: !animates)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            VStack(spacing: 6) {
                if let signal {
                    if activity.working || style == .dots {
                        signal(t)
                    } else {
                        restingIndicator(t)
                    }
                }
                if activity.working { workingIndicator(t) }
            }
        }
        .accessibilityHidden(true)
    }

    /// 0...1 sine wave; resting at full when motion is off.
    private func wave(_ t: Double, period: Double) -> Double {
        animates ? (1 - cos(t / period * 2 * .pi)) / 2 : 1
    }

    private var signal: ((Double) -> AnyView)? {
        if activity.attention {
            return { t in
                let w = wave(t, period: 2.0)
                return AnyView(Circle().fill(Color.dockWarning.opacity(0.45 + 0.55 * w)).frame(width: 7, height: 7))
            }
        }
        if activity.hasUpdate {
            return { _ in AnyView(Circle().fill(Color.dockSuccess).frame(width: 7, height: 7)) }
        }
        if activity.working { return nil }
        if activity.status == .offline {
            return { _ in AnyView(Circle().strokeBorder(Color.dockSecondaryText, lineWidth: 1.5).frame(width: 7, height: 7)) }
        }
        return { _ in AnyView(Circle().fill(Color.dockSecondaryText.opacity(0.35)).frame(width: 5, height: 5)) }
    }

    @ViewBuilder
    private func restingIndicator(_ t: Double) -> some View {
        let color: Color = activity.attention ? .dockWarning : activity.hasUpdate ? .dockSuccess : .dockSecondaryText
        let opacity = activity.attention ? 0.45 + 0.55 * wave(t, period: 2) : activity.quiet ? 0.35 : 1
        if style == .line {
            Capsule().stroke(color.opacity(opacity), lineWidth: 1)
                .background {
                    if activity.status != .offline { Capsule().fill(color.opacity(opacity)) }
                }
                .frame(width: 3, height: 30)
        } else {
            Circle().stroke(color.opacity(opacity), lineWidth: 2)
                .frame(width: 10, height: 10)
                .overlay {
                    if activity.hasUpdate || activity.attention {
                        Circle().fill(color.opacity(opacity)).frame(width: 4, height: 4)
                    }
                }
        }
    }

    @ViewBuilder
    private func workingIndicator(_ t: Double) -> some View {
        switch style {
        case .dots:
            Circle().fill(Color.dockSecondaryText.opacity(0.4 + 0.6 * wave(t, period: 1.4)))
                .frame(width: 6, height: 6)
        case .line:
            Capsule().fill(Color.dockSecondaryText.opacity(0.2))
                .frame(width: 3, height: 30)
                .overlay(alignment: .top) {
                    Capsule().fill(Color.dockSecondaryText)
                        .frame(width: 3, height: 10)
                        .offset(y: 20 * wave(t, period: 1.6))
                }
        case .ring:
            Circle().stroke(Color.dockSecondaryText.opacity(0.2), lineWidth: 2)
                .overlay {
                    Circle().trim(from: 0, to: 0.7)
                        .stroke(Color.dockSecondaryText, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(animates ? t.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360 : -90))
                }
                .frame(width: 10, height: 10)
        }
    }
}

