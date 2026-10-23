import SwiftUI

enum EdgeQuotaLayout: String, CaseIterable {
    case list, grid

    static let storageKey = "hermes.notch.quota.layout"

    var title: String { self == .list ? "List" : "Grid" }
    var symbol: Ph { self == .list ? .listBullets : .squaresFour }
}

/// Shared inset icon selector for the Tasks source and Quota layout.
struct EdgePreviewModeToggle<Option: Hashable>: View {
    let options: [Option]
    let selection: Option
    let title: (Option) -> String
    /// Nil draws text segments; icons only suit options whose glyph says what they do.
    let symbol: ((Option) -> Ph)?
    let select: (Option) -> Void

    var body: some View {
        if symbol == nil {
            // Secondary filter under the Tasks/Quota tabs: plain text so it never reads as a second tab bar.
            HStack(spacing: 10) {
                ForEach(options, id: \.self) { option in
                    Button { select(option) } label: {
                        Text(title(option))
                            .font(.system(size: 11, weight: selection == option ? .semibold : .regular))
                            .foregroundStyle(selection == option ? Color.dockPrimaryText : Color.dockMetadataText)
                            .frame(height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .help(title(option))
                    .accessibilityLabel(title(option))
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
                }
            }
        } else {
            segmented
        }
    }

    private var segmented: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button { select(option) } label: {
                    DockIcon(symbol?(option) ?? .circle, size: 13,
                             color: selection == option ? .dockAccent : .dockSecondaryText)
                        .frame(width: 26, height: 22)
                        .background(DockThemeShape(cornerRadius: 5)
                            .dockSelectionFill(selection == option, fallback: selection == option ? Color.dockAccentMuted : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .help(title(option))
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(2)
        .background(DockThemeShape(cornerRadius: DockLayout.controlRadius - 1).dockSurfaceFill(Color.dockSurface4))
    }
}

/// Layout toggle and refresh control shown in the notch tab row while the
/// Quota tab is selected, so the preview body can spend its height on providers.
struct EdgeQuotaToolbar: View {
    @ObservedObject var control: ControlCenterModel
    @AppStorage(EdgeQuotaLayout.storageKey) private var layout: EdgeQuotaLayout = .list

    private var refreshing: Bool { control.refreshState(for: "provider.quota")?.isRefreshing == true }

    var body: some View {
        HStack(spacing: 4) {
            EdgePreviewModeToggle(options: EdgeQuotaLayout.allCases, selection: layout,
                                  title: { "\($0.title) layout" }, symbol: { $0.symbol }) { layout = $0 }

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
            .buttonStyle(.dockHover)
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
    var sessionActions: (() -> Void)? = nil
    @AppStorage(EdgeQuotaLayout.storageKey) private var layout: EdgeQuotaLayout = .list

    private var refreshing: Bool { control.refreshState(for: "provider.quota")?.isRefreshing == true }
    /// Pooled accounts with no usage windows stay on the Quota page; the notch is for capacity.
    private var quotas: [ProviderQuotaSnapshot] {
        control.providerQuotas.filter { !$0.provider.hasPrefix("hermes-pool-") }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let change {
                    EdgeQuotaChangeCard(change: change)
                        .id(change.current.updatedAt)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else if quotas.isEmpty {
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
            if let updatedAt = quotas.map(\.updatedAt).max() {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    Text(refreshing ? "Refreshing…" :
                         control.refreshState(for: "provider.quota")?.isStale == true ? "Stale data" :
                         "Updated \(Self.shortDuration(timeline.date.timeIntervalSince(updatedAt))) ago")
                        .foregroundStyle(Color.dockSecondaryText)
                }
            }
            Spacer(minLength: 0)
            if let sessionActions { Button("Session…", action: sessionActions).buttonStyle(.dockCompact).accessibilityLabel("Capacity and actions for the selected quick destination") }
            Button(action: openQuota) {
                DockIconLabel("Open Quota", icon: .arrowRight)
            }
            .buttonStyle(.dockCompact)
        }
        .lineLimit(1)
        .padding(.vertical, 6)
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(quotas.enumerated()), id: \.element.provider) { index, snapshot in
                if index > 0 { Divider().overlay(Color.dockBorderLight).padding(.leading, 28) }
                HStack(alignment: .top, spacing: 8) {
                    ProviderMarkBadge(mark: ProviderMark(providerID: snapshot.provider, displayName: snapshot.displayName))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(snapshot.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .frame(height: 20)
                        PeakNoticeBadge(quotaID: snapshot.provider, compact: true)
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
                                    .fill(Color.dockWarningFill)
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
            ForEach(quotas, id: \.provider) { snapshot in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ProviderMarkBadge(mark: ProviderMark(providerID: snapshot.provider, displayName: snapshot.displayName), size: 18)
                        Text(snapshot.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    PeakNoticeBadge(quotaID: snapshot.provider, compact: true)
                    let windows = Self.compactWindows(snapshot.windows)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 8) {
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
                .background(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous).dockSurfaceFill(Color.dockSurface2))
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
                        .fill(Color.dockWarningFill)
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
                    } else if let value = Self.ringValue(window) {
                        Text(value)
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: 32)
                    } else {
                        Text("—").font(.system(size: 11, weight: .semibold))
                    }
                }
                .lineLimit(1)
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
            .help("Resets \(resets.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))")
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
            parts.append("resets \(resets.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))")
        }
        return parts.joined(separator: ", ")
    }

    /// Short in-ring text for windows that report a value, not a percentage
    /// (pay-as-you-go balance and runway).
    nonisolated static func ringValue(_ window: ProviderQuotaWindow) -> String? {
        guard let display = window.remainingDisplay else { return nil }
        if display == "Under a day" { return "<1d" }
        return display.replacingOccurrences(of: " days", with: "d").replacingOccurrences(of: " est.", with: "")
    }

    /// Keeps every reported allowance, with the common session and weekly windows first.
    nonisolated static func compactWindows(_ windows: [ProviderQuotaWindow]) -> [(label: String, window: ProviderQuotaWindow)] {
        let session = windows.first { $0.label == "Session" || $0.id == "gemini-5h" }
        let weekly = windows.first { $0.label == "Weekly" || $0.id == "gemini-weekly" }
        let known = [session.map { ("5h", $0) }, weekly.map { ("7d", $0) }].compactMap { $0 }
        if !known.isEmpty {
            let ids = Set(known.map { $0.1.id })
            return known.map { (label: $0.0, window: $0.1) }
                + windows.filter { !ids.contains($0.id) }.map { (label: $0.label, window: $0) }
        }
        // Pay-as-you-go cards: balance plus how long it lasts.
        if let runway = windows.first(where: { $0.id == "hermes-runway" }), let balance = windows.first {
            return [(label: balance.label, window: balance), (label: "Runway", window: runway)]
        }
        return windows.map { (label: $0.label, window: $0) }
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
    /// Chat banner: provider and meters in one row instead of a stack.
    var inline = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    var body: some View {
        let layout = inline
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 20))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: compact ? 10 : 16))
        layout {
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
            .fixedSize()
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

enum ChatQuotaSettingsKey {
    static let chip = "hermes.chat.shows-quota-chip"
    static let dropBanner = "hermes.chat.shows-quota-drop-banner"
}

/// The provider closest to its limit, beside the composer's context ring.
/// Each bot may spend a different provider, so this tracks the lowest of all;
/// clicking lists every provider.
struct ChatQuotaChip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var control: ControlCenterModel
    let openQuota: () -> Void
    /// Hermes provider of the selected model (e.g. `openai-codex`); its quota is shown when known.
    var selectedProvider: String? = nil
    @AppStorage(ChatQuotaSettingsKey.chip) private var enabled = true
    @State private var showingDetail = false

    private var lowest: (snapshot: ProviderQuotaSnapshot, window: ProviderQuotaWindow, remaining: Double)? {
        control.quotaReading(for: selectedProvider)
    }

    var body: some View {
        if enabled, let lowest {
            Button { showingDetail.toggle() } label: {
                HStack(spacing: 4) {
                    ProviderMarkBadge(mark: ProviderMark(providerID: lowest.snapshot.provider,
                                                         displayName: lowest.snapshot.displayName), size: 14)
                    Text("\(Int(lowest.remaining.rounded()))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(QuotaWorkspaceView.color(for: lowest.window.threshold))
                        .contentTransition(.numericText(value: lowest.remaining.rounded()))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: Int(lowest.remaining.rounded()))
                }
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .help("\(lowest.snapshot.displayName) has \(Int(lowest.remaining.rounded()))% left")
            .accessibilityLabel("Quota: \(lowest.snapshot.displayName) \(Int(lowest.remaining.rounded())) percent remaining")
            .popover(isPresented: $showingDetail, arrowEdge: .top) {
                EdgeQuotaPreview(control: control) {
                    showingDetail = false
                    openQuota()
                }
                .frame(width: 320, height: 300)
            }
        }
    }
}

/// The notch's drop announcement, shown over the chat while the workspace
/// hides the notch: same 10% bands, same card, gone after a few seconds.
struct ChatQuotaBanner: View {
    @ObservedObject var control: ControlCenterModel
    /// The chat's reading width and side inset, so the banner lines up with messages.
    let metrics: ConversationWorkspaceMetrics
    @AppStorage(ChatQuotaSettingsKey.dropBanner) private var enabled = true
    @State private var lastQuotas: [ProviderQuotaSnapshot]?
    @State private var change: EdgeQuotaChange?
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let change {
                EdgeQuotaChangeCard(change: change, compact: true, inline: true)
                    .id(change.current.updatedAt)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: metrics.readingWidth)
                    .dockFloatingSurface(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous), tint: .dockSurface2, stroke: .dockBorderLight)
                    .shadow(color: .black.opacity(DockThemeStyle.current.material == .glass ? 0 : 0.12), radius: 8, y: 2)
                    .padding(.horizontal, metrics.contentInset)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { self.change = nil }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: change)
        .onReceive(control.$providerQuotas) { quotas in
            // An empty list is a reset (rebind or failed read), not a reading.
            guard !quotas.isEmpty else { return }
            defer { lastQuotas = quotas }
            guard enabled, let previousQuotas = lastQuotas,
                  let provider = EdgeQuotaBands.droppedProvider(from: EdgeQuotaBands.bands(previousQuotas),
                                                                to: EdgeQuotaBands.bands(quotas)),
                  let previous = previousQuotas.first(where: { $0.provider == provider }),
                  let current = quotas.first(where: { $0.provider == provider }) else { return }
            change = EdgeQuotaChange(previous: previous, current: current)
            dismissTask?.cancel()
            dismissTask = Task {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                change = nil
            }
        }
    }
}
