import Combine
import Foundation

extension Notification.Name {
    static let hermGatewayAuthenticationChanged = Notification.Name("herm.gateway.authentication.changed")
}

struct GatewayCloudAgent: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
    let dashboardURL: String?
}

struct GatewayCloudOrganization: Identifiable, Equatable {
    let id: String
    let name: String
    let slug: String
}

@MainActor
final class GatewayConnectionModel: ObservableObject {
    @Published var draft: GatewayConnectionSettings
    @Published var tokenDraft = ""
    @Published private(set) var isBusy = false
    @Published private(set) var message = ""
    @Published private(set) var isError = false
    @Published private(set) var signedIn = false
    @Published private(set) var portalSignedIn = false
    @Published private(set) var agents: [GatewayCloudAgent] = []
    @Published private(set) var organizations: [GatewayCloudOrganization] = []
    let store: GatewayConnectionStore

    init(store: GatewayConnectionStore = .shared) {
        self.store = store
        draft = store.selected
        if let error = store.error {
            message = error
            isError = true
        }
    }

    func select(_ settings: GatewayConnectionSettings) {
        guard !isBusy else { return }
        draft = settings
        tokenDraft = ""
        message = ""
        agents = []
        organizations = []
        Task { await refreshAuthentication() }
    }

    func refreshAuthentication() async {
        let settings = draft
        let portal = await GatewayWebAuthentication.shared.hasSession(GatewayWebAuthentication.portalURL, portal: true)
        let remote: Bool
        if let url = try? GatewayConnectionSettings.normalizedURL(settings.remoteURL) {
            let browserSession = await GatewayWebAuthentication.shared.hasSession(url)
            remote = (try? await GatewayNativeAuthentication.shared.hasSession(url)) == true || browserSession
        } else {
            remote = false
        }
        guard settings == draft else { return }
        portalSignedIn = portal
        signedIn = remote
    }

    func run(_ operation: () async throws -> String) async {
        guard !isBusy else { return }
        isBusy = true
        isError = false
        message = ""
        defer { isBusy = false }
        do { message = try await operation() } catch is CancellationError { message = "Sign-in canceled." } catch {
            message = DockModel.safeUserDiagnostic(error.localizedDescription)
            isError = true
        }
        await refreshAuthentication()
    }

    func signIn() async {
        await run {
            let portal = draft.mode == .cloud
            let base =
                portal
                ? GatewayWebAuthentication.portalURL : try GatewayConnectionSettings.normalizedURL(draft.remoteURL)
            if portal {
                try await GatewayWebAuthentication.shared.signIn(base, portal: true)
            } else {
                let (_, status) = try await GatewayHTTP.request(GatewayConnectionSettings.endpoint(base, "/api/status"))
                let providers = try? await GatewayHTTP.request(
                    GatewayConnectionSettings.endpoint(base, "/api/auth/providers"))
                let supportsOAuth =
                    (providers?.1["providers"] as? [[String: Any]])?.contains {
                        $0["supports_password"] as? Bool == false
                    } ?? false
                if (status["auth_flows"] as? [String])?.contains("native_pkce") == true && supportsOAuth {
                    try await GatewayNativeAuthentication.shared.signIn(base)
                } else {
                    try await GatewayWebAuthentication.shared.signIn(base)
                }
            }
            NotificationCenter.default.post(name: .hermGatewayAuthenticationChanged, object: base)
            if portal { try await discover() }
            return "Signed in."
        }
    }

    func signOut() async {
        await run {
            let portal = draft.mode == .cloud
            let base =
                portal
                ? GatewayWebAuthentication.portalURL : try GatewayConnectionSettings.normalizedURL(draft.remoteURL)
            if !portal { try await GatewayNativeAuthentication.shared.signOut(base) }
            await GatewayWebAuthentication.shared.signOut(base)
            if portal {
                agents = []
                organizations = []
            }
            NotificationCenter.default.post(name: .hermGatewayAuthenticationChanged, object: base)
            return "Signed out."
        }
    }

    func refreshCloud() async {
        await run {
            try await discover()
            return agents.isEmpty && organizations.isEmpty ? "No Cloud agents were returned for this account." : ""
        }
    }

    private func discover() async throws {
        var organization = draft.cloudOrganization
        var renewed = false
        var resetOrganization = false
        while true {
            var parts = URLComponents(
                url: try GatewayConnectionSettings.endpoint(GatewayWebAuthentication.portalURL, "/api/agents"),
                resolvingAgainstBaseURL: false)!
            if !organization.isEmpty { parts.queryItems = [URLQueryItem(name: "org", value: organization)] }
            let (status, json) = try await GatewayHTTP.request(parts.url!, signIn: true)
            if status == 401, !renewed {
                renewed = true
                try await GatewayWebAuthentication.shared.signIn(
                    GatewayWebAuthentication.portalURL, portal: true, silent: true)
                continue
            }
            if !organization.isEmpty, !resetOrganization,
                (status == 403 && json["error"] as? String == "org_access_denied")
                    || (status == 404 && json["error"] as? String == "org_not_found")
            {
                resetOrganization = true
                organization = ""
                draft.cloudOrganization = ""
                continue
            }
            if status == 409, json["error"] as? String == "org_selection_required",
                let rows = json["orgs"] as? [[String: Any]]
            {
                organizations = try rows.map { row in
                    guard let id = row["id"] as? String, !id.isEmpty else {
                        throw HermesGateway.GatewayError.malformedResponse
                    }
                    return GatewayCloudOrganization(
                        id: id, name: row["name"] as? String ?? id, slug: row["slug"] as? String ?? id)
                }
                agents = []
                return
            }
            guard (200..<300).contains(status) else { throw HermesGateway.GatewayError.httpError(status) }
            guard let rows = json["agents"] as? [[String: Any]] else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            agents = try Self.parseAgents(rows)
            organizations = []
            return
        }
    }

    static func parseAgents(_ rows: [[String: Any]]) throws -> [GatewayCloudAgent] {
        var ids = Set<String>()
        return try rows.map { row in
            guard let id = row["id"] as? String, !id.isEmpty, ids.insert(id).inserted else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            let text = row["dashboardUrl"] as? String
            let url = text.flatMap { try? GatewayConnectionSettings.normalizedURL($0).absoluteString }
            return GatewayCloudAgent(
                id: id, name: row["name"] as? String ?? id, status: row["status"] as? String ?? "Unknown",
                dashboardURL: url)
        }
    }

    func chooseAgent(_ agent: GatewayCloudAgent) async {
        await run {
            guard let text = agent.dashboardURL else {
                throw GatewayConnectionError.unavailable("This agent does not have a dashboard URL yet.")
            }
            let base = try GatewayConnectionSettings.normalizedURL(text)
            if !(await GatewayWebAuthentication.shared.hasSession(base)) {
                try await GatewayWebAuthentication.shared.signIn(base)
            }
            var selected = draft
            selected.remoteURL = base.absoluteString
            selected.name = agent.name
            selected.authentication = .signIn
            let gateway = HermesGateway(connectionSettings: selected)
            defer { gateway.close() }
            try await gateway.testConnection()
            draft = selected
            return "Cloud agent selected. Save to use it after restarting Herm."
        }
    }

    func test() async {
        await run {
            let settings = try draft.validated()
            let token =
                settings.mode == .remote && settings.authentication == .token
                ? (store.environmentOverride
                    ? store.launchToken : try await store.token(for: settings, draft: tokenDraft))
                : nil
            var probeSettings = settings
            // A test owns a separate SSH backend, so it cannot stop the active one.
            if probeSettings.mode == .ssh { probeSettings.id = UUID().uuidString }
            let gateway = HermesGateway(connectionSettings: probeSettings, sessionToken: token)
            defer { gateway.close() }
            try await gateway.testConnection()
            return "Gateway HTTP and WebSocket connections succeeded."
        }
    }

    @discardableResult
    func save() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await store.save(draft, token: tokenDraft)
            draft = store.selected
            tokenDraft = ""
            message = "Saved for the next Herm restart."
            isError = false
            return true
        } catch {
            message = error.localizedDescription
            isError = true
            return false
        }
    }

    func removeSavedConnection() {
        do {
            try store.remove(draft)
            message = "Saved connection removed."
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }
}
