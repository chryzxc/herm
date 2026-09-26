import SwiftUI

enum EdgeQuotaLayout: String, CaseIterable {
    case list, grid

    static let storageKey = "hermes.notch.quota.layout"

    var title: String { self == .list ? "List" : "Grid" }
    var symbol: Ph { self == .list ? .listBullets : .squaresFour }
}

/// Layout toggle and refresh control shown in the notch tab row while the
/// Quota tab is selected, so the preview body can spend its height on providers.
struct EdgeQuotaToolbar: View {
    @ObservedObject var control: ControlCenterModel
    @AppStorage(EdgeQuotaLayout.storageKey) private var layout: EdgeQuotaLayout = .list

    private var refreshing: Bool { control.refreshState(for: "provider.quota")?.isRefreshing == true }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(EdgeQuotaLayout.allCases, id: \.self) { option in
                    Button { layout = option } label: {
                        DockIcon(option.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(layout == option ? Color.dockAccent : Color.dockSecondaryText)
                            .frame(width: 26, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(layout == option ? Color.dockAccentMuted : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(option.title) layout")
                    .accessibilityLabel("\(option.title) layout")
                    .accessibilityAddTraits(layout == option ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.dockSurface4))

            Button { control.refreshProviderQuota() } label: {
                Group {
                    if refreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        DockIcon(.arrowClockwise).font(.system(size: 12, weight: .semibold))
                    }
                }
                .foregroundStyle(Color.dockSecondaryText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(refreshing)
            .help("Refresh quota")
            .accessibilityLabel("Refresh quota")
        }
    }
}

/// A small projection of the same quota inventory used by the full workspace:
/// every connected provider with its 5-hour and weekly windows.
struct EdgeQuotaPreview: View {
    @ObservedObject var control: ControlCenterModel
    let openQuota: () -> Void
    /// Set while a quota announcement is showing: only that provider is drawn.
    var change: EdgeQuotaChange? = nil
    @AppStorage(EdgeQuotaLayout.storageKey) private var layout: EdgeQuotaLayout = .list

    private var refreshing: Bool { control.refreshState(for: "provider.quota")?.isRefreshing == true }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let change {
                    EdgeQuotaChangeCard(change: change)
                        .id(change.current.updatedAt)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else if control.providerQuotas.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(refreshing ? "Loading quota…" : "Quota unavailable")
                            .font(.system(size: 12, weight: .semibold))
                        Text(refreshing ? "Reading connected providers" : "Open Quota to connect a provider or review its status.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        if layout == .grid { grid } else { list }
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Color.dockBorderLight)
            footer
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.dockPrimaryText)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let updatedAt = control.providerQuotas.map(\.updatedAt).max() {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    Text(refreshing ? "Refreshing…" :
                         control.refreshState(for: "provider.quota")?.isStale == true ? "Stale data" :
                         "Updated \(Self.shortDuration(timeline.date.timeIntervalSince(updatedAt))) ago")
                        .foregroundStyle(Color.dockSecondaryText)
                }
            }
            Spacer(minLength: 0)
            EdgePreviewFooterButton(title: "Open Quota", icon: .arrowRight, action: openQuota)
        }
        .lineLimit(1)
        .padding(.vertical, 6)
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(control.providerQuotas.enumerated()), id: \.element.provider) { index, snapshot in
                if index > 0 { Divider().overlay(Color.dockBorderLight).padding(.leading, 28) }
                HStack(alignment: .top, spacing: 8) {
                    ProviderMarkBadge(mark: ProviderMark(providerID: snapshot.provider, displayName: snapshot.displayName))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(snapshot.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .frame(height: 20)
                        let windows = Self.compactWindows(snapshot.windows)
                        if windows.isEmpty {
                            Text(snapshot.safeDetail ?? "No quota windows reported")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.dockSecondaryText)
                                .lineLimit(1)
                        }
                        ForEach(windows, id: \.window.id) { item in
                            listMeter(item.label, item.window)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func listMeter(_ label: String, _ window: ProviderQuotaWindow) -> some View {
        let remaining = Self.remainingPercent(window.remainingPercent)
        let marker = QuotaForecasting.visibleDailyBudgetMarker(for: window)
        return HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(Color.dockSecondaryText)
                .frame(minWidth: 18, alignment: .leading)
                .fixedSize()
            if let remaining {
                GeometryReader { geometry in
                    Capsule().fill(Color.dockBorder)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Self.color(window.threshold))
                                .frame(width: geometry.size.width * remaining / 100)
                        }
                        .overlay(alignment: .leading) {
                            if let marker {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.dockWarning)
                                    .frame(width: 2, height: 9)
                                    .offset(x: min(max(0, geometry.size.width * marker / 100), geometry.size.width - 2))
                            }
                        }
                }
                .frame(height: 4)
                Text("\(Int(remaining.rounded()))%")
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            } else {
                Text(window.remainingDisplay ?? "Remaining unavailable")
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            resetText(window)
                .foregroundStyle(Color.dockSecondaryText)
                .frame(width: 48, alignment: .trailing)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(label, window))
    }

    // MARK: Grid

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(control.providerQuotas, id: \.provider) { snapshot in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ProviderMarkBadge(mark: ProviderMark(providerID: snapshot.provider, displayName: snapshot.displayName), size: 18)
                        Text(snapshot.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    let windows = Self.compactWindows(snapshot.windows)
                    HStack(spacing: 4) {
                        if windows.isEmpty {
                            Text(snapshot.safeDetail ?? "No quota windows reported")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.dockSecondaryText)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                        }
                        ForEach(windows, id: \.window.id) { item in
                            ring(item.label, item.window).frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).fill(Color.dockSurface2))
                .overlay(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline))
            }
        }
        .padding(.vertical, 8)
    }

    private func ring(_ label: String, _ window: ProviderQuotaWindow) -> some View {
        let remaining = Self.remainingPercent(window.remainingPercent)
        let marker = QuotaForecasting.visibleDailyBudgetMarker(for: window)
        return VStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.dockBorder, lineWidth: 3)
                if let remaining, remaining > 0 {
                    Circle()
                        .trim(from: 0, to: remaining / 100)
                        .stroke(Self.color(window.threshold), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if let marker {
                    // Daily budget line: a radial tick across the ring at the
                    // balance to keep after today's even-use budget.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.dockWarning)
                        .frame(width: 2, height: 8)
                        .offset(y: -19)
                        .rotationEffect(.degrees(marker / 100 * 360))
                }
                Group {
                    if let remaining {
                        Text("\(Int(remaining.rounded()))")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                        + Text("%")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(Color.dockSecondaryText)
                    } else {
                        Text("—").font(.system(size: 11, weight: .semibold))
                    }
                }
                .lineLimit(1)
                .fixedSize()
            }
            .frame(width: 38, height: 38)
            HStack(spacing: 4) {
                Text(label).fontWeight(.semibold).foregroundStyle(Color.dockPrimaryText)
                resetText(window).foregroundStyle(Color.dockSecondaryText).monospacedDigit()
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(label, window))
    }

    // MARK: Shared

    @ViewBuilder
    private func resetText(_ window: ProviderQuotaWindow) -> some View {
        if let resets = window.resetsAt {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                Text(resets > timeline.date ? Self.shortDuration(resets.timeIntervalSince(timeline.date)) : "Now")
            }
            .help("Resets \(resets.formatted(date: .abbreviated, time: .shortened))")
        } else if let text = window.resetsDisplay {
            Text(text)
        }
    }

    private static func color(_ threshold: ProviderQuotaThreshold) -> Color {
        QuotaWorkspaceView.color(for: threshold)
    }

    private static func accessibilityLabel(_ label: String, _ window: ProviderQuotaWindow) -> String {
        var parts = [label == "5h" ? "5-hour window" : label == "7d" ? "Weekly window" : window.label]
        if let remaining = remainingPercent(window.remainingPercent) {
            parts.append("\(Int(remaining.rounded())) percent remaining")
        } else {
            parts.append(window.remainingDisplay ?? "remaining unavailable")
        }
        if let marker = QuotaForecasting.visibleDailyBudgetMarker(for: window) {
            parts.append("daily budget line at \(Int(marker)) percent")
        }
        if let resets = window.resetsAt {
            parts.append("resets \(resets.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: ", ")
    }

    /// Picks the 5-hour ("Session") and weekly windows every quota service
    /// reports, labelled compactly. Providers without those windows fall back
    /// to their first two windows under their own names.
    nonisolated static func compactWindows(_ windows: [ProviderQuotaWindow]) -> [(label: String, window: ProviderQuotaWindow)] {
        let session = windows.first { $0.label == "Session" || $0.id == "gemini-5h" }
        let weekly = windows.first { $0.label == "Weekly" || $0.id == "gemini-weekly" }
        let known = [session.map { ("5h", $0) }, weekly.map { ("7d", $0) }].compactMap { $0 }
        if !known.isEmpty { return known.map { (label: $0.0, window: $0.1) } }
        return windows.prefix(2).map { (label: $0.label, window: $0) }
    }

    static func shortDuration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    /// Remaining capacity clamped to 0–100, matching the Quota page.
    static func remainingPercent(_ remaining: Double?) -> Double? {
        guard let remaining, remaining.isFinite else { return nil }
        return min(100, max(0, remaining))
    }
}

/// One provider's reading before and after a quota drop.
struct EdgeQuotaChange: Equatable {
    let previous: ProviderQuotaSnapshot
    let current: ProviderQuotaSnapshot

    func previousRemaining(_ window: ProviderQuotaWindow) -> Double? {
        previous.windows.first { $0.id == window.id }?.remainingPercent
    }
}

/// The announced provider alone, its meters sliding from the previous
/// reading to the current one so the drop reads at a glance.
struct EdgeQuotaChangeCard: View {
    let change: EdgeQuotaChange
    /// Inside the combined status view: no header subtitle or outer padding.
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            HStack(spacing: 8) {
                ProviderMarkBadge(mark: ProviderMark(providerID: change.current.provider, displayName: change.current.displayName))
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.current.displayName).font(.system(size: compact ? 12 : 13, weight: .semibold))
                    if !compact {
                        Text("Quota used since the last check")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                }
            }
            ForEach(EdgeQuotaPreview.compactWindows(change.current.windows), id: \.window.id) { item in
                meter(item.label, item.window)
            }
        }
        .lineLimit(1)
        .padding(.vertical, compact ? 0 : 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task {
            guard !reduceMotion else { settled = true; return }
            // Let the notch finish opening before the meters move.
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeInOut(duration: 1.4)) { settled = true }
        }
    }

    @ViewBuilder
    private func meter(_ label: String, _ window: ProviderQuotaWindow) -> some View {
        if let now = EdgeQuotaPreview.remainingPercent(window.remainingPercent) {
            let before = EdgeQuotaPreview.remainingPercent(change.previousRemaining(window)) ?? now
            let shown = settled ? now : before
            let color = QuotaWorkspaceView.color(for: ProviderQuotaWindow.threshold(forRemaining: shown))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(label == "5h" ? "5-hour" : label == "7d" ? "Weekly" : label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dockSecondaryText)
                    Spacer(minLength: 0)
                    if before - now >= 0.5 {
                        Text("−\(Int((before - now).rounded()))%")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.dockWarning)
                            .opacity(settled ? 1 : 0)
                    }
                    CountingPercent(value: shown)
                        .font(.system(size: 20, weight: .semibold))
                        .monospacedDigit()
                }
                GeometryReader { geometry in
                    Capsule().fill(Color.dockBorder)
                        .overlay(alignment: .leading) {
                            // Where the window stood at the previous reading.
                            Capsule().fill(color.opacity(0.25)).frame(width: geometry.size.width * before / 100)
                        }
                        .overlay(alignment: .leading) {
                            Capsule().fill(color).frame(width: geometry.size.width * shown / 100)
                        }
                }
                .frame(height: 6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label == "5h" ? "5-hour window" : label == "7d" ? "Weekly window" : window.label), \(Int(before.rounded())) to \(Int(now.rounded())) percent remaining")
        }
    }
}

/// A percentage that counts through intermediate values while animating.
private struct CountingPercent: View, @preconcurrency Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { Text("\(Int(value.rounded()))%") }
}
