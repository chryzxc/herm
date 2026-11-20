import Combine
import SwiftUI

/// One provider's quota as concentric rings in the primary navigation rail: the outer ring is the
/// first reported percentage window (usually 5-hour), the inner ring the second (usually weekly).
/// Providers that report no percentage get no ring, so the rail never draws a fabricated meter.
struct QuotaRailRing: Equatable {
    struct Arc: Equatable {
        /// Short label from `EdgeQuotaPreview.compactWindows`, such as `5h` or `7d`.
        let label: String
        let remaining: Double
        let threshold: ProviderQuotaThreshold
        /// Today's even-use budget line, the same marker the Quota page meter draws; nil when hidden there.
        var budget: Double? = nil
    }

    static let preferenceKey = "herm.navigation.showsQuotaRings"
    static let defaultShown = true

    let snapshot: ProviderQuotaSnapshot
    /// Outer ring first; one or two arcs.
    let arcs: [Arc]
    /// Hermes picks this pooled account for the next request (the Quota page's Active pill).
    let isActive: Bool

    var provider: String { snapshot.provider }
    var displayName: String { snapshot.displayName }

    /// Rings in the Quota page's custom order, for every provider with at least one percentage window.
    static func make(
        _ snapshots: [ProviderQuotaSnapshot], activeCredentialKeys: Set<String> = [], now: Date = .now
    ) -> [Self] {
        snapshots.compactMap { snapshot in
            let arcs = EdgeQuotaPreview.compactWindows(snapshot.windows).compactMap { item -> Arc? in
                guard let remaining = item.window.remainingPercent, remaining.isFinite else { return nil }
                let clamped = min(max(remaining, 0), 100)
                let budget = QuotaForecasting.visibleDailyBudgetMarker(for: item.window, now: now)
                    .flatMap { $0.isFinite ? min(max($0, 0), 100) : nil }
                // A multi-day "Session" (Codex) is not a 5-hour window; speak its real label.
                let isMultiDay = (QuotaForecasting.cycleDuration(for: item.window, now: now) ?? 0) > 86_400
                return Arc(
                    label: item.label == "5h" && isMultiDay ? item.window.label : item.label, remaining: clamped,
                    threshold: ProviderQuotaWindow.threshold(forRemaining: clamped), budget: budget)
            }
            guard !arcs.isEmpty else { return nil }
            let isActive = snapshot.hermesCredential.map {
                activeCredentialKeys.contains(ControlCenterModel.hermesActiveCredentialKey($0))
            }
            return Self(snapshot: snapshot, arcs: Array(arcs.prefix(2)), isActive: isActive ?? false)
        }
    }

    /// Spoken summary, such as `Active, 5-hour 72% left, weekly 40% left`.
    var summary: String {
        let windows = arcs.map { "\(Self.spokenLabel($0.label)) \(Int($0.remaining.rounded()))% left" }
        return ((isActive ? ["Active"] : []) + windows).joined(separator: ", ")
    }

    static func spokenLabel(_ label: String) -> String {
        switch label {
        case "5h": "5-hour"
        case "7d": "weekly"
        default: label
        }
    }
}

/// The rail's quota group. It observes only the quota list and the active pool accounts, so
/// unrelated control-center updates do not redraw the rail.
struct QuotaRailRings: View {
    let control: ControlCenterModel
    let onOpenQuota: () -> Void
    @State private var rings: [QuotaRailRing] = []

    var body: some View {
        VStack(spacing: 4) {
            if !rings.isEmpty {
                Color.dockBorderLight
                    .frame(width: 22, height: DockLayout.hairline)
                    .dockPadding(.vertical, 4)
                    .accessibilityHidden(true)
                ForEach(rings, id: \.provider) { ring in
                    QuotaRailRingButton(ring: ring, action: onOpenQuota)
                }
            }
        }
        .onReceive(control.$providerQuotas.combineLatest(control.$hermesActiveCredentialKeys)) { snapshots, keys in
            let next = QuotaRailRing.make(snapshots, activeCredentialKeys: keys)
            if next != rings { rings = next }
        }
    }
}

private struct QuotaRailRingButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ring: QuotaRailRing
    let action: () -> Void
    @State private var showsDetail = false
    @State private var isDetailHovered = false
    @State private var hoverTask: Task<Void, Never>?

    private static let lineWidth: CGFloat = 2
    private static let outerDiameter: CGFloat = 32
    private static let innerDiameter: CGFloat = 24
    private static let activeDot: CGFloat = 7
    /// The outer ring's centerline at 45°.
    private static let dotOffset: CGFloat = (outerDiameter / 2) * 0.7071

    var body: some View {
        Button {
            hoverTask?.cancel()
            showsDetail = false
            action()
        } label: {
            ZStack {
                ForEach(Array(ring.arcs.enumerated()), id: \.offset) { index, arc in
                    arcView(arc, diameter: index == 0 ? Self.outerDiameter : Self.innerDiameter)
                }
                ProviderMarkBadge(
                    mark: QuotaWorkspaceView.mark(for: ring.snapshot),
                    size: ring.arcs.count > 1 ? 16 : 20, tile: false)
                if ring.isActive {
                    // The Active pill's dot, seated on the outer ring at the top right.
                    Circle()
                        .fill(Color.dockAccent)
                        .frame(width: Self.activeDot, height: Self.activeDot)
                        .overlay(Circle().stroke(Color.dockCanvas, lineWidth: 1.5))
                        .offset(x: Self.dotOffset, y: -Self.dotOffset)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.2), value: ring.isActive)
        .onHover { inside in
            hoverTask?.cancel()
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(inside ? 350 : 250))
                guard !Task.isCancelled else { return }
                if inside || !isDetailHovered { showsDetail = inside }
            }
        }
        .dockPopover(isPresented: $showsDetail, arrowEdge: .trailing) { detail }
        .accessibilityLabel("\(ring.displayName) quota")
        .accessibilityValue(ring.summary)
        .accessibilityHint("Opens Quota")
    }

    private func arcView(_ arc: QuotaRailRing.Arc, diameter: CGFloat) -> some View {
        QuotaRingArc(arc: arc, lineWidth: Self.lineWidth).frame(width: diameter, height: diameter)
    }

    /// The provider's Quota card in miniature: the same window cells the page draws.
    private var detail: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProviderMarkBadge(mark: QuotaWorkspaceView.mark(for: ring.snapshot), size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ring.displayName)
                            .dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(1)
                        if let model = ring.snapshot.model {
                            Text(model)
                                .dockFont(.metadata)
                                .foregroundStyle(Color.dockMetadataText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if ring.isActive {
                        HStack(spacing: 6) {
                            Circle().fill(Color.dockAccent).frame(width: 6, height: 6)
                            Text("Active")
                                .dockFont(.metadata, weight: .semibold)
                                .foregroundStyle(Color.dockPrimaryText)
                        }
                        .dockPill()
                        .help("Hermes picks this account for the next request.")
                    }
                }

                PeakNoticeBadge(quotaID: ring.provider, compact: true)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ring.snapshot.windows) { window in
                        QuotaWindowCell(window: window, now: timeline.date, isCompact: true)
                    }
                }

                HStack {
                    Text("Updated \(ring.snapshot.updatedAt.formatted(.dateTime.hour().minute()))")
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                    Spacer(minLength: 8)
                    Button {
                        showsDetail = false
                        action()
                    } label: {
                        DockIconLabel("Open Quota", icon: .arrowRight)
                    }
                    .buttonStyle(.dockSecondary)
                }
                .dockButtonSize(.compact)
            }
            .dockPadding(14)
            .frame(width: 300, alignment: .leading)
        }
        .onHover { inside in
            isDetailHovered = inside
            hoverTask?.cancel()
            guard !inside else { return }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { showsDetail = false }
            }
        }
    }
}

/// One ring: a faint track and the remaining arc, which sweeps in from empty when first shown and
/// eases to each new reading (and its health color) afterward. Reduce Motion shows it in place.
private struct QuotaRingArc: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let arc: QuotaRailRing.Arc
    let lineWidth: CGFloat
    @State private var hasAppeared = false

    var body: some View {
        let fraction = hasAppeared ? arc.remaining / 100 : 0
        ZStack {
            Circle().stroke(Color.dockBorder.opacity(0.6), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    QuotaWorkspaceView.color(for: arc.threshold),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                // A round cap draws a dot at zero length; hide it when nothing remains.
                .opacity(fraction > 0 ? 1 : 0)
            if let budget = arc.budget {
                // The page meter's budget line, turned radial: a short tick across the ring.
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color.dockPrimaryText.opacity(0.7))
                    .frame(width: 1.5, height: lineWidth + 3)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .offset(y: -1.5)
                    .rotationEffect(.degrees(budget * 3.6))
                    .opacity(hasAppeared ? 1 : 0)
            }
        }
        .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.7), value: hasAppeared)
        .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.45), value: arc)
        .task { if !hasAppeared { hasAppeared = true } }
    }
}
