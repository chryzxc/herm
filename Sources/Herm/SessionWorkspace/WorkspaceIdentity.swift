import CryptoKit
import Foundation

@MainActor
enum WorkspaceIdentity {
    static func session(_ model: DockModel) -> String {
        session(profileID: model.profileScopeID, sessionID: model.navigationSessionID)
    }
    static func session(profileID: String?, sessionID: String?) -> String {
        let settings = GatewayConnectionStore.shared.launchSettings
        let endpoint =
            settings.mode == .local
            ? "local"
            : settings.mode.rawValue + ":" + settings.remoteURL + ":" + settings.sshHost + ":" + settings.sshUser
        let backend = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        return backend + ":" + (profileID ?? "default") + ":" + (sessionID ?? "new")
    }
}
