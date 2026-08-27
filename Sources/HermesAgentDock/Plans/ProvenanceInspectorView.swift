import SwiftUI

struct ProvenanceInspectorView: View {
    let presentation: ProvenancePresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Provenance", systemImage: "link")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dockAccent)
            provenanceRow("SOURCE", presentation.sourceLabel)
            provenanceRow("SESSION", presentation.sessionID ?? "unavailable")
            provenanceRow("PROJECT", presentation.projectID ?? "unavailable")
            provenanceRow("REPOSITORY", presentation.repositoryPath ?? "unavailable")
            provenanceRow("BRANCH", presentation.branch ?? "unavailable")
            Text(presentation.verified ? "Observed from runtime" : "Unverified / context only")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(presentation.verified ? Color.dockSuccess : Color.dockWarning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 10)
    }

    private func provenanceRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.dockMetadataText).frame(width: 72, alignment: .leading)
            Text(value).font(.system(size: 11)).foregroundStyle(Color.dockPrimaryText).lineLimit(2)
        }
    }
}

struct CapacityRunwayView: View {
    let presentation: CapacityRunwayPresentation
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text("CAPACITY · \(presentation.state.rawValue.uppercased())")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.dockPrimaryText)
                Text(presentation.usedPercent.map { "\($0)% used" } ?? presentation.detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.dockSecondaryText)
            }
            Spacer()
        }
        .dockCard(padding: 10)
    }

    private var color: Color {
        switch presentation.state {
        case .available: return .dockSuccess
        case .constrained: return .dockWarning
        case .exhausted: return .dockWarning
        case .unknown: return .dockSecondaryText
        }
    }
}
