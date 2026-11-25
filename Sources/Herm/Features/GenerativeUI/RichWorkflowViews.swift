import SwiftUI

struct RichCodeView: View {
    let code: RichCode
    @Environment(\.richGlance) private var glance
    @Environment(\.richVoiceContext) private var voiceContext

    private var inVoicePreview: Bool { glance && voiceContext != nil }
    private var lineCount: Int { code.code.split(separator: "\n", omittingEmptySubsequences: false).count }

    private var codeText: some View {
        Text(code.code).dockFont(.code, design: .monospaced).textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: true).dockPadding(12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if code.filename != nil || code.language != nil || !glance {
                HStack(spacing: 8) {
                    if let filename = code.filename {
                        Text(filename).dockFont(.metadata, weight: .semibold, design: .monospaced)
                            .foregroundStyle(Color.dockSecondaryText).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if let language = code.language {
                        Text(language).dockPill(tint: .dockSecondaryText, compact: true)
                    }
                    Spacer(minLength: 0)
                    if !glance {
                        DockCopyButton(
                            code.code, label: "Copy code", accessibilityLabel: "Copy generated code",
                            presentation: .icon)
                    }
                }
                .dockPadding(.horizontal, 12).dockPadding(.vertical, 6)
                Divider().overlay(Color.dockBorderLight)
            }
            if inVoicePreview {
                // Let the voice card scroll the whole file vertically instead of nesting a second viewport.
                horizontalCode
            } else {
                ScrollView(.vertical) { horizontalCode }
                    .scrollIndicators(.never)
                    .frame(height: min(glance ? 220 : 320, max(44, CGFloat(lineCount) * 17 + 24)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockWell(.sunken, role: .pane)
    }

    private var horizontalCode: some View {
        ViewThatFits(in: .horizontal) {
            codeText.frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal) { codeText }
                .scrollIndicators(inVoicePreview ? .visible : .never)
        }
    }
}

struct RichFindingsView: View {
    let findings: RichFindings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(findings.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    DockIcon(icon(item.severity), size: 13, weight: .fill, color: color(item.severity))
                        .accessibilityLabel(item.severity.rawValue.capitalized)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).fontWeight(.semibold)
                        if let location = item.location {
                            Text(location).dockFont(.metadata, design: .monospaced)
                                .foregroundStyle(Color.dockMetadataText)
                        }
                        Text(item.detail).foregroundStyle(Color.dockSecondaryText)
                        if let recommendation = item.recommendation {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                DockIcon(.arrowBendDownRight, size: 11, color: .dockMetadataText)
                                Text(recommendation)
                            }
                            .dockPadding(.top, 2)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Recommendation: " + recommendation)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dockPadding(.vertical, 10)
                if item.id != findings.items.last?.id { Divider().overlay(Color.dockBorderLight) }
            }
        }
    }

    private func icon(_ severity: RichFindings.Item.Severity) -> Ph {
        switch severity {
        case .info: .info
        case .warning: .warning
        case .critical: .warningOctagon
        }
    }

    private func color(_ severity: RichFindings.Item.Severity) -> Color {
        switch severity {
        case .info: .dockInfo
        case .warning: .dockWarning
        case .critical: .dockDestructive
        }
    }
}

struct RichWorkflowView: View {
    let workflow: RichWorkflow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(workflow.items.enumerated()), id: \.element.id) { index, item in
                let last = index == workflow.items.count - 1
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 4) {
                        DockIcon(
                            item.status.icon, size: 14, weight: item.status.outlined ? .regular : .fill,
                            color: item.status.color
                        )
                        .frame(height: 16)
                        if !last {
                            Rectangle().fill(Color.dockBorder).frame(width: 1.5).frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 16)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.title).fontWeight(.semibold)
                            Spacer(minLength: 8)
                            Text(item.status.rawValue.capitalized)
                                .dockPill(tint: item.status.color, compact: true).fixedSize()
                        }
                        if let detail = item.detail { Text(detail).foregroundStyle(Color.dockSecondaryText) }
                        if let evidence = item.evidence {
                            Text(evidence).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .dockPadding(.bottom, last ? 0 : 14)
                    .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
            Text("Reported snapshot").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                .dockPadding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension RichWorkflow.Item.Status {
    var color: Color {
        switch self {
        case .passed: .dockSuccess
        case .failed: .dockDestructive
        case .blocked: .dockWarning
        case .running: .dockInfo
        case .proposed, .skipped: .dockSecondaryText
        }
    }

    /// Open statuses read as outlines; settled ones as solid marks.
    var outlined: Bool { self == .proposed || self == .skipped || self == .running }

    var icon: Ph {
        switch self {
        case .passed: .checkCircle
        case .failed: .xCircle
        case .blocked: .warningCircle
        case .running: .circleNotch
        case .proposed: .circleDashed
        case .skipped: .minusCircle
        }
    }
}
