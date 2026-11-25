import Foundation

extension DockModel {
    /// Points Hermes' browser tools at a profile's CDP endpoint; nil disconnects.
    func setHermesBrowser(cdpURL: String?) async throws {
        try await HermesControlRPC(client: sessionRPCClient).setBrowser(cdpURL: cdpURL, profile: profileScopeID)
    }
}
