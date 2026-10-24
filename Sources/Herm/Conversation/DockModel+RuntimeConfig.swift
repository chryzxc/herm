import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    func dateValue(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }

    func refreshRuntimeConfiguration(force: Bool = false) {
        Task { [weak self] in await self?.loadRuntimeConfiguration(force: force) }
    }

    func loadRuntimeConfiguration(force: Bool) async {
        let refresh = runtimeConfigurationRefresh
        refresh.onChange = { [weak self, weak refresh] in
            guard let self, let refresh else { return }
            self.isLoadingRuntimeConfiguration = self.isRuntimeModelMutationPending || refresh.isLoading
            self.runtimeConfigurationError = self.runtimeModelMutationError ?? refresh.error
            if refresh.configuration == nil {
                self.runtimeConfiguration = nil
                self.runtimeConfigurationProjectionState = .empty
            }
            if let configuration = refresh.configuration, Self.hasRuntimeConfigurationData(configuration) {
                self.runtimeConfiguration = configuration
                if let error = refresh.error {
                    self.runtimeConfigurationProjectionState = .stale(configuration, safeMessage: error)
                } else if !refresh.isLoading {
                    self.runtimeConfigurationProjectionState = .ready(configuration)
                }
            } else if let error = refresh.error {
                self.runtimeConfigurationProjectionState = Self.failedOrStale(
                    self.runtimeConfigurationProjectionState, safeMessage: error)
            } else if refresh.isLoading, self.runtimeConfiguration == nil {
                self.runtimeConfigurationProjectionState = .loading
            }
        }
        await refresh.refresh(force: force)
    }

    static func hasRuntimeConfigurationData(_ configuration: HermesRuntimeConfiguration) -> Bool {
        configuration.agentName != nil || configuration.model != nil || configuration.provider != nil
            || configuration.configPath != nil || configuration.maxTurns != nil || configuration.terminalTimeout != nil
            || !configuration.skills.isEmpty || !configuration.mcpServers.isEmpty || !configuration.plugins.isEmpty
    }

    enum RuntimeModelOptionsParseError: Error {
        case malformedResponse
    }

    func invalidateRuntimeModelOptionsRefresh() {
        runtimeModelOptionsRefreshGeneration &+= 1
        isLoadingRuntimeModelOptions = false
        runtimeModelOptionsError = nil
    }

    func refreshRuntimeModelOptions(sessionID: String? = nil) {
        runtimeModelOptionsRefreshGeneration += 1
        let generation = runtimeModelOptionsRefreshGeneration
        isLoadingRuntimeModelOptions = true
        runtimeModelOptionsError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let params = Self.runtimeModelOptionsRequest(sessionID: sessionID)
                let result = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.modelOptions.rawValue, params: params)
                guard generation == runtimeModelOptionsRefreshGeneration,
                    sessionID == nil || sessionID == self.sessionID
                else {
                    return
                }
                runtimeModelOptions = try Self.runtimeModelOptions(from: result)
                if sessionID == nil,
                    let provider = result["provider"] as? String,
                    let model = result["model"] as? String
                {
                    defaultModelOptionID = HermesModelOption(provider: provider, model: model).id
                }
                if let sessionID, sessionID == self.sessionID,
                    let provider = result["provider"] as? String,
                    let model = result["model"] as? String
                {
                    sessionModelOptionID = HermesModelOption(provider: provider, model: model).id
                    sessionModelValue = HermesModelOption(provider: provider, model: model).displayName
                } else if let sessionID, sessionID == self.sessionID,
                    let model = result["model"] as? String
                {
                    sessionModelValue = model
                }
            } catch {
                guard generation == runtimeModelOptionsRefreshGeneration,
                    sessionID == nil || sessionID == self.sessionID
                else {
                    return
                }
                runtimeModelOptionsError = "Hermes could not load its model catalog."
            }
            guard generation == runtimeModelOptionsRefreshGeneration,
                sessionID == nil || sessionID == self.sessionID
            else {
                return
            }
            isLoadingRuntimeModelOptions = false
        }
    }

    nonisolated static func runtimeModelOptionsRequest(sessionID: String?) -> [String: Any] {
        var params: [String: Any] = ["explicit_only": true]
        if let sessionID, !sessionID.isEmpty { params["session_id"] = sessionID }
        return params
    }

    nonisolated static func runtimeModelOptions(from result: [String: Any]) throws -> [HermesModelOption] {
        guard let providers = result["providers"] as? [[String: Any]] else {
            throw RuntimeModelOptionsParseError.malformedResponse
        }
        return try providers.flatMap { provider -> [HermesModelOption] in
            guard let name = (provider["slug"] as? String) ?? (provider["name"] as? String),
                !name.isEmpty,
                let models = provider["models"] as? [String],
                models.allSatisfy({ !$0.isEmpty })
            else {
                throw RuntimeModelOptionsParseError.malformedResponse
            }
            return models.map { HermesModelOption(provider: name, model: $0) }
        }
    }

    func refreshSessionModelOptions() {
        guard let sessionID, !sessionID.isEmpty else { return }
        refreshRuntimeModelOptions(sessionID: sessionID)
    }

    func refreshSessionReasoningVariant() {
        guard let sessionID, !sessionID.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await gateway.request(
                    HermesFeatureIDs.ID.configGet.rawValue,
                    params: [
                        "key": "reasoning",
                        "session_id": sessionID,
                    ])
                guard self.sessionID == sessionID,
                    let value = result["value"] as? String
                else { return }
                self.sessionReasoningVariant = HermesReasoningVariant(rawValue: value.lowercased())
            } catch {
                DebugLog.write(
                    "model: session reasoning lookup failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    /// New conversations inherit Hermes' global thinking default until they
    /// receive a session-specific override.
    func refreshDefaultReasoningVariant() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await gateway.request(
                    HermesFeatureIDs.ID.configGet.rawValue, params: globalConfigParams(["key": "reasoning"]))
                guard let value = result["value"] as? String else { return }
                defaultReasoningVariant = HermesReasoningVariant(rawValue: value.lowercased())
            } catch {
                DebugLog.write(
                    "model: default reasoning lookup failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    func updateRuntimeModel(_ option: HermesModelOption) {
        guard !isRuntimeModelMutationPending, !isLoadingRuntimeConfiguration else { return }
        isRuntimeModelMutationPending = true
        runtimeModelMutationError = nil
        isLoadingRuntimeConfiguration = true
        runtimeConfigurationError = nil

        Task { [weak self] in
            guard let self else { return }
            var updateError: String?
            do {
                // Hermes only persists `--global` through a live session. A
                // throwaway draft writes no DB row, so nothing reaches the sidebar.
                var createParams: [String: Any] = ["source": "dock-settings"]
                if let profileID = profileScopeID, !profileID.isEmpty {
                    createParams["profile"] = profileID
                }
                let created = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.sessionCreate.rawValue, params: createParams)
                guard let draftID = created["session_id"] as? String, !draftID.isEmpty else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                let request = Self.globalRuntimeModelSwitchRequest(option: option, sessionID: draftID)
                do {
                    _ = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.configSet.rawValue, params: request.parameters)
                } catch {
                    _ = try? await sessionRPCClient.request(
                        HermesFeatureIDs.ID.sessionClose.rawValue, params: ["session_id": draftID])
                    throw error
                }
                _ = try? await sessionRPCClient.request(
                    HermesFeatureIDs.ID.sessionClose.rawValue, params: ["session_id": draftID])
            } catch {
                updateError =
                    "Hermes could not apply the provider/model change: \(Self.safeUserDiagnostic(error.localizedDescription))"
                actionErrors.report("Could not change default model", error: error)
            }

            // The gateway is the sole writer. Re-read the persisted projection
            // afterward so settings reflect only what Hermes actually accepted.
            runtimeModelMutationError = updateError
            await loadRuntimeConfiguration(force: updateError == nil)
            runtimeConfigurationError = updateError ?? runtimeConfigurationRefresh.error
            isRuntimeModelMutationPending = false
            isLoadingRuntimeConfiguration = runtimeConfigurationRefresh.isLoading
        }
    }

    func updateSessionModel(_ option: HermesModelOption) {
        guard let sessionID, !sessionID.isEmpty else {
            // No session yet: hold the pick until createAuthorizedSession.
            sessionModelOptionID = option.id
            sessionModelValue = option.displayName
            return
        }
        guard !isUpdatingSessionModel else { return }
        let generation = sessionResumeGeneration
        let params = scopedSessionParams(
            Self.sessionRuntimeModelSwitchRequest(
                option: option, sessionID: sessionID, reasoning: sessionReasoningVariant
            ).parameters)
        isUpdatingSessionModel = true
        runtimeConfigurationError = nil

        Task { [weak self] in
            guard let self else { return }
            defer { self.isUpdatingSessionModel = false }
            do {
                let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.configSet.rawValue, params: params)
                guard self.sessionResumeGeneration == generation, self.sessionID == sessionID else { return }
                guard result["key"] as? String == "model", result["scope"] as? String == "session",
                    let value = result["value"] as? String, !value.isEmpty,
                    result["confirm_required"] as? Bool != true, result["deferred"] as? Bool != true
                else {
                    throw QuickDraftError.message(
                        "Hermes has not acknowledged the model change. Refresh before retrying.")
                }
                refreshSessionModelOptions()
            } catch {
                guard self.sessionResumeGeneration == generation, self.sessionID == sessionID else { return }
                runtimeConfigurationError =
                    "Hermes could not apply the session provider/model change: \(Self.safeUserDiagnostic(error.localizedDescription))"
                actionErrors.report("Could not change session model", error: error)
            }
            isUpdatingSessionModel = false
        }
    }

    func updateSessionReasoning(_ variant: HermesReasoningVariant) {
        guard let sessionID, !sessionID.isEmpty, !isUpdatingSessionReasoning else { return }
        isUpdatingSessionReasoning = true
        runtimeConfigurationError = nil

        Task { [weak self] in
            guard let self else { return }
            defer { self.isUpdatingSessionReasoning = false }
            do {
                _ = try await gateway.request(
                    HermesFeatureIDs.ID.configSet.rawValue,
                    params: [
                        "key": "reasoning",
                        "value": variant.rawValue,
                        "session_id": sessionID,
                    ])
                guard self.sessionID == sessionID else { return }
                self.sessionReasoningVariant = variant
                DebugLog.write("model: session reasoning set to \(variant.rawValue)")
            } catch {
                self.runtimeConfigurationError =
                    "Hermes could not apply the session reasoning change: \(Self.safeUserDiagnostic(error.localizedDescription))"
                actionErrors.report("Could not change session thinking level", error: error)
            }
        }
    }

    /// No session yet: hold the pick until createAuthorizedSession, which sends
    /// it as a per-session override (a sessionless config.set would rewrite the
    /// launch profile's global default instead).
    func updateDefaultReasoning(_ variant: HermesReasoningVariant) {
        defaultReasoningVariant = variant
    }

    /// Settings writes Hermes' global thinking default (`agent.reasoning_effort`).
    /// Open sessions keep their own override.
    func updateGlobalReasoning(_ variant: HermesReasoningVariant) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.configSet.rawValue,
                    params: globalConfigParams([
                        "key": "reasoning",
                        "value": variant.rawValue,
                        "scope": "global",
                    ]))
                defaultReasoningVariant = variant
            } catch {
                runtimeConfigurationError =
                    "Hermes could not save the default thinking level: \(Self.safeUserDiagnostic(error.localizedDescription))"
                actionErrors.report("Could not change default thinking level", error: error)
            }
        }
    }

    /// Settings target the launch profile, never the open session's profile.
    private func globalConfigParams(_ params: [String: Any]) -> [String: Any] {
        guard let profileID = profileScopeID, !profileID.isEmpty else { return params }
        return params.merging(["profile": profileID]) { _, new in new }
    }

    nonisolated static func globalRuntimeModelSwitchRequest(
        option: HermesModelOption,
        sessionID: String
    ) -> HermesRuntimeModelSwitchRequest {
        HermesRuntimeModelSwitchRequest(
            sessionID: sessionID,
            value: "\(option.model) --provider \(option.provider) --global"
        )
    }

    /// Hermes' switch re-resolves reasoning from config.yaml, so the session's
    /// thinking pick must ride along or the model change silently resets it.
    nonisolated static func sessionRuntimeModelSwitchRequest(
        option: HermesModelOption,
        sessionID: String,
        reasoning: HermesReasoningVariant? = nil
    ) -> HermesRuntimeModelSwitchRequest {
        let reasoningFlag = reasoning.map { " --reasoning \($0.rawValue)" } ?? ""
        return HermesRuntimeModelSwitchRequest(
            sessionID: sessionID,
            value: "\(option.model) --provider \(option.provider) --session\(reasoningFlag)"
        )
    }
}
