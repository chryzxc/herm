import SwiftUI

/// The top island always wears the black Island skin so it blends with the
/// camera notch; leaving the top restores the skin the user had before.
enum EdgeIslandTheme {
    static let previousThemeKey = "hermes.notch.theme-before-island"

    @MainActor static func apply(side: EdgeDockSide, store: DockThemeStore, defaults: UserDefaults) {
        if side == .top {
            guard store.selectedThemeID != .island else { return }
            defaults.set(store.selectedThemeID.rawValue, forKey: previousThemeKey)
            store.selectedThemeID = .island
        } else if store.selectedThemeID == .island,
            let previous = defaults.string(forKey: previousThemeKey).flatMap(DockThemeID.init(rawValue:))
        {
            defaults.removeObject(forKey: previousThemeKey)
            store.selectedThemeID = previous
        }
    }
}

/// The collapsed top island: two ears flank the camera housing, which stays
/// dark and empty. The shell fill lives in EdgeNotchView so it can grow into the preview.
struct EdgeIslandRail: View {
    @AppStorage(NotchDisplayStyle.defaultsKey) private var displayStyle: NotchDisplayStyle = .defaultStyle
    let activity: EdgeNotchActivity
    let notchWidth: CGFloat
    let ear: CGFloat
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // Extras (finished/blocked) left, the primary status right.
                EdgeNotchStatusIndicator(activity: activity, style: displayStyle, axis: .horizontal, part: .badges)
                    .frame(width: ear, height: height)
                Color.clear.frame(width: notchWidth, height: height)
                EdgeNotchStatusIndicator(activity: activity, style: displayStyle, axis: .horizontal, part: .primary)
                    .frame(width: ear, height: height)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
    }
}

/// The open top workspace's menu-bar band: what Hermes is doing left of the
/// camera, what needs you right of it. Reads the notch's own state so the
/// band and the collapsed island never disagree.
struct EdgeIslandStatusStrip: View {
    @AppStorage(NotchDisplayStyle.defaultsKey) private var displayStyle: NotchDisplayStyle = .defaultStyle
    @ObservedObject var state: EdgeNotchState
    @ObservedObject var control: ControlCenterModel
    let height: CGFloat
    let openTask: (EdgeNotchTask) -> Void
    let openQuota: () -> Void

    private var live: [EdgeNotchTask] { state.tasks.filter(\.isStatusCurrent) }
    private var attention: [EdgeNotchTask] { live.filter { $0.phase == .attention } }

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
            Button {
                headline.task.map(openTask)
            } label: {
                HStack(spacing: 6) {
                    EdgeNotchStatusIndicator(
                        activity: state.railActivity, style: displayStyle, axis: .horizontal, part: .primary)
                    Text(headline.text).lineLimit(1).truncationMode(.tail)
                        .contentTransition(.opacity)
                        .animation(.dockEase(duration: 0.25), value: headline.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .disabled(headline.task == nil)
            .help(headline.text)
            Color.clear.frame(width: state.notchSize.width + 24)
            HStack(spacing: 10) {
                if let first = attention.first {
                    chip("exclamationmark.circle.fill", "\(attention.count)", tint: .dockWarning) { openTask(first) }
                        .help("\(attention.count) need\(attention.count == 1 ? "s" : "") your attention")
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
