import Foundation

@MainActor
struct HermesReviewGuideReplyService {
    let client: HermesRPCClientProtocol
    func load(_ session: HermesSession) async throws -> String? {
        let result: [String: Any]
        do {
            result = try await HermesControlRPC(client: client).sessionMessages(
                sessionID: session.id, profileID: session.profileID, latest: true)
        } catch HermesGateway.GatewayError.httpError(404) {
            // New conversations may not have persisted history while their first turn runs.
            var scope: [String: Any] = [:]
            if let profile = session.profileID { scope["profile"] = profile }
            let active = try? await client.request(HermesFeatureIDs.ID.sessionActiveList.rawValue, params: scope)
            let rows = active?["sessions"] as? [[String: Any]] ?? []
            guard
                rows.contains(where: {
                    $0["session_key"] as? String == session.id
                        && ["starting", "working", "waiting"].contains($0["status"] as? String ?? "")
                })
            else { throw HermesGateway.GatewayError.httpError(404) }
            return nil
        }
        if let owner = result["session_id"] as? String, owner != session.id {
            throw HermesGateway.GatewayError.malformedResponse
        }
        if let profile = result["profile"] as? String, profile != (session.profileID ?? "default") {
            throw HermesGateway.GatewayError.malformedResponse
        }
        guard let rows = result["data"] as? [[String: Any]] ?? result["messages"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        guard
            let row = rows.last(where: {
                ["assistant", "hermes"].contains($0["role"] as? String ?? "")
                    && ($0["tool_calls"] as? [Any] ?? []).isEmpty
            })
        else { return nil }
        let text =
            row["content"] as? String ?? row["text"] as? String
            ?? (row["content"] as? [[String: Any]] ?? []).compactMap {
                $0["type"] as? String == "text" ? $0["text"] as? String : nil
            }.joined(separator: "\n")
        guard text.utf8.count <= 256_000 else {
            throw QuickDraftError.message(
                "This guide exceeds the preview limit. Open its conversation to read the full reply.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
