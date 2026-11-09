import SwiftUI

struct EdgeQuietMenu: View {
    @ObservedObject var coordinator: HermInterruptionCoordinator
    let showDigest: () -> Void
    var body: some View {
        // The label width changes with the countdown, so pin the popover to the trailing edge.
        DockMenu(anchor: .point(.bottomTrailing)) {
            if coordinator.quiet {
                Button {
                    coordinator.end()
                } label: {
                    Label("End quiet period", icon: .bellRinging)
                }
            } else {
                Button {
                    coordinator.start(minutes: 30)
                } label: {
                    Label("Quiet for 30 minutes", icon: .timer)
                }
                Button {
                    coordinator.start()
                } label: {
                    Label("Quiet for 60 minutes", icon: .clockCountdown)
                }
                Button {
                    coordinator.start(minutes: nil)
                } label: {
                    Label("Quiet until I end it", icon: .infinity)
                }
            }
            if !coordinator.entries.isEmpty || coordinator.overflow > 0 {
                Divider()
                Button(action: showDigest) {
                    Label("Review digest (\(coordinator.entries.count))", icon: .tray)
                }
            }
        } label: {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 4) {
                    DockIcon(coordinator.quiet ? .bellSimpleSlash : .bellSimple, size: 13)
                    Text(Self.title(quiet: coordinator.quiet, expiry: coordinator.expiry, now: context.date))
                        .dockFont(.metadata, weight: .medium)
                        .monospacedDigit()
                }
                .foregroundStyle(coordinator.quiet ? Color.dockPrimaryText : Color.dockSecondaryText)
            }
        }
        .fixedSize()
        .accessibilityLabel(
            coordinator.quiet ? "Quiet period active. Manage interruptions" : "Start a quiet period")
    }

    /// "Quiet", "Quiet · 42m", or "Quiet · On" for an open-ended period.
    static func title(quiet: Bool, expiry: Date?, now: Date) -> String {
        guard quiet else { return "Quiet" }
        guard let expiry else { return "Quiet · On" }
        let minutes = max(1, Int((expiry.timeIntervalSince(now) / 60).rounded(.up)))
        guard minutes >= 60 else { return "Quiet · \(minutes)m" }
        return minutes % 60 == 0 ? "Quiet · \(minutes / 60)h" : "Quiet · \(minutes / 60)h \(minutes % 60)m"
    }
}

struct EdgeDigestView: View {
    @ObservedObject var coordinator: HermInterruptionCoordinator
    let back: () -> Void
    let open: (HermNotice) -> Void
    let openActivity: () -> Void
    @State private var confirmsClear = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("While quiet").dockFont(.body, weight: .semibold)
                Spacer()
                Button("Back", action: back).buttonStyle(.dockCompact)
            }.dockPadding(10).frame(height: 40)
            Divider().overlay(Color.dockBorderLight)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if coordinator.entries.isEmpty {
                        Text("No activity waiting").dockFont(.body, weight: .semibold)
                        Text("Completions and ordinary quota changes will appear here.").dockFont(.body)
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                    ForEach(coordinator.entries.reversed()) { entry in
                        Button {
                            open(entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.kind.title).dockFont(.body, weight: .semibold)
                                Text(
                                    entry.unavailable
                                        ? (entry.canCheckCompletedSession
                                            ? "Check saved reply in its original profile."
                                            : "Source unavailable. Reconnect or open Herm.")
                                        : "\(entry.profileID ?? "Launch profile") · \(entry.source == .repository ? URL(fileURLWithPath: entry.sourceID).lastPathComponent : entry.sourceID)"
                                )
                                .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).dockPadding(8)
                        }.buttonStyle(.dockHover).disabled(entry.unavailable && !entry.canCheckCompletedSession)
                            .accessibilityLabel(
                                "\(entry.kind.title). \(entry.unavailable && !entry.canCheckCompletedSession ? "Source unavailable" : "Open source")"
                            )
                    }
                    if coordinator.overflow > 0 {
                        Text("\(coordinator.overflow) earlier updates. Open activity to review their sources.")
                            .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                    }
                }.dockPadding(10)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(Color.dockBorderLight)
            HStack {
                Button("Clear…") { confirmsClear = true }.buttonStyle(.dockCompact)
                Spacer()
                Button("Open Herm", action: openActivity).buttonStyle(.dockCompact)
            }.dockFont(.body, weight: .medium).dockPadding(10)
        }
        .foregroundStyle(Color.dockPrimaryText)
        .confirmationDialog("Clear this digest?", isPresented: $confirmsClear) {
            Button("Clear digest", role: .destructive) { coordinator.clearDigest() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes Herm's saved activity references. The sessions, reports and outputs remain in Hermes."
            )
        }
    }
}
