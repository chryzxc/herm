import SwiftUI

/// The collapsed top island: two ears flank the camera housing, which stays
/// dark and empty. The shell fill lives in EdgeNotchView so it can grow into the preview.
struct EdgeIslandRail: View {
    @AppStorage(NotchDisplayStyle.defaultsKey) private var displayStyle: NotchDisplayStyle = .defaultStyle
    let activity: EdgeNotchActivity
    let notchWidth: CGFloat
    let ears: (left: CGFloat, right: CGFloat)
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // Extras (finished/blocked) left, the primary status right.
                EdgeNotchStatusIndicator(activity: activity, style: displayStyle, axis: .horizontal, part: .badges)
                    .dockPadding(.leading, EdgeNotchState.islandBadgeInset)
                    .frame(width: ears.left, height: height)
                Color.clear.frame(width: notchWidth, height: height)
                EdgeNotchStatusIndicator(activity: activity, style: displayStyle, axis: .horizontal, part: .primary)
                    .frame(width: ears.right, height: height)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
    }
}

/// The open top workspace's reserved menu-bar band. Left of the camera: the
/// Bots working right now and what they are doing. Right of it: what needs
/// you, what finished, and quota. It reads the notch's own state, so the band
/// and the collapsed island never disagree.
struct EdgeIslandStatusStrip: View {
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
                Button {
                    headline.task.map(openTask)
                } label: {
                    Text(headline.text).lineLimit(1).truncationMode(.tail)
                        .contentTransition(.opacity)
                        .animation(.dockEase(duration: 0.25), value: headline.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .disabled(headline.task == nil)
                .help(headline.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: state.notchSize.width + 24)
            HStack(spacing: 10) {
                if let first = attention.first {
                    chip("exclamationmark.circle.fill", "\(attention.count)", tint: .dockWarning) { openTask(first) }
                        .help("\(attention.count) need\(attention.count == 1 ? "s" : "") your attention")
                }
                if let first = finished.first {
                    chip("checkmark.circle.fill", "\(finished.count)", tint: .dockSuccess) { openTask(first) }
                        .help("\(finished.count) finished · open \(first.title)")
                }
                if let quota {
                    chip(
                        "gauge.with.dots.needle.33percent", "\(Int(quota.percent.rounded()))%",
                        tint: quota.percent < 20 ? .dockWarning : .dockSecondaryText, action: openQuota
                    )
                    .help("\(quota.provider): \(Int(quota.percent.rounded()))% quota left")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.dockHover)
        .dockFont(.body, weight: .medium)
        .foregroundStyle(Color.dockSecondaryText)
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
                Text(text).monospacedDigit()
            }
            .dockPadding(.horizontal, 6)
            .contentShape(Rectangle())
        }
    }
}
