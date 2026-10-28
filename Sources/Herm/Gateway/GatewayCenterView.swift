import SwiftUI

/// Read-only gateway and messaging health projection. Configuration, pairing,
/// sending, webhook writes, and peer messages remain visibly unavailable until
/// Hermes exposes verified structured contracts for each operation.
struct GatewayCenterView: View {
    let snapshot: HermesGatewaySnapshot
    let webhooks: HermesWebhookSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                section("CHANNELS") {
                    if snapshot.channels.isEmpty {
                        unavailable("No verified channel inventory was returned by Hermes.")
                    }
                    ForEach(snapshot.channels) { channel in
                        row(
                            channel.name, detail: channel.diagnostic,
                            state: channel.connected
                                ? "Connected" : (channel.pairingRequired ? "Pairing required" : "Disconnected"))
                    }
                }
                section("WEBHOOKS") {
                    if webhooks.subscriptions.isEmpty {
                        unavailable(
                            webhooks.diagnostic.isEmpty ? "Webhook inventory unavailable." : webhooks.diagnostic)
                    }
                    ForEach(webhooks.subscriptions) { hook in
                        row(
                            hook.id, detail: "\(hook.event) → \(hook.target)",
                            state: "\(hook.deliveries.delivered) delivered / \(hook.deliveries.failed) failed")
                    }
                }
                section("PEERS / A2A") {
                    if snapshot.peers.isEmpty && webhooks.peers.isEmpty {
                        unavailable(
                            "Peer status is unavailable until Hermes provides a verified structured projection.")
                    }
                    ForEach(snapshot.peers + webhooks.peers) { peer in
                        row(peer.id, detail: peer.diagnostic, state: peer.state.rawValue)
                    }
                }
                unavailableActions
            }
            .padding(20)
        }
        .background(Color.dockCanvas)
        .accessibilityIdentifier("gateway-center")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("GATEWAY CONTROL").dockFont(.compactStatus, weight: .bold, design: .monospaced).foregroundStyle(
                    Color.dockMetadataText)
                Text("Messaging & peers").dockFont(.pageTitle).foregroundStyle(Color.dockPrimaryText)
            }
            Spacer()
            Text(snapshot.state.rawValue.uppercased()).dockFont(.compactStatus, weight: .regular, design: .monospaced)
                .foregroundStyle(Color.dockAccent)
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).dockFont(.compactStatus, weight: .bold, design: .monospaced).foregroundStyle(
                Color.dockMetadataText)
            content()
        }.dockCard(padding: 12)
    }
    private func row(_ title: String, detail: String, state: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).foregroundStyle(Color.dockPrimaryText)
                Text(detail).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
            }
            Spacer()
            Text(state.uppercased()).dockFont(.metadata, design: .monospaced).foregroundStyle(Color.dockMetadataText)
        }
    }
    private func unavailable(_ text: String) -> some View {
        Text(text).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
    }
    private var unavailableActions: some View {
        section("ACTIONS") {
            HStack {
                Button("Pair") {}.disabled(true)
                Button("Send") {}.disabled(true)
                Button("Manage webhooks") {}.disabled(true)
                Button("Connect peer") {}.disabled(true)
            }
            unavailable(
                "Pairing, sending, webhook mutations, and peer/A2A messaging are unavailable: Hermes 0.20.6 does not provide verified typed contracts for Herm use."
            )
        }
    }
}
