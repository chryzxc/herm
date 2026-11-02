import Foundation

extension DockModel {
    func resetEffortTransition() {
        sessionReasoningMutationToken = nil
        isUpdatingSessionReasoning = false
        sessionModelMutationToken = nil
        isUpdatingSessionModel = false
        sessionReasoningRevision &+= 1
        sessionReasoningStale = false
        draftReasoningVariant = nil
    }

    func applyEffortSessionInfo(_ params: [String: Any], payload: [String: Any], owner: String?) {
        if let sequence = (params["seq"] as? NSNumber)?.intValue, let owner {
            guard sequence > (sessionInfoSequencesBySessionID[owner] ?? -1) else { return }
            sessionInfoSequencesBySessionID[owner] = sequence
        } else if params["herm_trace_replayed"] as? Bool == true {
            refreshSessionReasoningVariant()
            refreshSessionModelOptions(keepingCatalog: true)
            return
        }
        if let raw = payload["reasoning_effort"] as? String, !raw.isEmpty {
            sessionReasoningRevision &+= 1
            sessionReasoningVariant = HermesReasoningVariant(rawValue: raw.lowercased())
            let wire = (payload["reasoning_effort_wire"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            sessionReasoningWire = wire?.isEmpty == false ? wire : nil
            sessionReasoningStale = false
        }
        if let fast = payload["fast"] as? Bool { sessionFastEnabled = fast }
        if payload["model"] as? String != nil || payload["provider"] as? String != nil {
            refreshSessionModelOptions(keepingCatalog: true)
        }
    }

    func updateSessionReasoning(_ variant: HermesReasoningVariant) {
        guard let sessionID, !sessionID.isEmpty, !isUpdatingSessionReasoning, !isUpdatingSessionModel else { return }
        let generation = sessionResumeGeneration
        let profile = sessionProfileID ?? profileScopeID
        let token = UUID()
        sessionReasoningMutationToken = token
        sessionReasoningRevision &+= 1
        let params = scopedSessionParams(["key": "reasoning", "value": variant.rawValue, "session_id": sessionID])
        isUpdatingSessionReasoning = true
        runtimeConfigurationError = nil
        Task { [weak self] in
            guard let self else { return }
            defer {
                if sessionReasoningMutationToken == token {
                    sessionReasoningMutationToken = nil
                    isUpdatingSessionReasoning = false
                }
            }
            do {
                let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.configSet.rawValue, params: params)
                guard sessionID == self.sessionID, sessionResumeGeneration == generation,
                    (sessionProfileID ?? profileScopeID) == profile, sessionReasoningMutationToken == token
                else { return }
                guard result["key"] as? String == "reasoning", let value = result["value"] as? String,
                    HermesReasoningVariant(rawValue: value.lowercased()) != nil,
                    result["scope"] == nil || result["scope"] as? String == "session",
                    result["deferred"] as? Bool != true, result["confirm_required"] as? Bool != true
                else { throw QuickDraftError.message("Hermes did not acknowledge the effort change.") }
                do {
                    let revision = sessionReasoningRevision
                    let readback = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.configGet.rawValue,
                        params: scopedSessionParams(["key": "reasoning", "session_id": sessionID], profileID: profile))
                    guard sessionID == self.sessionID, sessionResumeGeneration == generation,
                        (sessionProfileID ?? profileScopeID) == profile, sessionReasoningMutationToken == token,
                        sessionReasoningRevision == revision
                    else { return }
                    guard let value = readback["value"] as? String else {
                        throw HermesGateway.GatewayError.malformedResponse
                    }
                    let variant = HermesReasoningVariant(rawValue: value.lowercased())
                    if sessionReasoningVariant != variant { sessionReasoningWire = nil }
                    sessionReasoningVariant = variant
                    sessionReasoningStale = false
                } catch {
                    guard sessionID == self.sessionID, sessionResumeGeneration == generation,
                        (sessionProfileID ?? profileScopeID) == profile, sessionReasoningMutationToken == token
                    else { return }
                    sessionReasoningStale = true
                    runtimeConfigurationError = "Effort availability could not be refreshed."
                }
            } catch {
                guard sessionID == self.sessionID, sessionResumeGeneration == generation,
                    (sessionProfileID ?? profileScopeID) == profile, sessionReasoningMutationToken == token
                else { return }
                runtimeConfigurationError = "Could not change effort. Try again."
                actionErrors.report("Could not change session thinking level", error: error)
            }
        }
    }

    func updateSessionFast(_ enabled: Bool) {
        guard let sessionID, !sessionID.isEmpty, !isUpdatingSessionFast else { return }
        let generation = sessionResumeGeneration
        let params = scopedSessionParams(["key": "fast", "value": enabled ? "fast" : "normal", "session_id": sessionID])
        isUpdatingSessionFast = true
        Task { [weak self] in
            guard let self else { return }
            defer { if sessionID == self.sessionID { isUpdatingSessionFast = false } }
            do {
                let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.configSet.rawValue, params: params)
                guard sessionID == self.sessionID, sessionResumeGeneration == generation else { return }
                guard result["key"] as? String == "fast", let value = result["value"] as? String else {
                    throw QuickDraftError.message("Hermes did not acknowledge the fast change.")
                }
                sessionFastEnabled = value != "normal"
            } catch {
                guard sessionID == self.sessionID, sessionResumeGeneration == generation else { return }
                runtimeConfigurationError = "Could not change fast mode. Try again."
                actionErrors.report("Could not change session fast mode", error: error)
            }
        }
    }
}
