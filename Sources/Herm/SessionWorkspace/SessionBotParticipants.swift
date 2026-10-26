import Foundation

/// Shared, evidence-based lookup for chat attribution and session participant lists.
/// Mentions in prose are not proof that a Bot participated.
enum SessionBotParticipants {
    struct Participant: Identifiable, Equatable {
        let id: String
        var name: String
        var messageIDs: [UUID]
        var requestIDs: [String]
        var dispatchIDs: [String]
    }

    static func authorID(_ message: ChatMessage, activeProfileID: String? = nil) -> String? {
        guard message.role != .user, message.systemEvent == nil, message.kanbanNotice == nil else { return nil }
        return message.botProfileID ?? activeProfileID
    }

    static func collect(
        messages: [ChatMessage], records: [BotActivityRecord] = [], activeProfileID: String? = nil
    ) -> [Participant] {
        var result: [Participant] = []
        var indices: [String: Int] = [:]
        var requestID: String?
        func index(_ id: String, name: String?) -> Int {
            if let existing = indices[id] {
                if let name, !name.isEmpty { result[existing].name = name }
                return existing
            }
            let value = result.count
            indices[id] = value
            result.append(Participant(id: id, name: name ?? id, messageIDs: [], requestIDs: [], dispatchIDs: []))
            return value
        }
        for message in messages {
            guard message.systemEvent == nil, message.kanbanNotice == nil else { continue }
            if message.role == .user && !message.isSteering { requestID = message.id.uuidString }
            // Explicit user attribution is a direct Bot request; assistant attribution is a reply.
            guard
                let id = message.role == .user
                    ? message.botProfileID : authorID(message, activeProfileID: activeProfileID),
                !id.isEmpty
            else { continue }
            let i = index(id, name: message.botDisplayName)
            result[i].messageIDs.append(message.id)
            if let requestID, !result[i].requestIDs.contains(requestID) { result[i].requestIDs.append(requestID) }
        }
        for record in records where !record.isKanbanReference {
            let i = index(record.botID, name: record.botName)
            if !result[i].dispatchIDs.contains(record.id) { result[i].dispatchIDs.append(record.id) }
        }
        return result
    }
}
