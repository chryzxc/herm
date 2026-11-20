import SwiftUI

enum NotchDisplayStyle: String, CaseIterable, Identifiable {
    case dots, line, ring, icons, count, bots

    static let defaultsKey = "hermes.notch.display-style"
    static let enabledKey = "hermes.notch.enabled"
    static let defaultStyle = NotchDisplayStyle.bots
    /// Set once Bots has been introduced, so the switch runs a single time.
    static let botsIntroducedKey = "hermes.notch.bots-introduced"

    /// Moves everyone onto the Bots style once, so people who picked another
    /// style see the new one. Any choice made after that sticks.
    static func introduceBotsStyle(in defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: botsIntroducedKey) else { return }
        defaults.set(NotchDisplayStyle.bots.rawValue, forKey: defaultsKey)
        defaults.set(true, forKey: botsIntroducedKey)
    }
    /// The saved choice, for sizing code outside a view's `@AppStorage`.
    static var stored: Self {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? defaultStyle
    }
    var id: String { rawValue }
    /// Icons and Count would look identical to a bare working state, so preview what sets them apart.
    var previewActivity: EdgeNotchActivity {
        switch self {
        case .icons: .init(status: .idle, unread: true)
        case .count: .init(status: .working, workingCount: 3)
        case .bots: .init(status: .working, workingBotIDs: [""])
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
        case .bots: "Bots"
        }
    }
}

/// The notch preferences shared by Settings and the gear menu's Notch
/// submenu. Both surfaces draw these same controls on the same keys; only
/// the surrounding layout differs.
enum NotchPreferenceControls {
    struct ShowToggle: View {
        @AppStorage(NotchDisplayStyle.enabledKey) private var enabled = true

        var body: some View {
            // `.dockSwitch` always draws its label, so the switch carries none;
            // each surface names it beside the switch.
            Toggle(isOn: $enabled) { EmptyView() }
                .toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
                .accessibilityLabel("Show notch")
        }
    }

    struct PositionPicker: View {
        /// The gear menu's shorter, full-width track.
        var compact = false
        @AppStorage("hermes.notch.side") private var side: EdgeDockSide = .right

        var body: some View {
            DockSegmentedPicker(
                selection: Binding(get: { side == .top }, set: { side = $0 ? .top : .right }),
                options: [(false, "Side"), (true, "Top island")], height: compact ? 22 : 30)
        }
    }

    /// One tile per style, each with its live preview. Settings lays them out
    /// in a row; the gear menu packs the same tiles into a compact grid.
    struct StylePicker: View {
        var compact = false
        @AppStorage(NotchDisplayStyle.defaultsKey) private var style: NotchDisplayStyle = .defaultStyle

        var body: some View {
            Group {
                if compact {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                        ForEach(NotchDisplayStyle.allCases) { option in tile(option) }
                    }
                } else {
                    HStack(spacing: 12) {
                        ForEach(NotchDisplayStyle.allCases) { option in tile(option) }
                    }
                }
            }
            .accessibilityLabel("Working animation previews")
        }

        private func tile(_ option: NotchDisplayStyle) -> some View {
            let selected = style == option
            return Button {
                style = option
            } label: {
                HStack(spacing: compact ? 6 : 8) {
                    // The indicator draws in a fixed 20pt slot; the compact tile
                    // scales it to the text line without clipping the Bots face.
                    EdgeNotchStatusIndicator(activity: option.previewActivity, style: option)
                        .scaleEffect(compact ? 0.8 : 1)
                        .frame(width: compact ? 18 : 28, height: compact ? 18 : 44)
                    Text(option.title)
                        .dockFont(.body, weight: .medium)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(selected ? Color.dockAccent : Color.dockSecondaryText)
                .dockPadding(.horizontal, compact ? 6 : 0)
                .frame(maxWidth: .infinity, minHeight: compact ? 30 : 44)
                .background(selected ? Color.dockAccentMuted : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .accessibilityLabel(option.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

struct NotchDisplaySettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsPreferenceRow(
                title: "Show notch", detail: "Turn the screen-edge activity indicator off entirely."
            ) { NotchPreferenceControls.ShowToggle() }
            SettingsPreferenceRow(
                title: "Notch position", detail: "Dock on a screen edge, or as an island around the camera."
            ) { NotchPreferenceControls.PositionPicker() }
            SettingsPreferenceRow(
                title: "Notch status display", detail: "Choose how activity appears on the screen edge."
            ) { EmptyView() }
            NotchPreferenceControls.StylePicker()
                .dockPadding(.bottom, 8)
        }
    }
}

/// The gear menu's Notch submenu: the Settings section in compact form, with
/// the same controls on the same keys.
struct NotchQuickMenu: View {
    @AppStorage(NotchDisplayStyle.enabledKey) private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Show notch") { NotchPreferenceControls.ShowToggle() }
            Group {
                row("Position") { NotchPreferenceControls.PositionPicker(compact: true) }
                VStack(alignment: .leading, spacing: 6) {
                    title("Status display").dockPadding(.horizontal, 6)
                    NotchPreferenceControls.StylePicker(compact: true)
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
        }
        .dockPadding(8)
        .frame(width: 340)
    }

    private func title(_ text: String) -> some View {
        Text(text).dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
    }

    private func row<Control: View>(_ text: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            title(text)
            Spacer(minLength: 8)
            control()
        }
        .dockPadding(.horizontal, 6)
        .frame(minHeight: 26)
    }
}

/// Every state is one mark in a fixed 24pt slot, so all styles stack at the same size.
/// Priority: working > finished > blocked > offline > idle. While working, finished and
/// blocked ride along as extra marks; otherwise blocked trails a finished primary.
struct EdgeNotchStatusIndicator: View {
    let activity: EdgeNotchActivity
    var style: NotchDisplayStyle = .defaultStyle
    /// Marks stack down an edge rail and across the top island.
    var axis: Axis = .vertical
    /// The top island splits the marks: primary in one ear, extras in the other.
    enum Part { case all, primary, badges }
    var part: Part = .all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Mark { case working, done, blocked, offline, idle }
    private static let slot: CGFloat = 20

    private var animates: Bool { !reduceMotion && (activity.working || activity.attention) }

    private var primary: Mark {
        activity.working
            ? .working
            : activity.hasUpdate
                ? .done
                : activity.attention ? .blocked : activity.status == .offline ? .offline : .idle
    }

    private var badges: [Mark] {
        if activity.working {
            return (activity.hasUpdate ? [.done] : []) + (activity.attention ? [.blocked] : [])
        }
        return activity.hasUpdate && activity.attention ? [.blocked] : []
    }

    var body: some View {
        // A blocked-only pulse is a slow 2s breath; 15Hz keeps it smooth at half the renders.
        TimelineView(.dockMotion(rate: activity.working ? 30 : 15, paused: !animates || style == .bots)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                // A state change swaps the mark in place with a short scale-fade, never a jump cut.
                if part != .badges {
                    if style == .bots, primary == .working, activity.workingBotIDs.count > 1 {
                        // One face per working Bot, like the Bot picker's running list.
                        ForEach(activity.workingBotIDs, id: \.self) { id in
                            mark(.working, t, botID: id).transition(Self.swap)
                        }
                    } else {
                        mark(primary, t).id(primary).transition(Self.swap)
                    }
                }
                if part != .primary {
                    ForEach(badges, id: \.self) { mark($0, t).transition(Self.swap) }
                }
            }
            .animation(reduceMotion ? nil : .dockEase(duration: 0.22), value: primary)
            .animation(reduceMotion ? nil : .dockEase(duration: 0.22), value: badges)
            .animation(reduceMotion ? nil : .dockEase(duration: 0.22), value: activity.workingBotIDs)
        }
        .accessibilityHidden(true)
    }

    private static let swap = AnyTransition.scale(scale: 0.6).combined(with: .opacity)

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
        case .blocked: activity.attentionState.color
        case .offline, .idle: .dockSecondaryText
        }
    }

    private func mark(_ m: Mark, _ t: Double, botID: String? = nil) -> some View {
        let c = color(m)
        let level = m == .blocked ? 0.45 + 0.55 * wave(t, period: 2) : m == .idle ? 0.35 : 1
        return Group {
            switch style {
            case .dots: dot(m, c, level, t)
            case .line: bar(m, c, level, t)
            case .ring: ring(m, c, level, t)
            case .icons: chip(m, c, level, t)
            case .count: chip(m, c, level, t, number: activity.workingCount)
            case .bots: bot(m, c, t, id: botID)
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

    /// The Bot behind each state, playing the same `BotStatusMotion` as every
    /// other Bot surface. `live` keeps it moving with Herm in the background,
    /// since the notch carries status. Warnings and the finished count use
    /// the shared activity mark and badge, which hold still.
    @ViewBuilder
    private func bot(_ m: Mark, _ c: Color, _ t: Double, id botID: String? = nil) -> some View {
        let size: CGFloat = 22
        let id: String =
            switch m {
            case .working: botID ?? activity.workingBotIDs.first ?? ""
            case .blocked: activity.blockedBotID ?? ""
            case .done: activity.finishedBotID ?? ""
            default: ""
            }
        let attention = activity.attentionState
        let mood: BotMood =
            switch m {
            case .working: .tool
            case .blocked: attention == .failed ? .failed : attention == .clarification ? .clarify : .approval
            case .done: .done
            case .offline: .offline
            case .idle: .sleepy
            }
        let face = BotFaceMark(id: id, size: size, animated: !reduceMotion, mood: mood, live: true)
            .botStatusMotion(
                reduceMotion ? .resting : BotStatusMotion(mood: mood), size: size, live: true,
                cue: activity.finishedCount
            )
            .opacity(m == .offline || m == .idle ? 0.55 : 1)
        // Face and badge share one box that fits the 28pt rail and the island
        // ear, so nothing hangs past the screen edge or the menu bar.
        ZStack(alignment: .topTrailing) {
            face.frame(
                width: Self.botBox, height: Self.botBox,
                alignment: m == .blocked || m == .done ? .bottomLeading : .center)
            switch m {
            case .blocked:
                DockActivityIndicator(state: attention, role: .badge)
            case .done:
                EdgeNotchFinishedBadge(count: max(1, activity.finishedCount))
            default:
                EmptyView()
            }
        }
        .frame(width: Self.botBox, height: Self.botBox)
    }

    private static let botBox: CGFloat = 27

    /// Tinted disc with a glyph; working swaps the glyph for a rotating arc.
    private func chip(_ m: Mark, _ c: Color, _ level: Double, _ t: Double, number: Int = 0) -> some View {
        let symbol: String? =
            switch m {
            case .done: "checkmark"
            case .blocked: activity.attentionState.symbol
            case .offline: "moon.zzz.fill"
            default: nil
            }
        return ZStack {
            Circle().fill(c.opacity(0.16 * level))
            Circle().strokeBorder(c.opacity(0.35 * level), lineWidth: 1)
            if m == .working, number > 0 {
                Text(number > 9 ? "9+" : "\(number)")
                    .dockFont(size: 9, weight: .bold).monospacedDigit().foregroundStyle(c)
            } else if m == .working {
                Circle().trim(from: 0, to: 0.3)
                    .stroke(c, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .dockPadding(2)
                    .rotationEffect(.degrees(animates ? phase(t, period: 1.2) * 360 : -90))
                Circle().fill(c).frame(width: 4, height: 4)
            } else if m == .done, !activity.backgroundCompleted {
                Circle().fill(c.opacity(level)).frame(width: 6, height: 6)
            } else if let symbol {
                Image(systemName: symbol).dockFont(size: 9, weight: .bold).foregroundStyle(c.opacity(level))
            }
        }
    }
}

/// The Bots style's finished count. It pops when another result lands.
private struct EdgeNotchFinishedBadge: View {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(count > 9 ? "9+" : "\(count)")
            .dockFont(size: 10, weight: .bold).monospacedDigit()
            .foregroundStyle(DockAccentColor.green.onFill)
            .contentTransition(.numericText())
            .dockPadding(.horizontal, 3)
            // The activity mark's badge size, ringed in canvas like it.
            .frame(minWidth: 15, minHeight: 15)
            .background(DockAccentColor.green.fill, in: Capsule())
            .background(Color.dockOpaqueCanvas, in: Capsule().inset(by: -1.5))
            .keyframeAnimator(initialValue: CGFloat(1), trigger: count) { badge, scale in
                badge.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack(\.self) {
                    SpringKeyframe(reduceMotion ? 1 : 1.45, duration: 0.18)
                    SpringKeyframe(1, duration: 0.35, spring: .bouncy)
                }
            }
            .animation(reduceMotion ? nil : .dockEase(duration: 0.25), value: count)
    }
}
