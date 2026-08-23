import SwiftUI

struct AgentOperationsRadarView: View {
    let agents: [HermesSubagent]
    var body: some View {
        let rows = AgentOperationsPresentation.rows(agents: agents)
        VStack(alignment: .leading, spacing: 8) {
            Label("OPERATIONS RADAR", systemImage: "dot.radiowaves.left.and.right")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.scifiAccent)
            if rows.isEmpty {
                Text("No observed agent operations.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scifiMuted)
            } else {
                ForEach(rows.prefix(8)) { row in
                    HStack(spacing: 8) {
                        Circle().fill(color(for: row.state)).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.scifiFg).lineLimit(1)
                            Text("\(row.state.rawValue.uppercased()) · \(row.model)").font(.system(size: 8, design: .monospaced)).foregroundStyle(Color.scifiTertiary)
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Agent \(row.name), \(row.state.rawValue), model \(row.model)")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.scifiSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func color(for state: AgentOperationsState) -> Color {
        switch state {
        case .running: return .scifiAccent
        case .stalled, .failed: return .scifiWarning
        case .completed: return .scifiSuccess
        case .unknown, .unverified: return .scifiMuted
        }
    }
}
