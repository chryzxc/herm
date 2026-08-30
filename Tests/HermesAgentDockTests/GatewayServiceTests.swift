import Foundation
import Testing
@testable import HermesAgentDock

struct GatewayServiceTests {
    @Test func parsesSafeGatewayAndChannelSnapshot() throws {
        let output = #"{"schema":"hermes.gateway.snapshot.v1","gateway":{"state":"ready","diagnostic":"supervised"},"channels":[{"name":"telegram","enabled":true,"connected":true,"pairing_required":false,"auth_required":false,"diagnostic":"online","last_event":{"kind":"message","at":"2026-08-29T12:00:00Z"}}],"peers":[{"id":"peer-1","state":"connected","diagnostic":"ready"}]}"#
        let snapshot = HermesGatewayService.parse(output, format: .json)
        #expect(snapshot.state == .ready)
        #expect(snapshot.channels.first?.name == "telegram")
        #expect(snapshot.channels.first?.lastEvent?.kind == "message")
        #expect(snapshot.peers.first?.id == "peer-1")
    }

    @Test func rejectsHumanGatewayOutputAndSecrets() {
        #expect(HermesGatewayService.parse("gateway table", format: .humanTable).state == .unsupported)
        let inventory = HermesGatewayService.parse(#"{"schema":"hermes.gateway.snapshot.v1","gateway":{"state":"ready","diagnostic":"credential material"},"channels":[],"peers":[]}"#, format: .json)
        #expect(inventory.state == .malformed)
        #expect(inventory.channels.isEmpty)
    }

    @Test func pairingAndSendRemainUnavailableUnlessCapabilityIsVerifiedAndConfirmed() {
        #expect(HermesGatewayService.pairing(confirmed: false) == .confirmationRequired)
        #expect(HermesGatewayService.pairing(confirmed: true) == .unavailable)
        #expect(HermesGatewayService.send(confirmed: true) == .unavailable)
    }
}

struct WebhookServiceTests {
    @Test func parsesReadOnlyWebhookSummariesWithoutPayloadOrSecret() {
        let output = #"{"schema":"hermes.webhooks.snapshot.v1","subscriptions":[{"id":"build","event":"push","target":"telegram","state":"ready","deliveries":{"delivered":4,"failed":1}}],"peers":[{"id":"a2a-1","state":"connected","diagnostic":"ready"}]}"#
        let snapshot = HermesWebhookService.parse(output, format: .json)
        #expect(snapshot.state == .ready)
        #expect(snapshot.subscriptions.first?.id == "build")
        #expect(snapshot.subscriptions.first?.deliveries.failed == 1)
        #expect(snapshot.subscriptions.first?.signingSecret == nil)
        #expect(snapshot.peers.first?.id == "a2a-1")
    }

    @Test func malformedOrHumanWebhookDataIsExplicitlyUnavailable() {
        #expect(HermesWebhookService.parse("[]", format: .json).state == .malformed)
        #expect(HermesWebhookService.parse("webhook table", format: .humanTable).state == .unsupported)
    }
}
