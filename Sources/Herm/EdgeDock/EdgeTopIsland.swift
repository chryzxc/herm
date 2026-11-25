import SwiftUI

/// The collapsed top island: two ears flank the camera housing, which stays
/// dark and empty. The shell fill lives in EdgeNotchView so it can grow into the preview.
struct EdgeIslandRail: View {
    @AppStorage(NotchDisplayStyle.defaultsKey) private var displayStyle: NotchDisplayStyle = .defaultStyle
    let activity: EdgeNotchActivity
    let notchWidth: CGFloat
    let ears: (left: CGFloat, right: CGFloat)
    let height: CGFloat
    /// The wake-word microphone sits after the faces, in its own slot.
    var wakeStatus: EdgeWakeIndicator.Status?
    /// A reminder due within the hour, counting down beside the primary mark.
    var countdown: VoiceTimer?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // Extras (finished/blocked) left, the primary status right.
                EdgeNotchStatusIndicator(activity: activity, style: displayStyle, axis: .horizontal, part: .badges)
                    .dockPadding(.leading, EdgeNotchState.islandBadgeInset)
                    .frame(width: ears.left, height: height)
                Color.clear.frame(width: notchWidth, height: height)
                HStack(spacing: 0) {
                    EdgeNotchStatusIndicator(
                        activity: activity, style: displayStyle, axis: .horizontal, part: .primary
                    )
                    .frame(maxWidth: .infinity)
                    if let countdown {
                        VoiceTimerCountdown(timer: countdown)
                            .frame(width: EdgeNotchState.countdownSlot, height: height, alignment: .leading)
                            .transition(.opacity)
                    }
                    if let wakeStatus {
                        EdgeWakeIndicator(status: wakeStatus)
                            .frame(width: EdgeNotchState.wakeSlot, height: height)
                            .dockPadding(.trailing, EdgeNotchState.wakeEdgeInset)
                            .transition(.opacity)
                    }
                }
                .frame(width: ears.right, height: height)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
    }
}

/// The two toolbar groups must both fit beside the centered camera housing.
struct EdgeIslandToolbarLayout: Layout {
    let cameraWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let leading = subviews[0].sizeThatFits(.unspecified)
        let trailing = subviews[1].sizeThatFits(.unspecified)
        let minimumWidth = cameraWidth + 2 * (DockSpacing.micro + max(leading.width, trailing.width))
        return CGSize(
            width: max(proposal.width ?? 0, minimumWidth),
            height: max(leading.height, trailing.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
    }
}

/// The open top workspace's reserved menu-bar band. Left of the camera: the
/// Bots working right now and what they are doing. Right of it: what needs
/// you, what finished, and quota. It reads the notch's own state, so the band
/// and the collapsed island never disagree.
struct EdgeIslandStatusStrip: View {
    private static let palette = DockThemePalette(theme: .island)

    @AppStorage(NotchDisplayStyle.defaultsKey) private var displayStyle: NotchDisplayStyle = .defaultStyle
    @ObservedObject var state: EdgeNotchState
    @ObservedObject var control: ControlCenterModel
    let height: CGFloat
    let openTask: (EdgeNotchTask) -> Void
    let openQuota: () -> Void

    /// Faces shown before the rest collapse into a "+N" count.
    static let crewLimit = 3
    static let avatarSize: CGFloat = 22

    struct CrewMember: Identifiable {
        let task: EdgeNotchTask
        let bot: BotSummary
        var id: String { bot.id }
    }

    /// One face per working Bot, in task order, so a Bot running two sessions shows once.
    static func crew(_ tasks: [EdgeNotchTask], bots: [BotSummary]) -> [CrewMember] {
        var seen = Set<String>()
        return tasks.compactMap { task in
            guard task.isStatusCurrent, task.phase == .working, let bot = task.bot(in: bots),
                seen.insert(bot.id).inserted
            else { return nil }
            return CrewMember(task: task, bot: bot)
        }
    }

    private var live: [EdgeNotchTask] { state.tasks.filter(\.isStatusCurrent) }
    private var attention: [EdgeNotchTask] { live.filter { $0.phase == .attention } }
    private var finished: [EdgeNotchTask] { live.filter { $0.phase == .finished } }

    private var headline: (text: String, task: EdgeNotchTask?) {
        if state.showingAnnouncement, let task = state.glimpseTasks.first {
            return ("\(task.statusLabel) · \(task.title)", task)
        }
        let working = live.filter { $0.phase == .working }
        if let task = working.first { return ("\(working.count) running · \(task.title)", task) }
        return (state.railActivity.title, nil)
    }

    // ponytail: tightest window across every provider; scope to the active provider if it misleads.
    private var quota: (percent: Double, provider: String)? {
        control.providerQuotas.flatMap { snapshot in
            snapshot.windows.compactMap { $0.remainingPercent.map { ($0, snapshot.displayName) } }
        }.min { $0.0 < $1.0 }
    }

    var body: some View {
        HStack(spacing: 0) {
            let headline = headline
            let crew = Self.crew(state.tasks, bots: state.bots)
            HStack(spacing: 8) {
                if crew.isEmpty {
                    EdgeNotchStatusIndicator(
                        activity: state.railActivity, style: displayStyle, axis: .horizontal, part: .primary)
                } else {
                    crewStack(crew)
                }
                let title = Text(headline.text)
                    .foregroundStyle(Self.palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                    .animation(.dockEase(duration: 0.25), value: headline.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if let task = headline.task {
                        Button {
                            openTask(task)
                        } label: {
                            title.contentShape(Rectangle())
                        }
                    } else {
                        title.dockFont(.control)
                    }
                }
                .help(headline.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: state.notchSize.width + 24)
            HStack(spacing: 10) {
                if let first = attention.first {
                    chip("exclamationmark.circle.fill", "\(attention.count)", tint: Self.palette.warning) {
                        openTask(first)
                    }
                    .help("\(attention.count) need\(attention.count == 1 ? "s" : "") your attention")
                }
                if let first = finished.first {
                    chip("checkmark.circle.fill", "\(finished.count)", tint: Self.palette.success) { openTask(first) }
                        .help("\(finished.count) finished · open \(first.title)")
                }
                if let quota {
                    chip(
                        "gauge.with.dots.needle.33percent", "\(Int(quota.percent.rounded()))%",
                        tint: quota.percent < 20 ? Self.palette.warning : Self.palette.secondaryText, action: openQuota
                    )
                    .help("\(quota.provider): \(Int(quota.percent.rounded()))% quota left")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.dockHover)
        .dockFont(.body, weight: .medium)
        .foregroundStyle(Self.palette.secondaryText)
        .frame(height: height)
    }

    /// Overlapping faces of the working Bots; each opens the session it is running.
    private func crewStack(_ crew: [CrewMember]) -> some View {
        HStack(spacing: -6) {
            ForEach(crew.prefix(Self.crewLimit)) { member in
                Button {
                    openTask(member.task)
                } label: {
                    BotAvatarView(
                        bot: member.bot, imageData: state.avatarImages[member.bot.id], size: Self.avatarSize,
                        orbits: true, live: true)
                }
                .help("\(member.bot.name) · \(member.task.title)")
                .accessibilityLabel("\(member.bot.name), working on \(member.task.title)")
            }
            if crew.count > Self.crewLimit {
                Text("+\(crew.count - Self.crewLimit)")
                    .dockFont(.metadata, weight: .semibold)
                    .monospacedDigit()
                    .dockPadding(.leading, 10)
                    .help("\(crew.count) Bots working")
            }
        }
        // The band is only on screen while the workspace is open, so its Bots keep moving.
        .environment(\.dockBotIndicatorLive, true)
    }

    private func chip(_ symbol: String, _ text: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text).monospacedDigit().foregroundStyle(Self.palette.primaryText)
            }
            .dockPadding(.horizontal, 6)
            .contentShape(Rectangle())
        }
    }
}

/// The collapsed notch's cue that on-device wake listening is active.
struct EdgeWakeIndicator: View {
    static let accessibilityStatus = "Listening for the wake word"

    enum Status {
        case standby, listening, unavailable

        var icon: Ph { self == .unavailable ? .microphoneSlash : .microphone }
    }

    let status: Status
    @DockChromeTheme private var theme

    var body: some View {
        let palette = DockThemePalette(theme: theme)
        let listening = status == .listening
        let microphone = PhosphorShape(icon: status.icon, weight: .fill)
        microphone.fill(listening ? palette.primaryText : palette.secondaryText)
            .background {
                if theme.usesNativeMaterial {
                    microphone.stroke(palette.onAccent, lineWidth: DockLayout.hairline * 2)
                }
            }
            .frame(width: EdgeNotchState.wakeGlyphSize, height: EdgeNotchState.wakeGlyphSize)
            .frame(width: EdgeNotchState.wakeSlot, height: EdgeNotchState.wakeSlot)
            .background {
                if listening {
                    DockLayerMotion(kind: .breathe(period: 2.4), color: palette.primaryText.opacity(0.24))
                }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
