import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    func cacheCurrentAgentState() {
        // Subagent event storms called this per event; each call copies every
        // projection array and enqueues an encode/write. Coalesce to one
        // snapshot per interval with a trailing write for the last event.
        let now = Date()
        if let last = lastAgentStateCacheAt, now.timeIntervalSince(last) < 0.5 {
            if agentStateCacheTrailingTask == nil {
                agentStateCacheTrailingTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self else { return }
                    self.agentStateCacheTrailingTask = nil
                    self.writeAgentStateSnapshot()
                }
            }
            return
        }
        lastAgentStateCacheAt = now
        writeAgentStateSnapshot()
    }

    func writeAgentStateSnapshot() {
        lastAgentStateCacheAt = Date()
        guard let sessionStorageID else { return }
        let snapshot = agentStateBySessionID.merging([sessionStorageID: SessionAgentState(
            activeToolCalls: activeToolCalls,
            recentEvents: recentEvents,
            sessionAgents: sessionAgents,
            activeSubagents: activeSubagents,
            agentActivities: agentActivities,
            synthesizedSubagentIDs: synthesizedSubagentIDs
        )]) { _, new in new }
        Task { await agentStateWriter.enqueue(snapshot) }
    }

    func persistActiveSessionID(_ sessionID: String?) {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty else { return }
        defaults.set(sessionID, forKey: lastSessionIDKey(for: sessionProfileID ?? profileScopeID))
    }

    func lastSessionIDKey(for profileID: String?) -> String {
        let suffix = Self.normalizedProfileID(profileID) ?? "launch"
        return "\(lastSessionIDKey).\(suffix)"
    }

    static func normalizedProfileID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    func scopedSessionParams(_ params: [String: Any], profileID: String? = nil) -> [String: Any] {
        let scope = profileID ?? sessionProfileID ?? profileScopeID
        guard let scope, !scope.isEmpty else { return params }
        var scoped = params
        scoped["profile"] = scope
        return scoped
    }

    static func stableSessionID(from result: [String: Any]) -> String? {
        for key in ["session_key", "stored_session_id", "resumed"] {
            if let value = result[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    /// A resume response may legitimately carry a fresh runtime session id —
    /// a forked resumed conversation or the lazily created canonical Bot Chat
    /// resumed by title — but those responses alias the requested session
    /// through a storage key. Any other id (for example the gateway resolving
    /// resume to whichever session is currently responding) belongs to a
    /// different conversation and must not be adopted.
    static func resumeResponseProvesSessionOwnership(
        requestedSessionID: String,
        resolvedSessionID: String,
        result: [String: Any]
    ) -> Bool {
        let requested = requestedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedSessionID == requested { return true }
        if let storageAlias = stableSessionID(from: result),
           storageAlias.trimmingCharacters(in: .whitespacesAndNewlines) == requested {
            return true
        }
        return false
    }

    static func sessionAttributionID(runtimeID: String?, storageID: String?) -> String? {
        for candidate in [storageID, runtimeID] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Once Hermes accepts a resume, its resolved identifier is the identity
    /// that downstream runtime-owned records (including Kanban work) use.
    static func kanbanAttributionAfterResume(
        requestedSessionID: String,
        resolvedSessionID: String
    ) -> String {
        let resolved = resolvedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty { return resolved }
        return requestedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func kanbanAttributionID(
        requestedSessionID: String?,
        runtimeID: String?,
        storageID: String?
    ) -> String? {
        if let requestedSessionID = requestedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedSessionID.isEmpty {
            return requestedSessionID
        }
        return sessionAttributionID(runtimeID: runtimeID, storageID: storageID)
    }
}
