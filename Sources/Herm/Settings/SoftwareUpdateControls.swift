import AppKit
import SwiftUI

/// The same updates and confirmation flow serve the Settings page and rail popover.
struct SoftwareUpdateControls: View {
    let appUpdater: HermAppUpdater
    let agentUpdateService: HermesUpdateService
    var compact = false

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 10) { sections }
                .dockPadding(12)
                .frame(width: 360)
        } else {
            sections
        }
    }

    @ViewBuilder private var sections: some View {
        HermAppUpdateControls(appUpdater: appUpdater, compact: compact)
        Divider().overlay(Color.dockBorderLight)
        HermesAgentUpdateControls(agentUpdateService: agentUpdateService, compact: compact)
    }
}

private struct HermAppUpdateControls: View {
    @ObservedObject var appUpdater: HermAppUpdater
    let compact: Bool

    var body: some View {
        let (status, color): (String, Color) =
            switch appUpdater.phase {
            case .idle: ("Updates are checked automatically every hour.", .dockMetadataText)
            case .unavailable(let reason): (reason, .dockMetadataText)
            case .checking: ("Checking \(HermAppUpdater.repository)…", .dockSecondaryText)
            case .upToDate: ("Up to date", .dockSecondaryText)
            case .available(let version):
                ("Herm \(version) is available. " + (appUpdater.installUnavailableReason ?? ""), .dockWarning)
            case .downloading:
                ("\(appUpdater.downloadStage) Herm \(appUpdater.latest?.version ?? "")…", .dockSecondaryText)
            case .readyToInstall(let version):
                (
                    appUpdater.waitingForIdle
                        ? "Herm \(version) will install and restart when the current turn finishes."
                        : "Herm \(version) is ready to install and restart.", .dockWarning
                )
            case .installing: ("Installing and restarting…", .dockWarning)
            case .failed(let reason): (reason, .dockWarning)
            }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Herm").dockFont(.navigation, weight: .semibold)
                if let version = appUpdater.currentVersion {
                    Text(version).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                }
                if compact {
                    Spacer(minLength: 0)
                    appUpdateAction
                } else {
                    DockBuildBadge(build: .current, includesCommit: true)
                }
            }
            .frame(minHeight: compact ? DockControlMetrics.compactHeight : nil)
            .accessibilityElement(children: .contain)

            HStack(spacing: 8) {
                if appUpdater.phase == .downloading {
                    DockStatusDot(tone: .working, size: 7, pulses: true)
                } else if appUpdater.phase == .checking {
                    DockLoadingIndicator().controlSize(.small)
                } else {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(status)
                    .dockFont(.body)
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if appUpdater.phase == .downloading, appUpdater.downloadStage == "Downloading",
                    let fraction = appUpdater.downloadFraction
                {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .dockFont(.machineMetadata)
                        .monospacedDigit()
                        .foregroundStyle(Color.dockSecondaryText)
                        .contentTransition(.numericText())
                }
                if !compact { appUpdateAction }
            }
            Color.clear.frame(height: 4)
                .overlay {
                    if appUpdater.phase == .downloading {
                        if appUpdater.downloadStage == "Downloading", let fraction = appUpdater.downloadFraction {
                            DockProgressBar(fraction: fraction)
                        } else {
                            DockShimmerTrack(tone: .working)
                        }
                    }
                }
            HStack {
                if !compact {
                    Text(
                        "Source  ·  \(HermAppUpdater.repository)"
                            + (appUpdater.lastChecked.map { "  ·  checked " + HumanDateFormatting.timeOnly($0) } ?? "")
                    )
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                }
                Button("Releases on GitHub") {
                    let fallback = "https://github.com/\(HermAppUpdater.repository)/releases"
                    if let url = appUpdater.latest?.pageURL ?? URL(string: fallback) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.dockLink)
            }
        }
        .onAppear { appUpdater.checkIfStale() }
    }

    @ViewBuilder private var appUpdateAction: some View {
        switch appUpdater.phase {
        case .readyToInstall:
            Button("Install and restart") { appUpdater.installWhenIdle() }
                .buttonStyle(.dockPrimary)
                .accessibilityLabel("Install Herm and restart")
                .disabled(appUpdater.waitingForIdle)
        case .available where appUpdater.installUnavailableReason == nil:
            Button("Download") { appUpdater.downloadUpdate() }
                .buttonStyle(.dockPrimary)
                .accessibilityLabel("Download Herm update")
        case .unavailable:
            EmptyView()
        default:
            if appUpdater.canCheck {
                Button("Check for updates") { appUpdater.checkForUpdates() }
                    .buttonStyle(.dockSecondary)
                    .accessibilityLabel("Check for Herm updates")
            }
        }
    }
}

private struct HermesAgentUpdateControls: View {
    @ObservedObject var agentUpdateService: HermesUpdateService
    let compact: Bool
    @State private var isShowingAgentUpdateConfirmation = false
    @State private var isAgentUpdateOutputExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Hermes Agent")
                    .dockFont(.navigation, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                Spacer()
                if compact && agentUpdateService.phase == .updateAvailable {
                    agentUpdateButton
                } else if agentUpdateService.phase == .checking {
                    HStack(spacing: 6) {
                        DockLoadingIndicator().controlSize(.small)
                        Text("Checking…")
                            .dockFont(.body)
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                } else {
                    Button("Check for updates") { agentUpdateService.checkForUpdates() }
                        .buttonStyle(.dockSecondary)
                        .accessibilityLabel("Check for Hermes Agent updates")
                        .disabled(!agentUpdateService.canCheck)
                }
            }
            .frame(minHeight: compact ? DockControlMetrics.compactHeight : nil)
            .task {
                if agentUpdateService.phase == .idle {
                    agentUpdateService.checkForUpdates()
                }
            }

            switch agentUpdateService.phase {
            case .idle: agentUpdateIdleContent
            case .checking: agentUpdateIdleContent
            case .upToDate:
                agentUpdateCheckedContent(
                    statusText: "Up to date", statusColor: .dockSecondaryText, showsUpdateButton: false)
            case .updateAvailable:
                agentUpdateCheckedContent(
                    statusText: "Update available", statusColor: .dockWarning, showsUpdateButton: true)
            case .checkFailed(let reason): agentUpdateCheckFailedContent(reason)
            case .updating: agentUpdateProgressContent
            case .updateSucceeded: agentUpdateSucceededContent
            case .updateFailed(let reason): agentUpdateFailedContent(reason)
            }
        }
        .confirmationDialog("Update Hermes Agent?", isPresented: $isShowingAgentUpdateConfirmation) {
            Button("Update Hermes Agent") {
                guard agentUpdateService.canStartUpdate else { return }
                isAgentUpdateOutputExpanded = false
                agentUpdateService.performUpdate()
            }
            .disabled(!agentUpdateService.canStartUpdate)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                verbatim:
                    "Herm will run the allow-listed command `\(HermesUpdateService.updateCommandDisplay)`. It pulls the latest code from NousResearch/hermes-agent, reinstalls dependencies, and may migrate new configuration options. Running Hermes sessions keep the current version until Hermes restarts."
            )
        }
    }

    private var agentUpdateButton: some View {
        Button("Update") { isShowingAgentUpdateConfirmation = true }
            .buttonStyle(.dockPrimary)
            .accessibilityLabel("Update Hermes Agent")
            .disabled(!agentUpdateService.canStartUpdate)
    }

    private var agentUpdateIdleContent: some View {
        Text("Compares the installed Hermes agent with the latest release from NousResearch/hermes-agent.")
            .dockFont(.body)
            .foregroundStyle(Color.dockMetadataText)
    }

    private func agentUpdateCheckedContent(statusText: String, statusColor: Color, showsUpdateButton: Bool) -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(statusColor)
                if showsUpdateButton && !compact { agentUpdateButton }
            }
            .dockButtonSize(.inline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                if let installed = agentUpdateService.installed {
                    GridRow {
                        Text("Installed")
                        Text(
                            [installed.displayVersion, compact ? nil : agentUpdateService.installMethod].compactMap {
                                $0
                            }
                            .joined(separator: "  ·  "))
                    }
                }
                if let latest = agentUpdateService.latest {
                    GridRow {
                        Text("Latest release")
                        Text(
                            latest.displayVersion
                                + (compact
                                    ? ""
                                    : latest.publishedAt.map { "  ·  " + HumanDateFormatting.dateAndTime($0) } ?? ""))
                    }
                    if let page = latest.pageURL, let url = URL(string: page) {
                        GridRow {
                            Color.clear.frame(width: 0, height: 0)
                            Button("Release notes") { ExternalOpen.open(url) }.buttonStyle(.dockLink)
                        }
                    }
                }
            }
            .dockFont(.body)
            .foregroundStyle(Color.dockSecondaryText)
            if !compact {
                Text(
                    "Source  ·  NousResearch/hermes-agent"
                        + (agentUpdateService.lastChecked.map { "  ·  checked " + HumanDateFormatting.timeOnly($0) }
                            ?? "")
                )
                .dockFont(.metadata)
                .foregroundStyle(Color.dockMetadataText)
            }
        }
    }

    private func agentUpdateCheckFailedContent(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            installedAgentVersion
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Color.dockWarningFill).frame(width: 6, height: 6).dockPadding(.top, 5)
                Text(reason)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var agentUpdateProgressContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DockStatusDot(tone: .working, size: 7, pulses: true)
                Text("Updating Hermes Agent")
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                Spacer()
                TimelineView(.dockMotion(rate: 1)) { context in
                    Text(agentUpdateElapsedText(until: context.date))
                        .dockFont(.machineMetadata).monospacedDigit()
                        .foregroundStyle(Color.dockMetadataText)
                }
            }
            DockShimmerTrack(tone: .working)
            if let latestLine = agentUpdateService.logLines.last {
                Text(latestLine)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            agentUpdateLogTail
        }
    }

    private var agentUpdateSucceededContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DockIcon(.checkCircle, weight: .fill)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSuccess)
                Text("HERMES AGENT UPDATED")
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockSuccess)
                Spacer()
            }
            installedAgentVersion
            Text("Herm will restart automatically so new sessions run the updated agent.")
                .dockFont(.body)
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
            agentUpdateLogTail
        }
    }

    @ViewBuilder private var installedAgentVersion: some View {
        if let installed = agentUpdateService.installed {
            Text("Installed: \(installed.displayVersion)")
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
        }
    }

    private func agentUpdateFailedContent(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                DockIcon(.warning)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockDestructive)
                Text(reason)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(
                "Herm never retries an update automatically. Review the output below and run CHECK before trying again."
            )
            .dockFont(.body)
            .foregroundStyle(Color.dockSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
            if let latestLine = agentUpdateService.logLines.last {
                Text(latestLine)
                    .dockFont(.body, weight: .regular, design: .monospaced)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            agentUpdateLogTail
        }
    }

    private var agentUpdateLogTail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.dockEase(duration: 0.18)) { isAgentUpdateOutputExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    DockIcon(isAgentUpdateOutputExpanded ? .caretDown : .caretRight)
                        .dockFont(.compactStatus, weight: .semibold)
                    Text(isAgentUpdateOutputExpanded ? "Hide output" : "Show output")
                        .dockFont(.body, weight: .medium)
                }
                .foregroundStyle(Color.dockSecondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)

            if isAgentUpdateOutputExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(agentUpdateService.logLines.suffix(120).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .dockFont(.metadata, weight: .regular, design: .monospaced)
                                .foregroundStyle(Color.dockSecondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                    .dockPadding(.vertical, 2)
                }
                .frame(maxHeight: 150)
                .transition(.dockPanelReveal)
            }
        }
    }

    private func agentUpdateElapsedText(until now: Date) -> String {
        guard let started = agentUpdateService.updateStartedAt else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(started)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
