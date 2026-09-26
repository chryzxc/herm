import SwiftUI

struct AgentOperationsRadarView: View {
    let agents: [HermesSubagent]

    var body: some View {
        let rows = AgentOperationsPresentation.rows(agents: agents)

        VStack(alignment: .leading, spacing: 10) {
            DockIconLabel("OPERATIONS RADAR", icon: .broadcast)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Color.dockAccent)

            if rows.isEmpty {
                Text("No observed agent operations.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSecondaryText)
                    .dockListRow()
            } else {
                VStack(spacing: 0) {
                    ForEach(rows.prefix(8)) { row in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(color(for: row.state))
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.dockPrimaryText)
                                    .lineLimit(1)

                                Text("\(row.state.displayLabel) · \(row.model)")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.dockMetadataText)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)
                        }
                        .dockListRow()
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Agent \(row.name), \(row.state.displayLabel), model \(row.model)")
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockGlassPane()
    }

    private func color(for state: AgentOperationsState) -> Color {
        switch state {
        case .running: return .dockAccent
        case .stalled, .failed, .pending: return .dockWarning
        case .completed: return .dockSuccess
        case .unknown, .unverified: return .dockSecondaryText
        }
    }
}
