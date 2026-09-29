import SwiftUI

struct HermesGatewaySettingsView: View {
    @ObservedObject var service: HermesGatewayLifecycleModel
    @ObservedObject private var theme = DockThemeStore.shared
    @State private var confirmsRestart = false

    private var statusColor: Color {
        if service.isRestarting || !service.hasChecked { return .dockSecondaryText }
        return service.status.state == .running ? .dockSecondaryText : .dockWarning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(service.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .accessibilityLabel("Hermes gateway: \(service.label)")
                Spacer(minLength: 0)
                DockIconButton(icon: .arrowsClockwise, label: "Refresh gateway status", isBusy: service.isRefreshing, style: theme.palette) {
                    Task { await service.refresh() }
                }
                .disabled(service.isRestarting)
                Button { confirmsRestart = true } label: {
                    DockActionLabel(title: "Restart gateway", pendingTitle: "Restarting…", isPending: service.isRestarting)
                        .frame(width: 140)
                }
                .buttonStyle(.dockPress)
                .font(.system(size: 12, weight: .medium))
                .disabled(!service.canRestart)
            }
            Text(service.detail)
                .font(.system(size: 12))
                .foregroundStyle(service.error == nil ? Color.dockSecondaryText : Color.dockWarning)
                .lineLimit(3)
                .frame(height: 48, alignment: .topLeading)
                .help(service.detail)
        }
        .task {
            while !Task.isCancelled {
                await service.refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
        .confirmationDialog("Restart Hermes gateway?", isPresented: $confirmsRestart) {
            Button("Restart gateway", role: .destructive) {
                Task { await service.restart() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restarts the default-profile messaging gateway. Connected messaging channels and scheduled work may be interrupted while it restarts.")
        }
        .accessibilityIdentifier("hermes-gateway-settings")
    }
}
