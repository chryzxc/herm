import SwiftUI

struct SessionRailSummarySections: View {
    let summary: SessionRailSummary
    let onViewAllOutputs: () -> Void
    let onOpenOutput: (ArtifactRecord) -> Void
    let onRespondInChat: () -> Void
    let onViewPin: (PinnedMessage) async -> Bool
    var onViewTimeline: () -> Void = {}
    var onRestoreCheckpoint: (RestoreCheckpoint) -> Void = { _ in }

    var body: some View {
        if !summary.attention.isEmpty {
            SessionRailSummarySection(title: "Needs attention", icon: .warning, count: summary.attention.count) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(summary.attention) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).dockFont(.body, weight: .semibold)
                            Text(item.detail).textSelection(.enabled).foregroundStyle(Color.dockSecondaryText)
                        }
                    }
                    Button("Respond in chat", action: onRespondInChat).buttonStyle(.dockLink)
                }
            }
        }
        if let plan = summary.plan {
            SessionRailSummarySection(
                title: "Tasks", icon: .listChecks, detail: "\(plan.done)/\(plan.items.count)",
                subtitle: plan.inProgress.map { "In progress: \($0.content)" }
            ) {
                TodoPlanTaskList(plan: plan, isWorking: summary.isWorking)
            }
        }
        if !summary.processes.isEmpty {
            let running = summary.runningProcessCount
            SessionRailSummarySection(
                title: "Background processes", icon: .terminal,
                detail: running > 0 ? "\(running) running" : "Finished",
                subtitle: summary.processes.last { $0.state == "running" }?.latestOutput
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(summary.processes) { process in
                        SessionRailProcessRow(process: process)
                    }
                }
            }
        }
        if !summary.subagents.isEmpty {
            let running = summary.runningSubagentCount
            SessionRailSummarySection(
                title: "Subagents", icon: .usersThree, count: summary.subagents.count,
                detail: running > 0 ? "\(running) running" : nil,
                subtitle: summary.subagents.lazy.compactMap(SessionRailSubagentRow.activity).first
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(summary.subagents) { agent in
                        SessionRailSubagentRow(agent: agent)
                    }
                }
            } footer: {
                Button("View in timeline", action: onViewTimeline).buttonStyle(.dockLink)
            }
        }
        if !summary.checkpoints.isEmpty {
            SessionRailSummarySection(
                title: "Checkpoints", icon: .clockCounterClockwise, count: summary.checkpoints.count,
                subtitle: summary.checkpoints.first.flatMap(SessionRailCheckpointRow.relativeTime).map {
                    "Latest \($0)"
                }
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(summary.checkpoints) { checkpoint in
                        SessionRailCheckpointRow(
                            checkpoint: checkpoint,
                            canRestore: !summary.isWorking && !summary.isRestoringCheckpoint,
                            onRestore: { onRestoreCheckpoint(checkpoint) })
                    }
                }
            }
        }
        if !summary.outputs.isEmpty || summary.outputsError != nil {
            SessionRailSummarySection(title: "Outputs", icon: .files, count: summary.outputs.count) {
                VStack(alignment: .leading, spacing: 10) {
                    if summary.outputsError != nil {
                        Text("Outputs unavailable. Refresh to retry.").foregroundStyle(Color.dockWarning)
                    }
                    ForEach(summary.outputs) { record in
                        Button {
                            onOpenOutput(record)
                        } label: {
                            SessionRailOutputRow(record: record)
                        }
                        .buttonStyle(.dockHover)
                        .help("Preview in a new tab")
                    }
                }
            } footer: {
                Button("View all outputs", action: onViewAllOutputs).buttonStyle(.dockLink)
            }
        }
        if !summary.contextFiles.isEmpty {
            let loaded = summary.contextFiles.count(where: \.loaded)
            SessionRailSummarySection(
                title: "Context files", icon: .fileText, detail: "\(loaded)/\(summary.contextFiles.count)",
                subtitle: summary.contextFiles.contains(where: \.needsAttention) ? "Some files need review" : nil
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(summary.contextFiles) { file in
                        SessionRailContextFileRow(file: file)
                    }
                    Text("Instruction files Hermes considered for this session’s system prompt.")
                        .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                }
            }
        }
        if !summary.pins.isEmpty {
            SessionRailSummarySection(title: "Pinned items", icon: .pushPin, count: summary.pins.count) {
                VStack(alignment: .leading, spacing: 10) {
                    if summary.pinsError != nil {
                        Text("Pinned items may be out of date. Refresh to retry.").foregroundStyle(Color.dockWarning)
                    }
                    ForEach(summary.pins) { pin in
                        SessionRailPinnedItem(pin: pin, onView: onViewPin)
                    }
                }
            }
        }
        if let workspace = summary.workspace {
            SessionRailSummarySection(title: "Workspace", icon: .folder, iconColor: DockAccentColor.amber.color) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(URL(fileURLWithPath: workspace.path).lastPathComponent)
                            .dockFont(.body, weight: .semibold)
                        Text((workspace.path as NSString).abbreviatingWithTildeInPath)
                            .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                    }
                    .textSelection(.enabled)
                    if let branch = workspace.branch {
                        HStack(alignment: .top, spacing: 8) {
                            DockIcon(.gitBranch, size: 14, color: DockAccentColor.violet.color)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Branch").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                                Text(branch).dockFont(.body, design: .monospaced).textSelection(.enabled)
                            }
                        }
                    }
                    if let commit = workspace.latestCommit {
                        HStack(alignment: .top, spacing: 8) {
                            DockIcon(.gitCommit, size: 14, color: .dockMetadataText).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Latest commit").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                                DockCommitSummary(value: commit).foregroundStyle(Color.dockSecondaryText)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// All summary disclosures use the rail's existing bounded inline presentation.
struct SessionRailSummarySection<Content: View, Footer: View>: View {
    let title: String
    let icon: Ph
    var count: Int? = nil
    var detail: String? = nil
    var fileName: String? = nil
    var iconColor: Color = .dockSecondaryText
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content
    @ViewBuilder var footer: () -> Footer
    @State private var expanded = false

    init(
        title: String, icon: Ph, count: Int? = nil, detail: String? = nil, fileName: String? = nil,
        iconColor: Color = .dockSecondaryText, subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.title = title
        self.icon = icon
        self.count = count
        self.detail = detail
        self.fileName = fileName
        self.iconColor = iconColor
        self.subtitle = subtitle
        self.content = content
        self.footer = footer
    }

    init(
        title: String, icon: Ph, count: Int? = nil, detail: String? = nil, fileName: String? = nil,
        iconColor: Color = .dockSecondaryText, subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) where Footer == EmptyView {
        self.init(
            title: title, icon: icon, count: count, detail: detail, fileName: fileName, iconColor: iconColor,
            subtitle: subtitle,
            content: content, footer: { EmptyView() })
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                SessionRailExpandedContent { content() }
                footer()
            }.dockPadding(.top, 8)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if let fileName, let image = ArtifactFileIcon.image(for: fileName) {
                        Image(nsImage: image).renderingMode(.original)
                            .resizable().interpolation(.high).scaledToFit()
                    } else {
                        DockIcon(
                            icon, size: 14, weight: expanded ? .fill : .regular,
                            color: expanded ? .dockPrimaryText : iconColor)
                    }
                }
                .frame(width: 14, height: 14).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).lineLimit(2).truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle).dockFont(.metadata).foregroundStyle(Color.dockAccent)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if let detail {
                    Text(detail).foregroundStyle(Color.dockMetadataText).monospacedDigit().fixedSize()
                } else if let count {
                    Text(count.formatted()).foregroundStyle(Color.dockMetadataText).monospacedDigit().fixedSize()
                }
            }
        }
        .disclosureGroupStyle(DockDisclosureGroupStyle(alignment: .top))
        .dockFont(.body)
    }
}

private struct SessionRailContextFileRow: View {
    let file: SessionContextFile

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            DockIcon(
                file.needsAttention ? .warningCircle : file.loaded ? .checkCircle : .minusCircle, size: 14,
                color: file.needsAttention ? .dockWarning : file.loaded ? .dockSuccess : .dockMetadataText
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.label).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(file.loaded ? Color.dockPrimaryText : Color.dockSecondaryText)
                if let note = file.note {
                    Text(note).dockFont(.metadata)
                        .foregroundStyle(file.needsAttention ? Color.dockWarning : Color.dockMetadataText)
                }
            }
            Spacer(minLength: 0)
            if file.loaded {
                Text(SessionTokenFormatting.formatCompact(file.estimatedTokens))
                    .foregroundStyle(Color.dockMetadataText).monospacedDigit().fixedSize()
            }
        }
        .help((file.path as NSString).abbreviatingWithTildeInPath)
        .accessibilityElement(children: .combine)
    }
}

private struct SessionRailProcessRow: View {
    let process: ProcessSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if process.state == "running" {
                    DockStatusDot(tone: .working, size: 7, pulses: true)
                } else {
                    // An exit is not a success claim; stopped and exited stay neutral.
                    DockIcon(
                        process.state == "killed" ? .minusCircle : .checkCircle, size: 14, color: .dockMetadataText)
                }
            }
            .frame(width: 14, height: 14).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(process.name).lineLimit(1).truncationMode(.middle).dockFont(.body, design: .monospaced)
                if process.state == "running", let latest = process.latestOutput {
                    Text(latest).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            Text(process.state.capitalized).foregroundStyle(Color.dockMetadataText).fixedSize()
        }
        .help(process.detail ?? process.name)
        .accessibilityElement(children: .combine)
    }
}

private struct SessionRailSubagentRow: View {
    let agent: HermesSubagent

    private var isActive: Bool { AgentActivityPresentation.isActiveStatus(agent.status) }
    private var failed: Bool {
        let status = agent.status.lowercased()
        return status.contains("fail") || status.contains("error")
    }
    private var finished: Bool { ["complete", "completed", "done"].contains(agent.status.lowercased()) }

    /// Live progress only; raw tool payloads and compaction handoffs are not progress.
    static func activity(_ agent: HermesSubagent) -> String? {
        guard AgentActivityPresentation.isActiveStatus(agent.status),
            let text = agent.latestActivity?.trimmingCharacters(in: .whitespacesAndNewlines),
            let first = text.first, first != "{", first != "["
        else { return nil }
        return SessionTraceProjection.taskTitle(text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if isActive {
                    DockStatusDot(tone: .working, size: 7, pulses: true)
                } else {
                    DockIcon(
                        failed ? .warningCircle : finished ? .checkCircle : .minusCircle, size: 14,
                        color: failed ? .dockWarning : finished ? .dockSuccess : .dockMetadataText)
                }
            }
            .frame(width: 14, height: 14).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name ?? agent.role ?? SessionTraceProjection.taskTitle(agent.goal))
                    .lineLimit(1).truncationMode(.tail)
                if let activity = Self.activity(agent) {
                    Text(activity).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Group {
                if finished, let duration = agent.durationSeconds, duration.isFinite, duration >= 0 {
                    Text(TurnActivityView.stepDuration(duration))
                } else if !finished {
                    Text(agent.status.replacingOccurrences(of: "_", with: " ").capitalized)
                }
            }
            .foregroundStyle(failed ? Color.dockWarning : Color.dockMetadataText).monospacedDigit().fixedSize()
        }
        .padding(.leading, CGFloat(min(agent.depth, 3)) * 12)
        .help(agent.goal)
        .accessibilityElement(children: .combine)
    }
}

private struct SessionRailCheckpointRow: View {
    let checkpoint: RestoreCheckpoint
    let canRestore: Bool
    let onRestore: () -> Void

    private static let iso8601 = ISO8601DateFormatter()

    /// Hermes stamps checkpoints with git's strict ISO-8601 author date.
    static func relativeTime(_ checkpoint: RestoreCheckpoint) -> String? {
        iso8601.date(from: checkpoint.timestamp)?.formatted(.relative(presentation: .named))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            DockIcon(.gitCommit, size: 14, color: .dockMetadataText).frame(width: 14, height: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(checkpoint.message.isEmpty ? String(checkpoint.hash.prefix(7)) : checkpoint.message)
                    .lineLimit(1).truncationMode(.tail).help(checkpoint.hash)
                if let time = Self.relativeTime(checkpoint) {
                    Text(time).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                }
            }
            Spacer(minLength: 0)
            Button("Restore…", action: onRestore).buttonStyle(.dockLink).dockFont(.metadata).disabled(!canRestore)
                .help(
                    canRestore
                        ? "Restore files and rewind the chat to this checkpoint"
                        : "Wait for the turn to finish")
        }
    }
}

private struct SessionRailOutputRow: View {
    let record: ArtifactRecord

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if record.kind == .file || record.kind == .image, let image = ArtifactFileIcon.image(for: record.label)
                {
                    Image(nsImage: image).renderingMode(.original).resizable().interpolation(.high).scaledToFit()
                } else {
                    DockIcon(record.kind == .interactive ? .squaresFour : .link, size: 14, color: .dockSecondaryText)
                }
            }
            .frame(width: 14, height: 14).accessibilityHidden(true)
            Text(record.label).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 0)
            DockIcon(.arrowSquareIn, size: 12, color: .dockMetadataText).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The session inspector tab for one rail output; the rail itself only lists them.
struct SessionOutputPreview: View {
    let record: ArtifactRecord
    @ObservedObject var model: DockModel
    @State private var preview: ArtifactTextPreview.Content?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.label).dockFont(.body, weight: .semibold).textSelection(.enabled)
                Text(record.location).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            if record.generated == nil, record.unavailableBookmark == nil {
                HStack(spacing: 8) {
                    Button {
                        ArtifactOpener.open(record.value)
                    } label: {
                        DockIconLabel(record.kind == .link ? "Open link" : "Open", icon: .arrowSquareOut)
                    }
                    .buttonStyle(.dockSecondary)
                    DockCopyButton(
                        record.value, label: "Copy \(record.kind == .link ? "link" : "path")",
                        accessibilityLabel: "Copy \(record.kind == .link ? "link" : "path")",
                        presentation: .iconAndText, iconSize: 12, color: .dockPrimaryText
                    )
                    .buttonStyle(.dockSecondary)
                }
                .dockButtonSize(.compact)
            }
            content
        }
        .task(id: record.id) {
            guard record.kind == .file else { return }
            guard let url = ArtifactOpener.url(record.value), url.isFileURL else {
                preview = .binary
                return
            }
            let result = await Task.detached { ArtifactTextPreview.Content.load(url) }.value
            guard !Task.isCancelled else { return }
            preview = result
        }
    }

    @ViewBuilder private var content: some View {
        if let generated = record.generated {
            RichArtifactPreview(model: model, generated: generated)
        } else if record.unavailableBookmark != nil {
            Text("Source unavailable. Refresh to retry.").foregroundStyle(Color.dockWarning)
        } else if record.kind == .image, let url = ArtifactOpener.url(record.value) {
            ArtifactImagePreview(url: url, maximumPixelSize: 1600) {
                Text("Image preview unavailable").foregroundStyle(Color.dockMetadataText)
            }.scaledToFit().frame(maxWidth: .infinity)
        } else if let preview {
            switch preview {
            case .text(let text, let truncated):
                if ["md", "markdown"].contains(URL(fileURLWithPath: record.label).pathExtension.lowercased()) {
                    MarkdownMessageView(markdown: text, cacheKey: "artifact:\(record.id)")
                } else {
                    Text(text).dockFont(.metadata, design: .monospaced).textSelection(.enabled)
                }
                if truncated {
                    Text("Preview truncated — open the file to see the rest.").foregroundStyle(Color.dockMetadataText)
                }
            case .missing:
                Text("File no longer available").foregroundStyle(Color.dockWarning)
            case .binary:
                Text("No text preview available").foregroundStyle(Color.dockMetadataText)
            }
        } else if record.kind == .file {
            Text("Loading preview…").foregroundStyle(Color.dockMetadataText)
        } else {
            Text(record.value).textSelection(.enabled)
        }
    }
}
