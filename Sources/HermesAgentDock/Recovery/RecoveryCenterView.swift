import SwiftUI

/// Read-only recovery status. No backup, restore, import, migration, sync, or
/// update control is exposed until Hermes publishes a typed contract and the
/// disposable-workspace recovery procedure is approved.
struct RecoveryCenterView: View {
    let snapshot: RecoverySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RECOVERY & DISTRIBUTION")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color.dockSecondaryText)

            ForEach(snapshot.items) { item in
                HStack(spacing: 10) {
                    LucideImage(systemName: icon(for: item.id))
                        .foregroundStyle(color(for: item.state))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.id.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockPrimaryText)
                        Text(item.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockMetadataText)
                            .lineLimit(2)
                    }
                    Spacer()
                    Text(label(for: item.state))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(color(for: item.state))
                }
                .padding(10)
                .dockGlassPane()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(for state: RecoveryFeatureState) -> String {
        switch state {
        case .ready: "READY"
        case .requiresConfirmation: "REVIEW ONLY"
        case .unavailable: "UNAVAILABLE"
        case .unsupported: "UNSUPPORTED"
        }
    }

    private func color(for state: RecoveryFeatureState) -> Color {
        switch state {
        case .ready: .dockSuccess
        case .requiresConfirmation: .dockWarning
        case .unavailable, .unsupported: .dockMetadataText
        }
    }

    private func icon(for feature: RecoveryFeature) -> String {
        switch feature {
        case .backup: "externaldrive"
        case .import, .importAgent: "square.and.arrow.down"
        case .migration, .openClawMigration: "arrow.triangle.2.circlepath"
        case .sync: "arrow.triangle.2.circlepath.circle"
        case .update: "arrow.down.circle"
        }
    }
}
