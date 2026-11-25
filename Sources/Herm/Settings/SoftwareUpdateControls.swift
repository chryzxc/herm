import AppKit
import SwiftUI

/// The same updates and confirmation flow serve the Settings page and rail popover.
struct SoftwareUpdateControls: View {
    let appUpdater: HermAppUpdater
    let agentUpdateService: HermesUpdateService
    var compact = false

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: DockSpacing.group) { sections }
                .dockPadding(DockSpacing.group)
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
            case .idle:
                (
                    compact ? "Checks automatically every hour." : "Updates are checked automatically every hour.",
                    .dockMetadataText
                )
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
        return VStack(alignment: .leading, spacing: compact ? DockSpacing.tight : DockSpacing.control) {
            HStack(spacing: DockSpacing.control) {
                Text("Herm").dockFont(.navigation, weight: .semibold)
                if let version = appUpdater.currentVersion {
                    Text(version).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                }
                DockBuildBadge(build: appUpdater.build, includesCommit: !compact)
                if compact {
                    Spacer(minLength: 0)
                    if showsReleasesInHeader { releasesLink } else { appUpdateAction }
                }
            }
            .frame(minHeight: compact ? DockControlMetrics.compactHeight : nil)
            .accessibilityElement(children: .contain)

            HStack(spacing: 8) {
                if appUpdater.phase == .downloading {
                    DockStatusDot(tone: .working, size: 7, pulses: true)
                } else if appUpdater.phase == .checking {
                    DockLoadingIndicator().controlSize(.small)
                } else if !compact {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(compact && appUpdater.phase == .checking ? "Checking for updates…" : status)
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
                if !compact {
                    appUpdateAction
                } else if !showsReleasesInHeader {
                    releasesLink.fixedSize()
                }
            }
            if !showsReleasesInHeader {
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
            }
            if !compact {
                HStack {
                    Text(
                        "Source  ·  \(HermAppUpdater.repository)"
                            + (appUpdater.lastChecked.map { "  ·  checked " + HumanDateFormatting.timeOnly($0) } ?? "")
                    )
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    releasesLink
                }
            }
            HermAlternateReleaseRow(appUpdater: appUpdater, compact: compact)
                .dockPadding(.top, DockSpacing.micro)
        }
        .onAppear { appUpdater.checkIfStale() }
    }

    private var showsReleasesInHeader: Bool {
        if compact, case .unavailable = appUpdater.phase { return true }
        return false
    }

    private var releasesLink: some View {
        Button {
            let fallback = "https://github.com/\(HermAppUpdater.repository)/releases"
            if let url = appUpdater.latest?.pageURL ?? URL(string: fallback) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            releaseLinkLabel(compact ? "Releases" : "Releases on GitHub", externalMark: compact)
        }
        .buttonStyle(.dockLink)
        .accessibilityLabel("Herm releases on GitHub")
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

private struct HermAlternateReleaseRow: View {
    @ObservedObject var appUpdater: HermAppUpdater
    let compact: Bool

    var body: some View {
        let state = appUpdater.alternateReleaseState
        VStack(alignment: .leading, spacing: DockSpacing.tight) {
            HStack(spacing: DockSpacing.control) {
                VStack(alignment: .leading, spacing: DockSpacing.micro) {
                    Text(appUpdater.alternateChannel.title)
                        .dockFont(.body, weight: .semibold)
                    if let release = state.release {
                        Text(release.downloadVersionLabel)
                            .dockFont(.body)
                            .foregroundStyle(Color.dockSecondaryText)
                        if let date = release.updatedAt {
                            let fullTimestamp = "Updated \(HumanDateFormatting.dateAndTime(date))"
                            let shortTimestamp = date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                            Text(compact ? "Updated \(shortTimestamp)" : fullTimestamp)
                                .dockFont(compact ? .compactStatus : .metadata, weight: .regular)
                                .foregroundStyle(Color.dockSecondaryText)
                                .accessibilityLabel(fullTimestamp)
                                .help(fullTimestamp)
                        }
                    } else if state == .checking || state == .idle {
                        Text("Checking for the latest build…")
                            .dockFont(.body)
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                action(for: state)
                    .fixedSize()
            }
            .buttonStyle(DockSecondaryButtonStyle(onWell: true))
            switch state {
            case .downloading(_, let fraction, let stage):
                HStack {
                    Text("\(stage)…")
                    Spacer()
                    if stage == "Downloading", let fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                    }
                }
                .dockFont(.body)
                .foregroundStyle(Color.dockSecondaryText)
                if stage == "Downloading", let fraction {
                    DockProgressBar(fraction: fraction)
                } else {
                    DockShimmerTrack(tone: .working)
                }
            case .downloaded:
                Text("Saved to Downloads")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
            case .failed(let reason), .downloadFailed(_, let reason):
                Text(reason)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
            default: EmptyView()
            }
        }
        .dockPadding(DockSpacing.control)
        .dockWell(.sunken)
        .task { appUpdater.checkAlternateIfStale() }
    }

    @ViewBuilder private func action(for state: HermAlternateReleaseState) -> some View {
        switch state {
        case .idle, .checking:
            DockLoadingIndicator(size: 12)
        case .available(let release), .downloading(let release, _, _):
            Button("Download") { appUpdater.downloadAlternateRelease() }
                .accessibilityLabel("Download \(appUpdater.alternateChannel.title)")
                .disabled(state != .available(release))
        case .downloaded(_, let url):
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .failed, .downloadFailed:
            Button("Check again") { appUpdater.checkAlternateRelease() }
        }
    }
}

@MainActor private func releaseLinkLabel(_ title: String, externalMark: Bool) -> some View {
    HStack(spacing: DockSpacing.micro) {
        Text(title)
        if externalMark { DockIcon(.arrowUpRight, size: 11) }
    }
}

private struct HermesAgentUpdateControls: View {
    @ObservedObject var agentUpdateService: HermesUpdateService
    let compact: Bool
    @State private var isShowingAgentUpdateConfirmation = false
    @State private var isAgentUpdateOutputExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? DockSpacing.tight : DockSpacing.group) {
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
        VStack(alignment: .leading, spacing: compact ? DockSpacing.control : 8) {
            HStack(spacing: DockSpacing.tight) {
                if !compact || showsUpdateButton {
                    Circle().fill(statusColor).frame(width: 6, height: 6).accessibilityHidden(true)
                }
                Text(statusText)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(statusColor)
                if compact {
                    Spacer(minLength: 0)
                    agentReleaseNotes.fixedSize()
                } else if showsUpdateButton {
                    agentUpdateButton
                }
            }
            .dockButtonSize(.inline)
            if compact {
                compactAgentVersions
            } else {
                fullAgentVersions
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

    private var compactAgentVersions: some View {
        HStack(alignment: .top, spacing: DockSpacing.group) {
            if let installed = agentUpdateService.installed {
                let version = installed.marketing.map { "v\($0)" }
                versionColumn(
                    "Installed", version: version ?? installed.displayVersion,
                    detail: version == nil ? nil : installed.calendar.map { "Build \($0)" })
            }
            if let latest = agentUpdateService.latest {
                let version = latest.marketing.map { "v\($0)" }
                let tag = latest.tag == version || latest.tag == latest.marketing ? nil : latest.tag
                versionColumn(
                    "Latest release", version: version ?? latest.displayVersion, detail: version == nil ? nil : tag)
            }
        }
    }

    private func versionColumn(_ label: String, version: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: DockSpacing.micro) {
            Text(label).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
            Text(version).dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
            if let detail {
                Text(detail).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var agentReleaseNotes: some View {
        if let page = agentUpdateService.latest?.pageURL, let url = URL(string: page) {
            Button {
                ExternalOpen.open(url)
            } label: {
                releaseLinkLabel("Release notes", externalMark: compact)
            }
            .buttonStyle(.dockLink)
            .accessibilityLabel("Hermes Agent release notes")
        }
    }

    private var fullAgentVersions: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            if let installed = agentUpdateService.installed {
                GridRow {
                    Text("Installed")
                    Text(
                        [installed.displayVersion, agentUpdateService.installMethod].compactMap {
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
                            + (latest.publishedAt.map { "  ·  " + HumanDateFormatting.dateAndTime($0) } ?? ""))
                }
                if latest.pageURL != nil {
                    GridRow {
                        Color.clear.frame(width: 0, height: 0)
                        agentReleaseNotes
                    }
                }
            }
        }
        .dockFont(.body)
        .foregroundStyle(Color.dockSecondaryText)
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
