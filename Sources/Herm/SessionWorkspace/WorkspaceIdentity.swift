import CryptoKit
import Foundation

@MainActor
enum WorkspaceIdentity {
    private static let backend: String = {
        let settings = GatewayConnectionStore.shared.launchSettings
        let endpoint =
            settings.mode == .local
            ? "local"
            : settings.mode.rawValue + ":" + settings.remoteURL + ":" + settings.sshHost + ":" + settings.sshUser
        return SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
    }()

    static func session(_ model: DockModel) -> String {
        session(profileID: model.profileScopeID, sessionID: model.navigationSessionID)
    }

    static func session(profileID: String?, sessionID: String?) -> String {
        return backend + ":" + (profileID ?? "default") + ":" + (sessionID ?? "new")
    }
}
