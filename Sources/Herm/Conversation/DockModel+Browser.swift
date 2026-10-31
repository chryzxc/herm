import Foundation

extension DockModel {
    /// Points Hermes' browser tools at a profile's CDP endpoint; nil disconnects.
    func setHermesBrowser(cdpURL: String?) async throws {
        let profile = profileScopeID
        var scope: [String: Any] = [:]
        if let profile, !profile.isEmpty { scope["profile"] = profile }
        if let cdpURL {
            var statusParams = scope
            statusParams["action"] = "status"
            let status = try await sessionRPCClient.request(
                HermesFeatureIDs.ID.browserManage.rawValue, params: statusParams)
            if status["connected"] as? Bool == true, status["url"] as? String == cdpURL { return }
        }
        var params = scope
        params["action"] = cdpURL == nil ? "disconnect" : "connect"
        if let cdpURL { params["url"] = cdpURL }
        let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.browserManage.rawValue, params: params)
        if cdpURL != nil, result["connected"] as? Bool != true {
            let detail = (result["messages"] as? [String])?.last ?? "Hermes could not connect to the browser."
            throw NSError(domain: "Herm.AgentBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }
}
