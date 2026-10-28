import SwiftUI

struct RichCodeView: View {
    let code: RichCode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let filename = code.filename { Text(filename).fontWeight(.semibold).textSelection(.enabled) }
                    if let language = code.language { Text(language).foregroundStyle(Color.dockSecondaryText) }
                }
                Spacer(minLength: 0)
                DockCopyButton(code.code, label: "Copy code", accessibilityLabel: "Copy generated code")
            }
            ScrollView([.horizontal, .vertical]) {
                Text(code.code).dockFont(.code, design: .monospaced).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true).padding(12)
                    .padding([.bottom, .trailing], 8)
            }
            .frame(
                height: min(
                    320,
                    max(64, CGFloat(code.code.split(separator: "\n", omittingEmptySubsequences: false).count) * 17 + 44)
                )
            )
            .background(Color.dockSurface2, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct RichFindingsView: View {
    let findings: RichFindings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(findings.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.severity.rawValue.capitalized).foregroundStyle(color(item.severity))
                        Text(item.title).fontWeight(.semibold)
                    }
                    if let location = item.location {
                        Text(location).dockFont(.code, design: .monospaced)
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                    Text(item.detail)
                    if let recommendation = item.recommendation {
                        Text("Recommendation: " + recommendation).foregroundStyle(Color.dockSecondaryText)
                    }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if item.id != findings.items.last?.id { Divider().overlay(Color.dockBorder) }
            }
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Reported snapshot").foregroundStyle(Color.dockSecondaryText)
            ForEach(Array(workflow.items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 12) {
                    Text(String(index + 1)).monospacedDigit().foregroundStyle(Color.dockMetadataText)
                        .frame(width: 24, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 6) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.title).fontWeight(.semibold)
                                Spacer(minLength: 12)
                                status(item.status)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).fontWeight(.semibold)
                                status(item.status)
                            }
                        }
                        if let detail = item.detail { Text(detail) }
                        if let evidence = item.evidence {
                            Text("Evidence: " + evidence).foregroundStyle(Color.dockSecondaryText)
                        }
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if item.id != workflow.items.last?.id { Divider().overlay(Color.dockBorder) }
            }
        }
    }

    private func status(_ status: RichWorkflow.Item.Status) -> some View {
        Text(status.rawValue.capitalized).foregroundStyle(status.color).fixedSize()
    }
}

extension RichWorkflow.Item.Status {
    var color: Color {
        switch self {
        case .passed: .dockSuccess
        case .failed: .dockDestructive
        case .blocked: .dockWarning
        case .proposed, .running, .skipped: .dockSecondaryText
        }
    }
}
