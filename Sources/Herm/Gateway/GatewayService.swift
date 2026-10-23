import Foundation

/// Pure, fail-closed parser for a future structured gateway projection.
/// Hermes 0.20.6's gateway/pairing commands are human-oriented, so callers
/// must pass `.json` only after a verified structured contract is available.
enum HermesGatewayService {
    static func parse(_ output: String, format: HermesGatewayInputFormat) -> HermesGatewaySnapshot {
        guard format == .json else { return unavailable(.unsupported, "Human-readable gateway output is unsupported.") }
        do { return try parseVerifiedJSON(output) } catch {
            return unavailable(.malformed, "Structured gateway data was malformed.")
        }
    }

    static func parseVerifiedJSON(
        _ output: String, observedAt: Date? = nil, now: Date = Date(), maxAge: TimeInterval = 300
    ) throws -> HermesGatewaySnapshot {
        guard let data = output.data(using: .utf8),
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(root.keys) == ["schema", "gateway", "channels", "peers"],
            root["schema"] as? String == "hermes.gateway.snapshot.v1",
            let gateway = root["gateway"] as? [String: Any], Set(gateway.keys) == ["state", "diagnostic"],
            let rawState = gateway["state"] as? String, let diagnostic = gateway["diagnostic"] as? String,
            HermesGatewaySafety.safe(diagnostic), let rawChannels = root["channels"] as? [[String: Any]],
            let rawPeers = root["peers"] as? [[String: Any]]
        else { throw ParseError.invalid }
        var channels: [HermesChannelSummary] = []
        for item in rawChannels {
            guard
                Set(item.keys).isSubset(of: [
                    "name", "enabled", "connected", "pairing_required", "auth_required", "diagnostic", "last_event",
                ]),
                let name = item["name"] as? String, HermesGatewaySafety.safe(name),
                let enabled = item["enabled"] as? Bool, let connected = item["connected"] as? Bool,
                let pairing = item["pairing_required"] as? Bool, let auth = item["auth_required"] as? Bool,
                let detail = item["diagnostic"] as? String, HermesGatewaySafety.safe(detail)
            else { throw ParseError.invalid }
            var event: HermesLastSafeEvent?
            if let raw = item["last_event"] {
                guard let e = raw as? [String: Any], Set(e.keys) == ["kind", "at"], let kind = e["kind"] as? String,
                    let at = e["at"] as? String, HermesGatewaySafety.safe(kind), HermesGatewaySafety.safe(at)
                else { throw ParseError.invalid }
                event = HermesLastSafeEvent(kind: kind, at: at)
            }
            channels.append(
                HermesChannelSummary(
                    id: name, name: name, enabled: enabled, connected: connected, pairingRequired: pairing,
                    authRequired: auth, diagnostic: detail, lastEvent: event))
        }
        var peers: [HermesPeerSummary] = []
        for item in rawPeers {
            guard Set(item.keys) == ["id", "state", "diagnostic"], let id = item["id"] as? String,
                HermesGatewaySafety.safe(id), let state = item["state"] as? String,
                let detail = item["diagnostic"] as? String, HermesGatewaySafety.safe(detail)
            else { throw ParseError.invalid }
            peers.append(HermesPeerSummary(id: id, state: HermesGatewaySafety.state(state), diagnostic: detail))
        }
        let stale = observedAt.map { maxAge >= 0 && now.timeIntervalSince($0) > maxAge } ?? false
        return HermesGatewaySnapshot(
            state: stale ? .stale : HermesGatewaySafety.state(rawState),
            diagnostic: stale ? "Gateway snapshot is stale; refresh is required." : diagnostic, channels: channels,
            peers: peers, observedAt: observedAt)
    }

    static func unavailable(
        _ state: HermesGatewaySnapshotState = .unavailable, _ diagnostic: String = "Gateway inventory is unavailable."
    ) -> HermesGatewaySnapshot {
        HermesGatewaySnapshot(state: state, diagnostic: diagnostic, channels: [], peers: [], observedAt: nil)
    }
    static func pairing(confirmed: Bool) -> HermesGatewayOperationResult {
        confirmed ? .unavailable : .confirmationRequired
    }
    static func send(confirmed: Bool) -> HermesGatewayOperationResult {
        confirmed ? .unavailable : .confirmationRequired
    }
    static func peerConnect(confirmed: Bool) -> HermesGatewayOperationResult {
        confirmed ? .unavailable : .confirmationRequired
    }
    static func peerSend(confirmed: Bool) -> HermesGatewayOperationResult {
        confirmed ? .unavailable : .confirmationRequired
    }
    private enum ParseError: Error { case invalid }
}

enum HermesWebhookMutation: Equatable, Sendable { case create, edit, pause, delete }

enum HermesWebhookService {
    static func mutation(_ mutation: HermesWebhookMutation, confirmed: Bool) -> HermesGatewayOperationResult {
        confirmed ? .unavailable : .confirmationRequired
    }

    static func parse(_ output: String, format: HermesWebhookInputFormat) -> HermesWebhookSnapshot {
        guard format == .json else {
            return HermesWebhookSnapshot(
                state: .unsupported, subscriptions: [], peers: [],
                diagnostic: "Human-readable webhook output is unsupported.")
        }
        do {
            guard let data = output.data(using: .utf8),
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(root.keys) == ["schema", "subscriptions", "peers"],
                root["schema"] as? String == "hermes.webhooks.snapshot.v1",
                let raw = root["subscriptions"] as? [[String: Any]], let peerData = root["peers"] as? [[String: Any]]
            else { throw HermesWebhookParseError.invalid }
            let subscriptions = try raw.map { item -> HermesWebhookSubscriptionSummary in
                guard Set(item.keys).isSubset(of: ["id", "event", "target", "state", "deliveries"]),
                    let id = item["id"] as? String, HermesGatewaySafety.safe(id), let event = item["event"] as? String,
                    HermesGatewaySafety.safe(event), let target = item["target"] as? String,
                    HermesGatewaySafety.safe(target), let state = item["state"] as? String,
                    let d = item["deliveries"] as? [String: Any], Set(d.keys) == ["delivered", "failed"],
                    let delivered = d["delivered"] as? Int, let failed = d["failed"] as? Int, delivered >= 0,
                    failed >= 0
                else { throw HermesWebhookParseError.invalid }
                return HermesWebhookSubscriptionSummary(
                    id: id, event: event, target: target, state: HermesWebhookState(rawValue: state) ?? .unavailable,
                    deliveries: HermesWebhookDeliverySummary(delivered: delivered, failed: failed), signingSecret: nil)
            }
            let peers = try peerData.map { item -> HermesPeerSummary in
                guard Set(item.keys) == ["id", "state", "diagnostic"], let id = item["id"] as? String,
                    HermesGatewaySafety.safe(id), let state = item["state"] as? String,
                    let detail = item["diagnostic"] as? String, HermesGatewaySafety.safe(detail)
                else { throw HermesWebhookParseError.invalid }
                return HermesPeerSummary(id: id, state: HermesGatewaySafety.state(state), diagnostic: detail)
            }
            return HermesWebhookSnapshot(state: .ready, subscriptions: subscriptions, peers: peers, diagnostic: "")
        } catch {
            return HermesWebhookSnapshot(
                state: .malformed, subscriptions: [], peers: [], diagnostic: "Structured webhook data was malformed.")
        }
    }
    static func unavailable() -> HermesWebhookSnapshot {
        HermesWebhookSnapshot(
            state: .unavailable, subscriptions: [], peers: [], diagnostic: "Webhook inventory is unavailable.")
    }
}
private enum HermesWebhookParseError: Error { case invalid }
