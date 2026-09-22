import SwiftUI

/// A small projection of the same quota inventory used by the full workspace.
struct EdgeQuotaPreview: View {
    @ObservedObject var control: ControlCenterModel
    let openQuota: () -> Void
    @AppStorage("hermes.notch.quota.provider") private var selectedProvider = ""

    private var snapshot: ProviderQuotaSnapshot? {
        control.providerQuotas.first { $0.provider == selectedProvider } ?? control.providerQuotas.first
    }
    private var refreshing: Bool { control.refreshState(for: "provider.quota")?.isRefreshing == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let snapshot {
                    Menu {
                        ForEach(control.providerQuotas, id: \.provider) { provider in
                            Button(provider.displayName) { selectedProvider = provider.provider }
                        }
                    } label: {
                        Text(snapshot.displayName).font(.system(size: 12, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                } else {
                    Text("Provider usage").font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                Button { control.refreshProviderQuota() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(refreshing)
                .accessibilityLabel("Refresh quota")
            }
            .frame(height: 44)

            if let snapshot {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshot.windows.prefix(2)) { window in
                        quotaWindow(window)
                    }
                    if snapshot.windows.isEmpty {
                        Text("No quota windows reported").foregroundStyle(Color.dockSecondaryText)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(refreshing ? "Loading quota…" : "Quota unavailable")
                        .font(.system(size: 12, weight: .semibold))
                    Text(refreshing ? "Reading connected providers" : "Open Quota to connect a provider or review its status.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockSecondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            HStack(spacing: 8) {
                if let snapshot {
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        Text(refreshing ? "Refreshing…" :
                             control.refreshState(for: "provider.quota")?.isStale == true ? "Stale data" :
                             "Updated \(Self.shortDuration(timeline.date.timeIntervalSince(snapshot.updatedAt))) ago")
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                }
                Spacer(minLength: 0)
                Button("Open Quota", action: openQuota)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.dockAccent)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(height: 44)
            }
            .lineLimit(1)

        }
        .font(.system(size: 12))
        .foregroundStyle(Color.dockPrimaryText)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func quotaWindow(_ window: ProviderQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 4)
                if let used = Self.usedPercent(remaining: window.remainingPercent) {
                    Text("\(Int(used.rounded()))% used")
                        .monospacedDigit().foregroundStyle(Color.dockSecondaryText)
                }
            }
            if let used = Self.usedPercent(remaining: window.remainingPercent) {
                GeometryReader { geometry in
                    Capsule().fill(Color.dockBorder)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(window.threshold == .critical ? Color.dockDestructive : window.threshold == .warning ? Color.dockWarning : Color.dockAccent)
                                .frame(width: geometry.size.width * used / 100)
                        }
                }
                .frame(height: 4)
                .accessibilityLabel("\(window.label), \(Int(used.rounded())) percent used")
            }
            HStack {
                if window.remainingPercent == nil {
                    Text(window.remainingDisplay ?? "Usage unavailable")
                }
                Spacer(minLength: 0)
                if let resets = window.resetsAt {
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        Text(resets > timeline.date ? "Resets in \(Self.shortDuration(resets.timeIntervalSince(timeline.date)))" : "Reset time passed")
                    }
                    .help("Resets \(resets.formatted(date: .abbreviated, time: .shortened))")
                } else if let text = window.resetsDisplay {
                    Text(text)
                }
            }
            .foregroundStyle(Color.dockSecondaryText)
            .lineLimit(1)
        }
    }

    static func shortDuration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    static func usedPercent(remaining: Double?) -> Double? {
        guard let remaining, remaining.isFinite else { return nil }
        return 100 - min(100, max(0, remaining))
    }
}
