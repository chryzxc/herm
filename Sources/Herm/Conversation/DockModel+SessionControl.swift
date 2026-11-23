import Foundation

extension DockModel {
    func sessionControlKey(sessionID: String, profileID: String?) -> String {
        "\(profileID ?? "")|\(sessionID)"
    }

    func applySessionControlEvent(_ payload: [String: Any], sessionID: String) {
        guard self.sessionID == sessionID, let snapshot = HermesSessionControl.parse(payload) else { return }
        sessionControlEventGeneration &+= 1
        publishSessionControl(snapshot, sessionID: sessionID, profileID: sessionProfileID ?? profileScopeID)
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
            publishSessionControl(HermesSessionControl.parse(result), sessionID: sessionID, profileID: profileID)
        } catch {
            guard !Task.isCancelled, self.sessionID == sessionID, (sessionProfileID ?? profileScopeID) == profileID,
                sessionResumeGeneration == generation,
                sessionControlEventGeneration == eventGeneration
            else { return }
            publishSessionControl(nil, sessionID: sessionID, profileID: profileID)
        }
    }

    private func publishSessionControl(_ snapshot: HermesSessionControl?, sessionID: String, profileID: String?) {
        let owner = sessionControlKey(sessionID: sessionID, profileID: profileID)
        let isStale = snapshot == nil
        if let snapshot, sessionControl != snapshot { sessionControl = snapshot }
        if sessionControlOwner != owner { sessionControlOwner = owner }
        if sessionControlStale != isStale { sessionControlStale = isStale }
    }

    /// Runs a tray action through `session.control`, applies the snapshot Hermes returns, and submits
    /// the follow-up prompt when Hermes asks for one (resuming a goal kicks off its next turn).
    func runSessionControlAction(_ action: HermesSessionControl.Action) async {
        guard sessionActionsReady, let sessionID, !sessionID.isEmpty else { return }
        let profileID = sessionProfileID ?? profileScopeID
        let generation = sessionResumeGeneration
        do {
            let result = try await HermesControlRPC(client: sessionRPCClient)
                .sessionControlAction(action, sessionID: sessionID, profileID: profileID)
            guard self.sessionID == sessionID, sessionResumeGeneration == generation else { return }
            if let snapshot = HermesSessionControl.parse(result) {
                sessionControlEventGeneration &+= 1
                publishSessionControl(snapshot, sessionID: sessionID, profileID: profileID)
            }
            guard let dispatch = result["dispatch"] as? [String: Any], dispatch["type"] as? String == "send",
                let message = (dispatch["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !message.isEmpty
            else { return }
            let display = (dispatch["display"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            messages.append(
                ChatMessage(
                    role: .user, text: display ?? "/\(action.rawValue.replacingOccurrences(of: ".", with: " "))"))
            if let notice = (dispatch["notice"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !notice.isEmpty
            {
                appendSlashOutput(notice, generation: generation)
            }
            status = .working
            isSending = true
            _ = try await sessionRPCClient.request(
                HermesFeatureIDs.ID.promptSubmit.rawValue,
                params: scopedSessionParams(["session_id": sessionID, "text": message], profileID: profileID))
        } catch {
            appendSlashOutput(
                "\(action.label) failed: \(Self.safeUserDiagnostic(error.localizedDescription))",
                generation: generation, isError: true)
        }
    }
}
