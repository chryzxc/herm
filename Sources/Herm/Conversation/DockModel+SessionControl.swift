import Foundation

extension DockModel {
    func sessionControlKey(sessionID: String, profileID: String?) -> String {
        "\(profileID ?? "")|\(sessionID)"
    }

    func applySessionControlEvent(_ payload: [String: Any], sessionID: String) {
        guard self.sessionID == sessionID, let snapshot = HermesSessionControl.parse(payload) else { return }
        sessionControlEventGeneration &+= 1
        sessionControl = snapshot
        sessionControlOwner = sessionControlKey(sessionID: sessionID, profileID: sessionProfileID ?? profileScopeID)
        sessionControlStale = false
    }

    func refreshSessionControl(sessionID: String, profileID: String?) async {
        let generation = sessionResumeGeneration
        let eventGeneration = sessionControlEventGeneration
        do {
            let result = try await HermesControlRPC(client: sessionRPCClient)
                .sessionControl(sessionID: sessionID, profileID: profileID)
            guard !Task.isCancelled, self.sessionID == sessionID, (sessionProfileID ?? profileScopeID) == profileID,
                sessionResumeGeneration == generation,
                sessionControlEventGeneration == eventGeneration
            else { return }
            guard let snapshot = HermesSessionControl.parse(result) else {
                sessionControlStale = true
                sessionControlOwner = sessionControlKey(sessionID: sessionID, profileID: profileID)
                return
            }
            sessionControl = snapshot
            sessionControlOwner = sessionControlKey(sessionID: sessionID, profileID: profileID)
            sessionControlStale = false
        } catch {
            guard !Task.isCancelled, self.sessionID == sessionID, (sessionProfileID ?? profileScopeID) == profileID,
                sessionResumeGeneration == generation,
                sessionControlEventGeneration == eventGeneration
            else { return }
            sessionControlStale = true
            sessionControlOwner = sessionControlKey(sessionID: sessionID, profileID: profileID)
        }
    }
}
