import AppKit
import ServiceManagement
import SwiftUI
import Foundation
import UniformTypeIdentifiers

extension WorkspaceActivitySidebar {
    var appUpdateSection: some View {
        let (status, color): (String, Color) = switch appUpdater.phase {
        case .idle: ("Updates are checked automatically every few hours.", .dockMetadataText)
        case .unavailable(let reason): (reason, .dockMetadataText)
        case .checking: ("Checking \(HermAppUpdater.repository)…", .dockSecondaryText)
        case .upToDate: ("Up to date", .dockSecondaryText)
        case .downloading: ("Downloading Herm \(appUpdater.latest?.version ?? "")…", .dockSecondaryText)
        case .readyToInstall(let version): ("Herm \(version) is ready. It installs and restarts once the current turn finishes.", .dockWarning)
        case .installing: ("Installing and restarting…", .dockWarning)
        case .failed(let reason): (reason, .dockWarning)
        }
        let isUnavailable = if case .unavailable = appUpdater.phase { true } else { false }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if case .readyToInstall = appUpdater.phase {
                    Button("Restart now") { appUpdater.installNow() }
                        .buttonStyle(.dockPrimary)
                        .controlSize(.small)
                } else if appUpdater.canCheck && !isUnavailable {
                    Button("Check for updates") { appUpdater.checkForUpdates() }
                        .buttonStyle(.dockCompact)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockAccent)
                }
            }
            Text("Source  ·  \(HermAppUpdater.repository)" + (appUpdater.lastChecked.map { "  ·  checked " + HumanDateFormatting.timeOnly($0) } ?? ""))
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
        }
    }

    var agentUpdateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Hermes Agent")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.dockPrimaryText)
                Spacer()
                if agentUpdateService.phase == .checking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                } else {
                    Button("Check for updates") { agentUpdateService.checkForUpdates() }
                        .buttonStyle(.dockCompact)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockAccent)
                        .disabled(!agentUpdateService.canCheck)
                }
            }
            .task {
                if agentUpdateService.phase == .idle {
                    agentUpdateService.checkForUpdates()
                }
            }

            switch agentUpdateService.phase {
            case .idle: agentUpdateIdleContent
            case .checking: agentUpdateIdleContent
            case .upToDate: agentUpdateCheckedContent(statusText: "UP TO DATE", statusColor: .dockSecondaryText, showsUpdateButton: false)
            case .updateAvailable: agentUpdateCheckedContent(statusText: "UPDATE AVAILABLE", statusColor: .dockWarning, showsUpdateButton: true)
            case .checkFailed(let reason): agentUpdateCheckFailedContent(reason)
            case .updating: agentUpdateProgressContent
            case .updateSucceeded: agentUpdateSucceededContent
            case .updateFailed(let reason): agentUpdateFailedContent(reason)
            }
        }
        .confirmationDialog("Update Hermes Agent?", isPresented: $isShowingAgentUpdateConfirmation) {
            Button("Update Hermes Agent") {
                isAgentUpdateOutputExpanded = false
                agentUpdateService.performUpdate()
            }
                .disabled(agentUpdateService.isBusy)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "Herm will run the allow-listed command `\(HermesUpdateService.updateCommandDisplay)`. It pulls the latest code from NousResearch/hermes-agent, reinstalls dependencies, and may migrate new configuration options. Running Hermes sessions keep the current version until Hermes restarts.")
        }
    }

    var agentUpdateIdleContent: some View {
        Text("Compares the installed Hermes agent with the latest release from NousResearch/hermes-agent.")
            .font(.system(size: 12))
            .foregroundStyle(Color.dockMetadataText)
    }

    func agentUpdateCheckedContent(statusText: String, statusColor: Color, showsUpdateButton: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let installed = agentUpdateService.installed {
                HStack(spacing: 8) {
                    Text("Installed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(width: 76, alignment: .leading)
                    Text(installed.displayVersion)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                    if let method = agentUpdateService.installMethod {
                        Text("·  \(method)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                }
                .lineLimit(1)
            }
            if let latest = agentUpdateService.latest {
                HStack(spacing: 8) {
                    Text("Latest release")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockSecondaryText)
                        .frame(width: 76, alignment: .leading)
                    Text(latest.displayVersion + (latest.publishedAt.map { "  ·  " + HumanDateFormatting.dateAndTime($0) } ?? ""))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let page = latest.pageURL, let url = URL(string: page) {
                        Button("Release notes") { ExternalOpen.open(url) }
                            .buttonStyle(.dockLink)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.dockAccent)
                    }
                }
            }
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText.lowercased().capitalized)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor)
                if showsUpdateButton,
                   let installed = agentUpdateService.installed,
                   let latest = agentUpdateService.latest {
                    Text("\(installed.displayVersion) → \(latest.displayVersion)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                if showsUpdateButton {
                    Button("Update Hermes") { isShowingAgentUpdateConfirmation = true }
                        .buttonStyle(.dockPrimary)
                        .controlSize(.small)
                        .disabled(!agentUpdateService.canStartUpdate)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(statusColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))
            Text("Source  ·  NousResearch/hermes-agent" + (agentUpdateService.lastChecked.map { "  ·  checked " + HumanDateFormatting.timeOnly($0) } ?? ""))
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
        }
    }

    func agentUpdateCheckFailedContent(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let installed = agentUpdateService.installed {
                diagnosticRow(label: "INSTALLED", value: installed.displayVersion, color: Color.dockMetadataText)
            }
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Color.dockWarning).frame(width: 6, height: 6).padding(.top, 5)
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var agentUpdateProgressContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DockStatusDot(tone: .working, size: 7, pulses: true)
                Text("Updating Hermes Agent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Spacer()
                TimelineView(.periodic(from: agentUpdateService.updateStartedAt ?? Date(), by: 1)) { context in
                    Text(agentUpdateElapsedText(until: context.date))
                        .font(DockTypography.machineMetadata.monospacedDigit())
                        .foregroundStyle(Color.dockMetadataText)
                }
            }
            DockShimmerTrack(tone: .working)
            if let latestLine = agentUpdateService.logLines.last {
                Text(latestLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            agentUpdateLogTail
        }
    }

    var agentUpdateSucceededContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DockIcon(.checkCircle, weight: .fill)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSuccess)
                Text("HERMES AGENT UPDATED")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockSuccess)
                Spacer()
            }
            if let installed = agentUpdateService.installed {
                diagnosticRow(label: "INSTALLED", value: installed.displayVersion, color: Color.dockSuccess)
            }
            Text("Herm will restart automatically so new sessions run the updated agent.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
            agentUpdateLogTail
        }
    }

    func agentUpdateFailedContent(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                DockIcon(.warning)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockDestructive)
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Herm never retries an update automatically. Review the output below and run CHECK before trying again.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dockSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let latestLine = agentUpdateService.logLines.last {
                Text(latestLine)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            agentUpdateLogTail
        }
    }

    var agentUpdateLogTail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.dockEase(duration: 0.18)) { isAgentUpdateOutputExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    DockIcon(isAgentUpdateOutputExpanded ? .caretDown : .caretRight)
                        .font(.system(size: 10, weight: .semibold))
                    Text(isAgentUpdateOutputExpanded ? "Hide output" : "Show output")
                        .font(.system(size: 12, weight: .medium))
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
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.dockSecondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 150)
            }
        }
    }

    func agentUpdateElapsedText(until now: Date) -> String {
        guard let started = agentUpdateService.updateStartedAt else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(started)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
