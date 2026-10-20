import Foundation

struct ConversationExcerptPage: Equatable, Sendable {
    let messages: [String]
    let partial: Bool
}

@MainActor
struct HermesConversationExcerptService {
    let client: HermesRPCClientProtocol
    func load(_ session: HermesSession) async throws -> ConversationExcerptPage {
        try Self.parse(
            await HermesControlRPC(client: client).sessionMessages(sessionID: session.id, profileID: session.profileID),
            session: session)
    }
    static func parse(_ result: [String: Any], session: HermesSession) throws -> ConversationExcerptPage {
        if let owner = result["session_id"] as? String, owner != session.id {
            throw HermesGateway.GatewayError.malformedResponse
        }
        if let profile = result["profile"] as? String, profile != (session.profileID ?? "default") {
            throw HermesGateway.GatewayError.malformedResponse
        }
        guard let rows = result["data"] as? [[String: Any]] ?? result["messages"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        let messages = rows.suffix(500).compactMap { row -> String? in
            guard let role = row["role"] as? String, ["user", "assistant", "hermes"].contains(role) else { return nil }
            let body: String?
            if let text = row["content"] as? String ?? row["text"] as? String {
                body = text
            } else if let blocks = row["content"] as? [[String: Any]] {
                body = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(
                    separator: "\n")
            } else {
                body = nil
            }
            guard let body, !body.isEmpty else { return nil }
            let projection =
                role == "user" ? GenerativeUIIntegration.displayUserText(body) : GenerativeUIIntegration.plainText(body)
            return role + ": " + String(projection.prefix(8_000))
        }
        return ConversationExcerptPage(messages: messages, partial: rows.count > 500)
    }
}
