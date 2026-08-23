import SwiftUI

struct ProvenanceInspectorView: View {
    let presentation: ProvenancePresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("PROVENANCE", systemImage: "link")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.scifiAccent)
            provenanceRow("SOURCE", presentation.sourceLabel)
            provenanceRow("SESSION", presentation.sessionID ?? "unavailable")
            provenanceRow("PROJECT", presentation.projectID ?? "unavailable")
            provenanceRow("REPOSITORY", presentation.repositoryPath ?? "unavailable")
            provenanceRow("BRANCH", presentation.branch ?? "unavailable")
            Text(presentation.verified ? "OBSERVED FROM RUNTIME" : "UNVERIFIED / CONTEXT ONLY")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(presentation.verified ? Color.scifiSuccess : Color.scifiWarning)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.scifiSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func provenanceRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.system(size: 8, design: .monospaced)).foregroundStyle(Color.scifiTertiary).frame(width: 72, alignment: .leading)
            Text(value).font(.system(size: 9, design: .monospaced)).foregroundStyle(Color.scifiFg).lineLimit(2)
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
                    .foregroundStyle(Color.scifiFg)
                Text(presentation.usedPercent.map { "\($0)% used" } ?? presentation.detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.scifiMuted)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.scifiSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var color: Color {
        switch presentation.state {
        case .available: return .scifiSuccess
        case .constrained: return .scifiWarning
        case .exhausted: return .scifiWarning
        case .unknown: return .scifiMuted
        }
    }
}
