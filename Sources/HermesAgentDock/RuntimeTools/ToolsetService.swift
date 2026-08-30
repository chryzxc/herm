import Foundation

/// Bounded projection for the optional Hermes toolset contract.
/// Human-formatted CLI output is intentionally not accepted here.
struct ToolsetService {
    static func snapshot(from payload: [String: Any]) -> ToolsetSnapshot {
        let toolsets = parseToolsets(payload["toolsets"])
        let backends = RuntimeToolset.allCases.map { backendStatus(for: $0, payload: payload) }
        let session = (payload["active_session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolsetSnapshot(
            toolsets: toolsets,
            backends: backends,
            activeSessionID: session?.isEmpty == false ? session : nil,
            restartRequired: true
        )
    }

    /// There is no verified Hermes mutation contract in this Dock surface.
    /// Keep this API explicit so a future adapter cannot accidentally mutate an
    /// active conversation or pretend a local preference changed Hermes.
    static func requestChange(_ change: ToolsetChange, toolset: RuntimeToolset, snapshot: ToolsetSnapshot, confirmed: Bool = true) -> ToolsetChangeResult {
        guard confirmed else { return .confirmationRequired }
        return .unavailable("Toolset changes apply to the next session; the active conversation is unchanged.")
    }

    private static func parseToolsets(_ raw: Any?) -> [ToolsetEntry] {
        guard let values = raw as? [String: Any] else { return [] }
        return values.keys.sorted().compactMap { id in
            guard let value = values[id] as? [String: Any], let enabled = value["enabled"] as? Bool else { return nil }
            let detail = (value["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ToolsetEntry(id: id, isEnabled: enabled, detail: detail)
        }
    }

    private static func backendStatus(for toolset: RuntimeToolset, payload: [String: Any]) -> RuntimeBackendStatus {
        guard let value = payload["\(toolset.payloadKey)_backend"] as? [String: Any]
                ?? payload[toolset.payloadKey] as? [String: Any] else {
            return RuntimeBackendStatus(id: toolset, state: .unavailable, detail: "Hermes did not provide structured backend status.")
        }
        if value["supported"] as? Bool == false {
            return RuntimeBackendStatus(id: toolset, state: .unsupported, detail: "This Hermes version does not expose this backend.")
        }
        guard let configured = value["configured"] as? Bool ?? value["available"] as? Bool else {
            return RuntimeBackendStatus(id: toolset, state: .unavailable, detail: "Hermes backend status is incomplete.")
        }
        if configured == false {
            return RuntimeBackendStatus(id: toolset, state: .requiresSetup, detail: (value["detail"] as? String) ?? "This backend requires setup.")
        }
        if toolset == .browser || toolset == .computerUse {
            guard value["authorized"] as? Bool == true else {
                return RuntimeBackendStatus(id: toolset, state: .requiresSetup, detail: "Browser/computer-use authorization is required.")
            }
        }
        guard value["available"] as? Bool != false else {
            return RuntimeBackendStatus(id: toolset, state: .unavailable, detail: "Hermes reports this backend as unavailable.")
        }
        return RuntimeBackendStatus(id: toolset, state: .available, detail: (value["detail"] as? String) ?? "Backend is available.")
    }
}
