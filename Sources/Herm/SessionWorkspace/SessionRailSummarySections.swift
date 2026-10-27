import SwiftUI

struct SessionRailSummarySections: View {
    let summary: SessionRailSummary
    let onViewAllOutputs: () -> Void
    let onRespondInChat: () -> Void
    let onViewPin: (PinnedMessage) async -> Bool

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
        if !summary.outputs.isEmpty || summary.outputsError != nil {
            SessionRailSummarySection(title: "Outputs", icon: .files, count: summary.outputs.count) {
                VStack(alignment: .leading, spacing: 10) {
                    if summary.outputsError != nil {
                        Text("Outputs unavailable. Refresh to retry.").foregroundStyle(Color.dockWarning)
                    }
                    ForEach(summary.outputs) { record in
                        SessionRailSummarySection(
                            title: record.label, icon: record.kind == .interactive ? .squaresFour : .link,
                            fileName: record.kind == .file || record.kind == .image ? record.label : nil
                        ) {
                            SessionRailOutputPreview(record: record)
                        }
                    }
                }
            } footer: {
                Button("View all outputs", action: onViewAllOutputs).buttonStyle(.dockLink)
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
                                Text(commit).foregroundStyle(Color.dockSecondaryText).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// All summary disclosures use the rail's existing bounded inline presentation.
private struct SessionRailSummarySection<Content: View, Footer: View>: View {
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
            }.padding(.top, 8)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if let fileName, let image = ArtifactFileIcon.image(for: fileName) {
                        Image(nsImage: image).renderingMode(.original)
                            .resizable().interpolation(.high).scaledToFit()
                    } else {
                        DockIcon(icon, size: 14, color: iconColor)
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

private struct SessionRailPinnedItem: View {
    let pin: PinnedMessage
    let onView: (PinnedMessage) async -> Bool
    @State private var opening = false
    @State private var failed = false

    var body: some View {
        SessionRailSummarySection(
            title: pin.preview.isEmpty ? "Message with an attachment" : pin.preview, icon: .chatCircle
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text(pin.role == "user" ? "You" : "Herm").foregroundStyle(Color.dockMetadataText)
                Text(pin.preview).textSelection(.enabled)
                Button(opening ? "Opening…" : "Show in chat") {
                    opening = true
                    failed = false
                    Task {
                        failed = !(await onView(pin))
                        opening = false
                    }
                }.buttonStyle(.dockLink).disabled(opening)
                if failed { Text("Message unavailable. Refresh and retry.").foregroundStyle(Color.dockWarning) }
            }
        }
    }
}

private struct SessionRailOutputPreview: View {
    let record: ArtifactRecord
    @State private var preview: ArtifactTextPreview.Content?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.location).foregroundStyle(Color.dockMetadataText).textSelection(.enabled)
            if record.kind == .image, let url = ArtifactOpener.url(record.value) {
                ArtifactImagePreview(url: url, maximumPixelSize: 640) {
                    Text("Image preview unavailable").foregroundStyle(Color.dockMetadataText)
                }.frame(height: 160).clipped()
            } else if let preview {
                switch preview {
                case .text(let text, let truncated):
                    Text(text).dockFont(.metadata, design: .monospaced).textSelection(.enabled)
                    if truncated { Text("Partial preview").foregroundStyle(Color.dockMetadataText) }
                case .missing:
                    Text("File no longer available").foregroundStyle(Color.dockWarning)
                case .binary:
                    Text("No text preview available").foregroundStyle(Color.dockMetadataText)
                }
            } else if record.kind == .file {
                Text("Loading preview…").foregroundStyle(Color.dockMetadataText)
            } else if record.kind == .interactive {
                Text("Interactive output · View all outputs to use it").foregroundStyle(Color.dockMetadataText)
            } else {
                Text(record.value).textSelection(.enabled)
            }
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
}
