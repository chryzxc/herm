import Foundation

struct MessagingEnvVar: Identifiable, Equatable {
    let key: String
    let prompt: String
    let description: String
    let help: String
    let url: URL?
    let isPassword: Bool
    let isList: Bool
    let required: Bool
    let advanced: Bool
    let isSet: Bool
    let redactedValue: String
    /// Only list values (allowlists) come back in clear; secrets stay redacted.
    let value: String?
    var id: String { key }
}

struct MessagingPlatform: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let docsURL: URL?
    let enabled: Bool
    let configured: Bool
    let state: String
    let errorMessage: String?
    let envVars: [MessagingEnvVar]

    var statusTone: DockStatusTone {
        switch state {
        case "connected", "running": .complete
        case "pending_restart", "startup_failed", "fatal", "error": .attention
        case "disabled", "not_configured", "gateway_stopped": .inactive
        default: .queued
        }
    }

    var statusLabels: [(DockStatusTone, String)] {
        var labels: [(DockStatusTone, String)] = [enabled ? (statusTone, stateLabel) : (.inactive, "Disabled")]
        if !configured { labels.append((.attention, "Needs setup")) }
        return labels
    }

    private var stateLabel: String {
        switch state {
        case "connected", "running": "Connected"
        case "pending_restart": "Restart gateway to apply"
        case "gateway_stopped": "Gateway stopped"
        case "startup_failed": "Start failed"
        case "not_configured": "Enabled"
        default: state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Gateway messaging platforms over the dashboard's `/api/messaging` routes,
/// scoped to one profile.
@MainActor
final class MessagingPlatformsModel: ObservableObject {
    struct QRPairing: Equatable {
        let platform: String
        let id: String
        var qrPayload: String
        let deepLink: URL?
    }

    @Published private(set) var platforms: [MessagingPlatform] = []
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var testResult: (ok: Bool, message: String)?
    @Published private(set) var pairing: QRPairing?
    let client: HermesRPCClientProtocol
    private var pollTask: Task<Void, Never>?

    init(client: HermesRPCClientProtocol) {
        self.client = client
    }

    static let qrPlatforms: Set<String> = ["telegram", "whatsapp"]

    private func query(_ profileID: String?) -> String {
        guard let profileID, let encoded = profileID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return "" }
        return "?profile=\(encoded)"
    }

    func load(profileID: String?) async {
        do {
            let result = try await client.fetchHTTP("/api/messaging/platforms\(query(profileID))")
            platforms = ((result["platforms"] as? [[String: Any]]) ?? []).compactMap(Self.platform)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Sends only what changed; blank secrets keep their saved value.
    func save(_ platform: MessagingPlatform, enabled: Bool, drafts: [String: String], profileID: String?) async -> Bool
    {
        var body: [String: Any] = [:]
        if enabled != platform.enabled { body["enabled"] = enabled }
        let env = drafts.filter { key, value in
            let current = platform.envVars.first { $0.key == key }
            return !value.isEmpty && value != current?.value
        }
        if !env.isEmpty { body["env"] = env }
        let cleared = drafts.filter { key, value in
            value.isEmpty && platform.envVars.first { $0.key == key }?.isList == true
        }.map(\.key)
        if !cleared.isEmpty { body["clear_env"] = cleared }
        guard !body.isEmpty else { return true }
        if let profileID { body["profile"] = profileID }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.sendHTTP("PUT", path: "/api/messaging/platforms/\(platform.id)", body: body)
            notice = "Saved \(platform.name)."
            await load(profileID: profileID)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func test(_ platform: MessagingPlatform, profileID: String?) async {
        busy = true
        defer { busy = false }
        do {
            let result = try await client.sendHTTP(
                "POST", path: "/api/messaging/platforms/\(platform.id)/test\(query(profileID))", body: [:])
            testResult = (result["ok"] as? Bool ?? false, (result["message"] as? String) ?? "No result.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Starts a stopped gateway, otherwise restarts it, then re-reads state while it comes up.
    func restartGateway(start: Bool, profileID: String?) async {
        busy = true
        do {
            _ = try await client.sendHTTP(
                "POST", path: "/api/gateway/\(start ? "start" : "restart")\(query(profileID))", body: [:])
            notice = start ? "Starting the gateway…" : "Restarting the gateway…"
        } catch {
            self.error = error.localizedDescription
            busy = false
            return
        }
        busy = false
        // ponytail: fixed re-polls; a gateway that takes >10s just needs one more manual visit.
        for delay in [3, 7] {
            try? await Task.sleep(for: .seconds(delay))
            await load(profileID: profileID)
        }
    }

    /// QR onboarding for Telegram (Hermes creates the bot) and WhatsApp (links this device).
    func startQR(platform: String, whatsappMode: String = "bot", profileID: String?) async {
        cancelQR()
        busy = true
        defer { busy = false }
        do {
            var body: [String: Any] = platform == "whatsapp" ? ["mode": whatsappMode] : [:]
            if platform == "whatsapp", let profileID { body["profile"] = profileID }
            let result = try await client.sendHTTP(
                "POST", path: "/api/messaging/\(platform)/onboarding/start", body: body)
            guard let id = result["pairing_id"] as? String else { throw HermesGateway.GatewayError.malformedResponse }
            let deepLink = (result["deep_link"] as? String).flatMap(URL.init(string:))
            pairing = QRPairing(
                platform: platform, id: id,
                qrPayload: (result["qr_payload"] as? String) ?? deepLink?.absoluteString ?? "", deepLink: deepLink)
            pollTask = Task { [weak self] in await self?.pollQR(platform: platform, id: id, profileID: profileID) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancelQR() {
        pollTask?.cancel()
        pollTask = nil
        if let pairing {
            Task {
                _ = try? await client.sendHTTP(
                    "DELETE", path: "/api/messaging/\(pairing.platform)/onboarding/\(pairing.id)", body: [:])
            }
        }
        pairing = nil
    }

    private func pollQR(platform: String, id: String, profileID: String?) async {
        let base = "/api/messaging/\(platform)/onboarding/\(id)"
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, pairing?.id == id else { return }
            do {
                let status = try await client.fetchHTTP(base)
                let state = status["status"] as? String
                if state == "error" {
                    throw HermesGateway.GatewayError.httpRefused(409, (status["error"] as? String) ?? "Pairing failed.")
                }
                // WhatsApp rotates its QR every ~20s.
                if let qr = status["qr_payload"] as? String, !qr.isEmpty { pairing?.qrPayload = qr }
                guard state == (platform == "telegram" ? "ready" : "connected") else { continue }
                var body: [String: Any] = [:]
                if platform == "telegram" {
                    let owner = status["owner_user_id"].map { "\($0)" } ?? ""
                    body["allowed_user_ids"] = owner.isEmpty ? [] : [owner]
                }
                if let profileID { body["profile"] = profileID }
                let applied = try await client.sendHTTP("POST", path: "\(base)/apply\(query(profileID))", body: body)
                pairing = nil
                let account =
                    (applied["bot_username"] as? String).map { " as @\($0)" }
                    ?? (status["account_name"] as? String).map { " as \($0)" } ?? ""
                notice = "\(platform == "telegram" ? "Telegram" : "WhatsApp") connected\(account)."
                await load(profileID: profileID)
                return
            } catch {
                pairing = nil
                self.error = error.localizedDescription
                return
            }
        }
    }

    nonisolated static func platform(_ row: [String: Any]) -> MessagingPlatform? {
        guard let id = row["id"] as? String else { return nil }
        let envVars = ((row["env_vars"] as? [[String: Any]]) ?? []).compactMap { env -> MessagingEnvVar? in
            guard let key = env["key"] as? String else { return nil }
            return MessagingEnvVar(
                key: key, prompt: (env["prompt"] as? String) ?? key, description: (env["description"] as? String) ?? "",
                help: (env["help"] as? String) ?? "", url: (env["url"] as? String).flatMap(URL.init(string:)),
                isPassword: env["is_password"] as? Bool ?? false, isList: env["is_list"] as? Bool ?? false,
                required: env["required"] as? Bool ?? false, advanced: env["advanced"] as? Bool ?? false,
                isSet: env["is_set"] as? Bool ?? false, redactedValue: (env["redacted_value"] as? String) ?? "",
                value: env["value"] as? String)
        }
        return MessagingPlatform(
            id: id, name: (row["name"] as? String) ?? id, description: (row["description"] as? String) ?? "",
            docsURL: (row["docs_url"] as? String).flatMap(URL.init(string:)), enabled: row["enabled"] as? Bool ?? false,
            configured: row["configured"] as? Bool ?? false, state: (row["state"] as? String) ?? "",
            errorMessage: row["error_message"] as? String, envVars: envVars)
    }
}
