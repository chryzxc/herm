import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The fullscreen Quota destination: an overview of the whole provider pool,
/// then one signage card per connected provider, then providers that can be
/// connected. Every figure comes from a provider report; nothing is estimated
/// except the forecasts that `QuotaForecasting` labels as such.
struct QuotaWorkspaceView: View {
    @ObservedObject var control: ControlCenterModel
    @AppStorage("dock.quota.autoRefreshMinutes") private var autoRefreshMinutes = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var connectTarget: QuotaProviderDescriptor?
    @State private var renamingProviderID: String?
    @State private var renameDraft = ""
    @State private var draggingProviderID: String?
    @State private var removalCandidate: ProviderQuotaSnapshot?
    @FocusState private var renameFieldFocused: Bool

    private static let autoRefreshChoices = [0, 1, 5, 15]

    private var refreshState: ProjectionRefreshState? { control.refreshState(for: "provider.quota") }

    /// The user's drag-and-drop order, shared with the notch Quota tab.
    private var connectedSnapshots: [ProviderQuotaSnapshot] { control.providerQuotas }

    private var availableDescriptors: [QuotaProviderDescriptor] {
        let connectedIDs = control.providerQuotas.map(\.provider)
        return QuotaProviderCatalog.all.filter { descriptor in
            !connectedIDs.contains { $0 == descriptor.id || $0.hasPrefix(descriptor.id + "-") }
        }
    }

    private var canReorder: Bool { control.providerQuotas.count > 1 }

    var body: some View {
        let connected = connectedSnapshots
        let available = availableDescriptors

        VStack(alignment: .leading, spacing: 16) {
            toolbar

            if refreshState?.isRefreshing == true && control.providerQuotas.isEmpty {
                compactMessage(title: "Reading provider quota…", detail: "Each connected provider is asked for its current windows.")
            } else {
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 16) {
                        if connected.isEmpty {
                            compactMessage(
                                title: "No provider quota yet",
                                detail: "Connect a provider below to see its remaining capacity and reset windows."
                            )
                        } else {
                            overview(connected, now: context.date)
                            providerList(connected, now: context.date)
                        }
                    }
                }

                if !available.isEmpty {
                    availableSection(available)
                }
            }

            if let state = refreshState, let error = state.error {
                Text(state.isStale ? "Showing last successful data. \(error)" : error)
                    .font(DockTypography.metadata)
                    .foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $connectTarget) { descriptor in
            ProviderConnectSheet(descriptor: descriptor, control: control)
        }
        .task(id: autoRefreshMinutes) { await runAutoRefresh() }
        .task { await control.configEditor.load() }  // rotation strategy for the credential menu
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(get: { removalCandidate != nil }, set: { if !$0 { removalCandidate = nil } }),
            titleVisibility: .visible,
            presenting: removalCandidate
        ) { snapshot in
            Button("Remove from Hermes", role: .destructive) {
                control.removeHermesPooledCredential(for: snapshot.provider)
            }
            Button("Cancel", role: .cancel) {}
        } message: { snapshot in
            if let credential = snapshot.hermesCredential {
                Text("Runs `hermes auth remove \(credential.provider) \(credential.id)`. Hermes stops using “\(credential.label)” (#\(credential.position) in its \(credential.provider) pool) for every agent, not just this page. Sign in again with `hermes auth add` to restore it.")
            }
        }
    }

    private var removalTitle: String {
        guard let removalCandidate else { return "Remove account from Hermes?" }
        return "Remove \(removalCandidate.displayName) from Hermes?"
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(QuotaWorkspacePresentation.overviewSentence(
                providerCount: control.providerQuotas.count + availableDescriptors.count,
                connectedCount: control.providerQuotas.count,
                attentionCount: control.providerQuotas.filter(QuotaWorkspacePresentation.needsAttention).count
            ))
            .font(DockTypography.control)
            .foregroundStyle(Color.dockSecondaryText)
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 8)

            autoRefreshMenu

            if let lastSuccess = refreshState?.lastSuccess {
                Text("Updated \(lastSuccess, format: .dateTime.hour().minute())")
                    .font(DockTypography.machineMetadata)
                    .foregroundStyle(refreshState?.isStale == true ? Color.dockWarning : Color.dockMetadataText)
                    .lineLimit(1)
                    .help(refreshState?.isStale == true ? "The last refresh failed; figures are from this time." : "Last successful provider read")
            }

            DockIconButton(
                icon: .arrowsClockwise,
                label: refreshState?.isRefreshing == true ? "Refreshing provider quota" : "Refresh provider quota",
                isBusy: refreshState?.isRefreshing == true,
                style: DockThemePalette(theme: DockThemeRuntime.current)
            ) { control.refreshProviderQuota() }
        }
        .frame(minHeight: DockControlMetrics.hitTarget)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    private var autoRefreshMenu: some View {
        Menu {
            Picker("Auto-refresh", selection: $autoRefreshMinutes) {
                ForEach(Self.autoRefreshChoices, id: \.self) { minutes in
                    Text(Self.autoRefreshTitle(minutes)).tag(minutes)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                DockIcon(.clock, size: 13, color: Color.dockMetadataText)
                Text(autoRefreshMinutes == 0 ? "Auto off" : "Every \(autoRefreshMinutes)m")
                    .font(DockTypography.control)
                    .foregroundStyle(Color.dockSecondaryText)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Re-read provider quota automatically while this page is open")
    }

    private static func autoRefreshTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Off"
        case 1: "Every minute"
        default: "Every \(minutes) minutes"
        }
    }

    private func runAutoRefresh() async {
        guard autoRefreshMinutes > 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(autoRefreshMinutes * 60))
            guard !Task.isCancelled else { return }
            if refreshState?.isRefreshing != true {
                control.refreshProviderQuota()
            }
        }
    }

    // MARK: Overview

    private func overview(_ snapshots: [ProviderQuotaSnapshot], now: Date) -> some View {
        let best = QuotaWorkspacePresentation.bestAvailable(snapshots)
        let attention = snapshots.filter(QuotaWorkspacePresentation.needsAttention)
        let reset = QuotaWorkspacePresentation.nextReset(snapshots, now: now)

        let headroom = if let best, let remaining = QuotaWorkspacePresentation.effectiveRemaining(best) {
            overviewMetric(
                title: "Most headroom",
                value: "\(Int(remaining.rounded()))%",
                valueColor: Self.figureColor(for: ProviderQuotaWindow.threshold(forRemaining: remaining)),
                detail: [best.displayName, QuotaWorkspacePresentation.limitingWindow(best)?.label].compactMap { $0 }.joined(separator: " · "),
                help: "The provider with the most capacity left in its tightest window."
            )
        } else {
            overviewMetric(title: "Most headroom", value: "—", valueColor: .dockMetadataText, detail: "No provider reported a percentage", help: nil)
        }
        let needsAttention = overviewMetric(
            title: "Needs attention",
            value: "\(attention.count) of \(snapshots.count)",
            valueColor: attention.isEmpty ? .dockPrimaryText : .dockWarning,
            detail: attention.isEmpty ? "Every connected provider has headroom" : attention.map(\.displayName).joined(separator: ", "),
            help: "Providers with a window at or below 20% remaining."
        )
        let nextReset = if let reset {
            overviewMetric(
                title: reset.restoresAttention ? "Next recovery" : "Next reset",
                value: QuotaWorkspacePresentation.compactDuration(from: now, to: reset.date),
                valueColor: .dockPrimaryText,
                detail: "\(reset.snapshot.displayName) · \(reset.window.label) · \(reset.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))",
                help: reset.restoresAttention
                    ? "The soonest reset of a window that is low or exhausted."
                    : "The soonest reported window reset."
            )
        } else {
            overviewMetric(title: "Next reset", value: "—", valueColor: .dockMetadataText, detail: "No reset times reported", help: nil)
        }

        // Three columns when there is room, stacked rows on narrow windows.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                headroom
                overviewDivider
                needsAttention
                overviewDivider
                nextReset
            }
            .frame(minWidth: 620)
            VStack(alignment: .leading, spacing: 0) {
                headroom
                Color.dockBorderLight.frame(height: DockLayout.hairline).padding(.horizontal, 12)
                needsAttention
                Color.dockBorderLight.frame(height: DockLayout.hairline).padding(.horizontal, 12)
                nextReset
            }
        }
        .dockCard(padding: 0)
    }

    private var overviewDivider: some View {
        Color.dockBorderLight
            .frame(width: DockLayout.hairline)
            .padding(.vertical, 12)
    }

    private func overviewMetric(title: String, value: String, valueColor: Color, detail: String, help: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DockSectionLabel(title: title)
            Text(value)
                .font(DockTypography.metric)
                .foregroundStyle(valueColor)
                .lineLimit(1)
            Text(detail)
                .font(DockTypography.metadata)
                .foregroundStyle(Color.dockMetadataText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .help(help ?? "")
    }

    // MARK: Providers

    private func providerList(_ snapshots: [ProviderQuotaSnapshot], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DockSectionLabel(title: "Connected", count: snapshots.count)
                .padding(.top, 4)
            ForEach(snapshots, id: \.provider) { snapshot in
                providerCard(snapshot, now: now)
                    .onDrop(
                        of: [UTType.text],
                        delegate: QuotaReorderDropDelegate(
                            targetID: snapshot.provider,
                            isEnabled: canReorder,
                            draggingID: $draggingProviderID,
                            move: { control.moveProviderQuota($0, to: $1) }
                        )
                    )
            }
        }
        .animation(reduceMotion ? nil : .dockEase(duration: 0.2), value: snapshots.map(\.provider))
    }

    private func providerCard(_ snapshot: ProviderQuotaSnapshot, now: Date) -> some View {
        let health = QuotaWorkspacePresentation.worstThreshold(snapshot)

        return VStack(alignment: .leading, spacing: 14) {
            providerHeader(snapshot, health: health)

            if snapshot.windows.isEmpty {
                Text("No quota windows were reported.")
                    .font(DockTypography.body)
                    .foregroundStyle(Color.dockSecondaryText)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240), spacing: 24, alignment: .top)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(snapshot.windows) { window in
                        windowCell(window, now: now)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DockControlMetrics.paneRadius, style: .continuous)
                .fill(Color.dockSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DockControlMetrics.paneRadius, style: .continuous)
                .stroke(Color.dockBorderLight, lineWidth: 1)
        )
        .contextMenu { providerActions(snapshot) }
    }

    private func providerHeader(_ snapshot: ProviderQuotaSnapshot, health: ProviderQuotaThreshold) -> some View {
        HStack(spacing: 10) {
            if canReorder {
                dragHandle(snapshot)
            }

            ProviderMarkBadge(mark: ProviderMark(providerID: snapshot.provider, displayName: snapshot.displayName), size: 26)

            VStack(alignment: .leading, spacing: 2) {
                if renamingProviderID == snapshot.provider {
                    renameField(snapshot)
                } else {
                    Text(snapshot.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                        .onTapGesture(count: 2) { beginRename(snapshot) }
                        .help("Double-click to rename")
                }
                if let error = control.providerQuotaActionErrors[snapshot.provider] {
                    Text(error)
                        .font(DockTypography.metadata)
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(error)
                } else if let metadata = metadataLine(snapshot) {
                    Text(metadata)
                        .font(DockTypography.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            if let credential = snapshot.hermesCredential, control.isHermesActiveCredential(credential) {
                QuotaHealthPill(text: "Active", color: .dockAccent)
                    .help("Hermes picks this account for the next request (hermes auth list marks it ←).")
            }

            if let label = QuotaWorkspacePresentation.healthLabel(snapshot) {
                QuotaHealthPill(text: label, color: Self.color(for: health))
            }

            if control.isActionPending(ControlCenterModel.hermesCredentialRemovalActionID(snapshot.provider))
                || control.isActionPending(ControlCenterModel.hermesCredentialPrimaryActionID(snapshot.provider)) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: DockControlMetrics.compactHeight, height: DockControlMetrics.compactHeight)
                    .accessibilityLabel("Removing \(snapshot.displayName) from Hermes")
            } else {
                Menu { providerActions(snapshot) } label: {
                    DockIcon(.dotsThree, size: 15, color: Color.dockSecondaryText)
                        .frame(width: DockControlMetrics.compactHeight, height: DockControlMetrics.compactHeight)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Provider actions")
                .accessibilityLabel("Actions for \(snapshot.displayName)")
            }
        }
    }

    private func metadataLine(_ snapshot: ProviderQuotaSnapshot) -> String? {
        var parts: [String] = []
        if control.getProviderNickname(for: snapshot.provider) != nil,
           let reported = control.reportedProviderName(for: snapshot.provider),
           reported != snapshot.displayName {
            parts.append(reported)
        }
        if let credential = snapshot.hermesCredential { parts.append("Hermes pool · \(credential.label)") }
        if let model = snapshot.model { parts.append(model) }
        if let detail = snapshot.safeDetail { parts.append(detail) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func dragHandle(_ snapshot: ProviderQuotaSnapshot) -> some View {
        DockIcon(.list)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.dockMetadataText)
            .frame(width: 16, height: DockControlMetrics.compactHeight)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .onDrag {
                draggingProviderID = snapshot.provider
                return NSItemProvider(object: snapshot.provider as NSString)
            } preview: {
                HStack(spacing: 8) {
                    ProviderMarkBadge(mark: ProviderMark(providerID: snapshot.provider, displayName: snapshot.displayName), size: 20)
                    Text(snapshot.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DockControlMetrics.paneRadius, style: .continuous)
                        .fill(Color.dockSurface4)
                )
            }
            .help("Drag to reorder")
            // Move up/down in the actions menu is the accessible path.
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func providerActions(_ snapshot: ProviderQuotaSnapshot) -> some View {
        Button("Rename…", icon: .pencilSimple) { beginRename(snapshot) }
        if control.getProviderNickname(for: snapshot.provider) != nil {
            Button("Restore reported name", icon: .arrowCounterClockwise) {
                control.removeProviderNickname(for: snapshot.provider)
            }
        }
        if canReorder {
            let ids = control.providerQuotas.map(\.provider)
            Divider()
            Button("Move up", icon: .arrowUp) {
                withReorderAnimation { control.moveProviderQuota(snapshot.provider, by: -1) }
            }
            .disabled(ids.first == snapshot.provider)
            Button("Move down", icon: .arrowDown) {
                withReorderAnimation { control.moveProviderQuota(snapshot.provider, by: 1) }
            }
            .disabled(ids.last == snapshot.provider)
        }
        if let website = QuotaWorkspacePresentation.descriptor(forProvider: snapshot.provider)?.website {
            Divider()
            Button("Open provider website", icon: .arrowSquareOut) {
                ExternalOpen.open(website)
            }
        }
        if let credential = snapshot.hermesCredential {
            Divider()
            if !(control.isHermesActiveCredential(credential) && control.isHermesPinnedPrimary(credential)) {
                // round_robin rewrites the order after every pick, so "first" only means next in line.
                let rotates = control.configEditor.value("credential_pool_strategies.\(credential.provider)") as? String == "round_robin"
                Button(rotates ? "Make next in line" : "Make primary", icon: .arrowUp) {
                    control.makeHermesPooledCredentialPrimary(for: snapshot.provider)
                }
            }
            Button("Remove from Hermes…", icon: .trash, role: .destructive) {
                removalCandidate = snapshot
            }
        }
    }

    private func withReorderAnimation(_ body: () -> Void) {
        if reduceMotion { body() } else { withAnimation(.dockEase(duration: 0.2), body) }
    }

    // MARK: Rename

    private func renameField(_ snapshot: ProviderQuotaSnapshot) -> some View {
        TextField(control.reportedProviderName(for: snapshot.provider) ?? snapshot.displayName, text: $renameDraft)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.dockPrimaryText)
            .focused($renameFieldFocused)
            .onSubmit { commitRename(snapshot.provider) }
            .onExitCommand { renamingProviderID = nil }
            .onChange(of: renameFieldFocused) { _, focused in
                if !focused { commitRename(snapshot.provider) }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: 280, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous)
                    .fill(Color.dockControlSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous)
                    .stroke(Color.dockAccent.opacity(0.7), lineWidth: 1)
            )
            .accessibilityLabel("Provider name")
            .help("Return saves, Escape cancels. Leave empty to restore the reported name.")
    }

    private func beginRename(_ snapshot: ProviderQuotaSnapshot) {
        renameDraft = snapshot.displayName
        renamingProviderID = snapshot.provider
        // The field is inserted in this update; focus it on the next one.
        Task { @MainActor in renameFieldFocused = true }
    }

    private func commitRename(_ providerID: String) {
        guard renamingProviderID == providerID else { return }
        renamingProviderID = nil
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == control.reportedProviderName(for: providerID) {
            control.removeProviderNickname(for: providerID)
        } else {
            control.setProviderNickname(name, for: providerID)
        }
    }

    // MARK: Windows

    private func windowCell(_ window: ProviderQuotaWindow, now: Date) -> some View {
        let color = Self.color(for: window.threshold)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.label)
                    .font(DockTypography.control)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let reset = window.resetsAt, reset > now {
                    Text("Resets in \(QuotaWorkspacePresentation.compactDuration(from: now, to: reset))")
                        .font(DockTypography.machineMetadata)
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                        .help(reset.formatted(date: .complete, time: .shortened))
                } else if let reset = window.resetsDisplay {
                    Text(reset)
                        .font(DockTypography.machineMetadata)
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                }
            }

            if let remaining = window.remainingPercent {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(remaining.rounded()))%")
                        .font(DockTypography.metric)
                        .foregroundStyle(Self.figureColor(for: window.threshold))
                    Text("left")
                        .font(DockTypography.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                    Spacer(minLength: 8)
                    if let limit = window.limitDisplay {
                        Text(limit)
                            .font(DockTypography.machineMetadata)
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(1)
                    }
                }
                QuotaMeter(
                    remaining: remaining,
                    color: color,
                    budgetMarker: QuotaForecasting.visibleDailyBudgetMarker(for: window, now: now)
                )
                .accessibilityLabel("\(window.label), \(Int(remaining.rounded())) percent remaining")
            } else {
                Text(window.remainingDisplay ?? "No percentage reported")
                    .font(DockTypography.body)
                    .foregroundStyle(Color.dockSecondaryText)
                if let limit = window.limitDisplay {
                    Text(limit)
                        .font(DockTypography.machineMetadata)
                        .foregroundStyle(Color.dockSecondaryText)
                }
            }

            windowInsights(window, now: now)
        }
        .accessibilityElement(children: .combine)
    }

    /// At most two lines explaining what the figure means for today.
    @ViewBuilder
    private func windowInsights(_ window: ProviderQuotaWindow, now: Date) -> some View {
        if let remaining = window.remainingPercent, remaining <= 0 {
            if let reset = window.resetsAt, reset > now {
                insight("Exhausted until \(reset.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))", color: .dockDestructive)
            } else {
                insight("Exhausted", color: .dockDestructive)
            }
        } else {
            if let forecast = QuotaForecasting.limitForecast(for: window, now: now) {
                insight(
                    "Runs out in ~\(QuotaWorkspacePresentation.compactDuration(from: now, to: forecast)) at this pace",
                    color: window.threshold == .healthy ? .dockSecondaryText : .dockWarning,
                    icon: .flame
                )
                .help("Estimated from the average consumption so far this cycle; the provider does not report a depletion time.")
            }
            if let daily = QuotaForecasting.dailyAllowance(for: window, now: now) {
                insight("\(daily)% available today", color: .dockSecondaryText)
                    .help("Even-use budget through today, including unused days carried forward. The marker shows where it ends.")
            } else if let delta = QuotaWorkspacePresentation.paceDelta(for: window, now: now), abs(delta) >= 3 {
                insight(
                    delta < 0 ? "\(Int(-delta.rounded()))% over even-use pace" : "\(Int(delta.rounded()))% under even-use pace",
                    color: delta < 0 ? .dockWarning : .dockSecondaryText
                )
                .help("Compared with spending this window evenly until it resets.")
            }
        }
    }

    private func insight(_ text: String, color: Color, icon: Ph? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon { DockIcon(icon, size: 11, color: color == .dockSecondaryText ? .dockMetadataText : color) }
            Text(text)
                .font(DockTypography.metadata)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    // MARK: Available providers

    private func availableSection(_ descriptors: [QuotaProviderDescriptor]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DockSectionLabel(title: "Available to connect", count: descriptors.count)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ForEach(descriptors) { descriptor in
                availableRow(descriptor)
            }
        }
    }

    private func availableRow(_ descriptor: QuotaProviderDescriptor) -> some View {
        let diagnostic = control.providerQuotaDiagnostics[descriptor.id]
        return HStack(spacing: 10) {
            ProviderMarkBadge(mark: ProviderMark(providerID: descriptor.id, displayName: descriptor.displayName), size: 22)
                .opacity(0.7)
            VStack(alignment: .leading, spacing: 3) {
                Text(descriptor.displayName)
                    .font(DockTypography.rowTitle)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
                Text(diagnostic ?? descriptor.summary)
                    .font(DockTypography.metadata)
                    .foregroundStyle(diagnostic == nil ? Color.dockMetadataText : Color.dockWarning)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { connectTarget = descriptor } label: {
                Text("Connect…")
                    .font(DockTypography.control)
                    .frame(minWidth: 76, minHeight: DockControlMetrics.compactHeight)
            }
            .buttonStyle(.bordered)
            if let website = descriptor.website {
                Link(destination: website) {
                    DockIcon(.arrowSquareOut, size: 13, color: Color.dockSecondaryText)
                        .frame(width: DockControlMetrics.hitTarget, height: DockControlMetrics.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .help("Open \(descriptor.displayName) website")
                .accessibilityLabel("Open \(descriptor.displayName) website")
            }
        }
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Color.dockBorderLight.opacity(0.6).frame(height: DockLayout.hairline) }
    }

    // MARK: Shared

    private func compactMessage(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
            Text(detail)
                .font(DockTypography.body)
                .foregroundStyle(Color.dockSecondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    /// Shared with the notch Quota tab so both surfaces use the same hues.
    /// Traffic-light hues for meters and rings: green, orange, red.
    static func color(for threshold: ProviderQuotaThreshold) -> Color {
        switch threshold {
        case .healthy: .dockSuccess
        case .warning: .dockWarning
        case .critical: .dockDestructive
        case .unknown: .dockMetadataText
        }
    }

    /// Figures read as plain text until they need attention.
    static func figureColor(for threshold: ProviderQuotaThreshold) -> Color {
        threshold == .healthy ? .dockPrimaryText : color(for: threshold)
    }
}

/// Remaining-capacity meter. An exhausted window shows an empty track rather
/// than a token sliver, and the optional marker is today's budget line.
private struct QuotaMeter: View {
    let remaining: Double
    let color: Color
    let budgetMarker: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // The taller marker is an overlay so it can't stretch the 6pt capsules.
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dockSurface4)
                if remaining > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: max(4, width * min(remaining, 100) / 100))
                }
            }
            .frame(height: 6)
            .overlay(alignment: .leading) {
                if let budgetMarker {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.dockPrimaryText.opacity(0.7))
                        .frame(width: 2, height: 12)
                        .offset(x: min(max(0, width * budgetMarker / 100), width - 2))
                        .help("Balance to keep after today's even-use budget: \(Int(budgetMarker))%")
                }
            }
        }
        .frame(height: 6)
    }
}

/// Capsule health label in the quota semantic hue; mirrors `DockStatusPill`.
private struct QuotaHealthPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.dockSurface4))
        .accessibilityElement(children: .combine)
    }
}

/// Live reorder: hovering a dragged card over another moves it into that
/// position immediately, so the drop itself only has to end the drag.
private struct QuotaReorderDropDelegate: DropDelegate {
    let targetID: String
    let isEnabled: Bool
    @Binding var draggingID: String?
    let move: (String, String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && draggingID != nil
    }

    func dropEntered(info: DropInfo) {
        guard isEnabled, let draggingID, draggingID != targetID else { return }
        withAnimation(.dockEase(duration: 0.2)) { move(draggingID, targetID) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

// MARK: - Presentation

struct QuotaWorkspacePresentation {
    struct ResetEvent {
        let snapshot: ProviderQuotaSnapshot
        let window: ProviderQuotaWindow
        let date: Date
        /// True when the reset restores a low or exhausted window.
        let restoresAttention: Bool
    }

    static func needsAttention(_ snapshot: ProviderQuotaSnapshot) -> Bool {
        snapshot.windows.contains { $0.threshold == .warning || $0.threshold == .critical }
    }

    static func severityRank(_ snapshot: ProviderQuotaSnapshot) -> Int {
        if snapshot.windows.contains(where: { $0.threshold == .critical }) { return 0 }
        if snapshot.windows.contains(where: { $0.threshold == .warning }) { return 1 }
        if snapshot.windows.isEmpty || snapshot.windows.contains(where: { $0.threshold == .unknown }) { return 2 }
        return 3
    }

    static func worstThreshold(_ snapshot: ProviderQuotaSnapshot) -> ProviderQuotaThreshold {
        switch severityRank(snapshot) {
        case 0: .critical
        case 1: .warning
        case 2: .unknown
        default: .healthy
        }
    }

    /// Applies the user's saved order. Providers without a saved position
    /// follow in catalog order (accounts such as `codex-hermes-<pool entry id>` group with
    /// their catalog entry), then in reported order.
    static func ordered(
        _ snapshots: [ProviderQuotaSnapshot],
        savedOrder: [String],
        catalogOrder: [String] = QuotaProviderCatalog.orderedProviderIDs()
    ) -> [ProviderQuotaSnapshot] {
        let saved = Dictionary(savedOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let catalog = Dictionary(catalogOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func catalogRank(_ id: String) -> Int {
            catalog.filter { id == $0.key || id.hasPrefix($0.key + "-") }
                .max { $0.key.count < $1.key.count }?.value ?? Int.max
        }
        return snapshots.enumerated()
            .map { (key: (saved[$0.element.provider] ?? Int.max, catalogRank($0.element.provider), $0.offset), snapshot: $0.element) }
            .sorted { $0.key < $1.key }
            .map(\.snapshot)
    }

    /// Moves `id` into the position currently held by `target`.
    static func moving(_ id: String, to target: String, in ids: [String]) -> [String] {
        guard id != target,
              let from = ids.firstIndex(of: id),
              let to = ids.firstIndex(of: target) else { return ids }
        var result = ids
        result.remove(at: from)
        result.insert(id, at: to)
        return result
    }

    static func descriptor(forProvider providerID: String) -> QuotaProviderDescriptor? {
        QuotaProviderCatalog.all
            .filter { providerID == $0.id || providerID.hasPrefix($0.id + "-") }
            .max { $0.id.count < $1.id.count }
    }

    /// The window with the least remaining capacity; it bounds what the
    /// provider can actually do right now.
    static func limitingWindow(_ snapshot: ProviderQuotaSnapshot) -> ProviderQuotaWindow? {
        snapshot.windows
            .filter { $0.remainingPercent != nil }
            .min { ($0.remainingPercent ?? 0) < ($1.remainingPercent ?? 0) }
    }

    static func effectiveRemaining(_ snapshot: ProviderQuotaSnapshot) -> Double? {
        limitingWindow(snapshot)?.remainingPercent
    }

    /// The provider with the most usable capacity. Ties keep incoming order.
    static func bestAvailable(_ snapshots: [ProviderQuotaSnapshot]) -> ProviderQuotaSnapshot? {
        var best: (snapshot: ProviderQuotaSnapshot, remaining: Double)?
        for snapshot in snapshots {
            guard let remaining = effectiveRemaining(snapshot) else { continue }
            if best == nil || remaining > best!.remaining { best = (snapshot, remaining) }
        }
        return best?.snapshot
    }

    /// The soonest upcoming reset, preferring windows that are low or
    /// exhausted because those resets change what the user can do.
    static func nextReset(_ snapshots: [ProviderQuotaSnapshot], now: Date = .now) -> ResetEvent? {
        let events = snapshots.flatMap { snapshot in
            snapshot.windows.compactMap { window -> ResetEvent? in
                guard let reset = window.resetsAt, reset > now else { return nil }
                let attention = window.threshold == .warning || window.threshold == .critical
                return ResetEvent(snapshot: snapshot, window: window, date: reset, restoresAttention: attention)
            }
        }
        let attention = events.filter(\.restoresAttention)
        return (attention.isEmpty ? events : attention).min { $0.date < $1.date }
    }

    /// A short label for a provider that needs a decision; healthy and
    /// unknown providers carry no label.
    static func healthLabel(_ snapshot: ProviderQuotaSnapshot) -> String? {
        let percents = snapshot.windows.compactMap(\.remainingPercent)
        if percents.contains(where: { $0 <= 0 }) { return "Exhausted" }
        switch worstThreshold(snapshot) {
        case .critical: return "Critical"
        case .warning: return "Low"
        case .healthy, .unknown: return nil
        }
    }

    /// Remaining balance minus the even-use expectation; negative means the
    /// window is being spent faster than an even pace.
    static func paceDelta(for window: ProviderQuotaWindow, now: Date = .now) -> Double? {
        guard let remaining = window.remainingPercent,
              let expected = QuotaForecasting.expectedRemainingMarker(for: window, now: now) else { return nil }
        return remaining - expected
    }

    /// Compact countdown such as `45m`, `3h 20m`, or `2d 4h`.
    static func compactDuration(from now: Date, to date: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        let days = hours / 24
        let restHours = hours % 24
        return restHours == 0 ? "\(days)d" : "\(days)d \(restHours)h"
    }

    static func overviewSentence(providerCount: Int, connectedCount: Int, attentionCount: Int) -> String {
        let availableCount = max(0, providerCount - connectedCount)
        let connected = connectedCount == 1 ? "1 connected" : "\(connectedCount) connected"
        let attention = attentionCount == 1 ? "1 needs attention" : "\(attentionCount) need attention"
        let available = availableCount == 1 ? "1 available to connect" : "\(availableCount) available to connect"
        return "\(connected) · \(attention) · \(available)"
    }
}
