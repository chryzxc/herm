import Foundation

@MainActor
struct HermesReviewGuideReplyService {
    let client: HermesRPCClientProtocol
    func load(_ session: HermesSession) async throws -> String? {
        let result = try await HermesControlRPC(client: client).sessionMessages(
            sessionID: session.id, profileID: session.profileID)
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
        return text.isEmpty ? nil : text
    }
}
