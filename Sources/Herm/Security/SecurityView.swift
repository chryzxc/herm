import SwiftUI

public struct SecurityView: View {
    public let snapshot: SecuritySnapshot
    public init(snapshot: SecuritySnapshot) { self.snapshot = snapshot }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Security").font(.headline); Spacer(); Text(snapshot.state.rawValue.capitalized).foregroundStyle(.secondary) }
            GroupBox("Approvals & safe mode") {
                VStack(alignment: .leading) { row("Pending approvals", "\(snapshot.approvals.pending)"); row("Safe mode", snapshot.safeMode.state) }
            }
            GroupBox("Control-plane health") {
                VStack(alignment: .leading) { row("Checkpoints", "\(snapshot.checkpoints.count)"); row("Secret sources", "\(snapshot.secretSources.sources.count)"); row("Egress", snapshot.egress.network); row("Doctor", "\(snapshot.doctor.failures) failures"); row("Security", snapshot.security.score); row("Logs", "\(snapshot.logs.events) events") }
            }
            if snapshot.state != .ready { Text("Security details unavailable; no actions are enabled.").font(.caption).foregroundStyle(.secondary) }
        }.padding()
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
    }
}

public typealias SecurityControlPlaneView = SecurityView
