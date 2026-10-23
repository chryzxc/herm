import Foundation

struct PullRequestChatMessage: Identifiable, Equatable {
    let id: String
    let isUser: Bool
    let text: String
}

struct PullRequestChatSnapshot: Equatable {
    let messages: [PullRequestChatMessage]
    let isRunning: Bool
    let needsAttention: Bool
}

@MainActor
struct HermesPullRequestChatService {
    let client: HermesRPCClientProtocol

    func load(_ destination: QuickDestination) async throws -> PullRequestChatSnapshot {
        guard let session = destination.session else { throw HermesGateway.GatewayError.malformedResponse }
        let active = try await client.request(HermesFeatureIDs.ID.sessionActiveList.rawValue,
            params: ["profile": destination.profileID ?? "default"])
        guard let sessions = active["sessions"] as? [[String: Any]] else { throw HermesGateway.GatewayError.malformedResponse }
        let row = sessions.first {
            let key = $0["session_key"] as? String ?? $0["session_id"] as? String
            return key == session.id || (destination.runtimeID != nil && key == destination.runtimeID)
        }
        let status = row?["status"] as? String
        let running = ["starting", "working", "waiting"].contains(status ?? "")
        do {
            let result = try await HermesControlRPC(client: client).sessionMessages(
                sessionID: session.id, profileID: session.profileID, latest: true, limit: 80)
            return try Self.parse(result, session: session, isRunning: running, needsAttention: status == "waiting")
        } catch HermesGateway.GatewayError.httpError(404) where running {
            return PullRequestChatSnapshot(messages: [], isRunning: true, needsAttention: status == "waiting")
        }
    }

    static func parse(_ result: [String: Any], session: HermesSession, isRunning: Bool, needsAttention: Bool = false) throws -> PullRequestChatSnapshot {
        if let owner = result["session_id"] as? String, owner != session.id { throw HermesGateway.GatewayError.malformedResponse }
        if let profile = result["profile"] as? String, profile != (session.profileID ?? "default") { throw HermesGateway.GatewayError.malformedResponse }
        guard let rows = result["data"] as? [[String: Any]] ?? result["messages"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        var bytes = 0
        let messages = try rows.suffix(80).enumerated().compactMap { index, row -> PullRequestChatMessage? in
            guard let role = row["role"] as? String, ["user", "assistant", "hermes"].contains(role),
                  (row["tool_calls"] as? [Any] ?? []).isEmpty else { return nil }
            var text = row["content"] as? String ?? row["text"] as? String
                ?? (row["content"] as? [[String: Any]] ?? []).compactMap {
                    $0["type"] as? String == "text" ? $0["text"] as? String : nil
                }.joined(separator: "\n")
            if role == "user", text.hasPrefix("<pull_request_context>\n"),
               let end = text.range(of: "\n</pull_request_context>\n\n", options: .backwards) {
                text = String(text[end.upperBound...])
            }
            text = role == "user" ? GenerativeUIIntegration.displayUserText(text) : GenerativeUIIntegration.plainText(text)
            bytes += text.utf8.count
            guard bytes <= 256_000 else { throw QuickDraftError.message("This conversation exceeds the preview limit. Open the conversation to continue.") }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let id = row["row_id"].map { String(describing: $0) } ?? row["id"].map { String(describing: $0) } ?? String(index)
            return PullRequestChatMessage(id: id + ":" + String(index), isUser: role == "user", text: text)
        }
        return PullRequestChatSnapshot(messages: messages, isRunning: isRunning, needsAttention: needsAttention)
    }
}
